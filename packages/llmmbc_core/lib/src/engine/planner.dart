import 'dart:math' as math;

import '../interfaces.dart';
import '../models.dart';

/// Deterministic, pure cluster planner.
///
/// Memory model: `weights + KV cache + 10% overhead`. The KV cache is
/// `blockCount * contextLength * embeddingLength * 2 * 2` bytes (K and V in
/// f16). The planned context is the model's context length capped at
/// [defaultContextLength] (4096).
///
/// Dense models get a proportional layer split. MoE models additionally keep
/// attention/shared tensors on the coordinator when they fit and spread the
/// `ffn_*_exps` tensors as contiguous layer ranges over the workers with
/// `--override-tensor` rules.
///
/// With [ClusterPlanner.plan]'s `allowExpertStreaming` (MoE only) the plan only
/// requires non-expert weights + KV to fit: expert layers are spread over all
/// nodes proportionally to their budgets, so a worker may hold more expert
/// bytes than its budget. Workers run `rpc-server --lazy-weights`, so those
/// bytes stay on disk until the router selects an expert (docs §2.4, §6.1).
class DefaultClusterPlanner implements ClusterPlanner {
  const DefaultClusterPlanner();

  /// Context used when the model does not advertise one (and the ceiling for
  /// models that advertise a larger one), see docs/ARCHITECTURE.md §9.
  static const int defaultContextLength = 4096;

  /// llama.cpp loads RPC devices *before* the local device, so the
  /// `--tensor-split` list is ordered `[rpc workers..., local coordinator]`.
  static const int memoryOverheadPercent = 10;

  @override
  ClusterPlan plan(LocalModel model, List<PlanNode> nodes,
      {bool allowExpertStreaming = false}) {
    _validateNodes(nodes);

    final metadata = model.metadata;
    final contextLength = _contextLength(metadata);
    final weights = _weightsBytes(model);
    final kvBytes = _kvBytes(metadata, contextLength);
    final totalWithOverhead = _withOverhead(weights + kvBytes);
    final blockCount =
        metadata != null && metadata.blockCount > 0 ? metadata.blockCount : 1;
    final isMoe = metadata != null &&
        metadata.isMoe &&
        metadata.expertTensorBytes > 0 &&
        metadata.expertTensorBytes < weights;
    // §2.4: with expert streaming, expert shards on the workers may exceed their
    // budgets (they stay on disk and are paged in on demand); non-expert weights
    // and KV still have to fit.
    final streaming = allowExpertStreaming && isMoe;
    final expertBytes =
        metadata == null ? 0 : math.min(metadata.expertTensorBytes, weights);
    final requiredWithOverhead = streaming
        ? _withOverhead(weights - expertBytes + kvBytes)
        : totalWithOverhead;

    final budgetSum = nodes.fold<int>(
        0, (a, n) => a + (n.budgetBytes > 0 ? n.budgetBytes : 0));
    if (budgetSum < requiredWithOverhead) {
      throw PlanError(
          'model does not fit in cluster memory: needs ${_fmt(requiredWithOverhead)}, '
          'cluster offers ${_fmt(budgetSum)}');
    }

    if (metadata == null) {
      return _planUnknownDense(model, nodes, totalWithOverhead, contextLength);
    }

    if (isMoe) {
      return _planMoe(
        model: model,
        nodes: nodes,
        metadata: metadata,
        weights: weights,
        kvBytes: kvBytes,
        totalWithOverhead: totalWithOverhead,
        blockCount: blockCount,
        contextLength: contextLength,
        allowExpertStreaming: streaming,
      );
    }
    return _planDense(
      model: model,
      nodes: nodes,
      totalWithOverhead: totalWithOverhead,
      blockCount: blockCount,
      contextLength: contextLength,
    );
  }

  @override
  List<String> llamaServerArgs(ClusterPlan plan) =>
      _llamaServerArgs(plan, 0, legacy: true);

  /// Model-aware variant used by `LlamaCppEngine`.
  ///
  /// With `--rpc` present, llama.cpp only offloads layers to RPC devices when
  /// `-ngl` is positive, and the local device's `--tensor-split` entry is
  /// ignored. To realize the plan we therefore:
  ///  * keep `blockCount - rpcLayers` repeating layers (and their KV) on the
  ///    coordinator by setting `-ngl = rpcLayers + 1` (llama.cpp counts the
  ///    output layer in `-ngl`; `0` keeps everything local, `999` offloads all),
  ///  * pass `--tensor-split` over the RPC devices only, using their planned
  ///    layer counts, so the offloaded layers land where the plan says.
  List<String> llamaServerArgsForModel(ClusterPlan plan, LocalModel model) =>
      _llamaServerArgs(plan, model.metadata?.blockCount ?? 0);

  List<String> _llamaServerArgs(ClusterPlan plan, int blockCount,
      {bool legacy = false}) {
    final rpcNodes = plan.nodes.where((n) => !n.isCoordinator).toList();
    final byNode = {for (final a in plan.assignments) a.nodeId: a};

    final rpcLayers = <int>[
      for (final n in rpcNodes)
        blockCount > 0
            ? ((byNode[n.nodeId]?.layerFraction ?? 0.0).clamp(0.0, 1.0) *
                    blockCount)
                .round()
            : 0,
    ];

    final rpcTotal = rpcLayers.fold<int>(0, (a, b) => a + b);
    final args = <String>[];
    if (rpcNodes.isNotEmpty) {
      args.addAll(['--rpc', rpcNodes.map((n) => n.rpcEndpoint!).join(',')]);
      // Tensor-split only has to describe the RPC devices; the coordinator's
      // share is whatever -ngl leaves on the local device. With no offloaded
      // layers (MoE attention on the coordinator) there is nothing to split.
      if (blockCount == 0 || rpcTotal > 0) {
        final splitCounts = [...rpcLayers];
        if (blockCount > 0 &&
            rpcTotal > 0 &&
            rpcTotal < blockCount &&
            splitCounts.isNotEmpty) {
          // The output layer is offloaded as part of -ngl but carries no KV;
          // giving the last RPC device the extra slot keeps the repeating-layer
          // split (and therefore the KV split) exactly at rpcLayers.
          splitCounts[splitCounts.length - 1]++;
        }
        final split = blockCount > 0
            ? _formatCounts(splitCounts)
            : _formatTensorSplit([
                for (final n in rpcNodes)
                  byNode[n.nodeId]?.layerFraction ?? 0.0,
              ]);
        args.addAll(['--tensor-split', split]);
      }
    }
    if (plan.tensorOverrides.isNotEmpty) {
      args.addAll(['--override-tensor', plan.tensorOverrides.join(',')]);
    }

    var ngl = blockCount == 0 ? (legacy ? 999 : 0) : 999;
    if (blockCount > 0) {
      ngl = rpcTotal <= 0
          ? 0
          : rpcTotal >= blockCount
              ? 999
              // llama.cpp counts the output layer as one offloaded layer.
              : rpcTotal + 1;
    }
    args.addAll([
      '-ngl',
      '$ngl',
      '-c',
      '${plan.contextLength}',
      '--jinja',
      // Qwen3-style templates otherwise put the whole completion budget in
      // reasoning_content, leaving message.content empty for clients.
      '--reasoning',
      'off',
      // Present since b4xxx; keep the server headless.
      '--no-webui',
    ]);
    return args;
  }

  String _formatCounts(List<int> counts) {
    if (counts.isEmpty) return '';
    // llama.cpp accepts proportions, not only percentages.
    return counts.map((c) => c <= 0 ? '0' : '$c').join(',');
  }

  // -------------------------------------------------------------------------
  // Dense
  // -------------------------------------------------------------------------

  ClusterPlan _planDense({
    required LocalModel model,
    required List<PlanNode> nodes,
    required int totalWithOverhead,
    required int blockCount,
    required int contextLength,
  }) {
    final caps = <String, int>{
      for (final n in nodes)
        n.nodeId: n.budgetBytes <= 0
            ? 0
            : math.min(
                blockCount, (n.budgetBytes * blockCount) ~/ totalWithOverhead),
    };
    final layers = _waterfill(
      nodes: nodes,
      caps: caps,
      count: blockCount,
      what: 'model does not fit in cluster memory: layer split is not feasible',
    );

    final active = [
      for (final n in nodes)
        if (n.isCoordinator || (layers[n.nodeId] ?? 0) > 0) n,
    ];
    final assignments = [
      for (final n in active)
        PlanAssignment(
          nodeId: n.nodeId,
          layerFraction: (layers[n.nodeId] ?? 0) / blockCount,
          estimatedBytes: _denseBytes(
              n, layers[n.nodeId] ?? 0, totalWithOverhead, blockCount),
        ),
    ];
    _verifyBudgets(active, assignments, 'does not fit');
    return ClusterPlan(
      model: model.ref,
      nodes: active,
      assignments: assignments,
      contextLength: contextLength,
    );
  }

  int _denseBytes(
      PlanNode node, int layers, int totalWithOverhead, int blockCount) {
    if (layers <= 0) return 0;
    return (totalWithOverhead * layers + blockCount - 1) ~/ blockCount;
  }

  /// No metadata: treat the file as a single dense blob and split it by budget.
  ClusterPlan _planUnknownDense(LocalModel model, List<PlanNode> nodes,
      int totalWithOverhead, int contextLength) {
    final usable = [
      for (final n in nodes)
        if (n.budgetBytes > 0 || n.isCoordinator) n,
    ];
    final budgetSum =
        usable.fold<int>(0, (a, n) => a + math.max(0, n.budgetBytes));
    if (budgetSum < totalWithOverhead) {
      throw PlanError(
          'model does not fit in cluster memory: needs ${_fmt(totalWithOverhead)}, '
          'cluster offers ${_fmt(budgetSum)}');
    }

    final allocated = <String, int>{
      for (final n in usable)
        n.nodeId: n.budgetBytes <= 0
            ? 0
            : (totalWithOverhead * n.budgetBytes) ~/ budgetSum,
    };
    var remaining =
        totalWithOverhead - allocated.values.fold<int>(0, (a, b) => a + b);
    // Rounding remainder goes to nodes with slack, largest budget first.
    final bySlack = [...usable]..sort((a, b) {
        final slackA = math.max(0, a.budgetBytes) - (allocated[a.nodeId] ?? 0);
        final slackB = math.max(0, b.budgetBytes) - (allocated[b.nodeId] ?? 0);
        final c = slackB.compareTo(slackA);
        return c != 0 ? c : a.nodeId.compareTo(b.nodeId);
      });
    for (final n in bySlack) {
      if (remaining <= 0) break;
      final slack = math.max(0, n.budgetBytes) - (allocated[n.nodeId] ?? 0);
      final add = math.min(slack, remaining);
      allocated[n.nodeId] = (allocated[n.nodeId] ?? 0) + add;
      remaining -= add;
    }
    if (remaining > 0) {
      throw PlanError(
          'model does not fit in cluster memory: assignment rounding failed');
    }

    final assignments = [
      for (final n in usable)
        PlanAssignment(
          nodeId: n.nodeId,
          layerFraction: totalWithOverhead == 0
              ? 0.0
              : allocated[n.nodeId]! / totalWithOverhead,
          estimatedBytes: allocated[n.nodeId]!,
        ),
    ];
    _verifyBudgets(usable, assignments, 'does not fit');
    return ClusterPlan(
        model: model.ref,
        nodes: usable,
        assignments: assignments,
        contextLength: contextLength);
  }

  // -------------------------------------------------------------------------
  // MoE
  // -------------------------------------------------------------------------

  ClusterPlan _planMoe({
    required LocalModel model,
    required List<PlanNode> nodes,
    required GgufMetadata metadata,
    required int weights,
    required int kvBytes,
    required int totalWithOverhead,
    required int blockCount,
    required int contextLength,
    required bool allowExpertStreaming,
  }) {
    final expertBytes = math.min(metadata.expertTensorBytes, weights);
    final nonExpertBytes = weights - expertBytes;
    if (expertBytes <= 0 || nonExpertBytes <= 0) {
      return _planDense(
        model: model,
        nodes: nodes,
        totalWithOverhead: totalWithOverhead,
        blockCount: blockCount,
        contextLength: contextLength,
      );
    }

    final coordinator = nodes.firstWhere((n) => n.isCoordinator);

    // 1. Attention/shared tensors: fill the coordinator first ("when it fits"),
    //    then spread the rest over workers proportional to budget.
    final attentionTotal = _withOverhead(nonExpertBytes + kvBytes);
    final attentionCap = <String, int>{
      for (final n in nodes)
        n.nodeId: n.budgetBytes <= 0
            ? 0
            : math.min(
                blockCount, (n.budgetBytes * blockCount) ~/ attentionTotal),
    };
    var coordinatorAttention =
        math.min(blockCount, attentionCap[coordinator.nodeId] ?? 0);
    final attentionLayers = <String, int>{
      for (final n in nodes) n.nodeId: 0,
    };
    attentionLayers[coordinator.nodeId] = coordinatorAttention;

    if (coordinatorAttention < blockCount) {
      final rest = _waterfill(
        nodes: [
          for (final n in nodes)
            if (!n.isCoordinator) n
        ],
        caps: attentionCap,
        count: blockCount - coordinatorAttention,
        what:
            'model does not fit in cluster memory: attention tensors do not fit',
        seed: attentionLayers,
      );
      attentionLayers.addAll(rest);
      coordinatorAttention = attentionLayers[coordinator.nodeId] ?? 0;
    }

    // 2. Expert tensors: prefer the normal capacity-based split. With expert streaming
    //    (§2.4) fall back to spreading every expert layer over the workers in proportion
    //    to their budgets, allowing them to exceed it. Streaming experts live on workers
    //    only: they are the nodes that run `rpc-server --lazy-weights`, while the
    //    coordinator keeps attention/KV locally.
    //    Streaming is a relaxation, never a requirement: when the normal split fits, or
    //    when no worker lends memory (single node, all workers at zero budget), the plan
    //    is exactly the one produced with the flag off.
    final streamingWorkers = [
      for (final n in nodes)
        if (!n.isCoordinator && n.budgetBytes > 0) n,
    ];

    Map<String, int>? normalExpertLayers;
    if (!allowExpertStreaming || streamingWorkers.isEmpty) {
      normalExpertLayers = _normalExpertLayers(
        nodes: nodes,
        attentionLayers: attentionLayers,
        expertBytes: expertBytes,
        nonExpertBytes: nonExpertBytes,
        kvBytes: kvBytes,
        blockCount: blockCount,
      );
    } else {
      try {
        normalExpertLayers = _normalExpertLayers(
          nodes: nodes,
          attentionLayers: attentionLayers,
          expertBytes: expertBytes,
          nonExpertBytes: nonExpertBytes,
          kvBytes: kvBytes,
          blockCount: blockCount,
        );
      } on PlanError {
        // Experts do not fit the workers' remaining budgets: stream them instead.
        normalExpertLayers = null;
      }
    }
    final streaming = normalExpertLayers == null;
    final expertLayers = streaming
        ? <String, int>{
            for (final n in nodes) n.nodeId: 0,
            ..._spreadByBudget(streamingWorkers, blockCount),
          }
        : normalExpertLayers;

    // 3. Assign contiguous layer ranges and per-node bytes.
    final overrides = <String>[];
    final assignments = <PlanAssignment>[];
    var layerCursor = 0;
    for (final n in nodes) {
      final attention = attentionLayers[n.nodeId] ?? 0;
      final experts = expertLayers[n.nodeId] ?? 0;
      final bytes = _attentionBytes(
              n, attention, nonExpertBytes, kvBytes, blockCount) +
          _withOverhead((expertBytes * experts + blockCount - 1) ~/ blockCount);
      final fraction = blockCount == 0 ? 0.0 : attention / blockCount;
      assignments.add(PlanAssignment(
        nodeId: n.nodeId,
        layerFraction: fraction,
        estimatedBytes: bytes,
      ));
      if (experts > 0) {
        final start = layerCursor;
        final end = start + experts - 1;
        // llama.cpp names an RPC buffer type `RPC<remote-device-index>[host:port]`;
        // the bundled rpc-server exposes one CPU device, hence RPC0. The pinned
        // tag (b12360) rejects the older `RPC[host:port]` spelling.
        final device = n.isCoordinator ? 'CPU' : 'RPC0[${n.rpcEndpoint}]';
        overrides.add('${_layerRangeRegex(start, end)}=$device');
        layerCursor += experts;
      }
    }

    final active = [
      for (var i = 0; i < nodes.length; i++)
        if (nodes[i].isCoordinator ||
            assignments[i].layerFraction > 0 ||
            (expertLayers[nodes[i].nodeId] ?? 0) > 0)
          nodes[i],
    ];
    final activeAssignments = [
      for (var i = 0; i < nodes.length; i++)
        if (active.contains(nodes[i])) assignments[i],
    ];
    if (streaming) {
      // Only non-expert weights + KV have to fit; a worker's expert shard may exceed
      // its budget. The coordinator holds no experts, so its full estimate is checked.
      final hardBytes = <String, int>{};
      for (var i = 0; i < nodes.length; i++) {
        final n = nodes[i];
        if (!active.contains(n)) continue;
        hardBytes[n.nodeId] = n.isCoordinator
            ? assignments[i].estimatedBytes
            : _attentionBytes(n, attentionLayers[n.nodeId] ?? 0, nonExpertBytes,
                kvBytes, blockCount);
      }
      _verifyBudgets(active, activeAssignments, 'does not fit',
          hardBytes: hardBytes);
    } else {
      _verifyBudgets(active, activeAssignments, 'does not fit');
    }

    // Non-coordinator nodes that only hold expert shards still need a positive
    // layer fraction so they are not dropped by consumers that filter zero
    // assignments; keep their attention fraction (0 is meaningful: attention on
    // the coordinator). Their expert shard is encoded in tensorOverrides.
    return ClusterPlan(
      model: model.ref,
      nodes: active,
      assignments: activeAssignments,
      tensorOverrides: overrides,
      contextLength: contextLength,
    );
  }

  /// Capacity-based expert allocation: every node gets expert layers for the
  /// budget it has left after attention/KV. Throws [PlanError] when all layers
  /// cannot be placed this way (the caller may then stream them).
  Map<String, int> _normalExpertLayers({
    required List<PlanNode> nodes,
    required Map<String, int> attentionLayers,
    required int expertBytes,
    required int nonExpertBytes,
    required int kvBytes,
    required int blockCount,
  }) {
    final expertLayerCost =
        _withOverhead((expertBytes + blockCount - 1) ~/ blockCount);
    final expertCaps = <String, int>{};
    for (final n in nodes) {
      final used = _attentionBytes(n, attentionLayers[n.nodeId] ?? 0,
          nonExpertBytes, kvBytes, blockCount);
      final available = math.max(0, n.budgetBytes - used);
      expertCaps[n.nodeId] = available ~/ expertLayerCost;
    }
    return _waterfill(
      nodes: nodes,
      caps: expertCaps,
      count: blockCount,
      what: 'model does not fit in cluster memory: expert tensors do not fit',
    );
  }

  int _attentionBytes(PlanNode node, int attentionLayers, int nonExpertBytes,
      int kvBytes, int blockCount) {
    if (attentionLayers <= 0) return 0;
    final bytes =
        (nonExpertBytes * attentionLayers + blockCount - 1) ~/ blockCount +
            (kvBytes * attentionLayers + blockCount - 1) ~/ blockCount;
    return _withOverhead(bytes);
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  void _validateNodes(List<PlanNode> nodes) {
    if (nodes.isEmpty) {
      throw PlanError('model does not fit in cluster memory: no nodes');
    }
    final coordinators = nodes.where((n) => n.isCoordinator).length;
    if (coordinators != 1) {
      throw PlanError('plan needs exactly one coordinator, got $coordinators');
    }
    final ids = <String>{};
    final endpoints = <String>{};
    for (final n in nodes) {
      if (!ids.add(n.nodeId)) {
        throw PlanError('duplicate plan node ${n.nodeId}');
      }
      final endpoint = n.rpcEndpoint;
      if (endpoint != null && !endpoints.add(endpoint)) {
        throw PlanError('duplicate RPC endpoint $endpoint');
      }
    }
  }

  int _contextLength(GgufMetadata? metadata) {
    final modelCtx = metadata?.contextLength ?? 0;
    if (modelCtx <= 0) return defaultContextLength;
    return math.min(modelCtx, defaultContextLength);
  }

  int _weightsBytes(LocalModel model) {
    final meta = model.metadata;
    if (meta == null) return model.sizeBytes;
    return meta.totalTensorBytes > 0 ? meta.totalTensorBytes : model.sizeBytes;
  }

  int _kvBytes(GgufMetadata? metadata, int contextLength) {
    if (metadata == null ||
        metadata.blockCount <= 0 ||
        metadata.embeddingLength <= 0) {
      return 0;
    }
    // K and V, f16 (2 bytes each): 2 * 2 * embeddingLength per layer per token.
    return metadata.blockCount * contextLength * metadata.embeddingLength * 4;
  }

  int _withOverhead(int bytes) {
    if (bytes <= 0) return 0;
    final numerator = bytes * (100 + memoryOverheadPercent);
    return (numerator + 99) ~/ 100;
  }

  /// Distributes [count] layers over [nodes], proportionally to each node's
  /// capacity ([caps]). Deterministic: ties prefer the coordinator, then the
  /// lexicographically smallest nodeId.
  Map<String, int> _waterfill({
    required List<PlanNode> nodes,
    required Map<String, int> caps,
    required int count,
    required String what,
    Map<String, int>? seed,
  }) {
    if (nodes.isEmpty) {
      if (count == 0) return {};
      throw PlanError(what);
    }
    final layers = <String, int>{
      for (final n in nodes) n.nodeId: seed?[n.nodeId] ?? 0,
    };
    for (var i = 0; i < count; i++) {
      PlanNode? best;
      var bestScore = -1.0;
      for (final n in nodes) {
        final cap = caps[n.nodeId] ?? 0;
        final have = layers[n.nodeId] ?? 0;
        if (have >= cap) continue;
        // cap/(have+1) is a proportional water-filling score: nodes with more
        // room get layers first, but everyone with room gets one before a large
        // node gets its second.
        final score = cap / (have + 1);
        if (score > bestScore || (score == bestScore && _precedes(n, best))) {
          best = n;
          bestScore = score;
        }
      }
      if (best == null) throw PlanError(what);
      layers[best.nodeId] = (layers[best.nodeId] ?? 0) + 1;
    }
    return layers;
  }

  bool _precedes(PlanNode candidate, PlanNode? current) {
    if (current == null) return true;
    if (candidate.isCoordinator != current.isCoordinator) {
      return candidate.isCoordinator;
    }
    return candidate.nodeId.compareTo(current.nodeId) < 0;
  }

  /// Expert streaming: distributes [count] expert layers proportionally to each node's
  /// budget, ignoring spare capacity. Largest-remainder rounding keeps it deterministic
  /// and covers every layer exactly once.
  Map<String, int> _spreadByBudget(List<PlanNode> nodes, int count) {
    final budgets = {
      for (final n in nodes) n.nodeId: math.max(0, n.budgetBytes),
    };
    final sum = budgets.values.fold<int>(0, (a, b) => a + b);
    if (sum <= 0 || count <= 0) {
      throw PlanError(
          'model does not fit in cluster memory: no budget for expert shards');
    }
    final layers = {
      for (final n in nodes) n.nodeId: (count * budgets[n.nodeId]!) ~/ sum,
    };
    var remaining = count - layers.values.fold<int>(0, (a, b) => a + b);
    final order = [...nodes]..sort((a, b) {
        final remainderA = (count * budgets[a.nodeId]!) % sum;
        final remainderB = (count * budgets[b.nodeId]!) % sum;
        final byRemainder = remainderB.compareTo(remainderA);
        if (byRemainder != 0) return byRemainder;
        if (a.isCoordinator != b.isCoordinator) return a.isCoordinator ? -1 : 1;
        return a.nodeId.compareTo(b.nodeId);
      });
    for (var i = 0; remaining > 0; i = (i + 1) % order.length) {
      final node = order[i];
      layers[node.nodeId] = layers[node.nodeId]! + 1;
      remaining--;
    }
    return layers;
  }

  void _verifyBudgets(
      List<PlanNode> nodes, List<PlanAssignment> assignments, String reason,
      {Map<String, int>? hardBytes}) {
    final budgets = {for (final n in nodes) n.nodeId: n.budgetBytes};
    for (final a in assignments) {
      final budget = budgets[a.nodeId] ?? 0;
      final bytes = hardBytes?[a.nodeId] ?? a.estimatedBytes;
      if (bytes > budget) {
        throw PlanError('model does not fit in cluster memory ($reason): '
            'node ${a.nodeId} needs ${_fmt(bytes)}, budget ${_fmt(budget)}');
      }
    }
    final sum = assignments.fold<double>(0, (a, x) => a + x.layerFraction);
    if (assignments.isNotEmpty && (sum - 1.0).abs() > 1e-6) {
      throw PlanError('internal planner error: layer fractions sum to $sum');
    }
  }

  String _layerRangeRegex(int start, int end) {
    final layers = [for (var i = start; i <= end; i++) '$i'].join('|');
    return r'blk\.(' + layers + r')\.ffn_.*_exps\.';
  }

  /// Integer percentages summing to 100, in device order.
  String _formatTensorSplit(List<double> fractions) {
    if (fractions.isEmpty) return '';
    final total = fractions.fold<double>(0, (a, f) => a + (f > 0 ? f : 0));
    if (total <= 0) return List.filled(fractions.length, '0').join(',');
    final scaled = [for (final f in fractions) (f > 0 ? f : 0) * 100 / total];
    final values = [for (final v in scaled) v.floor()];
    var remaining = 100 - values.fold<int>(0, (a, v) => a + v);
    final order = List<int>.generate(fractions.length, (i) => i)
      ..sort((a, b) {
        final byFraction = (scaled[b] - scaled[b].floor())
            .compareTo(scaled[a] - scaled[a].floor());
        return byFraction != 0 ? byFraction : a.compareTo(b);
      });
    for (final i in order) {
      if (remaining <= 0) break;
      values[i]++;
      remaining--;
    }
    return values.join(',');
  }

  String _fmt(int bytes) {
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }
}

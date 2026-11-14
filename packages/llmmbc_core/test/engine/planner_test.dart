import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:test/test.dart';

const int _mib = 1024 * 1024;
const int _gib = 1024 * 1024 * 1024;

GgufMetadata denseMeta({
  int blockCount = 28,
  int embeddingLength = 1024,
  int contextLength = 4096,
  int totalTensorBytes = 500 * _mib,
}) =>
    GgufMetadata(
      architecture: 'qwen3',
      blockCount: blockCount,
      embeddingLength: embeddingLength,
      contextLength: contextLength,
      totalTensorBytes: totalTensorBytes,
    );

GgufMetadata moeMeta({
  int blockCount = 48,
  int embeddingLength = 2048,
  int contextLength = 32768,
  int totalTensorBytes = 10 * _gib,
  int expertTensorBytes = 8 * _gib,
}) =>
    GgufMetadata(
      architecture: 'qwen3moe',
      blockCount: blockCount,
      expertCount: 128,
      expertUsedCount: 8,
      embeddingLength: embeddingLength,
      contextLength: contextLength,
      totalTensorBytes: totalTensorBytes,
      expertTensorBytes: expertTensorBytes,
    );

LocalModel model(GgufMetadata? metadata, {int sizeBytes = 500 * _mib}) =>
    LocalModel(
      ref: ModelRef.parse('test:model'),
      ggufPath: '/tmp/test.gguf',
      sizeBytes: sizeBytes,
      metadata: metadata,
    );

PlanNode coordinator(int budget) =>
    PlanNode(nodeId: 'coordinator', rpcEndpoint: null, budgetBytes: budget);

PlanNode worker(String id, int budget,
        {String host = '10.0.0.2', int port = 50052}) =>
    PlanNode(nodeId: id, rpcEndpoint: '$host:$port', budgetBytes: budget);

void main() {
  const planner = DefaultClusterPlanner();

  group('dense planning', () {
    test('single node gets the whole model', () {
      final m = model(denseMeta());
      final plan = planner.plan(m, [coordinator(4 * _gib)]);
      expect(plan.nodes, hasLength(1));
      expect(plan.assignments.single.layerFraction, 1.0);
      expect(
          plan.assignments.single.estimatedBytes, lessThanOrEqualTo(4 * _gib));
      expect(plan.contextLength, 4096);
      expect(plan.tensorOverrides, isEmpty);
    });

    test('two equal nodes split layers evenly', () {
      final plan = planner.plan(model(denseMeta()), [
        coordinator(2 * _gib),
        worker('w1', 2 * _gib),
      ]);
      expect(plan.nodes, hasLength(2));
      expect(plan.assignments.map((a) => a.layerFraction), [0.5, 0.5]);
      expect(
          plan.assignments.fold<double>(0, (a, x) => a + x.layerFraction), 1.0);
    });

    test('three nodes split proportionally; coordinator wins ties', () {
      final plan = planner.plan(model(denseMeta()), [
        coordinator(2 * _gib),
        worker('w1', 2 * _gib),
        worker('w2', 2 * _gib, host: '10.0.0.3', port: 50053),
      ]);
      expect(plan.nodes, hasLength(3));
      final fractions = plan.assignments.map((a) => a.layerFraction).toList();
      expect(fractions.fold<double>(0, (a, x) => a + x), closeTo(1.0, 1e-9));
      // 28 layers over 3 nodes: 10/9/9, coordinator gets the odd layer.
      expect(fractions[0], closeTo(10 / 28, 1e-9));
      expect(fractions[1], closeTo(9 / 28, 1e-9));
      expect(fractions[2], closeTo(9 / 28, 1e-9));
    });

    test('budget-proportional split', () {
      // 700 + 400 MiB is just above the 1.09 GiB estimate, so layer caps are
      // 18 and 10: the split follows the budgets.
      final plan = planner.plan(model(denseMeta()), [
        coordinator(700 * _mib),
        worker('w1', 400 * _mib),
      ]);
      expect(plan.assignments[0].layerFraction, closeTo(18 / 28, 1e-9));
      expect(plan.assignments[1].layerFraction, closeTo(10 / 28, 1e-9));
    });

    test('drops a node that would get less than one layer', () {
      final plan = planner.plan(model(denseMeta()), [
        coordinator(4 * _gib),
        worker('tiny', 1 * _mib),
      ]);
      expect(plan.nodes.map((n) => n.nodeId), ['coordinator']);
      expect(plan.assignments.single.layerFraction, 1.0);
    });

    test('throws does-not-fit when cluster memory is insufficient', () {
      expect(
        () => planner.plan(model(denseMeta()), [coordinator(300 * _mib)]),
        throwsA(isA<PlanError>()
            .having((e) => e.message, 'message', contains('does not fit'))),
      );
    });

    test('throws when layer granularity makes a fitting total unplaceable', () {
      // 28 layers, two nodes with 0.6 / 0.4 of the exact total: each cap is
      // 16/11 layers < 28, so no per-layer assignment stays within budget.
      final m = model(denseMeta(embeddingLength: 0));
      final total = planner
          .plan(m, [coordinator(_gib)])
          .assignments
          .single
          .estimatedBytes;
      expect(
        () => planner.plan(
            m, [coordinator(total * 6 ~/ 10), worker('w', total * 4 ~/ 10)]),
        throwsA(isA<PlanError>()),
      );
    });

    test('exact fit is accepted', () {
      final m = model(denseMeta(embeddingLength: 0, totalTensorBytes: 1000000));
      // 10% overhead -> 1_100_000.
      final plan = planner.plan(m, [coordinator(550000), worker('w', 550000)]);
      expect(plan.assignments.map((a) => a.layerFraction), [0.5, 0.5]);
      for (final a in plan.assignments) {
        expect(a.estimatedBytes, lessThanOrEqualTo(550000));
      }
    });

    test('unknown metadata is split by budget', () {
      // 100 MiB + 10% overhead = 110 MiB.
      final m = model(null, sizeBytes: 100 * _mib);
      final plan =
          planner.plan(m, [coordinator(66 * _mib), worker('w', 44 * _mib)]);
      expect(plan.assignments.map((a) => a.layerFraction),
          [closeTo(0.6, 1e-9), closeTo(0.4, 1e-9)]);
      expect(plan.contextLength, 4096);
      expect(plan.assignments[0].estimatedBytes, 66 * _mib);
      expect(plan.assignments[1].estimatedBytes, 44 * _mib);
    });

    test('context length is capped at 4096 but respects smaller model windows',
        () {
      expect(
          planner.plan(model(denseMeta(contextLength: 32768)),
              [coordinator(8 * _gib)]).contextLength,
          4096);
      expect(
          planner.plan(model(denseMeta(contextLength: 2048)),
              [coordinator(8 * _gib)]).contextLength,
          2048);
      expect(
          planner.plan(model(denseMeta(contextLength: 0)),
              [coordinator(8 * _gib)]).contextLength,
          4096);
    });
  });

  group('MoE planning', () {
    test(
        'attention stays on the coordinator when it fits; experts spread over all nodes',
        () {
      final m = model(moeMeta());
      final plan = planner.plan(m, [
        coordinator(16 * _gib),
        worker('w1', 8 * _gib),
        worker('w2', 8 * _gib, host: '10.0.0.3', port: 50053),
      ]);

      // All attention/shared layers on the coordinator -> local tensor share.
      expect(plan.assignments[0].layerFraction, 1.0);
      expect(plan.assignments[1].layerFraction, 0.0);
      expect(plan.assignments[2].layerFraction, 0.0);

      // Expert ranges cover every layer exactly once across the three nodes.
      final ranges = _parseRanges(plan.tensorOverrides);
      expect(_allLayers(ranges), List.generate(48, (i) => i));
      expect(ranges.first.layers.first, 0,
          reason: 'first range starts at layer 0');
      expect(ranges.last.layers.last, 47,
          reason: 'last range ends at layer 47');
      expect(ranges.where((r) => r.device == 'CPU'), hasLength(1));
      expect(ranges.where((r) => r.device == 'RPC0[10.0.0.2:50052]'),
          hasLength(1));
      expect(ranges.where((r) => r.device == 'RPC0[10.0.0.3:50053]'),
          hasLength(1));

      for (final a in plan.assignments) {
        final node = plan.nodes.firstWhere((n) => n.nodeId == a.nodeId);
        expect(a.estimatedBytes, lessThanOrEqualTo(node.budgetBytes));
      }
      expect(
          plan.assignments.fold<double>(0, (a, x) => a + x.layerFraction), 1.0);
      expect(plan.contextLength, 4096);
    });

    test(
        'when attention does not fit on the coordinator it is spread to workers',
        () {
      final plan = planner.plan(model(moeMeta()), [
        coordinator(1 * _gib),
        worker('w1', 12 * _gib),
        worker('w2', 12 * _gib, host: '10.0.0.3', port: 50053),
      ]);
      final attention = plan.assignments.map((a) => a.layerFraction).toList();
      expect(attention[0], greaterThan(0));
      expect(attention[0], lessThan(1));
      expect(attention.fold<double>(0, (a, x) => a + x), closeTo(1.0, 1e-9));
      expect(attention[1], greaterThan(0));
      expect(attention[2], greaterThan(0));
      // Expert ranges still cover all layers.
      final ranges = _parseRanges(plan.tensorOverrides);
      expect(_allLayers(ranges), List.generate(48, (i) => i));
    });

    test('throws does-not-fit when the cluster is too small', () {
      expect(
        () => planner.plan(
            model(moeMeta()), [coordinator(1 * _gib), worker('w', 1 * _gib)]),
        throwsA(isA<PlanError>()
            .having((e) => e.message, 'message', contains('does not fit'))),
      );
    });

    test('expert streaming lets expert shards exceed the worker budget', () {
      // non-expert + KV ~= 2.6 GiB, so a 3 GiB cluster can host attention but
      // not the 8 GiB of experts.
      final meta = GgufMetadata(
        architecture: 'qwen3moe',
        blockCount: 24,
        expertCount: 64,
        expertUsedCount: 8,
        embeddingLength: 1024,
        contextLength: 4096,
        totalTensorBytes: 10 * _gib,
        expertTensorBytes: 8 * _gib,
      );
      final m = model(meta);
      final nodes = [
        coordinator(2 * _gib),
        worker('w1', 512 * _mib),
        worker('w2', 512 * _mib, host: '10.0.0.3', port: 50053),
      ];

      expect(
          () => planner.plan(m, nodes),
          throwsA(isA<PlanError>()
              .having((e) => e.message, 'message', contains('does not fit'))));

      final plan = planner.plan(m, nodes, allowExpertStreaming: true);
      expect(plan.nodes, hasLength(3));
      expect(plan.assignments.fold<double>(0, (a, x) => a + x.layerFraction),
          closeTo(1.0, 1e-9),
          reason: 'all attention layers and KV still have to be placed');

      final ranges = _parseRanges(plan.tensorOverrides);
      expect(_allLayers(ranges), List.generate(24, (i) => i),
          reason: 'all expert layers are covered exactly once');

      // Every worker holds more expert bytes than its own budget.
      for (final node in plan.nodes.where((n) => !n.isCoordinator)) {
        final assignment =
            plan.assignments.firstWhere((a) => a.nodeId == node.nodeId);
        expect(assignment.estimatedBytes, greaterThan(node.budgetBytes),
            reason:
                'worker ${node.nodeId} should stream experts past its budget');
      }
      // No cluster-wide fit requirement remains: the plan succeeds even though
      // the weights are larger than the sum of every budget.
      expect(10 * _gib, greaterThan(3 * _gib));
    });

    test('expert streaming spreads expert layers proportionally to budget', () {
      // Attention (~3.85 GiB) fits the coordinator, but the experts do not:
      // the workers (1 and 2 GiB) are forced to stream them.
      final m = model(moeMeta());
      final nodes = [
        coordinator(4 * _gib),
        worker('w1', 1 * _gib),
        worker('w2', 2 * _gib, host: '10.0.0.3', port: 50053),
      ];
      expect(() => planner.plan(m, nodes), throwsA(isA<PlanError>()));

      final plan = planner.plan(m, nodes, allowExpertStreaming: true);
      // 48 expert layers over the two workers (1 and 2 GiB): 16 and 32.
      final ranges = _parseRanges(plan.tensorOverrides);
      final byDevice = {
        for (final r in ranges) r.device: r.layers.length,
      };
      expect(byDevice, isNot(contains('CPU')),
          reason: 'streamed experts live on workers only');
      expect(byDevice['RPC0[10.0.0.2:50052]'], 16);
      expect(byDevice['RPC0[10.0.0.3:50053]'], 32);
      expect(_allLayers(ranges), List.generate(48, (i) => i));
    });

    test('expert streaming on a single node plans like the flag being off', () {
      final m = model(moeMeta());
      final nodes = [coordinator(16 * _gib)];
      final plain = planner.plan(m, nodes);
      final streaming = planner.plan(m, nodes, allowExpertStreaming: true);
      _expectSamePlan(plain, streaming);
      // No worker exists, so the experts stay on the coordinator's CPU buffer.
      expect(_parseRanges(plain.tensorOverrides).single.device, 'CPU');
    });

    test(
        'expert streaming with only zero-budget workers plans like the flag off',
        () {
      final m = model(moeMeta());
      final nodes = [
        coordinator(16 * _gib),
        worker('w0', 0),
      ];
      final plain = planner.plan(m, nodes);
      final streaming = planner.plan(m, nodes, allowExpertStreaming: true);
      _expectSamePlan(plain, streaming);
      expect(streaming.nodes.map((n) => n.nodeId), ['coordinator']);
      expect(_parseRanges(plain.tensorOverrides).single.device, 'CPU');
    });

    test('expert streaming with one worker streams every expert layer to it',
        () {
      final m = model(moeMeta());
      final nodes = [
        coordinator(4 * _gib),
        worker('w1', 1 * _gib),
      ];
      // Experts do not fit the 1 GiB worker, so the normal plan fails.
      expect(() => planner.plan(m, nodes), throwsA(isA<PlanError>()));

      final plan = planner.plan(m, nodes, allowExpertStreaming: true);
      expect(plan.nodes, hasLength(2));
      final ranges = _parseRanges(plan.tensorOverrides);
      expect(ranges.single.device, 'RPC0[10.0.0.2:50052]');
      expect(_allLayers(ranges), List.generate(48, (i) => i));

      final coordinatorAssignment =
          plan.assignments.firstWhere((a) => a.nodeId == 'coordinator');
      expect(coordinatorAssignment.layerFraction, 1.0);
      expect(coordinatorAssignment.estimatedBytes, lessThanOrEqualTo(4 * _gib),
          reason: 'attention/KV still have to fit the coordinator');
      final workerAssignment =
          plan.assignments.firstWhere((a) => a.nodeId == 'w1');
      expect(workerAssignment.estimatedBytes, greaterThan(1 * _gib),
          reason: 'the expert shard streams past the worker budget');
    });

    test('expert streaming is a no-op when the model already fits', () {
      final m = model(moeMeta());
      final nodes = [
        coordinator(16 * _gib),
        worker('w1', 4 * _gib),
        worker('w2', 8 * _gib, host: '10.0.0.3', port: 50053),
      ];
      final plain = planner.plan(m, nodes);
      final streaming = planner.plan(m, nodes, allowExpertStreaming: true);
      _expectSamePlan(plain, streaming);
    });

    test('expert streaming does not relax dense plans', () {
      expect(
        () => planner.plan(model(denseMeta()), [coordinator(300 * _mib)],
            allowExpertStreaming: true),
        throwsA(isA<PlanError>()
            .having((e) => e.message, 'message', contains('does not fit'))),
      );
    });

    test('invalid plans are rejected', () {
      final m = model(moeMeta());
      expect(() => planner.plan(m, const []), throwsA(isA<PlanError>()));
      expect(
        () => planner.plan(m, [worker('w', 8 * _gib)]),
        throwsA(isA<PlanError>()),
      );
      expect(
        () => planner.plan(m, [coordinator(8 * _gib), coordinator(8 * _gib)]),
        throwsA(isA<PlanError>()),
      );
      expect(
        () => planner
            .plan(m, [coordinator(8 * _gib), worker('coordinator', 8 * _gib)]),
        throwsA(isA<PlanError>()),
      );
    });
  });

  group('llamaServerArgs', () {
    const densePlan = ClusterPlan(
      model: ModelRef('test'),
      nodes: [
        PlanNode(nodeId: 'coordinator', rpcEndpoint: null, budgetBytes: 1),
        PlanNode(nodeId: 'w1', rpcEndpoint: '10.0.0.2:50052', budgetBytes: 1),
        PlanNode(nodeId: 'w2', rpcEndpoint: '10.0.0.3:50053', budgetBytes: 1),
      ],
      assignments: [
        PlanAssignment(
            nodeId: 'coordinator', layerFraction: 0.5, estimatedBytes: 1),
        PlanAssignment(nodeId: 'w1', layerFraction: 0.25, estimatedBytes: 1),
        PlanAssignment(nodeId: 'w2', layerFraction: 0.25, estimatedBytes: 1),
      ],
      tensorOverrides: [
        r'blk\.(0)\.ffn_.*_exps\.=RPC0[10.0.0.2:50052]',
      ],
      contextLength: 4096,
    );

    test('plan-only args split the RPC devices', () {
      // No block count is available here, so this is the legacy helper: the
      // split only covers RPC devices and -ngl stays at 999.
      expect(planner.llamaServerArgs(densePlan), [
        '--rpc',
        '10.0.0.2:50052,10.0.0.3:50053',
        '--tensor-split',
        '50,50',
        '--override-tensor',
        r'blk\.(0)\.ffn_.*_exps\.=RPC0[10.0.0.2:50052]',
        '-ngl',
        '999',
        '-c',
        '4096',
        '--jinja',
        '--reasoning',
        'off',
        '--no-webui',
      ]);
    });

    test('model-aware args realize a dense plan with -ngl and RPC-only split',
        () {
      final args = planner.llamaServerArgsForModel(
          densePlan, model(denseMeta(blockCount: 28)));
      expect(
          args, containsAllInOrder(['--rpc', '10.0.0.2:50052,10.0.0.3:50053']));
      // 7 + 7 repeating layers on the workers; llama.cpp counts the output layer too.
      expect(args, containsAllInOrder(['--tensor-split', '7,8', '-ngl', '15']));
      expect(args, isNot(contains('999')));
    });

    test('model-aware args leave everything local when the plan does', () {
      const plan = ClusterPlan(
        model: ModelRef('test'),
        nodes: [
          PlanNode(nodeId: 'coordinator', rpcEndpoint: null, budgetBytes: 1)
        ],
        assignments: [
          PlanAssignment(
              nodeId: 'coordinator', layerFraction: 1, estimatedBytes: 1)
        ],
      );
      final args = planner.llamaServerArgsForModel(plan, model(denseMeta()));
      expect(args, isNot(contains('--rpc')));
      expect(args, isNot(contains('--tensor-split')));
      expect(args, containsAllInOrder(['-ngl', '0', '-c', '4096']));
    });

    test('MoE plan with attention on the coordinator offloads no layers', () {
      final plan = planner.plan(model(moeMeta()), [
        coordinator(16 * _gib),
        worker('w1', 8 * _gib),
        worker('w2', 8 * _gib, host: '10.0.0.3', port: 50053),
      ]);
      final args = planner.llamaServerArgsForModel(plan, model(moeMeta()));
      expect(args[args.indexOf('--rpc') + 1], '10.0.0.2:50052,10.0.0.3:50053');
      expect(args, isNot(contains('--tensor-split')));
      expect(args, containsAllInOrder(['-ngl', '0']));
    });

    test('override regexes match only their layer range', () {
      final meta = moeMeta(
          blockCount: 8, embeddingLength: 256, totalTensorBytes: 10 * _gib);
      final plan = planner.plan(model(meta), [
        coordinator(8 * _gib),
        worker('w1', 8 * _gib),
      ]);
      for (final rule in plan.tensorOverrides) {
        final eq = rule.indexOf('=');
        final pattern = RegExp(rule.substring(0, eq));
        final layers = _parseRuleLayers(rule);
        for (var layer = 0; layer < 8; layer++) {
          final name = 'blk.$layer.ffn_gate_exps.weight';
          expect(pattern.hasMatch(name), layers.contains(layer),
              reason: '$rule vs $name');
        }
      }
    });
  });
}

/// A streaming plan that is not needed must be identical to the flag-off plan.
void _expectSamePlan(ClusterPlan a, ClusterPlan b) {
  expect(b.model, a.model);
  expect(b.contextLength, a.contextLength);
  expect(b.nodes.map((n) => n.nodeId), a.nodes.map((n) => n.nodeId));
  expect(
      b.assignments.map((x) => (x.nodeId, x.layerFraction, x.estimatedBytes)),
      a.assignments.map((x) => (x.nodeId, x.layerFraction, x.estimatedBytes)));
  expect(b.tensorOverrides, a.tensorOverrides);
}

/// Parses `blk\.(a|b|...)\.ffn_.*_exps\.=DEVICE` rules into contiguous ranges.
List<({List<int> layers, String device})> _parseRanges(List<String> overrides) {
  final result = <({List<int> layers, String device})>[];
  final seen = <int>{};
  for (final rule in overrides) {
    final eq = rule.indexOf('=');
    final device = rule.substring(eq + 1);
    final layers = _parseRuleLayers(rule);
    for (final layer in layers) {
      expect(seen.add(layer), isTrue, reason: 'layer $layer assigned twice');
    }
    expect(layers, _contiguous(layers),
        reason: 'rule must be a contiguous range: $rule');
    result.add((layers: layers, device: device));
  }
  return result;
}

List<int> _allLayers(List<({List<int> layers, String device})> ranges) =>
    [for (final r in ranges) ...r.layers]..sort();

List<int> _contiguous(List<int> layers) =>
    [for (var i = layers.first; i <= layers.last; i++) i];

List<int> _parseRuleLayers(String rule) {
  final open = rule.indexOf(r'blk\.(');
  expect(open, 0, reason: 'rule must start with blk\\.(: $rule');
  final close = rule.indexOf(r')\.ffn_', open);
  expect(close, greaterThan(open),
      reason: 'rule must close the layer group: $rule');
  final inner = rule.substring(open + r'blk\.('.length, close);
  return [for (final part in inner.split('|')) int.parse(part)];
}

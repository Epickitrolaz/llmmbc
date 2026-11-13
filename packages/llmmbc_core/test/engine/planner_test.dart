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

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:test/test.dart';

const int _gib = 1024 * 1024 * 1024;
final bool _enabled = Platform.environment['LLMMBC_ENGINE_IT'] == '1';
final String _cacheDir = Platform.environment['LLMMBC_IT_MODEL_DIR'] ??
    '${Directory.systemTemp.path}/llmmbc-engine-it';

class _ModelSpec {
  const _ModelSpec({
    required this.name,
    required this.ref,
    required this.digest,
    required this.sizeBytes,
    required this.metadata,
  });

  final String name;
  final ModelRef ref;
  final String digest;
  final int sizeBytes;
  final GgufMetadata metadata;
}

final _specs = [
  _ModelSpec(
    name: 'qwen3:0.6b (dense)',
    ref: ModelRef.parse('qwen3:0.6b'),
    digest: '7f4030143c1c477224c5434f8272c662a8b042079a0a584f0a27a1684fe2e1fa',
    sizeBytes: 522640096,
    metadata: GgufMetadata(
      architecture: 'qwen3',
      blockCount: 28,
      embeddingLength: 1024,
      contextLength: 4096,
      totalTensorBytes: 522640096,
    ),
  ),
  _ModelSpec(
    name: 'granite3.1-moe:1b (MoE)',
    ref: ModelRef.parse('granite3.1-moe:1b'),
    digest: 'cd60b3e8bb445d4c05e0b0b99b1bb41e8bb77211b161e783c71931168131df80',
    sizeBytes: 1422239776,
    // ibm-granite/granite-3.1-1b-a400m config: 24 layers, hidden 1024, 32 experts / 8 used.
    metadata: GgufMetadata(
      architecture: 'granitemoe',
      blockCount: 24,
      expertCount: 32,
      expertUsedCount: 8,
      embeddingLength: 1024,
      contextLength: 4096,
      totalTensorBytes: 1422239776,
      expertTensorBytes: 1137791820,
    ),
  ),
];

void main() {
  group('llama.cpp engine integration', () {
    for (final spec in _specs) {
      test(spec.name, () async {
        final locator = DefaultEngineLocator();
        expect(await locator.available, isTrue,
            reason:
                'engine binaries missing - run scripts/fetch_engine.sh linux-x64');

        final modelFile = await _ensureModel(spec);
        final model = LocalModel(
          ref: spec.ref,
          ggufPath: modelFile.path,
          sizeBytes: spec.sizeBytes,
          metadata: spec.metadata,
        );

        final rpcPorts = [await _freePort(), await _freePort()];
        final coordinatorPort = await _freePort();
        final workerEngines = [
          LlamaCppEngine(locator: locator),
          LlamaCppEngine(locator: locator),
        ];
        final coordinatorEngine = LlamaCppEngine(locator: locator);
        addTearDown(() async {
          await coordinatorEngine.stopCoordinator();
          for (final engine in workerEngines) {
            await engine.stopRpcWorker();
          }
        });

        final cache = Directory('$_cacheDir/rpc-cache-${spec.ref.name}')
          ..createSync(recursive: true);
        for (var i = 0; i < workerEngines.length; i++) {
          final port = await workerEngines[i].startRpcWorker(
            port: rpcPorts[i],
            cacheDir: '${cache.path}/$i',
          );
          expect(port, rpcPorts[i]);
        }

        const planner = DefaultClusterPlanner();
        final plan = planner.plan(model, [
          PlanNode(
              nodeId: 'coordinator', rpcEndpoint: null, budgetBytes: 6 * _gib),
          PlanNode(
              nodeId: 'worker-1',
              rpcEndpoint: '127.0.0.1:${rpcPorts[0]}',
              budgetBytes: 4 * _gib),
          PlanNode(
              nodeId: 'worker-2',
              rpcEndpoint: '127.0.0.1:${rpcPorts[1]}',
              budgetBytes: 4 * _gib),
        ]);
        if (spec.metadata.isMoe) {
          expect(plan.tensorOverrides, isNotEmpty,
              reason: 'MoE plan must emit expert overrides');
        }

        final uri = await coordinatorEngine.startCoordinator(
          model: model,
          plan: plan,
          port: coordinatorPort,
        );
        final answer = await _chat(uri, spec.ref.toString());

        final args = planner.llamaServerArgsForModel(plan, model);
        final splitIndex = args.indexOf('--tensor-split');
        final tail = coordinatorEngine.logTail;
        final placement = _Placement.parse(tail);
        // ignore: avoid_print
        print(
            '${spec.name}: split=${splitIndex < 0 ? 'none' : args[splitIndex + 1]} '
            'ngl=${args[args.indexOf('-ngl') + 1]} overrides=${plan.tensorOverrides.length}');
        // ignore: avoid_print
        print(
            '${spec.name}: placement model=${placement.model} kv=${placement.kv}');
        // ignore: avoid_print
        print('${spec.name}: answer="${answer.trim()}"');

        expect(answer.trim(), isNotEmpty);
        // #32: the log ring must retain loader/placement diagnostics.
        expect(tail.join('\n'), contains('model buffer size'));
        expect(tail.join('\n'), contains('KV buffer size'));
        _assertPlacement(plan, spec, placement);
      }, timeout: Timeout(const Duration(minutes: 15)));
    }
  },
      skip: _enabled
          ? false
          : 'set LLMMBC_ENGINE_IT=1 to run the llama.cpp integration test');
}

Future<File> _ensureModel(_ModelSpec spec) async {
  final dir = Directory(_cacheDir);
  await dir.create(recursive: true);
  final target = File('${dir.path}/sha256-${spec.digest}.gguf');
  if (await target.exists() && await target.length() == spec.sizeBytes) {
    return target;
  }

  final partial = File('${target.path}.partial');
  if (await partial.exists()) await partial.delete();
  final url =
      'https://registry.ollama.ai/v2/library/${spec.ref.name}/blobs/sha256:${spec.digest}';
  final client = http.Client();
  IOSink? sink;
  try {
    final response = await client.send(http.Request('GET', Uri.parse(url)));
    if (response.statusCode != 200) {
      throw StateError('download failed (${response.statusCode}) for $url');
    }
    sink = partial.openWrite();
    var received = 0;
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
    }
    await sink.close();
    sink = null;
    if (received != spec.sizeBytes) {
      throw StateError(
          'short download for $url: $received != ${spec.sizeBytes}');
    }
    await partial.rename(target.path);
    return target;
  } finally {
    if (sink != null) await sink.close();
    client.close();
  }
}

Future<String> _chat(Uri base, String model) async {
  final client = http.Client();
  try {
    final response = await client
        .post(
          base.resolve('/v1/chat/completions'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'user', 'content': 'Reply with one short greeting.'}
            ],
            'max_tokens': 128,
            'temperature': 0,
            'stream': false,
          }),
        )
        .timeout(const Duration(minutes: 5));
    if (response.statusCode != 200) {
      throw StateError(
          'chat failed (${response.statusCode}): ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = body['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw StateError('chat response has no choices: ${response.body}');
    }
    final message = (choices.first as Map<String, dynamic>)['message']
        as Map<String, dynamic>?;
    final content = (message?['content'] as String? ?? '').trim();
    if (content.isNotEmpty) return content;
    // Reasoning models may put the whole answer in reasoning_content.
    return (message?['reasoning_content'] as String? ?? '').trim();
  } finally {
    client.close();
  }
}

void _assertPlacement(ClusterPlan plan, _ModelSpec spec, _Placement actual) {
  final meta = spec.metadata;
  final byAssignment = {for (final a in plan.assignments) a.nodeId: a};
  final actualKvTotal = actual.kv.values.fold<double>(0, (a, b) => a + b);

  // The coordinator must really run layers/KV; #28 was caused by -ngl 999
  // pushing everything to the RPC devices.
  final coordinator = plan.nodes.firstWhere((n) => n.isCoordinator);
  final coordinatorTotal = actual.forNode(coordinator);
  expect(coordinatorTotal, greaterThan(0),
      reason: 'coordinator received no model/KV buffers:\n${actual.raw}');

  for (final assignment in plan.assignments) {
    final node = plan.nodes.firstWhere((n) => n.nodeId == assignment.nodeId);
    // Compare against the measured cluster KV total: the planner cannot know
    // GQA head counts, but the per-layer *distribution* must follow the plan.
    final expectedKv = actualKvTotal * assignment.layerFraction;
    final actualKv = actual.kvForNode(node);
    final tolerance = expectedKv == 0 ? 8.0 : math.max(8.0, expectedKv * 0.10);
    expect((actualKv - expectedKv).abs(), lessThanOrEqualTo(tolerance),
        reason: 'KV placement for ${node.nodeId}: expected '
            '${expectedKv.toStringAsFixed(1)} MiB, actual ${actualKv.toStringAsFixed(1)} MiB');
    // Budget safety: the node must not exceed what the plan promised.
    expect(
        actual.forNode(node),
        lessThanOrEqualTo(
            assignment.estimatedBytes / (1024 * 1024) * 1.10 + 32),
        reason: 'node ${node.nodeId} exceeded its planned bytes');
  }

  if (meta.isMoe) {
    // Expert tensors must be on the workers, attention/KV on the coordinator.
    for (final node in plan.nodes.where((n) => !n.isCoordinator)) {
      expect(actual.modelForNode(node), greaterThan(0),
          reason: 'worker ${node.nodeId} received no expert tensors');
      expect(actual.kvForNode(node), lessThan(8),
          reason: 'worker ${node.nodeId} should have no KV');
    }
    expect(actual.kvForNode(coordinator),
        closeTo(actualKvTotal, math.max(8.0, actualKvTotal * 0.10)),
        reason: 'MoE attention/KV must stay on the coordinator');
    expect(actualKvTotal, greaterThan(0));
  }
  // Planned and actual assignment bookkeeping stays consistent.
  expect(byAssignment.length, plan.nodes.length);
}

class _Placement {
  _Placement(this.model, this.kv, this.raw);
  final Map<String, double> model;
  final Map<String, double> kv;
  final String raw;

  static final _line = RegExp(
      r'(?:load_tensors|llama_kv_cache):\s+(\S+) (model|KV) buffer size =\s+([\d.]+) MiB');

  factory _Placement.parse(List<String> lines) {
    final model = <String, double>{};
    final kv = <String, double>{};
    for (final line in lines) {
      final match = _line.firstMatch(line);
      if (match == null) continue;
      final device = match.group(1)!;
      final value = double.parse(match.group(3)!);
      (match.group(2) == 'model' ? model : kv)[device] =
          ((match.group(2) == 'model' ? model : kv)[device] ?? 0) + value;
    }
    return _Placement(model, kv, lines.join('\n'));
  }

  bool _isCoordinator(String device) => device.startsWith('CPU');

  double modelForNode(PlanNode node) {
    if (node.isCoordinator) {
      return model.entries
          .where((e) => _isCoordinator(e.key))
          .fold(0, (a, e) => a + e.value);
    }
    return model.entries
        .where((e) => e.key.contains('[${node.rpcEndpoint}]'))
        .fold(0, (a, e) => a + e.value);
  }

  double kvForNode(PlanNode node) {
    if (node.isCoordinator) {
      return kv.entries
          .where((e) => _isCoordinator(e.key))
          .fold(0, (a, e) => a + e.value);
    }
    return kv.entries
        .where((e) => e.key.contains('[${node.rpcEndpoint}]'))
        .fold(0, (a, e) => a + e.value);
  }

  double forNode(PlanNode node) => modelForNode(node) + kvForNode(node);
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:test/test.dart';

const int _gib = 1024 * 1024 * 1024;
const int _mib = 1024 * 1024;
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

  String get cacheName => 'sha256-$digest.gguf';
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
    test('dense: workers load weights from their own GGUF copy', () async {
      final spec = _specs[0];
      final model = await _prepareModel(spec);
      final workers = await _startWorkers(spec, lazy: const [true, true]);
      addTearDown(() async {
        for (final worker in workers) {
          await worker.engine.stopRpcWorker();
        }
      });
      final coordinatorEngine = LlamaCppEngine(locator: DefaultEngineLocator());
      addTearDown(coordinatorEngine.stopCoordinator);

      const planner = DefaultClusterPlanner();
      final plan = planner.plan(model, [
        PlanNode(
            nodeId: 'coordinator', rpcEndpoint: null, budgetBytes: 6 * _gib),
        PlanNode(
            nodeId: 'worker-1',
            rpcEndpoint: '127.0.0.1:${workers[0].port}',
            budgetBytes: 4 * _gib),
        PlanNode(
            nodeId: 'worker-2',
            rpcEndpoint: '127.0.0.1:${workers[1].port}',
            budgetBytes: 4 * _gib),
      ]);

      final uri = await coordinatorEngine.startCoordinator(
        model: model,
        plan: plan,
        port: await _freePort(),
      );
      final answer = await _chat(uri, spec.ref.toString());
      expect(answer.trim(), isNotEmpty);

      // Stopping the coordinator closes the RPC connections, which makes each
      // rpc-server log its exact transfer totals.
      await coordinatorEngine.stopCoordinator();
      final stats = [
        for (final worker in workers) await _waitRpcStats(worker.engine),
      ];

      final placement = _Placement.parse(coordinatorEngine.logTail);
      // ignore: avoid_print
      print('${spec.name}: answer="${answer.trim()}"');
      for (var i = 0; i < workers.length; i++) {
        final assigned = _weightsAssigned(plan, 'worker-${i + 1}');
        final s = stats[i];
        // ignore: avoid_print
        print('${spec.name}: worker-${i + 1} loaded=${workers[i].modelPath} '
            'planned_node_bytes=${_fmt(assigned)} from_file=${_fmt(s.fromFileBytes)} '
            '(${s.fromFileTensors} tensors) over_socket=${_fmt(s.socketBytes)}');
        expect(s.fromFileBytes, greaterThan(0),
            reason: 'worker-${i + 1} must load weights from its own file');
        expect(s.fromFileBytes, greaterThan((spec.sizeBytes * 0.1).round()),
            reason: 'the assigned weight shard is loaded from disk');
        expect(s.socketBytes, lessThan(spec.sizeBytes ~/ 20),
            reason: 'weights must not cross the socket ('
                '${s.socketBytes} bytes of ${spec.sizeBytes})');
        expect(workers[i].engine.logTail.join('\n'),
            contains('model file: ${workers[i].modelPath}'));
        expect(
            workers[i].engine.logTail.join('\n'), contains('lazy weights: on'));
      }
      _assertPlacement(plan, spec, placement);
    }, timeout: Timeout(const Duration(minutes: 15)));

    test('MoE expert streaming: mapped weights, low RSS, experts paged in',
        () async {
      final spec = _specs[1];
      final model = await _prepareModel(spec);
      final workers = await _startWorkers(spec, lazy: const [true, true]);
      addTearDown(() async {
        for (final worker in workers) {
          await worker.engine.stopRpcWorker();
        }
      });
      final coordinatorEngine = LlamaCppEngine(locator: DefaultEngineLocator());
      addTearDown(coordinatorEngine.stopCoordinator);

      // Attention + KV (~755 MiB) fits the coordinator; the cluster total
      // (~1.07 GiB) is below the 1.42 GiB model, so only expert streaming fits.
      // Each worker is planned 3 of the 24 expert layers (142 MiB), which is
      // more than its own 132 MiB budget.
      final nodes = [
        PlanNode(
            nodeId: 'coordinator', rpcEndpoint: null, budgetBytes: 780 * _mib),
        PlanNode(
            nodeId: 'worker-1',
            rpcEndpoint: '127.0.0.1:${workers[0].port}',
            budgetBytes: 132 * _mib),
        PlanNode(
            nodeId: 'worker-2',
            rpcEndpoint: '127.0.0.1:${workers[1].port}',
            budgetBytes: 132 * _mib),
      ];
      const planner = DefaultClusterPlanner();
      expect(
        () => planner.plan(model, nodes),
        throwsA(isA<PlanError>()),
        reason: 'without streaming the MoE weights do not fit these budgets',
      );
      final plan = planner.plan(model, nodes, allowExpertStreaming: true);
      expect(plan.tensorOverrides, isNotEmpty);

      final uri = await coordinatorEngine.startCoordinator(
        model: model,
        plan: plan,
        port: await _freePort(),
      );

      // Model loaded, no prompt yet: expert pages must mostly still be on disk.
      final rssBefore = <int>[];
      for (final worker in workers) {
        rssBefore.add(await _rpcServerRss(worker.engine));
      }
      final answer = await _chat(uri, spec.ref.toString());
      expect(answer.trim(), isNotEmpty);
      final rssAfter = <int>[];
      for (final worker in workers) {
        rssAfter.add(await _rpcServerRss(worker.engine));
      }

      await coordinatorEngine.stopCoordinator();
      final stats = [
        for (final worker in workers) await _waitRpcStats(worker.engine),
      ];
      final placement = _Placement.parse(coordinatorEngine.logTail);

      // ignore: avoid_print
      print('${spec.name}: answer="${answer.trim()}" '
          'budgets=780/132/132 MiB streaming=true');
      for (var i = 0; i < workers.length; i++) {
        final nodeId = 'worker-${i + 1}';
        final assigned = _weightsAssigned(plan, nodeId);
        final budget = nodes[i + 1].budgetBytes;
        final s = stats[i];
        // ignore: avoid_print
        print('${spec.name}: $nodeId planned_node_bytes=${_fmt(assigned)} '
            '(budget=${_fmt(budget)}) from_file=${_fmt(s.fromFileBytes)} '
            'over_socket=${_fmt(s.socketBytes)} '
            'rss_before=${_fmt(rssBefore[i])} rss_after=${_fmt(rssAfter[i])} '
            'rss_delta=${_fmt(rssAfter[i] - rssBefore[i])}');
        expect(assigned, greaterThan(budget),
            reason: '$nodeId should hold more expert bytes than its budget');
        expect(s.fromFileBytes, greaterThan(0));
        expect(s.fromFileBytes, greaterThan((assigned * 0.5).round()));
        expect(s.socketBytes, lessThan(spec.sizeBytes ~/ 20));
        expect(rssBefore[i], lessThan(assigned ~/ 2),
            reason: 'mapped weights must not be resident after load');
        expect(rssAfter[i], greaterThan(rssBefore[i]),
            reason: 'expert pages are paged in by the prompt');
      }
      _assertPlacement(plan, spec, placement);
    }, timeout: Timeout(const Duration(minutes: 15)));

    test('fallback: a worker without --model-file still receives bytes',
        () async {
      final spec = _specs[0];
      final model = await _prepareModel(spec);
      // Worker 0 forces the pread-into-buffer path (--model-file without
      // --lazy-weights); worker 1 behaves like an old rpc-server: it does not
      // advertise SET_TENSOR_FROM_FILE and receives the bytes.
      final workers = await _startWorkers(spec,
          lazy: const [false, false], modelFile: const [true, false]);
      addTearDown(() async {
        for (final worker in workers) {
          await worker.engine.stopRpcWorker();
        }
      });
      final coordinatorEngine = LlamaCppEngine(locator: DefaultEngineLocator());
      addTearDown(coordinatorEngine.stopCoordinator);

      const planner = DefaultClusterPlanner();
      final plan = planner.plan(model, [
        PlanNode(
            nodeId: 'coordinator', rpcEndpoint: null, budgetBytes: 6 * _gib),
        PlanNode(
            nodeId: 'worker-1',
            rpcEndpoint: '127.0.0.1:${workers[0].port}',
            budgetBytes: 4 * _gib),
        PlanNode(
            nodeId: 'worker-2',
            rpcEndpoint: '127.0.0.1:${workers[1].port}',
            budgetBytes: 4 * _gib),
      ]);
      final uri = await coordinatorEngine.startCoordinator(
        model: model,
        plan: plan,
        port: await _freePort(),
      );
      final answer = await _chat(uri, spec.ref.toString());
      expect(answer.trim(), isNotEmpty);

      await coordinatorEngine.stopCoordinator();
      final stats = [
        for (final worker in workers) await _waitRpcStats(worker.engine),
      ];
      final fromFile = stats[0];
      final overSocket = stats[1];
      final assigned = _weightsAssigned(plan, 'worker-2');
      // ignore: avoid_print
      print('${spec.name}: fallback worker (no --model-file) '
          'planned_node_bytes=${_fmt(assigned)} '
          'from_file=${_fmt(overSocket.fromFileBytes)} '
          'over_socket=${_fmt(overSocket.socketBytes)}');
      expect(fromFile.fromFileBytes, greaterThan(0));
      expect(fromFile.socketBytes, lessThan(spec.sizeBytes ~/ 20));
      expect(overSocket.fromFileBytes, 0,
          reason: 'old servers have no SET_TENSOR_FROM_FILE');
      expect(
          overSocket.socketBytes, greaterThan((spec.sizeBytes * 0.2).round()),
          reason: 'the fallback path sends the weights over the socket');
      expect(workers[1].engine.logTail.join('\n'),
          isNot(contains('model file: ')));
      _assertPlacement(plan, spec, _Placement.parse(coordinatorEngine.logTail));
    }, timeout: Timeout(const Duration(minutes: 15)));
  },
      skip: _enabled
          ? false
          : 'set LLMMBC_ENGINE_IT=1 to run the llama.cpp integration test');
}

class _Worker {
  _Worker(this.engine, this.port, this.modelPath);
  final LlamaCppEngine engine;
  final int port;
  final String? modelPath;
}

Future<LocalModel> _prepareModel(_ModelSpec spec) async {
  final file = await _ensureModel(spec);
  return LocalModel(
    ref: spec.ref,
    ggufPath: file.path,
    sizeBytes: spec.sizeBytes,
    metadata: spec.metadata,
  );
}

/// Starts two local rpc-servers. Each gets its **own copy** of the GGUF at a
/// separate path (architecture §2.2: every candidate already has the model).
Future<List<_Worker>> _startWorkers(_ModelSpec spec,
    {required List<bool> lazy,
    List<bool> modelFile = const [true, true]}) async {
  final locator = DefaultEngineLocator();
  expect(await locator.available, isTrue,
      reason:
          'engine binaries missing - run scripts/fetch_engine.sh linux-x64');
  final workers = <_Worker>[];
  for (var i = 0; i < 2; i++) {
    final engine = LlamaCppEngine(locator: locator);
    final path = modelFile[i] ? await _workerModelCopy(spec, i) : null;
    final port = await engine.startRpcWorker(
      port: await _freePort(),
      modelPath: path,
      lazyWeights: lazy[i] && path != null,
    );
    workers.add(_Worker(engine, port, path));
  }
  return workers;
}

/// A real per-worker copy (not a link): `rpc-server --model-file` must point at
/// a path that only this worker owns.
Future<String> _workerModelCopy(_ModelSpec spec, int index) async {
  final source = await _ensureModel(spec);
  final dir = Directory('$_cacheDir/workers/${spec.digest.substring(0, 12)}');
  await dir.create(recursive: true);
  final target = File('${dir.path}/worker-$index.gguf');
  if (await target.exists() && await target.length() == spec.sizeBytes) {
    return target.path;
  }
  final partial = File('${target.path}.copy');
  if (await partial.exists()) await partial.delete();
  await source.copy(partial.path);
  await partial.rename(target.path);
  return target.path;
}

Future<File> _ensureModel(_ModelSpec spec) async {
  final dir = Directory(_cacheDir);
  await dir.create(recursive: true);
  final target = File('${dir.path}/${spec.cacheName}');
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

/// Transfer counters logged by the patched rpc-server. The last line (logged
/// when the coordinator disconnects) carries the exact totals.
class _RpcStats {
  const _RpcStats(this.fromFileBytes, this.fromFileTensors, this.socketBytes);
  final int fromFileBytes;
  final int fromFileTensors;
  final int socketBytes;

  static final _line = RegExp(
      r'from_file_bytes=(\d+) from_file_tensors=(\d+) socket_bytes=(\d+)');

  static _RpcStats? parse(List<String> lines) {
    _RpcStats? best;
    for (final line in lines) {
      final match = _line.firstMatch(line);
      if (match == null) continue;
      final stats = _RpcStats(int.parse(match.group(1)!),
          int.parse(match.group(2)!), int.parse(match.group(3)!));
      if (best == null ||
          stats.fromFileBytes > best.fromFileBytes ||
          stats.socketBytes > best.socketBytes) {
        best = stats;
      }
    }
    return best;
  }
}

Future<_RpcStats> _waitRpcStats(LlamaCppEngine engine) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  // Only the destructor line (`~rpc_server`) has the exact totals; the periodic
  // 16 MiB lines are partial.
  bool isFinal(String line) =>
      line.contains('~rpc_server] totals:') && _RpcStats._line.hasMatch(line);
  while (DateTime.now().isBefore(deadline)) {
    if (engine.logTail.any(isFinal)) {
      return _RpcStats.parse(engine.logTail)!;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final fallback = _RpcStats.parse(engine.logTail);
  if (fallback == null) {
    throw StateError('rpc-server logged no transfer stats:\n'
        '${engine.logTail.join('\n')}');
  }
  return fallback;
}

/// The plan's estimate for a node: assigned weights plus the planner's 10%
/// overhead (and KV when the node runs attention layers).
int _weightsAssigned(ClusterPlan plan, String nodeId) =>
    plan.assignments.firstWhere((a) => a.nodeId == nodeId).estimatedBytes;

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

/// Resident set size of the rpc-server child of [engine]'s supervisor.
Future<int> _rpcServerRss(LlamaCppEngine engine) async {
  final supervisor = engine.rpcWorkerPid;
  if (supervisor == null) throw StateError('rpc-server is not running');
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    final childrenFile = File('/proc/$supervisor/task/$supervisor/children');
    if (await childrenFile.exists()) {
      final children = (await childrenFile.readAsString()).trim();
      // The supervisor forks both rpc-server and a watchdog subshell; pick the
      // engine by its comm name instead of relying on child order.
      for (final field in children.split(RegExp(r'\s+'))) {
        final pid = int.tryParse(field);
        if (pid == null) continue;
        final comm = File('/proc/$pid/comm');
        if (!await comm.exists() ||
            !(await comm.readAsString()).trim().contains('rpc-server')) {
          continue;
        }
        final status = File('/proc/$pid/status');
        if (await status.exists()) {
          for (final line in await status.readAsLines()) {
            if (line.startsWith('VmRSS:')) {
              final kb = int.parse(RegExp(r'\d+').firstMatch(line)!.group(0)!);
              return kb * 1024;
            }
          }
        }
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('could not read rpc-server RSS for supervisor $supervisor');
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

String _fmt(int bytes) {
  if (bytes >= _gib) return '${(bytes / _gib).toStringAsFixed(2)} GiB';
  if (bytes >= _mib) return '${(bytes / _mib).toStringAsFixed(1)} MiB';
  return '$bytes B';
}

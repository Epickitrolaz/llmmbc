import 'dart:async';
import 'dart:io';

import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:test/test.dart';

class _Locator implements EngineLocator {
  _Locator({this.llama, this.rpc});
  final String? llama;
  final String? rpc;

  @override
  Future<String?> llamaServerPath() async => llama;
  @override
  Future<String?> rpcServerPath() async => rpc;
  @override
  Future<bool> get available async => llama != null && rpc != null;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('llmmbc_engine_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('starts and stops cleanly when no process is running', () async {
    final engine = LlamaCppEngine(locator: _Locator());
    expect(engine.rpcWorkerRunning, isFalse);
    expect(engine.coordinatorRunning, isFalse);
    expect(engine.logTail, isEmpty);
    await engine.stopRpcWorker();
    await engine.stopCoordinator();
  });

  test('startRpcWorker reports a missing rpc-server as engine_error', () async {
    final engine = LlamaCppEngine(locator: _Locator());
    await expectLater(
      engine.startRpcWorker(port: 47102, cacheDir: '${tmp.path}/cache'),
      throwsA(isA<LlmmbcException>()
          .having((e) => e.code, 'code', 'engine_error')
          .having((e) => e.message, 'message', contains('rpc-server'))),
    );
    expect(engine.rpcWorkerRunning, isFalse);
  });

  test('startCoordinator reports a missing llama-server as engine_error',
      () async {
    final engine = LlamaCppEngine(locator: _Locator());
    final model = LocalModel(
        ref: ModelRef.parse('x:y'),
        ggufPath: '${tmp.path}/model.gguf',
        sizeBytes: 1);
    await expectLater(
      engine.startCoordinator(
        model: model,
        plan: ClusterPlan(
          model: model.ref,
          nodes: const [
            PlanNode(nodeId: 'c', rpcEndpoint: null, budgetBytes: 1)
          ],
          assignments: const [
            PlanAssignment(nodeId: 'c', layerFraction: 1, estimatedBytes: 1)
          ],
        ),
        port: 47103,
      ),
      throwsA(isA<LlmmbcException>()
          .having((e) => e.code, 'code', 'engine_error')
          .having((e) => e.message, 'message', contains('llama-server'))),
    );
  });

  test(
      'a missing coordinator model file is an engine_error with a useful message',
      () async {
    final exe = '${tmp.path}/llama-server';
    final engine = LlamaCppEngine(
        locator: _Locator(llama: exe, rpc: '${tmp.path}/rpc-server'));
    final model = LocalModel(
        ref: ModelRef.parse('x:y'),
        ggufPath: '${tmp.path}/nope.gguf',
        sizeBytes: 1);
    await expectLater(
      engine.startCoordinator(
        model: model,
        plan: ClusterPlan(
          model: model.ref,
          nodes: const [
            PlanNode(nodeId: 'c', rpcEndpoint: null, budgetBytes: 1)
          ],
          assignments: const [
            PlanAssignment(nodeId: 'c', layerFraction: 1, estimatedBytes: 1)
          ],
        ),
        port: 47103,
      ),
      throwsA(isA<LlmmbcException>()
          .having((e) => e.code, 'code', 'engine_error')
          .having(
              (e) => e.message, 'message', contains('model file not found'))),
    );
  });

  test('a binary that cannot be executed is reported as engine_error',
      () async {
    final exe = '${tmp.path}/rpc-server';
    await File(exe).writeAsString('#!/bin/sh\nexit 0\n');
    final engine = LlamaCppEngine(locator: _Locator(rpc: exe));
    await expectLater(
      engine.startRpcWorker(port: 47102, cacheDir: '${tmp.path}/cache'),
      throwsA(
          isA<LlmmbcException>().having((e) => e.code, 'code', 'engine_error')),
    );
  }, skip: Platform.isWindows ? 'POSIX execute permissions' : null);

  test('startCoordinator rejects duplicate RPC endpoints', () async {
    final modelPath = '${tmp.path}/model.gguf';
    await File(modelPath).writeAsString('fake');
    final engine =
        LlamaCppEngine(locator: _Locator(llama: '${tmp.path}/llama-server'));
    await expectLater(
      engine.startCoordinator(
        model: LocalModel(
            ref: ModelRef.parse('x:y'), ggufPath: modelPath, sizeBytes: 1),
        plan: ClusterPlan(
          model: ModelRef.parse('x:y'),
          nodes: const [
            PlanNode(nodeId: 'c', rpcEndpoint: null, budgetBytes: 1),
            PlanNode(
                nodeId: 'w1', rpcEndpoint: '127.0.0.1:47102', budgetBytes: 1),
            PlanNode(
                nodeId: 'w2', rpcEndpoint: '127.0.0.1:47102', budgetBytes: 1),
          ],
          assignments: const [],
        ),
        port: 47103,
      ),
      throwsA(isA<LlmmbcException>()
          .having((e) => e.code, 'code', 'engine_error')
          .having((e) => e.message, 'message', contains('duplicate RPC'))),
    );
  });

  test('two engines on one host get distinct RPC ports', () async {
    final locator = DefaultEngineLocator(environment: const {});
    if (!await locator.available) {
      markTestSkipped(
          'engine binaries unavailable; run scripts/fetch_engine.sh linux-x64');
      return;
    }
    final first = LlamaCppEngine(locator: locator);
    final second = LlamaCppEngine(locator: locator);
    addTearDown(() async {
      await first.stopRpcWorker();
      await second.stopRpcWorker();
    });

    final p1 = await first.startRpcWorker(
        port: 47102, cacheDir: '${tmp.path}/cache-1');
    final p2 = await second.startRpcWorker(
        port: 47102, cacheDir: '${tmp.path}/cache-2');
    expect(p1, isNot(p2));
    expect(p1, isNot(kLlamaServerPort));
    expect(p2, isNot(kLlamaServerPort));
    expect(first.rpcWorkerRunning, isTrue);
    expect(second.rpcWorkerRunning, isTrue);
    for (final port in [p1, p2]) {
      expect(port, greaterThan(0));
      final socket = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(seconds: 2));
      socket.destroy();
    }
  }, skip: Platform.isWindows ? 'POSIX listener check' : null);

  test('a dead rpc-server is reported as engine_error, not success', () async {
    final exe = '${tmp.path}/dead-rpc-server';
    await File(exe).writeAsString('#!/bin/sh\nexit 7\n');
    await Process.run('chmod', ['+x', exe]);
    final engine = LlamaCppEngine(locator: _Locator(rpc: exe));
    final port = await _freePort();
    await expectLater(
      engine.startRpcWorker(port: port, cacheDir: '${tmp.path}/cache'),
      throwsA(isA<LlmmbcException>()
          .having((e) => e.code, 'code', 'engine_error')
          .having((e) => e.message, 'message', contains('rpc-server'))),
    );
    expect(engine.rpcWorkerRunning, isFalse);
    expect(engine.logTail, isNotEmpty);
  }, skip: Platform.isWindows ? 'POSIX execute permissions' : null);

  test('supervisor shell resolves to the Android platform shell', () {
    expect(supervisorShell(android: true), '/system/bin/sh');
    expect(supervisorShell(android: false), '/bin/sh');
    expect(
        supervisorShell(), Platform.isAndroid ? '/system/bin/sh' : '/bin/sh');
  });

  test('constructing an engine does not keep the Dart VM alive', () async {
    final script = File('${tmp.path}/idle_probe.dart')..writeAsStringSync('''
import 'package:llmmbc_core/llmmbc_core.dart';
void main() {
  LlamaCppEngine(locator: DefaultEngineLocator(engineDir: '/nonexistent', environment: const {}));
  print('PROBE_DONE');
}
''');
    final result = await _runDart(script, environment: const {});
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout.toString(), contains('PROBE_DONE'));
  }, skip: Platform.isWindows ? 'POSIX process supervision' : null);

  test('exit(0) mid-session leaves no llama-server/rpc-server behind',
      () async {
    final locator = DefaultEngineLocator(environment: const {});
    if (!await locator.available) {
      markTestSkipped(
          'engine binaries unavailable; run scripts/fetch_engine.sh linux-x64');
      return;
    }
    final realRpc = (await locator.rpcServerPath())!;

    final binDir = Directory('${tmp.path}/engine')..createSync();
    final llama = File('${binDir.path}/llama-server')
      ..writeAsStringSync(
          '#!/bin/sh\nexec "\$PROBE_REAL_RPC" -H 127.0.0.1 -p "\$PROBE_FAKE_PORT" -c\n');
    await Process.run('chmod', ['+x', llama.path]);
    await Link('${binDir.path}/rpc-server').create(realRpc);
    await File('${binDir.path}/model.gguf').writeAsString('fake');

    final rpcPort = await _freePort();
    final fakePort = await _freePort();
    final httpPort = await _freePort();
    final script = File('${tmp.path}/exit_probe.dart')..writeAsStringSync(r'''
import 'dart:async';
import 'dart:io';

import 'package:llmmbc_core/llmmbc_core.dart';

Future<void> _waitPort(int port) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    try {
      final socket = await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 300));
      socket.destroy();
      return;
    } on SocketException {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  throw StateError('port $port never opened');
}

Future<void> main() async {
  final bin = Platform.environment['PROBE_ENGINE_BIN']!;
  final rpcPort = int.parse(Platform.environment['PROBE_RPC_PORT']!);
  final fakePort = int.parse(Platform.environment['PROBE_FAKE_PORT']!);
  final httpPort = int.parse(Platform.environment['PROBE_HTTP_PORT']!);
  final engine = LlamaCppEngine(
      locator: DefaultEngineLocator(engineDir: bin, environment: const {}));
  unawaited(engine.startRpcWorker(port: rpcPort, cacheDir: '$bin/cache'));
  final model = LocalModel(ref: ModelRef('probe'), ggufPath: '$bin/model.gguf', sizeBytes: 1);
  unawaited(engine.startCoordinator(
    model: model,
    plan: ClusterPlan(
      model: model.ref,
      nodes: const [PlanNode(nodeId: 'c', rpcEndpoint: null, budgetBytes: 1)],
      assignments: const [PlanAssignment(nodeId: 'c', layerFraction: 1, estimatedBytes: 1)],
    ),
    port: httpPort,
  ));
  await _waitPort(rpcPort);
  await _waitPort(fakePort);
  stdout.writeln('PROBE_STARTED rpc=$rpcPort fake=$fakePort');
  exit(0);
}
''');

    final result = await _runDart(script, environment: {
      'PROBE_ENGINE_BIN': binDir.path,
      'PROBE_REAL_RPC': realRpc,
      'PROBE_RPC_PORT': '$rpcPort',
      'PROBE_FAKE_PORT': '$fakePort',
      'PROBE_HTTP_PORT': '$httpPort',
    });
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout.toString(), contains('PROBE_STARTED'));

    // The shell supervisor must notice the dead Dart parent and kill both
    // engine processes; their ports must become unreachable.
    await _expectPortClosed(rpcPort);
    await _expectPortClosed(fakePort);
  },
      timeout: Timeout(const Duration(minutes: 2)),
      skip: Platform.isWindows ? 'POSIX process supervision' : null);
}

Future<ProcessResult> _runDart(File script,
    {required Map<String, String> environment}) async {
  final packageConfig =
      '${Directory.current.path}/.dart_tool/package_config.json';
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['--packages=$packageConfig', 'run', script.path],
    environment: {...Platform.environment, ...environment},
    includeParentEnvironment: false,
  );
  final stdoutText =
      process.stdout.transform(const SystemEncoding().decoder).join();
  final stderrText =
      process.stderr.transform(const SystemEncoding().decoder).join();
  final exitCode = await process.exitCode.timeout(const Duration(seconds: 30));
  return ProcessResult(
      process.pid, exitCode, await stdoutText, await stderrText);
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _expectPortClosed(int port) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    try {
      final socket = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(milliseconds: 300));
      socket.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    } on SocketException {
      return;
    }
  }
  fail('port $port is still open: engine process survived its parent');
}

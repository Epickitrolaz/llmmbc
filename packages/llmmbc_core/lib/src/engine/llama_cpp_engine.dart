import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../constants.dart';
import '../interfaces.dart';
import '../models.dart';
import 'engine_locator.dart';
import 'planner.dart';

/// The shell used for the parent-watching supervisor. Android does not always
/// have a `/bin` symlink, so it uses the platform shell directly.
String supervisorShell({bool? android}) =>
    (android ?? Platform.isAndroid) ? '/system/bin/sh' : '/bin/sh';

/// Supervises the two llama.cpp processes this node runs.
///
/// `rpc-server` is used on workers, `llama-server` on the session coordinator.
/// Both are started with the shared-library environment prepared by
/// [engineProcessEnvironment], their output is captured in a 200-line ring and
/// their whole process tree is killed on stop and on Dart process termination.
class LlamaCppEngine implements InferenceEngine {
  /// [planner] defaults to `DefaultClusterPlanner()`.
  LlamaCppEngine({required EngineLocator locator, ClusterPlanner? planner})
      : _locator = locator,
        _planner = planner ?? const DefaultClusterPlanner();

  final EngineLocator _locator;
  final ClusterPlanner _planner;
  bool _signalGuardHeld = false;

  Process? _rpcProcess;
  Process? _coordinatorProcess;
  Uri? _coordinatorUri;
  bool _rpcExited = false;
  bool _coordinatorExited = false;

  final List<String> _log = [];
  static const int _maxLogLines = 200;

  @override
  Future<int> startRpcWorker(
      {required int port, required String cacheDir}) async {
    await stopRpcWorker();
    _rpcExited = false;
    final exe = await _locator.rpcServerPath();
    if (exe == null) {
      throw LlmmbcException('engine_error',
          'rpc-server binary not found (engine location unavailable)');
    }
    await Directory(cacheDir).create(recursive: true);

    final candidates = await _rpcPortCandidates(port);
    if (candidates.isEmpty) {
      throw LlmmbcException('engine_error',
          'no free rpc-server port in 47102..47131 (requested $port)\n${_tail()}');
    }
    final env = {
      ...engineProcessEnvironment(File(exe).parent.path),
      'LLAMA_CACHE': Directory(cacheDir).absolute.path,
    };

    String? lastError;
    for (final candidate in candidates) {
      _rpcExited = false;
      final process = await _start(
        exe,
        ['-H', '0.0.0.0', '-p', '$candidate', '-c'],
        env,
        'rpc-server',
      );
      _rpcProcess = process;
      try {
        await _waitForRpc(process, candidate);
        // Guard against a foreign listener on the requested port: our own
        // process must still be alive shortly after the connect succeeds.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (_rpcExited) {
          throw LlmmbcException('engine_error',
              'rpc-server exited after binding port $candidate\n${_tail()}');
        }
        return candidate;
      } on LlmmbcException catch (e) {
        lastError = e.message;
        await _stopProcess(process, 'rpc-server');
        _rpcProcess = null;
      }
    }
    throw LlmmbcException('engine_error',
        lastError ?? 'rpc-server failed to start on any free port\n${_tail()}');
  }

  /// Ports to try, in order: the requested one when free, then the
  /// per-host RPC range (47102..47131), then an OS-assigned port. Only free
  /// candidates are returned, so two nodes on one host never share a port.
  Future<List<int>> _rpcPortCandidates(int requested) async {
    final candidates = <int>[];
    // 47103 is reserved for the local llama-server (docs/ARCHITECTURE.md §7):
    // never hand it to an rpc-server on the same host.
    if (requested > 0 &&
        requested != kLlamaServerPort &&
        await _portFree(requested)) {
      candidates.add(requested);
    }
    for (var p = kRpcServerPort;
        p <= kRpcServerPort + 29 && candidates.length < 3;
        p++) {
      if (p == requested || p == kLlamaServerPort) continue;
      if (await _portFree(p)) candidates.add(p);
    }
    if (candidates.length < 3) {
      final ephemeral = await _ephemeralPort();
      if (ephemeral > 0) candidates.add(ephemeral);
    }
    return candidates;
  }

  Future<bool> _portFree(int port) async {
    try {
      final socket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      await socket.close();
      return true;
    } on SocketException {
      return false;
    }
  }

  Future<int> _ephemeralPort() async {
    try {
      final socket = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      final port = socket.port;
      await socket.close();
      return port;
    } on SocketException {
      return 0;
    }
  }

  @override
  Future<void> stopRpcWorker() async {
    final process = _rpcProcess;
    _rpcProcess = null;
    _rpcExited = false;
    await _stopProcess(process, 'rpc-server');
    _maybeReleaseSignalGuard();
  }

  @override
  bool get rpcWorkerRunning => _rpcProcess != null && !_rpcExited;

  @override
  Future<Uri> startCoordinator(
      {required LocalModel model,
      required ClusterPlan plan,
      required int port}) async {
    await stopCoordinator();
    _coordinatorExited = false;
    final exe = await _locator.llamaServerPath();
    if (exe == null) {
      throw LlmmbcException('engine_error',
          'llama-server binary not found (engine location unavailable)');
    }
    if (!await File(model.ggufPath).exists()) {
      throw LlmmbcException(
          'engine_error', 'model file not found: ${model.ggufPath}');
    }
    final endpoints = <String>{};
    for (final node in plan.nodes) {
      final endpoint = node.rpcEndpoint;
      if (endpoint != null && !endpoints.add(endpoint)) {
        throw LlmmbcException(
            'engine_error', 'duplicate RPC endpoint in plan: $endpoint');
      }
    }

    final args = [
      '-m',
      model.ggufPath,
      '--host',
      '127.0.0.1',
      '--port',
      '$port',
      if (_planner is DefaultClusterPlanner)
        ..._planner.llamaServerArgsForModel(plan, model)
      else
        ..._planner.llamaServerArgs(plan),
      // Loader/placement diagnostics; the ring is bounded to 200 lines anyway.
      '-lv',
      '4',
    ];
    final process = await _start(exe, args,
        engineProcessEnvironment(File(exe).parent.path), 'llama-server');
    _coordinatorProcess = process;

    final uri = Uri(scheme: 'http', host: '127.0.0.1', port: port);
    final timeout = _loadTimeout(model);
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_coordinatorExited) {
        await stopCoordinator();
        throw LlmmbcException('engine_error',
            'llama-server exited before becoming healthy\n${_tail()}');
      }
      if (await _healthy(uri)) {
        _coordinatorUri = uri;
        return uri;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    await stopCoordinator();
    throw LlmmbcException(
        'engine_error',
        'llama-server did not become healthy within ${timeout.inSeconds}s '
            '(${_fmtBytes(model.sizeBytes)} model)\n${_tail()}');
  }

  @override
  Future<void> stopCoordinator() async {
    final process = _coordinatorProcess;
    _coordinatorProcess = null;
    _coordinatorUri = null;
    _coordinatorExited = false;
    await _stopProcess(process, 'llama-server');
    _maybeReleaseSignalGuard();
  }

  /// Stops both managed processes and releases the signal subscriptions.
  Future<void> dispose() async {
    await stopCoordinator();
    await stopRpcWorker();
  }

  @override
  bool get coordinatorRunning =>
      _coordinatorProcess != null && !_coordinatorExited;

  /// The coordinator's base URI while it is running (not part of the interface).
  Uri? get coordinatorUri => coordinatorRunning ? _coordinatorUri : null;

  @override
  List<String> get logTail => List.unmodifiable(_log);

  // -------------------------------------------------------------------------
  // Processes
  // -------------------------------------------------------------------------

  Future<Process> _start(String exe, List<String> args, Map<String, String> env,
      String name) async {
    try {
      // On POSIX the process is launched through a tiny shell supervisor. It
      // forwards TERM/INT to the engine and watches the Dart parent: if the VM
      // goes away (including a bare exit(0) that skips stop()), the engine is
      // terminated. Windows has no portable equivalent; there taskkill /T is
      // used on the explicit stop path and the README documents the limitation.
      final process = Platform.isWindows
          ? await Process.start(
              exe,
              args,
              workingDirectory: File(exe).parent.path,
              environment: env,
              includeParentEnvironment: false,
            )
          : await Process.start(
              '/bin/sh',
              ['-c', _supervisorScript, 'llmmbc-engine', '$pid', exe, ...args],
              workingDirectory: File(exe).parent.path,
              environment: env,
              includeParentEnvironment: false,
            );
      if (!_signalGuardHeld) {
        _EngineSignalGuard.acquire(this);
        _signalGuardHeld = true;
      }
      _pump(process.stdout, name);
      _pump(process.stderr, name);
      unawaited(process.exitCode.then((code) {
        if (name == 'rpc-server') {
          _rpcExited = true;
        } else {
          _coordinatorExited = true;
        }
        _append(name, 'exited with code $code');
        _maybeReleaseSignalGuard();
      }));
      return process;
    } on ProcessException catch (e) {
      throw LlmmbcException(
          'engine_error', 'failed to start $name ($exe): ${e.message}');
    }
  }

  /// Only holds SIGINT/SIGTERM subscriptions while at least one child is alive,
  /// so an idle `LlamaCppEngine` never keeps the Dart VM alive.
  void _maybeReleaseSignalGuard() {
    final rpcDone = _rpcProcess == null || _rpcExited;
    final coordinatorDone = _coordinatorProcess == null || _coordinatorExited;
    if (rpcDone && coordinatorDone && _signalGuardHeld) {
      _signalGuardHeld = false;
      _EngineSignalGuard.release(this);
    }
  }

  static const String _supervisorScript = r'''
dart_pid="$1"; shift
if [ -x /system/bin/sleep ]; then sleep_bin=/system/bin/sleep; else sleep_bin=sleep; fi
"$@" &
child=$!
(
  while kill -0 "$dart_pid" 2>/dev/null; do "$sleep_bin" 1; done
  kill -TERM "$child" 2>/dev/null
  "$sleep_bin" 2
  kill -KILL "$child" 2>/dev/null
) &
watchdog=$!
trap 'kill -TERM "$child" 2>/dev/null; kill "$watchdog" 2>/dev/null' TERM INT
wait "$child"
status=$?
kill "$watchdog" 2>/dev/null
wait "$watchdog" 2>/dev/null
exit "$status"
''';

  void _pump(Stream<List<int>> stream, String name) {
    stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _append(name, line), onError: (Object _) {});
  }

  void _append(String source, String line) {
    if (line.isEmpty) return;
    _log.add('[$source] $line');
    if (_log.length > _maxLogLines) {
      _log.removeRange(0, _log.length - _maxLogLines);
    }
  }

  String _tail([int lines = 40]) {
    final start = _log.length > lines ? _log.length - lines : 0;
    return _log.sublist(start).join('\n');
  }

  Future<void> _waitForRpc(Process process, int port) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      if (_rpcExited) {
        throw LlmmbcException(
            'engine_error', 'rpc-server exited before listening\n${_tail()}');
      }
      try {
        final socket = await Socket.connect('127.0.0.1', port,
            timeout: const Duration(milliseconds: 500));
        socket.destroy();
        return;
      } on SocketException {
        // Not listening yet.
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw LlmmbcException('engine_error',
        'rpc-server did not start listening on port $port\n${_tail()}');
  }

  Future<bool> _healthy(Uri base) async {
    final client = http.Client();
    try {
      final response = await client.get(base.resolve('/health'),
          headers: const {
            'Connection': 'close'
          }).timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } on Object {
      return false;
    } finally {
      client.close();
    }
  }

  Future<void> _stopProcess(Process? process, String name) async {
    if (process == null) return;
    final pid = process.pid;
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
      } on ProcessException {
        // Best effort; the exitCode await below still reaps the child.
      }
    } else {
      await _signalTree(pid, ProcessSignal.sigterm);
    }

    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      if (!Platform.isWindows) {
        await _signalTree(pid, ProcessSignal.sigkill);
      } else {
        try {
          await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
        } on ProcessException {
          // Ignore.
        }
      }
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        _append(name, 'still running after SIGKILL (pid $pid)');
      }
    }
  }

  /// Kills children first, then the process itself. pkill is best effort: it is
  /// absent on some minimal Android images, and llama.cpp binaries do not fork
  /// helpers, so the direct kill is the important part.
  Future<void> _signalTree(int pid, ProcessSignal signal) async {
    final flag = signal == ProcessSignal.sigkill ? '-KILL' : '-TERM';
    try {
      await Process.run('pkill', [flag, '-P', '$pid']);
    } on ProcessException {
      // pkill not available.
    }
    try {
      Process.killPid(pid, signal);
    } on ProcessException {
      // Already gone.
    }
  }

  /// Synchronous best-effort kill used from the signal handler.
  void killNow() {
    for (final process in [_rpcProcess, _coordinatorProcess]) {
      if (process == null) continue;
      final pid = process.pid;
      if (!Platform.isWindows) {
        Process.runSync('pkill', ['-KILL', '-P', '$pid']);
        Process.killPid(pid, ProcessSignal.sigkill);
      } else {
        Process.runSync('taskkill', ['/PID', '$pid', '/T', '/F']);
      }
    }
  }

  /// First 10 minutes cap; grows with model size so large models on slow disks
  /// are not killed while llama.cpp is still mmap-ing/loading tensors.
  Duration _loadTimeout(LocalModel model) {
    final seconds = 60 + model.sizeBytes ~/ (2 * 1024 * 1024);
    const max = Duration(minutes: 10);
    final duration = Duration(seconds: seconds);
    return duration > max ? max : duration;
  }

  String _fmtBytes(int bytes) {
    final gib = bytes / (1024 * 1024 * 1024);
    return gib >= 1
        ? '${gib.toStringAsFixed(1)} GiB'
        : '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MiB';
  }
}

/// Cancellable SIGINT/SIGTERM subscriptions, installed only while a supervised
/// child is running. Constructing an engine therefore never pins the VM's event
/// loop, and stopping the last child lets a CLI exit normally.
class _EngineSignalGuard {
  static final Set<LlamaCppEngine> _engines = Set<LlamaCppEngine>.identity();
  static final List<StreamSubscription<ProcessSignal>> _subscriptions = [];

  static void acquire(LlamaCppEngine engine) {
    _engines.add(engine);
    if (_subscriptions.isNotEmpty || Platform.isWindows) return;
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
      try {
        _subscriptions.add(signal.watch().listen((_) {
          for (final engine in List<LlamaCppEngine>.of(_engines)) {
            engine.killNow();
          }
          exit(0);
        }));
      } on SignalException {
        // Not supported on this platform; nothing to do.
      }
    }
  }

  static void release(LlamaCppEngine engine) {
    _engines.remove(engine);
    if (_engines.isNotEmpty) return;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }
}

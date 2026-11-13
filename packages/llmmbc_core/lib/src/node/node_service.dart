// core-net: `NodeService` facade, session manager and coordinator (§2).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../api/node_api_server.dart';
import '../api/node_client.dart';
import '../api/sse.dart';
import '../constants.dart';
import '../discovery/lan_discovery.dart';
import '../engine/engine_locator.dart';
import '../engine/llama_cpp_engine.dart';
import '../engine/planner.dart';
import '../hardware/hardware_probe.dart';
import '../interfaces.dart';
import '../models.dart';
import '../registry/model_store.dart';

const String _kAppVersion = '0.1.0';

class _WorkerSession {
  final String sessionId;
  final ModelRef model;
  final String coordinatorId;
  final int port;
  final int budgetBytes;
  final DateTime startedAt;

  _WorkerSession({
    required this.sessionId,
    required this.model,
    required this.coordinatorId,
    required this.port,
    required this.budgetBytes,
    required this.startedAt,
  });
}

class _CoordinatorSession {
  SessionInfo info;
  final Uri engineUri;
  final Set<String> candidateIds;
  final Map<String, Uri> workerBases;
  Timer? idleTimer;

  _CoordinatorSession({
    required this.info,
    required this.engineUri,
    required this.candidateIds,
    required this.workerBases,
  });
}

class _ClusterAccumulator {
  final List<NodeInfo> nodes = [];
  final List<LocalModel> models = [];
}

/// The facade used by the Flutter app and the headless CLI.
///
/// [LocalNodeService.internal] takes every collaborator so tests can inject fakes;
/// [LocalNodeService.create] wires the concrete default implementations.
class LocalNodeService implements NodeService {
  final HardwareProbe _hardwareProbe;
  final ModelStore _modelStore;
  final Discovery _discovery;
  final NodeClient _client;
  final EngineLocator _locator;
  final InferenceEngine _engine;
  final ClusterPlanner _planner;
  final PlatformHooks _platform;
  final String _settingsPath;
  final DateTime Function() _now;
  final Duration _idleTimeout;
  final http.Client _http;

  NodeSettings _settings;
  HardwareProfile _hardware;
  List<LocalModel> _localModels = const [];
  bool _engineAvailable = false;
  int _apiPort;
  String _host = '127.0.0.1';
  bool _running = false;

  NodeApiServer? _api;
  _WorkerSession? _workerSession;
  _CoordinatorSession? _coordinatorSession;
  Future<void> _sessionQueue = Future.value();

  final StreamController<String> _phases = StreamController<String>.broadcast();
  final StreamController<void> _changed = StreamController<void>.broadcast();
  StreamSubscription<List<NodeInfo>>? _discoverySub;

  LocalNodeService.internal({
    required NodeSettings settings,
    required HardwareProbe hardwareProbe,
    required ModelStore modelStore,
    required Discovery discovery,
    required NodeClient client,
    required EngineLocator locator,
    required InferenceEngine engine,
    required ClusterPlanner planner,
    required String settingsPath,
    PlatformHooks platform = const PlatformHooks(),
    DateTime Function()? now,
    Duration sessionIdleTimeout = kSessionIdleTimeout,
    http.Client? httpClient,
  })  : _settings = platform.clientOnly
            ? settings.copyWith(workerEnabled: false)
            : settings,
        _hardwareProbe = hardwareProbe,
        _modelStore = modelStore,
        _discovery = discovery,
        _client = client,
        _locator = locator,
        _engine = engine,
        _planner = planner,
        _platform = platform,
        _settingsPath = settingsPath,
        _now = now ?? DateTime.now,
        _idleTimeout = sessionIdleTimeout,
        _http = httpClient ?? http.Client(),
        _hardware = _fallbackHardware(),
        _apiPort = settings.apiPort;

  /// Loads/creates settings at [settingsPath] (JSON of NodeSettings), defaulting dataDir to
  /// [defaultDataDir]. Wires LocalHardwareProbe, FileModelStore, LanDiscovery, HttpNodeClient,
  /// DefaultEngineLocator, LlamaCppEngine, DefaultClusterPlanner and NodeApiServer.
  static Future<LocalNodeService> create({
    required String settingsPath,
    required String defaultDataDir,
    PlatformHooks platform = const PlatformHooks(),
  }) async {
    final settings =
        await _loadOrCreateSettings(settingsPath, defaultDataDir, platform);
    final client = HttpNodeClient();
    final envEngineDir = Platform.environment['LLMMBC_ENGINE_DIR'];
    final effective = envEngineDir != null && envEngineDir.isNotEmpty
        ? settings.copyWith(engineDir: envEngineDir)
        : settings;
    final locator =
        DefaultEngineLocator(engineDir: effective.engineDir, hooks: platform);
    final service = LocalNodeService.internal(
      settings: effective,
      hardwareProbe: LocalHardwareProbe(hooks: platform),
      modelStore: FileModelStore(effective.dataDir),
      discovery: LanDiscovery(client: client, hooks: platform),
      client: client,
      locator: locator,
      engine: LlamaCppEngine(locator: locator),
      planner: const DefaultClusterPlanner(),
      settingsPath: settingsPath,
      platform: platform,
    );
    await service._persistSettings();
    return service;
  }

  static Future<NodeSettings> _loadOrCreateSettings(
    String settingsPath,
    String defaultDataDir,
    PlatformHooks platform,
  ) async {
    final file = File(settingsPath);
    NodeSettings? loaded;
    if (await file.exists()) {
      try {
        loaded = NodeSettings.fromJson(
            jsonDecode(await file.readAsString()) as Map<String, dynamic>);
      } on Object {
        loaded = null;
      }
    }
    final settings = loaded ??
        NodeSettings(
          nodeId: const Uuid().v4(),
          name: _defaultName(),
          dataDir: defaultDataDir,
          workerEnabled: !platform.clientOnly,
          apiPort: kNodeApiPort,
        );
    if (platform.clientOnly) return settings.copyWith(workerEnabled: false);
    return settings;
  }

  static String _defaultName() {
    try {
      final host = Platform.localHostname;
      if (host.isNotEmpty) return host;
    } on Object {
      // no hostname available
    }
    return 'llmmbc-node';
  }

  static HardwareProfile _fallbackHardware() => HardwareProfile(
        os: Platform.operatingSystem,
        arch: 'unknown',
        cpuModel: '',
        cpuCores: Platform.numberOfProcessors,
        totalRamBytes: 4 << 30,
        availableRamBytes: 2 << 30,
      );

  bool get _workerEnabled => _settings.workerEnabled && !_platform.clientOnly;

  NodeStatus get _status {
    if (_workerSession != null) return NodeStatus.worker;
    if (_coordinatorSession != null) return NodeStatus.coordinator;
    return NodeStatus.idle;
  }

  // ---------------------------------------------------------------------------
  // NodeService surface
  // ---------------------------------------------------------------------------

  @override
  NodeSettings get settings => _settings;

  @override
  Future<void> updateSettings(NodeSettings next) async {
    final effective =
        _platform.clientOnly ? next.copyWith(workerEnabled: false) : next;
    final manualChanged =
        effective.manualPeers.length != _settings.manualPeers.length ||
            !effective.manualPeers.every(_settings.manualPeers.contains);
    _settings = effective;
    await _persistSettings();
    if (!_workerEnabled && _workerSession != null) {
      await _stopWorkerSession();
    }
    if (manualChanged) {
      for (final peer in effective.manualPeers) {
        unawaited(_discovery.addManualPeer(peer));
      }
    }
    _emitChanged();
  }

  @override
  Stream<String> get startupPhase => _phases.stream;

  @override
  HardwareProfile get hardware => _hardware;

  @override
  NodeInfo get self => NodeInfo(
        nodeId: _settings.nodeId,
        name: _settings.name,
        host: _host,
        apiPort: _apiPort,
        protocolVersion: kProtocolVersion,
        appVersion: _kAppVersion,
        workerEnabled: _workerEnabled,
        engineAvailable: _engineAvailable,
        status: _status,
        hardware: _hardware,
        models: List<LocalModel>.unmodifiable(_localModels),
        reachable: true,
        isSelf: true,
        lastSeen: _now(),
      );

  @override
  ModelStore get models => _modelStore;

  @override
  Discovery get discovery => _discovery;

  @override
  InferenceEngine get engine => _engine;

  @override
  Stream<void> get changed => _changed.stream;

  @override
  SessionInfo? get currentSession {
    final coordinator = _coordinatorSession;
    if (coordinator != null) return coordinator.info;
    final worker = _workerSession;
    if (worker != null) {
      return SessionInfo(
        sessionId: worker.sessionId,
        model: worker.model,
        coordinatorId: worker.coordinatorId,
        workerIds: const [],
        startedAt: worker.startedAt,
        lastUsedAt: worker.startedAt,
        plan: null,
      );
    }
    return null;
  }

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;

    _emitPhase('settings');
    await _persistSettings();
    _emitChanged();

    _emitPhase('hardware');
    try {
      _hardware = await _hardwareProbe.scan();
    } on Object {
      _hardware = _fallbackHardware();
    }
    _emitChanged();

    _emitPhase('models');
    try {
      _localModels = await _modelStore.list();
    } on Object {
      _localModels = const [];
    }
    _emitChanged();

    _emitPhase('api');
    await _resolveHost();
    try {
      _engineAvailable = await _locator.available;
    } on Object {
      _engineAvailable = false;
    }
    _api = NodeApiServer(this);
    try {
      _apiPort = await _api!.start(port: _settings.apiPort);
    } on Object {
      // The configured port is taken; fall back to an ephemeral one so the node
      // stays reachable (discovery beacons advertise the actual port).
      try {
        _apiPort = await _api!.start(port: 0);
      } on Object {
        _apiPort = 0;
      }
    }
    _emitChanged();

    _emitPhase('discovery');
    _discoverySub ??= _discovery.peersChanged.listen((_) => _emitChanged());
    try {
      await _discovery.start(() => self, _settings);
    } on Object {
      // Discovery must never prevent the node from serving its API.
    }
    _emitChanged();

    _emitPhase('ready');
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _discoverySub?.cancel();
    _discoverySub = null;
    try {
      await _discovery.stop();
    } on Object {
      // ignore
    }
    await _stopCoordinatorSession(notify: false);
    await _stopWorkerSession(notify: false);
    await _api?.stop();
    _api = null;
    _changed.add(null);
  }

  @override
  List<ClusterModel> clusterModels() {
    final accumulator = <ModelRef, _ClusterAccumulator>{};
    final nodes = <NodeInfo>[self, ..._discovery.peers];
    for (final node in nodes) {
      if (!node.reachable || !node.workerEnabled) continue;
      for (final model in node.models) {
        final acc = accumulator.putIfAbsent(model.ref, _ClusterAccumulator.new);
        acc.nodes.add(node);
        acc.models.add(model);
      }
    }

    final result = <ClusterModel>[];
    accumulator.forEach((ref, acc) {
      final candidates = acc.nodes.where((n) => n.isCandidateFor(ref)).toList();
      final withMetadata = acc.models.where((m) => m.metadata != null);
      final model =
          withMetadata.isNotEmpty ? withMetadata.first : acc.models.first;
      result.add(ClusterModel(
        ref: ref,
        sizeBytes: model.sizeBytes,
        metadata: model.metadata,
        candidates: candidates,
      ));
    });
    result.sort((a, b) => a.ref.toString().compareTo(b.ref.toString()));
    return result;
  }

  @override
  Stream<ChatDelta> chat(
    ModelRef model,
    List<ChatMessage> messages, {
    double? temperature,
    int? maxTokens,
  }) async* {
    final candidates = _candidatesFor(model);
    if (candidates.isEmpty) {
      throw LlmmbcException('no_candidates', 'no node can run $model');
    }
    final coordinator = _pickCoordinator(candidates);
    if (coordinator.isSelf) {
      yield* handleChat(model, messages,
          temperature: temperature, maxTokens: maxTokens);
    } else {
      yield* _client.chat(
        coordinator.baseUri,
        model,
        messages,
        temperature: temperature,
        maxTokens: maxTokens,
      );
    }
  }

  List<NodeInfo> _candidatesFor(ModelRef ref) {
    final nodes = <NodeInfo>[self, ..._discovery.peers];
    return nodes.where((n) => n.isCandidateFor(ref)).toList();
  }

  NodeInfo _pickCoordinator(List<NodeInfo> candidates) {
    final sorted = [...candidates]..sort((a, b) {
        final byMemory = b.hardware.usableMemoryBytes
            .compareTo(a.hardware.usableMemoryBytes);
        return byMemory != 0 ? byMemory : a.nodeId.compareTo(b.nodeId);
      });
    return sorted.first;
  }

  // ---------------------------------------------------------------------------
  // Coordinator side
  // ---------------------------------------------------------------------------

  /// Handles a chat request when this node has been selected as coordinator.
  ///
  /// Unlike [chat] this never routes to another node, which keeps the wire
  /// protocol loop-free.
  Stream<ChatDelta> handleChat(
    ModelRef model,
    List<ChatMessage> messages, {
    double? temperature,
    int? maxTokens,
  }) async* {
    final session = await _serialize(() => _ensureCoordinatorSession(model));
    _touchSession();

    final request =
        http.Request('POST', session.engineUri.resolve('/v1/chat/completions'))
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode({
            'model': model.toString(),
            'messages': [for (final m in messages) m.toJson()],
            'stream': true,
            if (temperature != null) 'temperature': temperature,
            if (maxTokens != null) 'max_tokens': maxTokens,
          });

    final http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } on Object catch (e) {
      throw _wrapEngineError(e);
    }
    if (response.statusCode != HttpStatus.ok) {
      final body = await response.stream.bytesToString();
      throw LlmmbcException('engine_error', body,
          httpStatus: response.statusCode);
    }
    await for (final delta
        in parseOpenAiSse(response.stream, servedBy: _settings.nodeId)) {
      _touchSession();
      yield delta;
    }
  }

  /// `POST /v1/rpc/start` handler: join a session as a worker.
  Future<({String host, int port, int budgetBytes})> handleRpcStart({
    required String sessionId,
    required ModelRef model,
    required String coordinatorId,
    String? hostHint,
  }) async {
    if (!_workerEnabled) {
      throw LlmmbcException(
          'not_candidate', 'worker mode is disabled on this node',
          httpStatus: 403);
    }
    if (!_engineAvailable) {
      throw LlmmbcException(
          'not_candidate', 'engine binaries are unavailable on this node',
          httpStatus: 403);
    }
    final local = await _findLocalModel(model);
    if (local == null) {
      throw LlmmbcException(
          'not_candidate', '$model is not downloaded on this node',
          httpStatus: 403);
    }

    final existing = _workerSession;
    if (existing != null) {
      if (existing.sessionId == sessionId) {
        return (
          host: hostHint ?? _host,
          port: existing.port,
          budgetBytes: existing.budgetBytes
        );
      }
      throw LlmmbcException(
          'busy', 'node is already participating in another session',
          httpStatus: 409);
    }
    if (_coordinatorSession != null) {
      throw LlmmbcException('busy', 'node is coordinating a session',
          httpStatus: 409);
    }

    final budget = _budgetBytes();
    final cacheDir = p.join(_settings.dataDir, 'rpc-cache');
    try {
      await Directory(cacheDir).create(recursive: true);
    } on FileSystemException {
      // The engine will surface a meaningful error if this is fatal.
    }

    final int port;
    try {
      port = await _engine.startRpcWorker(
          port: kRpcServerPort, cacheDir: cacheDir);
    } on Object catch (e) {
      throw _wrapEngineError(e);
    }

    _workerSession = _WorkerSession(
      sessionId: sessionId,
      model: model,
      coordinatorId: coordinatorId,
      port: port,
      budgetBytes: budget,
      startedAt: _now(),
    );
    _emitChanged();
    return (host: hostHint ?? _host, port: port, budgetBytes: budget);
  }

  /// `POST /v1/rpc/stop` handler.
  Future<void> handleRpcStop(String sessionId) async {
    final worker = _workerSession;
    if (worker == null || worker.sessionId != sessionId) return;
    await _stopWorkerSession();
  }

  Future<_CoordinatorSession> _ensureCoordinatorSession(ModelRef model) async {
    final local = await _findLocalModel(model);
    if (local == null) {
      throw LlmmbcException(
          'not_candidate', '$model is not downloaded on this node',
          httpStatus: 403);
    }
    if (_workerSession != null) {
      throw LlmmbcException('busy', 'node is already serving as a worker',
          httpStatus: 409);
    }

    // C's own view of the candidate set, refreshed (§2.3.4).
    try {
      await _discovery.scan().timeout(const Duration(seconds: 2));
    } on Object {
      // Keep the current directory when the refresh is slow or unsupported.
    }

    final candidates = _candidatesFor(model);
    final candidateIds = {for (final c in candidates) c.nodeId};
    final previous = _coordinatorSession;
    if (previous != null &&
        previous.info.model == model &&
        previous.candidateIds.length == candidateIds.length &&
        previous.candidateIds.containsAll(candidateIds) &&
        _engine.coordinatorRunning) {
      return previous;
    }
    if (candidates.isEmpty) {
      throw LlmmbcException('no_candidates', 'no node can run $model');
    }

    await _stopCoordinatorSession(notify: false);

    try {
      _hardware = await _hardwareProbe.refresh(_hardware);
    } on Object {
      // Keep the last profile when the cheap refresh fails.
    }

    final sessionId = const Uuid().v4();
    final workerBases = <String, Uri>{};
    final planNodes = <PlanNode>[
      PlanNode(
        nodeId: _settings.nodeId,
        rpcEndpoint: null,
        budgetBytes: _budgetBytes(),
        hasGpu: _hardware.gpus.any((g) => g.vramBytes > 0) ||
            _hardware.gpus.isNotEmpty,
      ),
    ];

    for (final candidate in candidates) {
      if (candidate.nodeId == _settings.nodeId) continue;
      try {
        final result = await _client.startRpc(
          candidate.baseUri,
          sessionId: sessionId,
          model: model,
          coordinatorId: _settings.nodeId,
        );
        workerBases[candidate.nodeId] = candidate.baseUri;
        planNodes.add(PlanNode(
          nodeId: candidate.nodeId,
          rpcEndpoint: '${result.host}:${result.port}',
          budgetBytes: result.budgetBytes,
          hasGpu: candidate.hardware.gpus.isNotEmpty,
        ));
      } on Object {
        // Failed or timed-out workers are dropped from S (§2.3.4).
      }
    }

    ClusterPlan plan;
    try {
      plan = _planner.plan(local, planNodes);
    } on PlanError catch (e) {
      await _stopWorkers(workerBases, sessionId);
      throw LlmmbcException('does_not_fit', e.message);
    } on Object catch (e) {
      await _stopWorkers(workerBases, sessionId);
      throw LlmmbcException('does_not_fit', e.toString());
    }

    final Uri engineUri;
    try {
      engineUri = await _engine.startCoordinator(
        model: local,
        plan: plan,
        port: kLlamaServerPort,
      );
    } on Object catch (e) {
      await _stopWorkers(workerBases, sessionId);
      try {
        await _engine.stopCoordinator();
      } on Object {
        // ignore
      }
      throw _wrapEngineError(e);
    }

    final now = _now();
    final session = _CoordinatorSession(
      info: SessionInfo(
        sessionId: sessionId,
        model: model,
        coordinatorId: _settings.nodeId,
        workerIds: workerBases.keys.toList(),
        startedAt: now,
        lastUsedAt: now,
        plan: plan.toJson(),
      ),
      engineUri: engineUri,
      candidateIds: candidateIds,
      workerBases: workerBases,
    );
    _coordinatorSession = session;
    _armIdleTimer();
    _emitChanged();
    return session;
  }

  void _touchSession() {
    final session = _coordinatorSession;
    if (session == null) return;
    final now = _now();
    final info = session.info;
    session.info = SessionInfo(
      sessionId: info.sessionId,
      model: info.model,
      coordinatorId: info.coordinatorId,
      workerIds: info.workerIds,
      startedAt: info.startedAt,
      lastUsedAt: now,
      plan: info.plan,
    );
    _armIdleTimer();
  }

  void _armIdleTimer() {
    final session = _coordinatorSession;
    if (session == null) return;
    session.idleTimer?.cancel();
    session.idleTimer =
        Timer(_idleTimeout, () => unawaited(_expireSession(session)));
  }

  Future<void> _expireSession(_CoordinatorSession session) async {
    if (!identical(_coordinatorSession, session)) return;
    if (_now().difference(session.info.lastUsedAt) < _idleTimeout) {
      _armIdleTimer();
      return;
    }
    await _stopCoordinatorSession();
  }

  Future<void> _stopCoordinatorSession({bool notify = true}) async {
    final session = _coordinatorSession;
    if (session == null) return;
    _coordinatorSession = null;
    session.idleTimer?.cancel();
    try {
      await _engine.stopCoordinator();
    } on Object {
      // ignore
    }
    await _stopWorkers(session.workerBases, session.info.sessionId);
    if (notify) _emitChanged();
  }

  Future<void> _stopWorkers(Map<String, Uri> workers, String sessionId) async {
    for (final base in workers.values) {
      try {
        await _client.stopRpc(base, sessionId);
      } on Object {
        // A worker that already went away is fine.
      }
    }
  }

  Future<void> _stopWorkerSession({bool notify = true}) async {
    final worker = _workerSession;
    if (worker == null) return;
    _workerSession = null;
    try {
      await _engine.stopRpcWorker();
    } on Object {
      // ignore
    }
    if (notify) _emitChanged();
  }

  Future<LocalModel?> _findLocalModel(ModelRef ref) async {
    for (final model in _localModels) {
      if (model.ref == ref) return model;
    }
    try {
      final found = await _modelStore.find(ref);
      if (found != null) {
        _localModels = [..._localModels, found];
      }
      return found;
    } on Object {
      return null;
    }
  }

  int _budgetBytes() {
    final raw = (_hardware.usableMemoryBytes * _settings.memoryShare).floor();
    return raw < 0 ? 0 : raw;
  }

  Future<void> _resolveHost() async {
    try {
      final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      for (final iface in interfaces) {
        for (final address in iface.addresses) {
          final value = address.address;
          if (value.startsWith('169.254.') || value.startsWith('100.')) {
            continue;
          }
          _host = value;
          return;
        }
      }
    } on Object {
      // fall back to loopback
    }
    _host = '127.0.0.1';
  }

  LlmmbcException _wrapEngineError(Object error) {
    if (error is LlmmbcException) return error;
    final tail = _engine.logTail;
    final detail = tail.isEmpty
        ? error.toString()
        : '${error.toString()}\n${tail.join('\n')}';
    return LlmmbcException('engine_error', detail);
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _sessionQueue.then((_) => action());
    _sessionQueue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _persistSettings() async {
    try {
      final file = File(_settingsPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(_settings.toJson()));
    } on FileSystemException {
      // Settings persistence is best-effort; the in-memory settings still work.
    }
  }

  void _emitPhase(String phase) {
    if (!_phases.isClosed) _phases.add(phase);
  }

  void _emitChanged() {
    if (!_changed.isClosed) _changed.add(null);
  }
}

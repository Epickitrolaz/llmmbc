/// UI-only node service used when the core runtime is not wired up (stub build)
/// or fails to start. It keeps the app usable and honest: real hardware data,
/// persisted settings, manual peer probes, but no local engine and no downloads.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:llmmbc_core/llmmbc_core.dart';

import 'local_hardware.dart';

String generateNodeId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Degraded implementation of [NodeService].
class DegradedNodeService implements NodeService {
  DegradedNodeService._({
    required this.settingsPath,
    required NodeSettings settings,
    required HardwareProfile hardware,
    required PlatformHooks platform,
  })  : _settings = settings,
        _hardware = hardware,
        _platform = platform {
    _discovery = _DegradedDiscovery(this);
  }

  final String settingsPath;
  final PlatformHooks _platform;
  NodeSettings _settings;
  final HardwareProfile _hardware;
  late final _DegradedDiscovery _discovery;
  final StreamController<String> _phases = StreamController<String>.broadcast();
  final StreamController<void> _changed = StreamController<void>.broadcast();
  final ModelStore _models = _UnavailableModelStore();
  final InferenceEngine _engine = _UnavailableEngine();
  SessionInfo? _session;

  /// Creates the service, loading or creating `<settingsPath>`.
  static Future<DegradedNodeService> create({
    required String settingsPath,
    required String defaultDataDir,
    PlatformHooks platform = const PlatformHooks(),
  }) async {
    NodeSettings settings;
    final file = File(settingsPath);
    if (file.existsSync()) {
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map<String, dynamic>) {
          settings = NodeSettings.fromJson(decoded);
        } else {
          throw const FormatException('settings must be a JSON object');
        }
      } catch (_) {
        settings = NodeSettings(
          nodeId: generateNodeId(),
          name: _defaultName(),
          dataDir: defaultDataDir,
          workerEnabled: !platform.clientOnly,
        );
      }
    } else {
      settings = NodeSettings(
        nodeId: generateNodeId(),
        name: _defaultName(),
        dataDir: defaultDataDir,
        workerEnabled: !platform.clientOnly,
      );
    }
    if (platform.clientOnly && settings.workerEnabled) {
      settings = settings.copyWith(workerEnabled: false);
    }
    final hardware = await probeLocalHardware(hooks: platform);
    final service = DegradedNodeService._(
      settingsPath: settingsPath,
      settings: settings,
      hardware: hardware,
      platform: platform,
    );
    service._persist();
    return service;
  }

  static String _defaultName() {
    try {
      final host = Platform.localHostname;
      if (host.isNotEmpty && host != 'localhost') return host;
    } catch (_) {
      // ignore
    }
    return 'LLMMBC node';
  }

  void _persist() {
    try {
      final file = File(settingsPath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(_settings.toJson()), flush: true);
    } catch (_) {
      // Settings persistence is best effort in degraded mode.
    }
  }

  @override
  NodeSettings get settings => _settings;

  @override
  Future<void> updateSettings(NodeSettings settings) async {
    _settings = settings;
    _persist();
    _changed.add(null);
  }

  @override
  Future<void> start() async {
    for (final phase in const ['settings', 'hardware', 'models', 'network']) {
      _phases.add(phase);
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }
    _phases.add('ready');
  }

  @override
  Future<void> stop() async {
    await _discovery.stop();
  }

  @override
  Stream<String> get startupPhase => _phases.stream;

  @override
  HardwareProfile get hardware => _hardware;

  @override
  NodeInfo get self => NodeInfo(
        nodeId: _settings.nodeId,
        name: _settings.name,
        host: '127.0.0.1',
        apiPort: _settings.apiPort,
        workerEnabled: _settings.workerEnabled,
        engineAvailable: false,
        status: NodeStatus.idle,
        hardware: _hardware,
        models: const [],
        appVersion: '0.1.0',
        isSelf: true,
        reachable: true,
        lastSeen: DateTime.now(),
      );

  @override
  ModelStore get models => _models;

  @override
  Discovery get discovery => _discovery;

  @override
  InferenceEngine get engine => _engine;

  @override
  List<ClusterModel> clusterModels() {
    final nodes = [self, ..._discovery.peers].where((n) => n.reachable).toList();
    final byRef = <String, ClusterModel>{};
    for (final node in nodes) {
      for (final model in node.models) {
        final key = model.ref.toString();
        final candidates = [
          for (final other in nodes)
            if (other.isCandidateFor(model.ref)) other,
        ];
        final existing = byRef[key];
        if (existing == null || model.sizeBytes > existing.sizeBytes) {
          byRef[key] = ClusterModel(
            ref: model.ref,
            sizeBytes: model.sizeBytes,
            metadata: model.metadata,
            candidates: candidates,
          );
        }
      }
    }
    final result = byRef.values.toList()
      ..sort((a, b) {
        if (a.isMoe != b.isMoe) return a.isMoe ? -1 : 1;
        return a.ref.toString().compareTo(b.ref.toString());
      });
    return result;
  }

  @override
  Stream<void> get changed => _changed.stream;

  @override
  Stream<ChatDelta> chat(
    ModelRef model,
    List<ChatMessage> messages, {
    double? temperature,
    int? maxTokens,
  }) {
    return Stream<ChatDelta>.error(
      LlmmbcException(
        'no_candidates',
        'The local core runtime is unavailable in this build, so no node can run '
            '${model.toString()}. Install the LLMMBC engine binaries and restart the app.',
      ),
    );
  }

  @override
  SessionInfo? get currentSession => _session;

  /// Not part of [NodeService]: the app uses this to explain the degraded mode.
  bool get isDegraded => true;

  /// Exposed for the Settings screen (no engine in this build).
  PlatformHooks get platform => _platform;
}

class _UnavailableEngine implements InferenceEngine {
  @override
  Future<int> startRpcWorker({required int port, required String cacheDir}) async =>
      throw LlmmbcException('engine_error', 'Engine binaries are not installed on this build.');

  @override
  Future<void> stopRpcWorker() async {}

  @override
  bool get rpcWorkerRunning => false;

  @override
  Future<Uri> startCoordinator({
    required LocalModel model,
    required ClusterPlan plan,
    required int port,
  }) async =>
      throw LlmmbcException('engine_error', 'Engine binaries are not installed on this build.');

  @override
  Future<void> stopCoordinator() async {}

  @override
  bool get coordinatorRunning => false;

  @override
  List<String> get logTail => const [];
}

class _UnavailableModelStore implements ModelStore {
  static const CatalogEntry _qwen = CatalogEntry(
    ref: ModelRef('qwen3', tag: '0.6b'),
    title: 'Qwen3 0.6B',
    description: 'Tiny dense model, good for a first smoke test on one device.',
    isMoe: false,
    approxSizeBytes: 520 * 1024 * 1024,
  );

  @override
  String get modelsDir => '';

  @override
  Future<List<LocalModel>> list() async => const [];

  @override
  Future<LocalModel?> find(ModelRef ref) async => null;

  @override
  Stream<DownloadProgress> pull(ModelRef ref) => Stream<DownloadProgress>.error(
        LlmmbcException('internal', 'Model downloads need the core runtime, which is unavailable in this build.'),
      );

  @override
  Future<void> cancel(ModelRef ref) async {}

  @override
  Future<void> delete(ModelRef ref) async {}

  @override
  List<CatalogEntry> catalog() => const [
        CatalogEntry(
          ref: ModelRef('qwen3', tag: '30b-a3b'),
          title: 'Qwen3 30B A3B',
          description: 'Flagship MoE — 30B parameters, 3B active per token. Spreads well across phones.',
          isMoe: true,
          approxSizeBytes: 18 * 1024 * 1024 * 1024,
        ),
        CatalogEntry(
          ref: ModelRef('granite3.1-moe', tag: '1b'),
          title: 'Granite 3.1 MoE 1B',
          description: 'Small MoE for planner and E2E checks (~1.4 GB).',
          isMoe: true,
          approxSizeBytes: 1400 * 1024 * 1024,
        ),
        CatalogEntry(
          ref: ModelRef('mixtral', tag: '8x7b'),
          title: 'Mixtral 8x7B',
          description: 'Classic MoE, 8 experts with 2 active per token.',
          isMoe: true,
          approxSizeBytes: 26 * 1024 * 1024 * 1024,
        ),
        _qwen,
      ];

  @override
  Future<int> remoteSize(ModelRef ref) async => 0;
}

class _DegradedDiscovery implements Discovery {
  _DegradedDiscovery(this._service);

  final DegradedNodeService _service;
  final List<NodeInfo> _peers = [];
  final StreamController<List<NodeInfo>> _peersChanged =
      StreamController<List<NodeInfo>>.broadcast();
  bool _started = false;

  @override
  Future<void> start(NodeInfo Function() self, NodeSettings settings) async {
    _started = true;
  }

  @override
  Future<void> stop() async {
    _started = false;
  }

  @override
  Future<void> scan() async {
    final manual = _service.settings.manualPeers;
    final refreshed = <NodeInfo>[];
    for (final peer in manual) {
      final info = await _probe(peer);
      if (info != null) refreshed.add(info);
    }
    _peers
      ..clear()
      ..addAll(refreshed);
    _emit();
  }

  @override
  List<NodeInfo> get peers => List.unmodifiable(_peers);

  @override
  Stream<List<NodeInfo>> get peersChanged => _peersChanged.stream;

  @override
  Future<NodeInfo?> addManualPeer(String hostPort) async {
    final info = await _probe(hostPort);
    if (info == null) return null;
    _peers.removeWhere((peer) => peer.nodeId == info.nodeId);
    _peers.add(info);
    _emit();
    return info;
  }

  void _emit() {
    if (!_peersChanged.isClosed) _peersChanged.add(peers);
  }

  Future<NodeInfo?> _probe(String hostPort) async {
    if (!_started) _started = true;
    var host = hostPort.trim();
    if (host.isEmpty) return null;
    var port = kNodeApiPort;
    final colon = host.lastIndexOf(':');
    if (colon > 0) {
      final parsed = int.tryParse(host.substring(colon + 1));
      if (parsed != null) {
        port = parsed;
        host = host.substring(0, colon);
      }
    }
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 1200);
    try {
      final uri = Uri(scheme: 'http', host: host, port: port, path: '/v1/node');
      final request = await client.getUrl(uri).timeout(const Duration(milliseconds: 1500));
      final response = await request.close().timeout(const Duration(milliseconds: 1500));
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      final info = NodeInfo.fromJson(decoded);
      return info.copyWith(host: host, reachable: true, lastSeen: DateTime.now());
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

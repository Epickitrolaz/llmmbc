// Shared fakes for the core-net test suites.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llmmbc_core/llmmbc_core.dart';

HardwareProfile hw({
  int total = 8 << 30,
  int available = 4 << 30,
  List<GpuInfo> gpus = const [],
  String os = 'linux',
}) =>
    HardwareProfile(
      os: os,
      arch: 'x64',
      cpuModel: 'fake',
      cpuCores: 8,
      totalRamBytes: total,
      availableRamBytes: available,
      gpus: gpus,
    );

LocalModel localModel(String ref, {int size = 1024, GgufMetadata? metadata}) =>
    LocalModel(
        ref: ModelRef.parse(ref),
        ggufPath: '/models/$ref.gguf',
        sizeBytes: size,
        metadata: metadata);

NodeInfo nodeInfo(
  String id, {
  String? name,
  String host = '127.0.0.1',
  int apiPort = 47101,
  HardwareProfile? hardware,
  List<LocalModel> models = const [],
  bool worker = true,
  bool engine = true,
  NodeStatus status = NodeStatus.idle,
  bool reachable = true,
  bool isSelf = false,
  int memoryBudgetBytes = 0,
}) =>
    NodeInfo(
      nodeId: id,
      name: name ?? id,
      host: host,
      apiPort: apiPort,
      workerEnabled: worker,
      engineAvailable: engine,
      status: status,
      hardware: hardware ?? hw(),
      models: models,
      memoryBudgetBytes: memoryBudgetBytes,
      reachable: reachable,
      isSelf: isSelf,
    );

class FakeHardwareProbe implements HardwareProbe {
  HardwareProfile profile;
  int scans = 0;
  int refreshes = 0;

  FakeHardwareProbe(this.profile);

  @override
  Future<HardwareProfile> scan() async {
    scans++;
    return profile;
  }

  @override
  Future<HardwareProfile> refresh(HardwareProfile previous) async {
    refreshes++;
    return profile;
  }
}

class FakeModelStore implements ModelStore {
  List<LocalModel> stored;

  FakeModelStore([this.stored = const []]);

  @override
  String get modelsDir => '/fake/models';

  @override
  Future<List<LocalModel>> list() async => List.of(stored);

  @override
  Future<LocalModel?> find(ModelRef ref) async {
    for (final m in stored) {
      if (m.ref == ref) return m;
    }
    return null;
  }

  @override
  Stream<DownloadProgress> pull(ModelRef ref) => const Stream.empty();

  @override
  Future<void> cancel(ModelRef ref) async {}

  @override
  Future<void> delete(ModelRef ref) async {}

  @override
  List<CatalogEntry> catalog() => const [];

  @override
  Future<int> remoteSize(ModelRef ref) async => 0;
}

class FakeDiscovery implements Discovery {
  final List<NodeInfo> peerList;
  final Map<String, NodeInfo> manual = {};
  final StreamController<List<NodeInfo>> _changed =
      StreamController<List<NodeInfo>>.broadcast();
  NodeInfo Function()? selfProvider;
  NodeSettings? settings;
  int starts = 0;
  int scans = 0;
  int stops = 0;

  FakeDiscovery([List<NodeInfo>? peers]) : peerList = peers ?? [];

  @override
  Future<void> start(NodeInfo Function() self, NodeSettings settings) async {
    starts++;
    selfProvider = self;
    this.settings = settings;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> scan() async {
    scans++;
  }

  @override
  List<NodeInfo> get peers => List.unmodifiable(peerList);

  @override
  Stream<List<NodeInfo>> get peersChanged => _changed.stream;

  @override
  Future<NodeInfo?> addManualPeer(String hostPort) async {
    final value = manual[hostPort];
    if (value != null && !peerList.any((p) => p.nodeId == value.nodeId)) {
      peerList.add(value);
      _changed.add(peers);
    }
    return value;
  }
}

class RpcStartCall {
  final Uri base;
  final String sessionId;
  final ModelRef model;
  final String coordinatorId;
  RpcStartCall(this.base, this.sessionId, this.model, this.coordinatorId);
}

class FakeNodeClient implements NodeClient, ChatRouteClient {
  final Map<int, NodeInfo> infoByPort = {};
  final Map<int, List<NodeInfo>> peersByPort = {};
  final List<RpcStartCall> startRpcCalls = [];
  final List<({Uri base, String sessionId})> stopRpcCalls = [];
  final List<Uri> chatBases = [];
  final List<bool> chatRouteFlags = [];
  Map<int, int> rpcPortByApiPort = {};
  List<ChatDelta> chatDeltas = [
    const ChatDelta('remote '),
    const ChatDelta('answer', finishReason: 'stop'),
  ];
  LlmmbcException? startRpcError;
  SessionInfo? sessionResult;
  int infoCalls = 0;
  int concurrentInfoCalls = 0;
  int maxConcurrentInfoCalls = 0;
  Completer<void>? infoGate;

  @override
  Future<NodeInfo> info(Uri base, {Duration? timeout}) async {
    infoCalls++;
    concurrentInfoCalls++;
    if (concurrentInfoCalls > maxConcurrentInfoCalls) {
      maxConcurrentInfoCalls = concurrentInfoCalls;
    }
    try {
      final gate = infoGate;
      if (gate != null) await gate.future;
      final info = infoByPort[base.port];
      if (info == null) {
        throw LlmmbcException('not_found', 'no fake node on ${base.port}');
      }
      return info.copyWith(host: info.host.isEmpty ? base.host : info.host);
    } finally {
      concurrentInfoCalls--;
    }
  }

  @override
  Future<List<NodeInfo>> peers(Uri base) async =>
      peersByPort[base.port] ?? const [];

  @override
  Future<({String host, int port, int budgetBytes})> startRpc(
    Uri base, {
    required String sessionId,
    required ModelRef model,
    required String coordinatorId,
  }) async {
    startRpcCalls.add(RpcStartCall(base, sessionId, model, coordinatorId));
    final error = startRpcError;
    if (error != null) throw error;
    return (
      host: base.host,
      port: rpcPortByApiPort[base.port] ?? 5000,
      budgetBytes: 1 << 30
    );
  }

  @override
  Future<void> stopRpc(Uri base, String sessionId) async {
    stopRpcCalls.add((base: base, sessionId: sessionId));
  }

  @override
  Stream<ChatDelta> chat(
    Uri base,
    ModelRef model,
    List<ChatMessage> messages, {
    double? temperature,
    int? maxTokens,
    bool asCoordinator = false,
  }) async* {
    chatBases.add(base);
    chatRouteFlags.add(asCoordinator);
    for (final delta in chatDeltas) {
      yield ChatDelta(delta.content,
          finishReason: delta.finishReason, servedBy: 'remote');
    }
  }

  @override
  Future<SessionInfo?> session(Uri base) async => sessionResult;
}

class FakeEngineLocator implements EngineLocator {
  bool isAvailable;

  FakeEngineLocator({this.isAvailable = true});

  @override
  Future<String?> llamaServerPath() async =>
      isAvailable ? '/fake/llama-server' : null;

  @override
  Future<String?> rpcServerPath() async =>
      isAvailable ? '/fake/rpc-server' : null;

  @override
  Future<bool> get available async => isAvailable;
}

class FakeEngine implements InferenceEngine {
  bool _rpc = false;
  HttpServer? _server;
  int rpcStarts = 0;
  int rpcStops = 0;
  String? lastRpcCacheDir;
  String? lastRpcModelPath;
  bool? lastRpcLazyWeights;
  int concurrentRpcStarts = 0;
  int maxConcurrentRpcStarts = 0;
  Completer<void>? startRpcGate;
  Completer<void>? stopCoordinatorGate;
  Completer<void>? stopCoordinatorEntered;
  int coordinatorStarts = 0;
  int coordinatorStops = 0;
  LocalModel? lastModel;
  ClusterPlan? lastPlan;
  int lastCoordinatorPort = 0;
  List<(String, String?)> chunks = [
    ('Hello', null),
    (' world', null),
    ('', 'stop'),
  ];

  @override
  Future<int> startRpcWorker(
      {required int port,
      String? cacheDir,
      String? modelPath,
      bool lazyWeights = false}) async {
    rpcStarts++;
    lastRpcCacheDir = cacheDir;
    lastRpcModelPath = modelPath;
    lastRpcLazyWeights = lazyWeights;
    concurrentRpcStarts++;
    if (concurrentRpcStarts > maxConcurrentRpcStarts) {
      maxConcurrentRpcStarts = concurrentRpcStarts;
    }
    try {
      final gate = startRpcGate;
      if (gate != null) await gate.future;
      _rpc = true;
      return port;
    } finally {
      concurrentRpcStarts--;
    }
  }

  @override
  Future<void> stopRpcWorker() async {
    rpcStops++;
    _rpc = false;
  }

  @override
  bool get rpcWorkerRunning => _rpc;

  @override
  Future<Uri> startCoordinator(
      {required LocalModel model,
      required ClusterPlan plan,
      required int port}) async {
    coordinatorStarts++;
    lastModel = model;
    lastPlan = plan;
    lastCoordinatorPort = port;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      final response = request.response;
      response.statusCode = 200;
      response.headers.contentType = ContentType('text', 'event-stream');
      for (final chunk in chunks) {
        final payload = {
          'id': 'chatcmpl-fake',
          'object': 'chat.completion.chunk',
          'created': 0,
          'model': model.ref.toString(),
          'choices': [
            {
              'index': 0,
              'delta': chunk.$1.isEmpty
                  ? <String, dynamic>{}
                  : {'content': chunk.$1},
              'finish_reason': chunk.$2,
            }
          ],
        };
        response.write('data: ${jsonEncode(payload)}\n\n');
        await response.flush();
      }
      response.write('data: [DONE]\n\n');
      await response.close();
    });
    return Uri.parse('http://127.0.0.1:${server.port}');
  }

  @override
  Future<void> stopCoordinator() async {
    coordinatorStops++;
    final entered = stopCoordinatorEntered;
    if (entered != null && !entered.isCompleted) entered.complete();
    final gate = stopCoordinatorGate;
    if (gate != null) await gate.future;
    await _server?.close(force: true);
    _server = null;
  }

  @override
  bool get coordinatorRunning => _server != null;

  @override
  List<String> get logTail => const ['fake engine log'];
}

class FakePlanner implements ClusterPlanner {
  int plans = 0;
  bool fail = false;
  bool? lastAllowExpertStreaming;

  @override
  ClusterPlan plan(LocalModel model, List<PlanNode> nodes,
      {bool allowExpertStreaming = false}) {
    plans++;
    lastAllowExpertStreaming = allowExpertStreaming;
    if (fail) throw PlanError('model does not fit in cluster memory');
    final total = nodes.fold<int>(0, (sum, n) => sum + n.budgetBytes);
    return ClusterPlan(
      model: model.ref,
      nodes: nodes,
      assignments: [
        for (final node in nodes)
          PlanAssignment(
            nodeId: node.nodeId,
            layerFraction: total == 0 ? 0 : node.budgetBytes / total,
            estimatedBytes: total == 0
                ? 0
                : (model.sizeBytes * node.budgetBytes / total).round(),
          )
      ],
    );
  }

  @override
  List<String> llamaServerArgs(ClusterPlan plan) => const ['--fake'];
}

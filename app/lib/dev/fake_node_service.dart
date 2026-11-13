/// Simulated cluster used for demos, screenshots and widget tests.
///
/// Enabled with `flutter run --dart-define=LLMMBC_FAKE=1`. It implements the
/// whole [NodeService] surface: four peers, a model catalog, download progress,
/// and streamed chat answers including a coordinator session.
library;

import 'dart:async';
import 'dart:math';

import 'package:llmmbc_core/llmmbc_core.dart';

const int _mib = 1024 * 1024;
const int _gib = 1024 * _mib;

/// Demo link rate reported by simulated pulls (bytes/s).
const double _simulatedLinkBytesPerSecond = 18.2e6;

ModelRef _ref(String value) => ModelRef.parse(value);

GgufMetadata _denseMeta(String architecture, int layers, int context, int bytes) => GgufMetadata(
      architecture: architecture,
      blockCount: layers,
      contextLength: context,
      fileType: 15,
      totalTensorBytes: bytes,
    );

GgufMetadata _moeMeta(String architecture, int layers, int context, int experts, int used, int bytes) =>
    GgufMetadata(
      architecture: architecture,
      blockCount: layers,
      contextLength: context,
      expertCount: experts,
      expertUsedCount: used,
      fileType: 15,
      totalTensorBytes: bytes,
      expertTensorBytes: bytes * 9 ~/ 10,
    );

class FakeNodeService implements NodeService {
  FakeNodeService({
    this.phaseDelay = Duration.zero,
    this.tokenDelay = const Duration(milliseconds: 14),
    this.downloadTick = const Duration(milliseconds: 200),
    this.verifyDuration = const Duration(milliseconds: 1600),
    this.scanLatency = const Duration(milliseconds: 350),
    this.engineAvailable = true,
  }) {
    _models = _FakeModelStore(this);
    _discovery = _FakeDiscovery(this);
    _engine = _FakeEngine();
    _hardware = HardwareProfile(
      os: 'android',
      arch: 'arm64',
      cpuModel: 'Cortex-X3 + A715 + A510',
      cpuCores: 8,
      totalRamBytes: 12 * _gib,
      availableRamBytes: 6 * _gib + 800 * _mib,
      gpus: const [GpuInfo(name: 'Adreno 740', backend: GpuBackend.vulkan)],
      tags: const ['demo'],
    );
    _peers = _seedPeers();
    _localModels = [
      LocalModel(
        ref: _ref('qwen3:0.6b'),
        ggufPath: '/data/models/blobs/sha256-qwen3-0.6b',
        sizeBytes: 520 * _mib,
        metadata: _denseMeta('qwen3', 28, 40960, 520 * _mib),
      ),
      LocalModel(
        ref: _ref('granite3.1-moe:1b'),
        ggufPath: '/data/models/blobs/sha256-granite-1b',
        sizeBytes: 1400 * _mib,
        metadata: _moeMeta('granite_moe', 24, 4096, 32, 4, 1400 * _mib),
      ),
    ];
  }

  /// Delay between startup phases; >0 makes the startup screen watchable.
  final Duration phaseDelay;
  final Duration tokenDelay;
  final Duration downloadTick;

  /// Time the simulated sha256 verification takes, split into four steps so the
  /// verifying progress bar visibly moves.
  final Duration verifyDuration;
  final Duration scanLatency;

  /// Simulates a build without engine binaries (worker still runs the node API).
  final bool engineAvailable;

  /// Set to throw from [chat] (tests and the error UX demo).
  Object? chatFailure;

  late final _FakeModelStore _models;
  late final _FakeDiscovery _discovery;
  late final _FakeEngine _engine;
  late HardwareProfile _hardware;
  late List<NodeInfo> _peers;
  late List<LocalModel> _localModels;

  final StreamController<String> _phases = StreamController<String>.broadcast();
  final StreamController<void> _changed = StreamController<void>.broadcast();
  final Random _random = Random(7);
  SessionInfo? _session;
  NodeSettings _settings = NodeSettings(
    nodeId: 'demo-phone-9f3c1a7e',
    name: 'This phone',
    dataDir: '/data/user/0/dev.llmmbc.app/files',
    manualPeers: const ['192.168.1.20:47101'],
    memoryShare: kDefaultMemoryShare,
    memoryBasis: MemoryBasis.total,
  );

  @override
  NodeSettings get settings => _settings;

  @override
  Future<void> updateSettings(NodeSettings settings) async {
    _settings = settings;
    notifyChanged();
  }

  @override
  Future<void> start() async {
    // Same phase order as LocalNodeService (docs/ARCHITECTURE.md §2.1).
    for (final phase in const ['settings', 'hardware', 'models', 'api', 'discovery']) {
      _phases.add(phase);
      if (phaseDelay > Duration.zero) {
        await Future<void>.delayed(phaseDelay);
      }
    }
    _phases.add('ready');
  }

  @override
  Future<void> stop() async {}

  @override
  Stream<String> get startupPhase => _phases.stream;

  @override
  HardwareProfile get hardware => _hardware;

  @override
  NodeInfo get self => NodeInfo(
        nodeId: _settings.nodeId,
        name: _settings.name,
        host: '192.168.1.31',
        apiPort: _settings.apiPort,
        workerEnabled: _settings.workerEnabled,
        engineAvailable: engineAvailable,
        status: _session == null ? NodeStatus.worker : NodeStatus.coordinator,
        hardware: _hardware,
        models: List.unmodifiable(_localModels),
        memoryBudgetBytes: _hardware.memoryBudgetBytes(_settings.memoryBasis, _settings.memoryShare),
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
    final nodes = [self, ..._discovery.peers].where((node) => node.reachable).toList();
    final grouped = <String, ClusterModel>{};
    for (final node in nodes) {
      for (final model in node.models) {
        final key = model.ref.toString();
        final candidates = [
          for (final other in nodes)
            if (other.isCandidateFor(model.ref)) other,
        ];
        final previous = grouped[key];
        if (previous == null || model.sizeBytes > previous.sizeBytes) {
          grouped[key] = ClusterModel(
            ref: model.ref,
            sizeBytes: model.sizeBytes,
            metadata: model.metadata,
            candidates: candidates,
          );
        }
      }
    }
    return grouped.values.toList()
      ..sort((a, b) {
        if (a.isMoe != b.isMoe) return a.isMoe ? -1 : 1;
        return a.ref.toString().compareTo(b.ref.toString());
      });
  }

  @override
  Stream<void> get changed => _changed.stream;

  void notifyChanged() {
    if (!_changed.isClosed) _changed.add(null);
  }

  @override
  Stream<ChatDelta> chat(
    ModelRef model,
    List<ChatMessage> messages, {
    double? temperature,
    int? maxTokens,
  }) {
    final failure = chatFailure;
    if (failure != null) return Stream<ChatDelta>.error(failure);

    final candidates = clusterModels()
        .where((entry) => entry.ref == model)
        .expand((entry) => entry.candidates)
        .toList();
    if (candidates.isEmpty) {
      return Stream<ChatDelta>.error(
        LlmmbcException('no_candidates', 'No reachable worker has ${model.toString()} downloaded.'),
      );
    }
    candidates.sort((a, b) {
      final memory = b.effectiveBudgetBytes.compareTo(a.effectiveBudgetBytes);
      if (memory != 0) return memory;
      return a.nodeId.compareTo(b.nodeId);
    });
    final coordinator = candidates.first;
    final workers = candidates.skip(1).map((node) => node.nodeId).toList();
    _session = SessionInfo(
      sessionId: 'demo-session-${_random.nextInt(9999)}',
      model: model,
      coordinatorId: coordinator.nodeId,
      workerIds: workers,
      startedAt: DateTime.now(),
      lastUsedAt: DateTime.now(),
      plan: {
        'assignments': [
          for (final node in [coordinator, ...candidates.skip(1)])
            {'nodeId': node.nodeId, 'layerFraction': 1 / candidates.length},
        ],
      },
    );
    notifyChanged();

    final answer = _answerFor(model, coordinator.name, messages);
    final chunks = _chunk(answer);
    late StreamController<ChatDelta> controller;
    Timer? timer;
    var index = 0;

    void step() {
      if (index >= chunks.length) {
        timer?.cancel();
        controller.add(ChatDelta('', finishReason: 'stop', servedBy: coordinator.nodeId));
        _session = _session == null
            ? null
            : SessionInfo(
                sessionId: _session!.sessionId,
                model: _session!.model,
                coordinatorId: _session!.coordinatorId,
                workerIds: _session!.workerIds,
                startedAt: _session!.startedAt,
                lastUsedAt: DateTime.now(),
                plan: _session!.plan,
              );
        notifyChanged();
        controller.close();
        return;
      }
      controller.add(ChatDelta(chunks[index++], servedBy: coordinator.nodeId));
    }

    controller = StreamController<ChatDelta>(
      onListen: () {
        timer = Timer.periodic(tokenDelay, (_) => step());
      },
      onCancel: () {
        timer?.cancel();
        notifyChanged();
      },
    );
    return controller.stream;
  }

  @override
  SessionInfo? get currentSession => _session;

  /// Test hook: removes demo peers and local models to exercise empty states.
  void debugClearCluster() {
    _peers = [];
    _localModels = [];
    notifyChanged();
  }

  List<String> _chunk(String text) {
    final words = text.split(RegExp(r'(?<=\s)'));
    final chunks = <String>[];
    var buffer = StringBuffer();
    for (final word in words) {
      buffer.write(word);
      if (buffer.length >= 18) {
        chunks.add(buffer.toString());
        buffer = StringBuffer();
      }
    }
    if (buffer.isNotEmpty) chunks.add(buffer.toString());
    return chunks;
  }

  String _answerFor(ModelRef model, String coordinator, List<ChatMessage> messages) {
    final question = messages.isEmpty ? '' : messages.last.content.trim();
    final short = question.length > 80 ? '${question.substring(0, 79)}…' : question;
    final workers = clusterModels()
        .where((entry) => entry.ref == model)
        .expand((entry) => entry.candidates)
        .length;
    return '''
You asked **$short** — here is the simulated answer from `$model`.

## How this request was served

- Coordinator: **$coordinator** (largest advertised memory budget in the cluster)
- Candidate workers: **$workers**
- Transport: OpenAI-compatible SSE from the node API

The reply you are reading is generated by `FakeNodeService`, so it streams token by
token without touching a real model. In a real cluster the coordinator starts
`llama-server` locally and connects the workers' `rpc-server` processes:

```text
llama-server --model $model --rpc worker1:47102,worker2:47102 \\
             --tensor-split 0.6,0.4 --ctx-size 4096
```

### What to try next

1. Open **Cluster** and refresh discovery.
2. In **Models**, pull `granite3.1-moe:1b` and watch the progress stream.
3. Turn worker mode off in **Settings** and watch this model disappear from the picker.

> Everything above is demo data. Start the app without `LLMMBC_FAKE` to talk to a real node.
''';
  }

  List<NodeInfo> _seedPeers() {
    final studio = HardwareProfile(
      os: 'linux',
      arch: 'x64',
      cpuModel: 'AMD Ryzen 9 7900X 12-Core',
      cpuCores: 24,
      totalRamBytes: 32 * _gib,
      availableRamBytes: 21 * _gib,
      gpus: const [GpuInfo(name: 'NVIDIA GeForce RTX 4070 Ti', backend: GpuBackend.cuda, vramBytes: 12 * _gib)],
      tags: const ['desktop'],
    );
    final pixel = HardwareProfile(
      os: 'android',
      arch: 'arm64',
      cpuModel: 'Snapdragon 8 Gen 3',
      cpuCores: 8,
      totalRamBytes: 12 * _gib,
      availableRamBytes: 5 * _gib,
      gpus: const [GpuInfo(name: 'Adreno 750', backend: GpuBackend.vulkan)],
    );
    final pi = HardwareProfile(
      os: 'linux',
      arch: 'arm64',
      cpuModel: 'Cortex-A76',
      cpuCores: 4,
      totalRamBytes: 8 * _gib,
      availableRamBytes: 5 * _gib + 500 * _mib,
      tags: const ['raspberry-pi', 'docker'],
    );
    final tablet = HardwareProfile(
      os: 'android',
      arch: 'arm64',
      cpuModel: 'Snapdragon 778G',
      cpuCores: 8,
      totalRamBytes: 6 * _gib,
      availableRamBytes: 2 * _gib,
      gpus: const [GpuInfo(name: 'Adreno 642L', backend: GpuBackend.vulkan)],
    );
    final now = DateTime.now();
    return [
      NodeInfo(
        nodeId: 'studio-pc-7d21c4a0',
        name: 'Studio PC',
        host: '192.168.1.20',
        apiPort: kNodeApiPort,
        workerEnabled: true,
        engineAvailable: true,
        status: NodeStatus.idle,
        hardware: studio,
        models: [
          LocalModel(
            ref: _ref('qwen3:30b-a3b'),
            ggufPath: '/srv/llmmbc/models/blobs/sha256-qwen3-30b',
            sizeBytes: 18 * _gib,
            metadata: _moeMeta('qwen3moe', 48, 40960, 128, 8, 18 * _gib),
          ),
          LocalModel(
            ref: _ref('granite3.1-moe:1b'),
            ggufPath: '/srv/llmmbc/models/blobs/sha256-granite-1b',
            sizeBytes: 1400 * _mib,
            metadata: _moeMeta('granite_moe', 24, 4096, 32, 4, 1400 * _mib),
          ),
          LocalModel(
            ref: _ref('llama3.2:3b'),
            ggufPath: '/srv/llmmbc/models/blobs/sha256-llama-3b',
            sizeBytes: 2 * _gib,
            metadata: _denseMeta('llama', 28, 8192, 2 * _gib),
          ),
        ],
        memoryBudgetBytes: studio.memoryBudgetBytes(MemoryBasis.total, kDefaultMemoryShare),
        lastSeen: now.subtract(const Duration(seconds: 2)),
      ),
      NodeInfo(
        nodeId: 'pixel-8-3b9e0f12',
        name: 'Pixel 8',
        host: '192.168.1.31',
        apiPort: kNodeApiPort,
        workerEnabled: true,
        engineAvailable: true,
        status: NodeStatus.worker,
        hardware: pixel,
        models: [
          LocalModel(
            ref: _ref('qwen3:0.6b'),
            ggufPath: '/data/models/blobs/sha256-qwen3-0.6b',
            sizeBytes: 520 * _mib,
            metadata: _denseMeta('qwen3', 28, 40960, 520 * _mib),
          ),
          LocalModel(
            ref: _ref('granite3.1-moe:1b'),
            ggufPath: '/data/models/blobs/sha256-granite-1b',
            sizeBytes: 1400 * _mib,
            metadata: _moeMeta('granite_moe', 24, 4096, 32, 4, 1400 * _mib),
          ),
        ],
        memoryBudgetBytes: pixel.memoryBudgetBytes(MemoryBasis.total, kDefaultMemoryShare),
        lastSeen: now.subtract(const Duration(seconds: 5)),
      ),
      NodeInfo(
        nodeId: 'pi5-node-1c4f8a33',
        name: 'pi5-node',
        host: '192.168.1.40',
        apiPort: kNodeApiPort,
        workerEnabled: true,
        engineAvailable: true,
        status: NodeStatus.busy,
        hardware: pi,
        models: [
          LocalModel(
            ref: _ref('granite3.1-moe:1b'),
            ggufPath: '/srv/models/blobs/sha256-granite-1b',
            sizeBytes: 1400 * _mib,
            metadata: _moeMeta('granite_moe', 24, 4096, 32, 4, 1400 * _mib),
          ),
        ],
        memoryBudgetBytes: pi.memoryBudgetBytes(MemoryBasis.total, kDefaultMemoryShare),
        lastSeen: now.subtract(const Duration(minutes: 1)),
      ),
      NodeInfo(
        nodeId: 'tablet-old-55aa10bb',
        name: 'Kitchen tablet',
        host: '192.168.1.52',
        apiPort: kNodeApiPort,
        workerEnabled: false,
        engineAvailable: true,
        status: NodeStatus.idle,
        hardware: tablet,
        models: const [],
        memoryBudgetBytes: tablet.memoryBudgetBytes(MemoryBasis.total, kDefaultMemoryShare),
        lastSeen: now.subtract(const Duration(minutes: 3)),
      ),
    ];
  }
}

class _FakeModelStore implements ModelStore {
  _FakeModelStore(this._service);

  final FakeNodeService _service;
  final Map<String, StreamController<DownloadProgress>> _active = {};
  final Set<String> _cancelled = {};

  List<LocalModel> get localModels => _service._localModels;

  @override
  String get modelsDir => '${_service.settings.dataDir}/models';

  @override
  Future<List<LocalModel>> list() async => List.unmodifiable(localModels);

  @override
  Future<LocalModel?> find(ModelRef ref) async {
    for (final model in localModels) {
      if (model.ref == ref) return model;
    }
    return null;
  }

  @override
  Stream<DownloadProgress> pull(ModelRef ref) {
    final key = ref.toString();
    final local = localModels.where((model) => model.ref == ref).firstOrNull;
    if (local != null) {
      return Stream.value(
        DownloadProgress(ref, DownloadState.done, receivedBytes: local.sizeBytes, totalBytes: local.sizeBytes),
      );
    }
    _active.remove(key)?.close();

    final total = _approxSize(ref);
    late StreamController<DownloadProgress> controller;
    Timer? timer;
    var received = 0;
    _cancelled.remove(key);

    void finishCancelled() {
      timer?.cancel();
      if (!controller.isClosed) {
        controller.add(DownloadProgress(ref, DownloadState.cancelled, receivedBytes: received, totalBytes: total));
        controller.close();
      }
      _active.remove(key);
      _service.notifyChanged();
    }

    void complete() {
      final entry = catalog().where((e) => e.ref == ref).firstOrNull;
      localModels.add(
        LocalModel(
          ref: ref,
          ggufPath: '$modelsDir/blobs/sha256-${ref.name}',
          sizeBytes: total,
          metadata: entry == null
              ? _denseMeta('llama', 28, 8192, total)
              : (entry.isMoe ? _moeMeta('moe', 24, 4096, 32, 4, total) : _denseMeta('llama', 28, 8192, total)),
        ),
      );
      controller.add(DownloadProgress(ref, DownloadState.done, receivedBytes: total, totalBytes: total));
      _active.remove(key);
      controller.close();
      _service.notifyChanged();
    }

    // The demo compresses transfer time, but reports a plausible link rate and a
    // matching ETA so the stats row shows realistic numbers.
    void startVerifying() {
      final step = _service.verifyDuration ~/ 4;
      var hashed = 0;

      void hashingStep() {
        if (_cancelled.contains(key)) {
          finishCancelled();
          return;
        }
        hashed += 1;
        controller.add(DownloadProgress(
          ref,
          DownloadState.verifying,
          receivedBytes: total * hashed ~/ 4,
          totalBytes: total,
        ));
        if (hashed >= 4) {
          timer?.cancel();
          complete();
        }
      }

      if (step <= Duration.zero) {
        for (var i = 0; i < 4; i++) {
          hashingStep();
        }
      } else {
        // First hash slice immediately so `Verifying x%` replaces `Downloading`
        // without waiting a whole step.
        hashingStep();
        if (hashed < 4) timer = Timer.periodic(step, (_) => hashingStep());
      }
    }

    controller = StreamController<DownloadProgress>(
      onListen: () {
        controller.add(DownloadProgress(ref, DownloadState.resolving, totalBytes: total));
        timer = Timer.periodic(_service.downloadTick, (t) {
          if (_cancelled.contains(key)) {
            finishCancelled();
            return;
          }
          received += total ~/ 18;
          if (received < total) {
            final remaining = total - received;
            controller.add(DownloadProgress(
              ref,
              DownloadState.downloading,
              receivedBytes: received,
              totalBytes: total,
              bytesPerSecond: _simulatedLinkBytesPerSecond,
              eta: Duration(seconds: (remaining / _simulatedLinkBytesPerSecond).ceil()),
            ));
            return;
          }
          t.cancel();
          received = total;
          startVerifying();
        });
      },
      onCancel: () {
        timer?.cancel();
        if (localModels.any((model) => model.ref == ref)) return;
        _cancelled.add(key);
        _active.remove(key);
        _service.notifyChanged();
      },
    );
    _active[key] = controller;
    return controller.stream;
  }

  @override
  Future<void> cancel(ModelRef ref) async {
    final key = ref.toString();
    _cancelled.add(key);
    final controller = _active[key];
    if (controller != null && !controller.isClosed) {
      controller.add(
        DownloadProgress(ref, DownloadState.cancelled, totalBytes: _approxSize(ref)),
      );
      await controller.close();
      _active.remove(key);
    }
    _service.notifyChanged();
  }

  @override
  Future<void> delete(ModelRef ref) async {
    localModels.removeWhere((model) => model.ref == ref);
    _service.notifyChanged();
  }

  @override
  List<CatalogEntry> catalog() => const [
        CatalogEntry(
          ref: ModelRef('qwen3', tag: '30b-a3b'),
          title: 'Qwen3 30B A3B',
          description: 'Flagship MoE: 30B parameters, 3B active. Spreads across phones and desktops.',
          isMoe: true,
          approxSizeBytes: 18 * _gib,
        ),
        CatalogEntry(
          ref: ModelRef('granite3.1-moe', tag: '1b'),
          title: 'Granite 3.1 MoE 1B',
          description: 'Small MoE for planner and E2E checks (~1.4 GB).',
          isMoe: true,
          approxSizeBytes: 1400 * _mib,
        ),
        CatalogEntry(
          ref: ModelRef('mixtral', tag: '8x7b'),
          title: 'Mixtral 8x7B',
          description: 'Classic MoE — 8 experts, 2 active per token.',
          isMoe: true,
          approxSizeBytes: 26 * _gib,
        ),
        CatalogEntry(
          ref: ModelRef('qwen3', tag: '0.6b'),
          title: 'Qwen3 0.6B',
          description: 'Tiny dense model for a first smoke test on one device.',
          isMoe: false,
          approxSizeBytes: 520 * _mib,
        ),
        CatalogEntry(
          ref: ModelRef('llama3.2', tag: '3b'),
          title: 'Llama 3.2 3B',
          description: 'Dense general purpose model with an 8k context.',
          isMoe: false,
          approxSizeBytes: 2 * _gib,
        ),
      ];

  @override
  Future<int> remoteSize(ModelRef ref) async => _approxSize(ref);

  int _approxSize(ModelRef ref) {
    final entry = catalog().where((e) => e.ref == ref).firstOrNull;
    return entry?.approxSizeBytes ?? 1024 * _mib;
  }
}

class _FakeDiscovery implements Discovery {
  _FakeDiscovery(this._service);

  final FakeNodeService _service;
  final StreamController<List<NodeInfo>> _peersChanged = StreamController<List<NodeInfo>>.broadcast();

  @override
  Future<void> start(NodeInfo Function() self, NodeSettings settings) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> scan() async {
    await Future<void>.delayed(_service.scanLatency);
    final now = DateTime.now();
    _service._peers = [
      for (final peer in _service._peers)
        peer.copyWith(
          lastSeen: now.subtract(Duration(seconds: Random().nextInt(6))),
          reachable: true,
        ),
    ];
    _emit();
    _service.notifyChanged();
  }

  @override
  List<NodeInfo> get peers => List.unmodifiable(_service._peers);

  @override
  Stream<List<NodeInfo>> get peersChanged => _peersChanged.stream;

  @override
  Future<NodeInfo?> addManualPeer(String hostPort) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (hostPort.contains('bad') || hostPort.trim().isEmpty) return null;
    final host = hostPort.contains(':') ? hostPort.split(':').first : hostPort;
    final port = hostPort.contains(':') ? int.tryParse(hostPort.split(':').last) ?? kNodeApiPort : kNodeApiPort;
    final existing = _service._peers.where((peer) => peer.host == host).firstOrNull;
    if (existing != null) return existing;
    final peer = NodeInfo(
      nodeId: 'manual-${host.hashCode.toRadixString(16)}',
      name: 'Manual peer',
      host: host,
      apiPort: port,
      workerEnabled: true,
      engineAvailable: true,
      status: NodeStatus.idle,
      hardware: HardwareProfile(
        os: 'linux',
        arch: 'x64',
        cpuModel: 'Manual node',
        cpuCores: 4,
        totalRamBytes: 8 * _gib,
        availableRamBytes: 4 * _gib,
      ),
      models: [
        LocalModel(
          ref: _ref('qwen3:0.6b'),
          ggufPath: '/models/qwen3-0.6b.gguf',
          sizeBytes: 520 * _mib,
          metadata: _denseMeta('qwen3', 28, 40960, 520 * _mib),
        ),
      ],
      memoryBudgetBytes: (8 * _gib * kDefaultMemoryShare).round(),
      lastSeen: DateTime.now(),
    );
    _service._peers = [..._service._peers, peer];
    _emit();
    _service.notifyChanged();
    return peer;
  }

  void _emit() {
    if (!_peersChanged.isClosed) _peersChanged.add(peers);
  }
}

class _FakeEngine implements InferenceEngine {
  bool _rpc = false;
  bool _coordinator = false;

  @override
  Future<int> startRpcWorker({required int port, required String cacheDir}) async {
    _rpc = true;
    return port;
  }

  @override
  Future<void> stopRpcWorker() async {
    _rpc = false;
  }

  @override
  bool get rpcWorkerRunning => _rpc;

  @override
  Future<Uri> startCoordinator({
    required LocalModel model,
    required ClusterPlan plan,
    required int port,
  }) async {
    _coordinator = true;
    return Uri.parse('http://127.0.0.1:$port');
  }

  @override
  Future<void> stopCoordinator() async {
    _coordinator = false;
  }

  @override
  bool get coordinatorRunning => _coordinator;

  @override
  List<String> get logTail => const [
        'llama_model_load: loading model from /data/models/blobs/sha256-granite-1b',
        'llama_model_load: n_vocab = 49152, n_ctx = 4096',
        'llama_model_load: model type = 15 (Q4_K - Medium)',
        'llama_model_load: expert_count = 32, used = 4',
        'rpc: connecting to 192.168.1.20:47102 … ok',
        'rpc: connecting to 192.168.1.40:47102 … ok',
        'llama_server: listening on http://127.0.0.1:47103',
        'slots: n_slots = 1',
      ];
}

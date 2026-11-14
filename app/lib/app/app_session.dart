/// App wide state: the node service, startup progress, peers, chat history and
/// user preferences. Screens read it through [AppScope].
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:llmmbc_core/llmmbc_core.dart';

import '../models/conversation.dart';
import '../models/runtime_failure.dart';
import '../services/store.dart';
import '../services/worker_service.dart';

class AppSession extends ChangeNotifier {
  AppSession({
    required NodeService service,
    required this.conversations,
    required this.prefs,
    this.fake = false,
    bool degraded = false,
    String? notice,
    RuntimeFailure? runtimeFailure,
    bool clientOnly = false,
    bool android = false,
    ThemeMode themeMode = ThemeMode.system,
    Future<NodeService> Function()? degradedFactory,
    Future<NodeService> Function()? runtimeFactory,
    WorkerServiceController workerService = const PlatformWorkerServiceController(),
    bool workerServiceActive = false,
    bool notificationsAllowed = true,
  })  : _service = service,
        _degraded = degraded,
        _notice = notice,
        _runtimeFailure = runtimeFailure,
        clientOnly = clientOnly || (fake == false && _isIos),
        android = android,
        _themeMode = themeMode,
        _degradedFactory = degradedFactory,
        _runtimeFactory = runtimeFactory,
        _worker = workerService,
        _workerServiceActive = workerServiceActive,
        _notificationsAllowed = notificationsAllowed;

  static bool get _isIos {
    try {
      return Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  NodeService _service;
  final ConversationStore conversations;
  final AppPreferences prefs;
  final bool fake;
  final bool clientOnly;

  /// True on Android builds (drives the worker foreground-service UI).
  final bool android;

  final Future<NodeService> Function()? _degradedFactory;
  final Future<NodeService> Function()? _runtimeFactory;
  final WorkerServiceController _worker;

  bool _degraded;
  String? _notice;
  RuntimeFailure? _runtimeFailure;
  bool _workerServiceActive;
  bool _notificationsAllowed;
  bool _retryingRuntime = false;
  ThemeMode _themeMode;
  bool _ready = false;
  bool _started = false;
  String? _startupError;
  final List<String> _phases = [];
  List<Conversation> _history = [];
  List<NodeInfo> _peers = [];
  StreamSubscription<String>? _phaseSub;
  StreamSubscription<void>? _changedSub;
  StreamSubscription<List<NodeInfo>>? _peersSub;

  NodeService get service => _service;
  bool get degraded => _degraded;
  String? get notice => _notice;
  RuntimeFailure? get runtimeFailure => _runtimeFailure;
  bool get retryingRuntime => _retryingRuntime;
  bool get workerServiceActive => _workerServiceActive;
  bool get notificationsAllowed => _notificationsAllowed;
  ThemeMode get themeMode => _themeMode;
  bool get ready => _ready;
  String? get startupError => _startupError;
  List<String> get phases => List.unmodifiable(_phases);
  List<Conversation> get history => List.unmodifiable(_history);
  List<NodeInfo> get peers => List.unmodifiable(_peers);

  bool get downloadsEnabled => !_degraded;
  bool get chatEnabled => !_degraded;
  String get buildModeLabel => fake ? 'Simulated cluster' : (_degraded ? 'UI-only mode' : 'Live node');

  HardwareProfile get hardware => _service.hardware;

  List<NodeInfo> get allNodes {
    final nodes = <NodeInfo>[_service.self, ..._peers];
    final seen = <String>{};
    return [
      for (final node in nodes)
        if (seen.add(node.nodeId)) node,
    ];
  }

  /// Display name for a node id, falling back to a shortened id.
  String nodeName(String? nodeId) {
    if (nodeId == null || nodeId.isEmpty) return 'unknown node';
    for (final node in allNodes) {
      if (node.nodeId == nodeId) return node.name;
    }
    return nodeId.length <= 8 ? nodeId : nodeId.substring(0, 8);
  }

  NodeInfo? nodeById(String? nodeId) {
    if (nodeId == null) return null;
    for (final node in allNodes) {
      if (node.nodeId == nodeId) return node;
    }
    return null;
  }

  bool get isCoordinator =>
      _service.currentSession != null && _service.currentSession!.coordinatorId == _service.settings.nodeId;

  bool get isWorkerActive => _service.currentSession?.workerIds.contains(_service.settings.nodeId) ?? false;

  /// Runs the startup sequence. Safe to call once; [retry] restarts after a failure.
  Future<void> start({bool retry = false}) async {
    if (_started && !retry) return;
    _started = true;
    _startupError = null;
    await _startService();
  }

  Future<void> _startService() async {
    _ready = false;
    _phases.clear();
    _phaseSub?.cancel();
    _changedSub?.cancel();
    _peersSub?.cancel();
    notifyListeners();

    _phaseSub = _service.startupPhase.listen((phase) {
      if (!_phases.contains(phase)) _phases.add(phase);
      notifyListeners();
    });
    _changedSub = _service.changed.listen((_) => notifyListeners());
    _peersSub = _service.discovery.peersChanged.listen((peers) {
      _peers = _visiblePeers(peers);
      notifyListeners();
    });

    try {
      await _service.start();
      _ready = true;
      if (!_degraded) _runtimeFailure = null;
      _startupError = null;
      await _syncWorkerService();
    } catch (error, stack) {
      final failure = RuntimeFailure.capture(
        error,
        stack,
        phase: 'start',
        logTail: _logTail(),
      );
      _runtimeFailure = failure;
      final degradedFactory = _degradedFactory;
      if (!fake && !_degraded && degradedFactory != null) {
        try {
          final replacement = await degradedFactory();
          _service = replacement;
          _degraded = true;
          _notice = 'Core runtime failed to start: ${failure.summary}';
          await _startService();
          return;
        } catch (fallbackError, fallbackStack) {
          _runtimeFailure = RuntimeFailure.capture(
            fallbackError,
            fallbackStack,
            phase: 'fallback',
            logTail: _logTail(),
          );
        }
      }
      _startupError = error is UnimplementedError
          ? 'The node runtime is not available in this build.'
          : failure.summary;
    }
    await loadHistory();
    notifyListeners();
  }

  /// Rebuilds the real node runtime and starts it again; the degraded service
  /// stays in place until the replacement starts successfully.
  Future<void> retryRuntime() async {
    if (_retryingRuntime) return;
    _retryingRuntime = true;
    _startupError = null;
    notifyListeners();
    try {
      final runtimeFactory = _runtimeFactory;
      if (runtimeFactory != null) {
        final service = await runtimeFactory();
        _service = service;
        _degraded = false;
        _notice = null;
        _runtimeFailure = null;
        _started = false;
      }
      _retryingRuntime = false;
      await start(retry: true);
    } catch (error, stack) {
      _runtimeFailure = RuntimeFailure.capture(
        error,
        stack,
        phase: 'retry',
        logTail: _logTail(),
      );
      _retryingRuntime = false;
      notifyListeners();
    }
  }

  Future<void> _syncWorkerService() async {
    if (!android) {
      _workerServiceActive = false;
      return;
    }
    // Keep the node (API + discovery) alive in the background; a degraded
    // runtime has no node to keep alive, so no misleading notification.
    final shouldRun = !_degraded && _service.settings.workerEnabled && !clientOnly;
    if (!shouldRun) {
      await _worker.setEnabled(false);
      _workerServiceActive = false;
      notifyListeners();
      return;
    }
    final allowed = await _worker.requestNotificationPermission();
    final running = await _worker.setEnabled(true);
    _notificationsAllowed = allowed;
    _workerServiceActive = running;
    notifyListeners();
  }

  List<String> _logTail() {
    try {
      return List<String>.of(_service.engine.logTail);
    } catch (_) {
      return const [];
    }
  }

  /// Peers without this node. `GET /v1/peers` and the discovery stream include
  /// the queried node itself, which the UI shows as "This device" instead.
  List<NodeInfo> _visiblePeers(List<NodeInfo> peers) {
    final selfId = _service.settings.nodeId;
    return [
      for (final peer in peers)
        if (!peer.isSelf && peer.nodeId != selfId) peer,
    ];
  }

  /// Re-scans the local model store (no-op for fake/degraded services).
  Future<void> refreshModels({bool force = false}) async {
    final service = _service;
    if (service is LocalNodeService) {
      try {
        await service.refreshModels(force: force);
      } catch (_) {
        // The periodic refresh in the node service retries.
      }
    }
    // LocalNodeService emits `changed` itself; nothing to notify for others.
  }

  Future<void> loadHistory() async {
    try {
      _history = await conversations.load();
    } catch (_) {
      _history = [];
    }
    notifyListeners();
  }

  Future<void> saveHistory() => conversations.save(_history);

  /// Replaces the in-memory history (used by the chat screen).
  Future<void> setHistory(List<Conversation> items) async {
    _history = items;
    await saveHistory();
    notifyListeners();
  }

  Future<void> updateSettings(NodeSettings settings) async {
    await _service.updateSettings(settings);
    await _syncWorkerService();
    notifyListeners();
  }

  Future<void> setWorkerEnabled(bool enabled) async {
    if (clientOnly && enabled) return;
    await updateSettings(_service.settings.copyWith(workerEnabled: enabled));
  }

  Future<void> setNodeName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == _service.settings.name) return;
    await updateSettings(_service.settings.copyWith(name: trimmed));
  }

  Future<void> setMemoryShare(double share) async {
    await updateSettings(_service.settings.copyWith(memoryShare: share.clamp(0.1, 1.0)));
  }

  Future<void> setMemoryBasis(MemoryBasis basis) async {
    if (basis == _service.settings.memoryBasis) return;
    await updateSettings(_service.settings.copyWith(memoryBasis: basis));
  }

  /// Opt-in MoE expert streaming (docs/ARCHITECTURE.md §2.4); applies when this
  /// node coordinates and is persisted with the rest of [NodeSettings].
  Future<void> setExpertStreaming(bool enabled) async {
    if (enabled == _service.settings.allowExpertStreaming) return;
    await updateSettings(_service.settings.copyWith(allowExpertStreaming: enabled));
  }

  /// Bytes this node advertises to the cluster (docs/ARCHITECTURE.md §2.5).
  int get memoryBudgetBytes =>
      _service.hardware.memoryBudgetBytes(_service.settings.memoryBasis, _service.settings.memoryShare);

  /// Size of the pool [memoryBasis] draws from, before the share is applied.
  int get memoryBasisBytes => _service.settings.memoryBasis == MemoryBasis.total
      ? _service.hardware.totalRamBytes + _service.hardware.vramBytes
      : _service.hardware.usableMemoryBytes;

  /// Adds a manual peer; returns the peer or null when unreachable.
  Future<NodeInfo?> addManualPeer(String hostPort) async {
    final node = await _service.discovery.addManualPeer(hostPort);
    if (node != null) {
      final settings = _service.settings;
      if (!settings.manualPeers.contains(hostPort)) {
        await updateSettings(settings.copyWith(manualPeers: [...settings.manualPeers, hostPort]));
      }
      _peers = _visiblePeers(_service.discovery.peers);
      notifyListeners();
    }
    return node;
  }

  Future<void> removeManualPeer(String hostPort) async {
    final settings = _service.settings;
    await updateSettings(
      settings.copyWith(manualPeers: [for (final peer in settings.manualPeers) if (peer != hostPort) peer]),
    );
    await refreshPeers();
  }

  Future<void> refreshPeers() async {
    await _service.discovery.scan();
    _peers = _visiblePeers(_service.discovery.peers);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    await prefs.save({'themeMode': mode.name});
  }

  @override
  void dispose() {
    _phaseSub?.cancel();
    _changedSub?.cancel();
    _peersSub?.cancel();
    super.dispose();
  }
}

/// Inherited access to the [AppSession].
class AppScope extends InheritedNotifier<AppSession> {
  const AppScope({super.key, required AppSession session, required super.child})
      : super(notifier: session);

  static AppSession of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing above this widget');
    return scope!.notifier!;
  }
}

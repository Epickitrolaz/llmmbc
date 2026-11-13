/// App wide state: the node service, startup progress, peers, chat history and
/// user preferences. Screens read it through [AppScope].
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:llmmbc_core/llmmbc_core.dart';

import '../models/conversation.dart';
import '../services/platform_bridge.dart';
import '../services/store.dart';

/// Startup steps of docs/ARCHITECTURE.md §2.1 as shown on the startup screen.
const List<String> startupSteps = ['settings', 'hardware', 'models', 'network'];

class AppSession extends ChangeNotifier {
  AppSession({
    required NodeService service,
    required this.conversations,
    required this.prefs,
    this.fake = false,
    bool degraded = false,
    String? notice,
    bool clientOnly = false,
    ThemeMode themeMode = ThemeMode.system,
    Future<NodeService> Function()? degradedFallback,
  })  : _service = service,
        _degraded = degraded,
        _notice = notice,
        clientOnly = clientOnly || (fake == false && _isIos),
        _themeMode = themeMode,
        _degradedFallback = degradedFallback;

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
  final Future<NodeService> Function()? _degradedFallback;

  bool _degraded;
  String? _notice;
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
    _ready = false;
    _startupError = null;
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
      if (PlatformBridge.isAndroid) {
        await PlatformBridge.setWorkerNotification(
          _service.settings.workerEnabled && !clientOnly && _service.self.engineAvailable,
        );
      }
    } catch (error) {
      final fallback = _degradedFallback;
      if (!fake && !_degraded && fallback != null) {
        try {
          final replacement = await fallback();
          _service = replacement;
          _degraded = true;
          _notice ??= 'The core runtime failed to start; running in UI-only mode.';
          await start(retry: true);
          return;
        } catch (_) {
          // Fall through to the visible error.
        }
      }
      _startupError = error is UnimplementedError
          ? 'The node runtime is not available in this build.'
          : error.toString();
    }
    await loadHistory();
    notifyListeners();
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
    if (PlatformBridge.isAndroid) {
      await PlatformBridge.setWorkerNotification(
        settings.workerEnabled && !clientOnly && _service.self.engineAvailable,
      );
    }
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

  int get usableShareBytes =>
      (_service.hardware.usableMemoryBytes * _service.settings.memoryShare).round();

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

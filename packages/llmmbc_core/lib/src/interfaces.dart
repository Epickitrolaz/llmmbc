/// Service interfaces. CONTRACT – implementations live in the owner directories listed in
/// docs/ARCHITECTURE.md §1. Do not change signatures without orchestrator approval.
library;

import 'dart:async';

import 'models.dart';

// --- core-data ------------------------------------------------------------

/// Scans this device. Implementation: `LocalHardwareProbe` (lib/src/hardware/).
abstract class HardwareProbe {
  /// Full scan (CPU, RAM, GPUs). Must never throw: fall back to conservative values.
  Future<HardwareProfile> scan();

  /// Cheap refresh of `availableRamBytes` only.
  Future<HardwareProfile> refresh(HardwareProfile previous);
}

/// Ollama registry + on-disk model store. Implementation: `FileModelStore` (lib/src/registry/).
abstract class ModelStore {
  String get modelsDir;

  /// Fully downloaded models (§5 of the architecture doc). Reads GGUF metadata (cached).
  Future<List<LocalModel>> list();

  Future<LocalModel?> find(ModelRef ref);

  /// Pulls a model from the Ollama registry; resumable; emits progress, last event is
  /// `done`, `failed` or `cancelled`. Pulling an already complete model emits `done` at once.
  Stream<DownloadProgress> pull(ModelRef ref);

  /// Cancels an in-flight pull (keeps `.partial` files for resume).
  Future<void> cancel(ModelRef ref);

  /// Deletes the manifest and every blob no longer referenced by another manifest.
  Future<void> delete(ModelRef ref);

  /// Curated list for the downloader UI (MoE first).
  List<CatalogEntry> catalog();

  /// Remote size lookup (sum of layer sizes from the manifest) without downloading.
  Future<int> remoteSize(ModelRef ref);
}

/// Reads GGUF headers. Implementation: `GgufReader` (lib/src/registry/gguf.dart).
abstract class GgufInspector {
  Future<GgufMetadata> read(String path);
}

// --- engine ---------------------------------------------------------------

/// Finds the llama.cpp executables. Implementation: `DefaultEngineLocator` (lib/src/engine/).
abstract class EngineLocator {
  /// Absolute paths, or null if unavailable on this platform/install.
  Future<String?> llamaServerPath();
  Future<String?> rpcServerPath();
  Future<bool> get available;
}

/// Pure function planner. Implementation: `DefaultClusterPlanner` (lib/src/engine/).
abstract class ClusterPlanner {
  /// Throws [PlanError] if the model cannot fit. `nodes` contains exactly one coordinator
  /// (`rpcEndpoint == null`).
  ClusterPlan plan(LocalModel model, List<PlanNode> nodes);

  /// Converts a plan to llama-server CLI args (excluding `-m`, `--host`, `--port`).
  List<String> llamaServerArgs(ClusterPlan plan);
}

/// Manages engine processes on this node. Implementation: `LlamaCppEngine` (lib/src/engine/).
abstract class InferenceEngine {
  /// Starts rpc-server bound to 0.0.0.0:[port] with a local cache dir; returns actual port.
  Future<int> startRpcWorker({required int port, required String cacheDir});
  Future<void> stopRpcWorker();
  bool get rpcWorkerRunning;

  /// Starts llama-server on 127.0.0.1:[port] for [model] using [plan]; completes when /health is ok.
  /// Throws LlmmbcException('engine_error') with the process log tail on failure.
  Future<Uri> startCoordinator({required LocalModel model, required ClusterPlan plan, required int port});
  Future<void> stopCoordinator();
  bool get coordinatorRunning;

  /// Last ~200 lines of engine stdout/stderr (for UI diagnostics).
  List<String> get logTail;
}

// --- core-net -------------------------------------------------------------

/// LAN discovery + peer directory. Implementation: `LanDiscovery` (lib/src/discovery/).
abstract class Discovery {
  /// Start beacon, listener and initial sweep. `self` is used for beacons.
  Future<void> start(NodeInfo Function() self, NodeSettings settings);
  Future<void> stop();

  /// Probe + subnet sweep + manual peers. Completes when the sweep finishes.
  Future<void> scan();

  /// Current peers (excluding self).
  List<NodeInfo> get peers;
  Stream<List<NodeInfo>> get peersChanged;

  /// Adds `host[:port]`; resolves it via GET /v1/node. Returns null if unreachable.
  Future<NodeInfo?> addManualPeer(String hostPort);
}

/// HTTP client for another node's API. Implementation: `HttpNodeClient` (lib/src/api/).
abstract class NodeClient {
  Future<NodeInfo> info(Uri base);
  Future<List<NodeInfo>> peers(Uri base);
  Future<({String host, int port, int budgetBytes})> startRpc(Uri base,
      {required String sessionId, required ModelRef model, required String coordinatorId});
  Future<void> stopRpc(Uri base, String sessionId);
  Stream<ChatDelta> chat(Uri base, ModelRef model, List<ChatMessage> messages,
      {double? temperature, int? maxTokens});
  Future<SessionInfo?> session(Uri base);
}

/// The facade used by the Flutter app and the headless CLI.
/// Implementation: `LocalNodeService` (lib/src/node/node_service.dart), constructed with
/// `LocalNodeService.create(settingsPath: ..., defaultDataDir: ..., platform: PlatformHooks?)`.
abstract class NodeService {
  NodeSettings get settings;
  Future<void> updateSettings(NodeSettings settings);

  /// Runs the startup sequence (§2.1). Emits phases on [startupPhase].
  Future<void> start();
  Future<void> stop();
  Stream<String> get startupPhase;

  HardwareProfile get hardware;
  NodeInfo get self;
  ModelStore get models;
  Discovery get discovery;
  InferenceEngine get engine;

  /// Union of models across reachable nodes (incl. self) with candidate lists.
  List<ClusterModel> clusterModels();
  Stream<void> get changed;

  /// Picks coordinator per §2.3 and streams the answer. Throws LlmmbcException('no_candidates').
  Stream<ChatDelta> chat(ModelRef model, List<ChatMessage> messages, {double? temperature, int? maxTokens});

  SessionInfo? get currentSession;
}

/// Platform callbacks provided by the Flutter app (Android/iOS specifics). All optional.
class PlatformHooks {
  /// Android: directory containing libllama_server.so / librpc_server.so.
  final Future<String?> Function()? nativeLibraryDir;

  /// Android: acquire/release WifiManager.MulticastLock.
  final Future<void> Function(bool acquire)? multicastLock;

  /// Android: GPU renderer string from GL/Vulkan, if known.
  final Future<String?> Function()? gpuRenderer;

  /// Forces worker mode off (iOS).
  final bool clientOnly;
  const PlatformHooks({this.nativeLibraryDir, this.multicastLock, this.gpuRenderer, this.clientOnly = false});
}

/// Shared data types and their JSON wire shapes. CONTRACT – do not change field names or
/// semantics without orchestrator approval (see docs/ARCHITECTURE.md).
library;

import 'constants.dart';

// ---------------------------------------------------------------------------
// Hardware
// ---------------------------------------------------------------------------

enum GpuBackend { none, cuda, rocm, metal, vulkan, opencl, other }

class GpuInfo {
  final String name;
  final GpuBackend backend;

  /// Dedicated VRAM in bytes; 0 for unified/shared memory or unknown.
  final int vramBytes;
  const GpuInfo({required this.name, required this.backend, this.vramBytes = 0});

  Map<String, dynamic> toJson() => {'name': name, 'backend': backend.name, 'vramBytes': vramBytes};
  factory GpuInfo.fromJson(Map<String, dynamic> j) => GpuInfo(
        name: j['name'] as String,
        backend: GpuBackend.values.byName(j['backend'] as String? ?? 'other'),
        vramBytes: (j['vramBytes'] as num?)?.toInt() ?? 0,
      );
}

class HardwareProfile {
  /// `android`, `ios`, `linux`, `windows`, `macos`.
  final String os;

  /// `x64`, `arm64`, `arm`, `ia32`, ...
  final String arch;
  final String cpuModel;
  final int cpuCores;
  final int totalRamBytes;
  final int availableRamBytes;
  final List<GpuInfo> gpus;

  /// e.g. `raspberry-pi`, `docker`, `emulator`, or empty.
  final List<String> tags;

  const HardwareProfile({
    required this.os,
    required this.arch,
    required this.cpuModel,
    required this.cpuCores,
    required this.totalRamBytes,
    required this.availableRamBytes,
    this.gpus = const [],
    this.tags = const [],
  });

  /// Memory this node offers to a session: available RAM minus a safety reserve, plus
  /// dedicated VRAM. Never negative. `availableRamBytes` (MemAvailable) already excludes
  /// memory in use, so the reserve is a small slice of *available* memory:
  /// 10% of available, clamped to [256 MiB, 1 GiB] (#47). `NodeSettings.memoryShare`
  /// is applied on top by the node.
  int get usableMemoryBytes {
    const minReserve = 256 * 1024 * 1024;
    const maxReserve = 1024 * 1024 * 1024;
    final r = (availableRamBytes ~/ 10).clamp(minReserve, maxReserve);
    final ram = availableRamBytes - r;
    final vram = gpus.fold<int>(0, (a, g) => a + g.vramBytes);
    final total = (ram < 0 ? 0 : ram) + vram;
    return total;
  }

  Map<String, dynamic> toJson() => {
        'os': os,
        'arch': arch,
        'cpuModel': cpuModel,
        'cpuCores': cpuCores,
        'totalRamBytes': totalRamBytes,
        'availableRamBytes': availableRamBytes,
        'gpus': gpus.map((g) => g.toJson()).toList(),
        'tags': tags,
      };
  factory HardwareProfile.fromJson(Map<String, dynamic> j) => HardwareProfile(
        os: j['os'] as String,
        arch: j['arch'] as String,
        cpuModel: j['cpuModel'] as String? ?? '',
        cpuCores: (j['cpuCores'] as num?)?.toInt() ?? 1,
        totalRamBytes: (j['totalRamBytes'] as num).toInt(),
        availableRamBytes: (j['availableRamBytes'] as num).toInt(),
        gpus: [for (final g in (j['gpus'] as List? ?? const [])) GpuInfo.fromJson(g as Map<String, dynamic>)],
        tags: [for (final t in (j['tags'] as List? ?? const [])) t as String],
      );
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// Ollama model reference `[namespace/]name[:tag]`.
class ModelRef {
  final String namespace;
  final String name;
  final String tag;
  const ModelRef(this.name, {this.namespace = 'library', this.tag = 'latest'});

  /// Parses `qwen3:30b-a3b`, `library/qwen3`, `hf.co/...` is NOT supported (throws FormatException).
  factory ModelRef.parse(String s) {
    final t = s.trim();
    if (t.isEmpty || t.contains('..') || t.contains(' ')) throw FormatException('bad model ref', s);
    var rest = t;
    var tag = 'latest';
    final colon = rest.lastIndexOf(':');
    if (colon > 0) {
      tag = rest.substring(colon + 1);
      rest = rest.substring(0, colon);
    }
    final parts = rest.split('/');
    // Dots are fine in names (`llama3.2`, `granite3.1-moe`) but a dotted namespace is a
    // registry host (`hf.co/...`), which is not supported.
    if (parts.length > 2 ||
        parts.any((p) => p.isEmpty) ||
        tag.isEmpty ||
        (parts.length == 2 && parts.first.contains('.'))) {
      throw FormatException('bad model ref', s);
    }
    return parts.length == 2
        ? ModelRef(parts[1], namespace: parts[0], tag: tag)
        : ModelRef(parts[0], tag: tag);
  }

  /// Canonical display string: `name:tag` for `library`, else `ns/name:tag`.
  @override
  String toString() => namespace == 'library' ? '$name:$tag' : '$namespace/$name:$tag';

  @override
  bool operator ==(Object other) =>
      other is ModelRef && other.namespace == namespace && other.name == name && other.tag == tag;
  @override
  int get hashCode => Object.hash(namespace, name, tag);
}

/// Subset of GGUF metadata needed for planning.
class GgufMetadata {
  /// `general.architecture`, e.g. `qwen3moe`, `llama`, `gpt-oss`.
  final String architecture;

  /// `<arch>.block_count`.
  final int blockCount;

  /// `<arch>.expert_count` (0 for dense).
  final int expertCount;

  /// `<arch>.expert_used_count` (0 for dense).
  final int expertUsedCount;

  /// `<arch>.context_length`.
  final int contextLength;

  /// `<arch>.embedding_length`.
  final int embeddingLength;

  /// `general.file_type` as int (llama.cpp ftype), -1 if unknown.
  final int fileType;

  /// Total bytes of tensors whose name matches `ffn_.*_exps` (0 for dense).
  final int expertTensorBytes;

  /// Total bytes of all tensor data.
  final int totalTensorBytes;

  const GgufMetadata({
    required this.architecture,
    required this.blockCount,
    this.expertCount = 0,
    this.expertUsedCount = 0,
    this.contextLength = 0,
    this.embeddingLength = 0,
    this.fileType = -1,
    this.expertTensorBytes = 0,
    this.totalTensorBytes = 0,
  });

  bool get isMoe => expertCount > 0;

  Map<String, dynamic> toJson() => {
        'architecture': architecture,
        'blockCount': blockCount,
        'expertCount': expertCount,
        'expertUsedCount': expertUsedCount,
        'contextLength': contextLength,
        'embeddingLength': embeddingLength,
        'fileType': fileType,
        'expertTensorBytes': expertTensorBytes,
        'totalTensorBytes': totalTensorBytes,
      };
  factory GgufMetadata.fromJson(Map<String, dynamic> j) => GgufMetadata(
        architecture: j['architecture'] as String,
        blockCount: (j['blockCount'] as num).toInt(),
        expertCount: (j['expertCount'] as num?)?.toInt() ?? 0,
        expertUsedCount: (j['expertUsedCount'] as num?)?.toInt() ?? 0,
        contextLength: (j['contextLength'] as num?)?.toInt() ?? 0,
        embeddingLength: (j['embeddingLength'] as num?)?.toInt() ?? 0,
        fileType: (j['fileType'] as num?)?.toInt() ?? -1,
        expertTensorBytes: (j['expertTensorBytes'] as num?)?.toInt() ?? 0,
        totalTensorBytes: (j['totalTensorBytes'] as num?)?.toInt() ?? 0,
      );
}

/// A fully downloaded model in the local store.
class LocalModel {
  final ModelRef ref;

  /// Absolute path of the GGUF blob.
  final String ggufPath;
  final int sizeBytes;
  final GgufMetadata? metadata;
  const LocalModel({required this.ref, required this.ggufPath, required this.sizeBytes, this.metadata});

  Map<String, dynamic> toJson() => {
        'ref': ref.toString(),
        'ggufPath': ggufPath,
        'sizeBytes': sizeBytes,
        'metadata': metadata?.toJson(),
      };
  factory LocalModel.fromJson(Map<String, dynamic> j) => LocalModel(
        ref: ModelRef.parse(j['ref'] as String),
        ggufPath: j['ggufPath'] as String? ?? '',
        sizeBytes: (j['sizeBytes'] as num).toInt(),
        metadata: j['metadata'] == null ? null : GgufMetadata.fromJson(j['metadata'] as Map<String, dynamic>),
      );
}

/// Curated catalog entry shown in the model downloader.
class CatalogEntry {
  final ModelRef ref;
  final String title;
  final String description;
  final bool isMoe;

  /// Approximate download size in bytes.
  final int approxSizeBytes;
  const CatalogEntry({
    required this.ref,
    required this.title,
    required this.description,
    required this.isMoe,
    required this.approxSizeBytes,
  });
}

enum DownloadState { queued, resolving, downloading, verifying, done, failed, cancelled }

class DownloadProgress {
  final ModelRef ref;
  final DownloadState state;
  final int receivedBytes;
  final int totalBytes;
  final String? error;
  const DownloadProgress(this.ref, this.state, {this.receivedBytes = 0, this.totalBytes = 0, this.error});
  double get fraction => totalBytes <= 0 ? 0 : receivedBytes / totalBytes;
}

// ---------------------------------------------------------------------------
// Nodes
// ---------------------------------------------------------------------------

enum NodeStatus { idle, worker, coordinator, busy, offline }

class NodeSettings {
  final String nodeId;
  final String name;
  final bool workerEnabled;
  final String dataDir;
  final String? engineDir;
  final int apiPort;
  final List<String> manualPeers;

  /// Max fraction (0..1] of usableMemoryBytes this node lends to a session.
  final double memoryShare;

  const NodeSettings({
    required this.nodeId,
    required this.name,
    required this.dataDir,
    this.workerEnabled = true,
    this.engineDir,
    this.apiPort = kNodeApiPort,
    this.manualPeers = const [],
    this.memoryShare = 0.8,
  });

  NodeSettings copyWith({
    String? name,
    bool? workerEnabled,
    String? dataDir,
    String? engineDir,
    int? apiPort,
    List<String>? manualPeers,
    double? memoryShare,
  }) =>
      NodeSettings(
        nodeId: nodeId,
        name: name ?? this.name,
        workerEnabled: workerEnabled ?? this.workerEnabled,
        dataDir: dataDir ?? this.dataDir,
        engineDir: engineDir ?? this.engineDir,
        apiPort: apiPort ?? this.apiPort,
        manualPeers: manualPeers ?? this.manualPeers,
        memoryShare: memoryShare ?? this.memoryShare,
      );

  Map<String, dynamic> toJson() => {
        'nodeId': nodeId,
        'name': name,
        'workerEnabled': workerEnabled,
        'dataDir': dataDir,
        'engineDir': engineDir,
        'apiPort': apiPort,
        'manualPeers': manualPeers,
        'memoryShare': memoryShare,
      };
  factory NodeSettings.fromJson(Map<String, dynamic> j) => NodeSettings(
        nodeId: j['nodeId'] as String,
        name: j['name'] as String,
        dataDir: j['dataDir'] as String,
        workerEnabled: j['workerEnabled'] as bool? ?? true,
        engineDir: j['engineDir'] as String?,
        apiPort: (j['apiPort'] as num?)?.toInt() ?? kNodeApiPort,
        manualPeers: [for (final p in (j['manualPeers'] as List? ?? const [])) p as String],
        memoryShare: (j['memoryShare'] as num?)?.toDouble() ?? 0.8,
      );
}

/// Public description of a node, served at `GET /v1/node`.
class NodeInfo {
  final String nodeId;
  final String name;

  /// Address other nodes should use (IPv4 or hostname). Filled by the observer when unknown.
  final String host;
  final int apiPort;
  final int protocolVersion;
  final String appVersion;
  final bool workerEnabled;

  /// False when the engine binaries are unavailable (e.g. iOS): node can never be a candidate.
  final bool engineAvailable;
  final NodeStatus status;
  final HardwareProfile hardware;

  /// Fully downloaded models (`ModelRef.toString()` + size + metadata).
  final List<LocalModel> models;

  /// Observer-side fields (not sent by the node itself).
  final bool reachable;
  final bool isSelf;
  final DateTime? lastSeen;

  const NodeInfo({
    required this.nodeId,
    required this.name,
    required this.host,
    required this.apiPort,
    required this.workerEnabled,
    required this.engineAvailable,
    required this.status,
    required this.hardware,
    required this.models,
    this.protocolVersion = kProtocolVersion,
    this.appVersion = '0.0.0',
    this.reachable = true,
    this.isSelf = false,
    this.lastSeen,
  });

  Uri get baseUri => Uri(scheme: 'http', host: host, port: apiPort);

  /// Worker eligibility rule (docs/ARCHITECTURE.md §2.2).
  bool isCandidateFor(ModelRef ref) =>
      reachable && workerEnabled && engineAvailable && models.any((m) => m.ref == ref);

  NodeInfo copyWith({String? host, bool? reachable, bool? isSelf, DateTime? lastSeen, NodeStatus? status}) =>
      NodeInfo(
        nodeId: nodeId,
        name: name,
        host: host ?? this.host,
        apiPort: apiPort,
        protocolVersion: protocolVersion,
        appVersion: appVersion,
        workerEnabled: workerEnabled,
        engineAvailable: engineAvailable,
        status: status ?? this.status,
        hardware: hardware,
        models: models,
        reachable: reachable ?? this.reachable,
        isSelf: isSelf ?? this.isSelf,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  Map<String, dynamic> toJson() => {
        'nodeId': nodeId,
        'name': name,
        'host': host,
        'apiPort': apiPort,
        'protocolVersion': protocolVersion,
        'appVersion': appVersion,
        'workerEnabled': workerEnabled,
        'engineAvailable': engineAvailable,
        'status': status.name,
        'hardware': hardware.toJson(),
        'models': models.map((m) => m.toJson()).toList(),
      };
  factory NodeInfo.fromJson(Map<String, dynamic> j) => NodeInfo(
        nodeId: j['nodeId'] as String,
        name: j['name'] as String,
        host: j['host'] as String? ?? '',
        apiPort: (j['apiPort'] as num?)?.toInt() ?? kNodeApiPort,
        protocolVersion: (j['protocolVersion'] as num?)?.toInt() ?? kProtocolVersion,
        appVersion: j['appVersion'] as String? ?? '0.0.0',
        workerEnabled: j['workerEnabled'] as bool? ?? false,
        engineAvailable: j['engineAvailable'] as bool? ?? false,
        status: NodeStatus.values.byName(j['status'] as String? ?? 'idle'),
        hardware: HardwareProfile.fromJson(j['hardware'] as Map<String, dynamic>),
        models: [for (final m in (j['models'] as List? ?? const [])) LocalModel.fromJson(m as Map<String, dynamic>)],
      );
}

/// A model available somewhere in the cluster, with its candidate nodes.
class ClusterModel {
  final ModelRef ref;
  final int sizeBytes;
  final GgufMetadata? metadata;
  final List<NodeInfo> candidates;
  const ClusterModel({required this.ref, required this.sizeBytes, required this.candidates, this.metadata});
  bool get isMoe => metadata?.isMoe ?? false;
}

// ---------------------------------------------------------------------------
// Sessions / planning
// ---------------------------------------------------------------------------

/// A session member as seen by the planner.
class PlanNode {
  final String nodeId;

  /// `host:port` of the node's rpc-server; null for the coordinator itself.
  final String? rpcEndpoint;

  /// Bytes this node agreed to lend (from `/v1/rpc/start` or own budget).
  final int budgetBytes;
  final bool hasGpu;
  const PlanNode({required this.nodeId, required this.rpcEndpoint, required this.budgetBytes, this.hasGpu = false});
  bool get isCoordinator => rpcEndpoint == null;
}

class PlanAssignment {
  final String nodeId;

  /// Fraction of layers (0..1); all assignments sum to 1.
  final double layerFraction;

  /// Estimated bytes placed on this node.
  final int estimatedBytes;
  const PlanAssignment({required this.nodeId, required this.layerFraction, required this.estimatedBytes});
  Map<String, dynamic> toJson() =>
      {'nodeId': nodeId, 'layerFraction': layerFraction, 'estimatedBytes': estimatedBytes};
}

class ClusterPlan {
  final ModelRef model;
  final List<PlanNode> nodes;
  final List<PlanAssignment> assignments;

  /// Extra `--override-tensor` rules (`<regex>=<device>`), MoE only.
  final List<String> tensorOverrides;
  final int contextLength;
  const ClusterPlan({
    required this.model,
    required this.nodes,
    required this.assignments,
    this.tensorOverrides = const [],
    this.contextLength = 4096,
  });
  Map<String, dynamic> toJson() => {
        'model': model.toString(),
        'assignments': assignments.map((a) => a.toJson()).toList(),
        'tensorOverrides': tensorOverrides,
        'contextLength': contextLength,
      };
}

class PlanError implements Exception {
  final String message;
  PlanError(this.message);
  @override
  String toString() => 'PlanError: $message';
}

class SessionInfo {
  final String sessionId;
  final ModelRef model;
  final String coordinatorId;
  final List<String> workerIds;
  final DateTime startedAt;
  final DateTime lastUsedAt;
  final Map<String, dynamic>? plan;
  const SessionInfo({
    required this.sessionId,
    required this.model,
    required this.coordinatorId,
    required this.workerIds,
    required this.startedAt,
    required this.lastUsedAt,
    this.plan,
  });
  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'model': model.toString(),
        'coordinatorId': coordinatorId,
        'workerIds': workerIds,
        'startedAt': startedAt.toIso8601String(),
        'lastUsedAt': lastUsedAt.toIso8601String(),
        'plan': plan,
      };
  factory SessionInfo.fromJson(Map<String, dynamic> j) => SessionInfo(
        sessionId: j['sessionId'] as String,
        model: ModelRef.parse(j['model'] as String),
        coordinatorId: j['coordinatorId'] as String,
        workerIds: [for (final w in (j['workerIds'] as List? ?? const [])) w as String],
        startedAt: DateTime.parse(j['startedAt'] as String),
        lastUsedAt: DateTime.parse(j['lastUsedAt'] as String),
        plan: j['plan'] as Map<String, dynamic>?,
      );
}

// ---------------------------------------------------------------------------
// Chat
// ---------------------------------------------------------------------------

class ChatMessage {
  /// `system`, `user`, `assistant`.
  final String role;
  final String content;
  const ChatMessage(this.role, this.content);
  Map<String, dynamic> toJson() => {'role': role, 'content': content};
  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(j['role'] as String, j['content'] as String);
}

/// One streamed chunk of a chat answer.
class ChatDelta {
  final String content;

  /// Non-null on the final chunk (`stop`, `length`, `error`).
  final String? finishReason;

  /// Id of the coordinator that served the request.
  final String? servedBy;
  const ChatDelta(this.content, {this.finishReason, this.servedBy});
}

class LlmmbcException implements Exception {
  /// One of the error codes in docs/ARCHITECTURE.md §3.
  final String code;
  final String message;
  final int? httpStatus;
  LlmmbcException(this.code, this.message, {this.httpStatus});
  Map<String, dynamic> toJson() => {
        'error': {'code': code, 'message': message}
      };
  @override
  String toString() => 'LlmmbcException($code): $message';
}

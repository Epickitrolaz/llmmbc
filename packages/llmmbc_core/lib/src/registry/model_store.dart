// Ollama registry downloader + on-disk model store. Owned by core-data (docs/ARCHITECTURE.md §5).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../constants.dart';
import '../interfaces.dart';
import '../models.dart';
import 'gguf.dart';

/// Content-addressed model store backed by `<dataDir>/models`.
///
/// Layout (docs/ARCHITECTURE.md §5):
/// * `manifests/<ns>/<name>/<tag>.json` – raw registry manifest
/// * `blobs/sha256-<hex>` – verified layer blobs
/// * `blobs/sha256-<hex>.partial` – resumable partial downloads
/// * `meta-cache.json` – parsed GGUF metadata keyed by blob name
class FileModelStore implements ModelStore {
  /// [dataDir] is NodeSettings.dataDir; models live in `<dataDir>/models`.
  /// [registry] defaults to kOllamaRegistry (overridable for tests / mirrors).
  ///
  /// [requestTimeout] bounds registry requests: waiting for response headers, an idle blob
  /// body, and reading a manifest body. A stalled or hung registry therefore fails the pull
  /// (or unblocks `cancel()`) instead of wedging the job forever.
  FileModelStore(
    String dataDir, {
    GgufInspector inspector = const GgufReader(),
    String? registry,
    Duration requestTimeout = const Duration(seconds: 30),
  })  : _dataDir = dataDir,
        _inspector = inspector,
        _registryBase = _normalizeBase(registry ?? kOllamaRegistry),
        _requestTimeout = requestTimeout;

  final String _dataDir;
  final GgufInspector _inspector;
  final String _registryBase;
  final Duration _requestTimeout;
  final Map<String, _PullJob> _jobs = {};
  final Map<String, _CachedMetadata> _metadataCache = {};
  bool _metadataLoaded = false;

  static const Duration _progressInterval = Duration(milliseconds: 100);
  static const String _manifestMediaType = 'application/vnd.docker.distribution.manifest.v2+json';

  @override
  String get modelsDir => p.join(_dataDir, 'models');

  String get _manifestsDir => p.join(modelsDir, 'manifests');
  String get _blobsDir => p.join(modelsDir, 'blobs');
  String get _metadataCachePath => p.join(modelsDir, 'meta-cache.json');

  // -------------------------------------------------------------------------
  // Read side
  // -------------------------------------------------------------------------

  @override
  Future<List<LocalModel>> list() async {
    await _loadMetadataCache();
    final dir = Directory(_manifestsDir);
    if (!await dir.exists()) return const [];

    final manifestFiles = <File>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.endsWith('.json')) manifestFiles.add(entity);
    }
    manifestFiles.sort((a, b) => a.path.compareTo(b.path));

    final models = <LocalModel>[];
    for (final file in manifestFiles) {
      final ref = _refFromManifestPath(file.path);
      if (ref == null) continue;
      final manifest = await _readManifestFile(file);
      if (manifest == null) continue;
      final modelLayer = manifest.modelLayer;
      if (modelLayer == null || modelLayer.digest == null) continue;

      var complete = true;
      var sizeBytes = 0;
      for (final layer in manifest.layers) {
        if (layer.digest == null) {
          complete = false;
          break;
        }
        final blob = File(_blobPath(layer.digest!));
        if (!await blob.exists()) {
          complete = false;
          break;
        }
        final length = await blob.length();
        if (layer.size > 0 && length != layer.size) {
          complete = false;
          break;
        }
        sizeBytes += length;
      }
      if (!complete) continue;

      final ggufPath = _blobPath(modelLayer.digest!);
      final metadata = await _metadataFor(modelLayer.digest!, File(ggufPath));
      models.add(LocalModel(ref: ref, ggufPath: ggufPath, sizeBytes: sizeBytes, metadata: metadata));
    }
    return models;
  }

  @override
  Future<LocalModel?> find(ModelRef ref) async {
    for (final model in await list()) {
      if (model.ref == ref) return model;
    }
    return null;
  }

  @override
  Future<int> remoteSize(ModelRef ref) async {
    final manifest = await _fetchManifest(ref);
    return manifest.layers.fold<int>(0, (sum, layer) => sum + layer.size);
  }

  // -------------------------------------------------------------------------
  // Pull
  // -------------------------------------------------------------------------

  @override
  Stream<DownloadProgress> pull(ModelRef ref) {
    final key = ref.toString();
    final existing = _jobs[key];
    if (existing != null) return _attach(existing);

    // Create and register the job synchronously so two concurrent pulls of the same ref
    // share one download (no await between the lookup and the insert above).
    final job = _PullJob(ref);
    _jobs[key] = job;
    unawaited(_runPull(job));
    return _attach(job);
  }

  @override
  Future<void> cancel(ModelRef ref) async {
    final job = _jobs[ref.toString()];
    if (job == null) return;
    job.cancelled = true;
    // Abort an in-flight blob body and any request still waiting for response headers.
    job.abort?.call();
    job.client.close();
    // Safe to await from a progress listener: `finished` completes before listener streams
    // are closed (see _runPull's finally block).
    await job.finished.future;
  }

  @override
  Future<void> delete(ModelRef ref) async {
    final manifest = File(_manifestPath(ref));
    if (!await manifest.exists()) return;
    await manifest.delete();
    await _removeEmptyDirs(manifest.parent);
    await _collectGarbage();
  }

  @override
  List<CatalogEntry> catalog() => [
        const CatalogEntry(
          ref: ModelRef('qwen3', tag: '30b-a3b'),
          title: 'Qwen3 30B-A3B',
          description: 'Mixture-of-experts, 30B total / 3B active. Excellent quality per byte moved.',
          isMoe: true,
          approxSizeBytes: 18600000000,
        ),
        const CatalogEntry(
          ref: ModelRef('granite3.1-moe', tag: '1b'),
          title: 'Granite 3.1 MoE 1B',
          description: 'Tiny mixture-of-experts (1B active) – ideal for small clusters.',
          isMoe: true,
          approxSizeBytes: 1400000000,
        ),
        const CatalogEntry(
          ref: ModelRef('granite3.1-moe', tag: '3b'),
          title: 'Granite 3.1 MoE 3B',
          description: 'Compact mixture-of-experts with strong instruction following.',
          isMoe: true,
          approxSizeBytes: 2100000000,
        ),
        const CatalogEntry(
          ref: ModelRef('gpt-oss', tag: '20b'),
          title: 'GPT-OSS 20B',
          description: 'Open-weight MoE (3.6B active) in MXFP4, fits mid-size clusters.',
          isMoe: true,
          approxSizeBytes: 13800000000,
        ),
        const CatalogEntry(
          ref: ModelRef('deepseek-v2', tag: '16b'),
          title: 'DeepSeek V2 16B',
          description: 'DeepSeek MoE lite, 16B total / 2.4B active.',
          isMoe: true,
          approxSizeBytes: 8900000000,
        ),
        const CatalogEntry(
          ref: ModelRef('mixtral', tag: '8x7b'),
          title: 'Mixtral 8x7B',
          description: 'Classic 8-expert MoE, 47B total / 13B active.',
          isMoe: true,
          approxSizeBytes: 26000000000,
        ),
        const CatalogEntry(
          ref: ModelRef('qwen3-coder', tag: '30b'),
          title: 'Qwen3 Coder 30B',
          description: 'MoE coding model, 30B total / 3B active.',
          isMoe: true,
          approxSizeBytes: 18600000000,
        ),
        const CatalogEntry(
          ref: ModelRef('qwen3', tag: '0.6b'),
          title: 'Qwen3 0.6B',
          description: 'Dense starter model; tiny enough for phones and Raspberry Pi.',
          isMoe: false,
          approxSizeBytes: 520000000,
        ),
        const CatalogEntry(
          ref: ModelRef('qwen3', tag: '1.7b'),
          title: 'Qwen3 1.7B',
          description: 'Dense small model with a good quality/size balance.',
          isMoe: false,
          approxSizeBytes: 1400000000,
        ),
        const CatalogEntry(
          ref: ModelRef('qwen3', tag: '4b'),
          title: 'Qwen3 4B',
          description: 'Dense mid-size model for desktops and laptops.',
          isMoe: false,
          approxSizeBytes: 2600000000,
        ),
        const CatalogEntry(
          ref: ModelRef('llama3.2', tag: '1b'),
          title: 'Llama 3.2 1B',
          description: 'Dense 1B model for low-memory devices.',
          isMoe: false,
          approxSizeBytes: 1300000000,
        ),
        const CatalogEntry(
          ref: ModelRef('llama3.2', tag: '3b'),
          title: 'Llama 3.2 3B',
          description: 'Dense 3B model, a solid laptop baseline.',
          isMoe: false,
          approxSizeBytes: 2000000000,
        ),
        const CatalogEntry(
          ref: ModelRef('gemma3', tag: '1b'),
          title: 'Gemma 3 1B',
          description: 'Dense 1B model from Google, fast on CPU.',
          isMoe: false,
          approxSizeBytes: 815000000,
        ),
        const CatalogEntry(
          ref: ModelRef('phi4-mini', tag: 'latest'),
          title: 'Phi-4 Mini',
          description: 'Dense 3.8B reasoning model.',
          isMoe: false,
          approxSizeBytes: 2500000000,
        ),
      ];

  // -------------------------------------------------------------------------
  // Pull internals
  // -------------------------------------------------------------------------

  Stream<DownloadProgress> _attach(_PullJob job) {
    late StreamController<DownloadProgress> controller;
    controller = StreamController<DownloadProgress>(
      onListen: () {
        if (job.closed) {
          unawaited(controller.close());
          return;
        }
        job.listeners.add(controller);
        // Replay the current state to late subscribers. The synthetic `queued` state is not
        // replayed so that an already-complete model emits `done` as its first event.
        if (job.current.state != DownloadState.queued) controller.add(job.current);
      },
      onCancel: () {
        job.listeners.remove(controller);
      },
    );
    return controller.stream;
  }

  Future<void> _runPull(_PullJob job) async {
    try {
      final alreadyComplete = await find(job.ref);
      if (alreadyComplete != null) {
        _emit(job,
            DownloadProgress(job.ref, DownloadState.done,
                receivedBytes: alreadyComplete.sizeBytes, totalBytes: alreadyComplete.sizeBytes),
            force: true);
        return;
      }
      if (job.cancelled) throw const _Cancelled();

      _emit(job, DownloadProgress(job.ref, DownloadState.resolving), force: true);
      final manifest = await _fetchManifest(job.ref, job: job);
      if (job.cancelled) throw const _Cancelled();
      await _writeManifest(job.ref, manifest.raw);

      final totalBytes = manifest.layers.fold<int>(0, (sum, layer) => sum + layer.size);
      var completedBytes = 0;

      for (final layer in manifest.layers) {
        if (job.cancelled) throw const _Cancelled();
        final digest = layer.digest;
        if (digest == null || digest.isEmpty) {
          throw _PullFailure('manifest layer for ${job.ref} has no digest');
        }
        final target = File(_blobPath(digest));
        if (await target.exists()) {
          final length = await target.length();
          if (layer.size <= 0 || length == layer.size) {
            completedBytes += length;
            _emit(
                job,
                DownloadProgress(job.ref, DownloadState.downloading,
                    receivedBytes: completedBytes, totalBytes: totalBytes),
                force: true);
            continue;
          }
          // Invalid blob (wrong size): re-download it.
          await target.delete();
        }

        final baseBytes = completedBytes;
        await _downloadLayer(
          job: job,
          ref: job.ref,
          layer: layer,
          onProgress: (layerBytes) {
            _emit(
                job,
                DownloadProgress(job.ref, DownloadState.downloading,
                    receivedBytes: baseBytes + layerBytes, totalBytes: totalBytes),
                force: false);
          },
        );
        final downloaded = await File(_blobPath(digest)).length();
        completedBytes = baseBytes + downloaded;
      }

      if (job.cancelled) throw const _Cancelled();
      _emit(job,
          DownloadProgress(job.ref, DownloadState.verifying,
              receivedBytes: completedBytes, totalBytes: totalBytes),
          force: true);
      if (job.cancelled) throw const _Cancelled();
      // Every blob was digest-verified before its rename; reaching here means the model is whole.
      _emit(job,
          DownloadProgress(job.ref, DownloadState.done,
              receivedBytes: totalBytes, totalBytes: totalBytes),
          force: true);
    } on _Cancelled {
      _emit(job,
          DownloadProgress(job.ref, DownloadState.cancelled,
              receivedBytes: job.current.receivedBytes, totalBytes: job.current.totalBytes),
          force: true);
    } catch (error) {
      if (job.cancelled) {
        // Requests aborted by cancel() surface as client errors; report them as cancellation.
        _emit(job,
            DownloadProgress(job.ref, DownloadState.cancelled,
                receivedBytes: job.current.receivedBytes, totalBytes: job.current.totalBytes),
            force: true);
      } else {
        _emit(job,
            DownloadProgress(job.ref, DownloadState.failed,
                receivedBytes: job.current.receivedBytes,
                totalBytes: job.current.totalBytes,
                error: '$error'),
            force: true);
      }
    } finally {
      _jobs.remove(job.ref.toString());
      job.closed = true;
      job.client.close();
      // Complete waiters (cancel()) before awaiting listener shutdown. A listener may be
      // inside `await store.cancel(ref)`: it cannot drain its stream (and let close() finish)
      // until this future completes, which used to deadlock.
      if (!job.finished.isCompleted) job.finished.complete();
      for (final listener in List<StreamController<DownloadProgress>>.of(job.listeners)) {
        try {
          await listener.close();
        } catch (_) {
          // Listener already closed by its consumer.
        }
      }
      job.listeners.clear();
    }
  }

  void _emit(_PullJob job, DownloadProgress progress, {required bool force}) {
    job.current = progress;
    final now = DateTime.now();
    if (!force &&
        job.lastEmit != null &&
        now.difference(job.lastEmit!) < _progressInterval) {
      return;
    }
    job.lastEmit = now;
    for (final listener in List<StreamController<DownloadProgress>>.of(job.listeners)) {
      if (!listener.isClosed) listener.add(progress);
    }
  }

  Future<void> _downloadLayer({
    required _PullJob job,
    required ModelRef ref,
    required _Layer layer,
    required void Function(int layerBytes) onProgress,
    bool allowRetry = true,
  }) async {
    final digest = layer.digest!;
    final targetPath = _blobPath(digest);
    final partial = File('$targetPath.partial');
    await partial.parent.create(recursive: true);
    var existing = 0;
    if (await partial.exists()) existing = await partial.length();
    if (layer.size > 0 && existing > layer.size) {
      await partial.delete();
      existing = 0;
    }

    if (layer.size > 0 && existing == layer.size && await File(targetPath).exists()) {
      onProgress(existing);
      return;
    }

    var append = existing > 0;
    final request = http.Request('GET', _blobUri(ref, digest));
    if (append) request.headers[HttpHeaders.rangeHeader] = 'bytes=$existing-';
    final response = await _sendRequest(job.client, request, job: job);

    if (response.statusCode == HttpStatus.ok) {
      // Server ignored Range: restart from zero.
      append = false;
      existing = 0;
    } else if (response.statusCode == HttpStatus.partialContent) {
      // Resume accepted.
      append = true;
    } else if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
        existing > 0 &&
        allowRetry) {
      // A stale or oversized .partial cannot be resumed: drop it and fetch from scratch.
      await _drainErrorBody(response, job, digest);
      await partial.delete();
      return _downloadLayer(
        job: job,
        ref: ref,
        layer: layer,
        onProgress: onProgress,
        allowRetry: false,
      );
    } else {
      await _drainErrorBody(response, job, digest);
      throw _PullFailure(
          'blob ${layer.digest} download failed with HTTP ${response.statusCode}');
    }

    final sink = partial.openWrite(mode: append ? FileMode.append : FileMode.write);
    if (job.cancelled) {
      await sink.close();
      throw const _Cancelled();
    }
    final completer = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    Timer? idleTimer;
    var received = existing;

    void cancelIdleTimer() {
      idleTimer?.cancel();
      idleTimer = null;
    }

    void resetIdleTimer() {
      cancelIdleTimer();
      idleTimer = Timer(_requestTimeout, () {
        unawaited(subscription.cancel());
        if (!completer.isCompleted) {
          completer.completeError(
              _PullFailure('blob $digest download stalled for ${_requestTimeout.inMilliseconds}ms'));
        }
      });
    }

    job.abort = () {
      cancelIdleTimer();
      unawaited(subscription.cancel());
      if (!completer.isCompleted) completer.completeError(const _Cancelled());
    };

    subscription = response.stream.listen(
      (chunk) {
        if (job.cancelled) {
          cancelIdleTimer();
          unawaited(subscription.cancel());
          if (!completer.isCompleted) completer.completeError(const _Cancelled());
          return;
        }
        resetIdleTimer();
        sink.add(chunk);
        received += chunk.length;
        onProgress(received);
      },
      onDone: () {
        cancelIdleTimer();
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        cancelIdleTimer();
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
      cancelOnError: true,
    );
    // The body may never start after the headers arrive.
    resetIdleTimer();

    try {
      await completer.future;
      await sink.flush();
    } finally {
      cancelIdleTimer();
      job.abort = null;
      try {
        await sink.close();
      } catch (_) {
        // Sink may already be closed after a cancellation.
      }
    }

    final length = await partial.length();
    if (job.cancelled) throw const _Cancelled();
    if (layer.size > 0 && length != layer.size) {
      // Keep the partial so a later pull can resume it.
      throw _PullFailure(
          'blob $digest incomplete: $length of ${layer.size} bytes');
    }
    if (layer.digestSha256 != null) {
      final actual = await _sha256File(partial);
      if (actual != layer.digestSha256) {
        // Corrupt data must never be promoted to a blob; start over next time.
        await partial.delete();
        throw _PullFailure('blob $digest failed sha256 verification');
      }
    }
    if (await File(targetPath).exists()) await File(targetPath).delete();
    await partial.rename(targetPath);
    onProgress(received);
  }

  /// Drains a non-OK blob response body under the same idle timeout that guards the success
  /// path. A registry that sends an error status and then stalls its body must not wedge the
  /// pull (issue #26). Cancellation aborts the drain immediately.
  Future<void> _drainErrorBody(http.StreamedResponse response, _PullJob job, String digest) async {
    final completer = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    Timer? timer;

    void finish([Object? error]) {
      timer?.cancel();
      timer = null;
      if (completer.isCompleted) return;
      if (error == null) {
        completer.complete();
      } else {
        completer.completeError(error);
      }
    }

    subscription = response.stream.listen(
      (_) {},
      onDone: () => finish(),
      onError: (Object error, StackTrace stackTrace) {
        finish(job.cancelled ? const _Cancelled() : error);
      },
      cancelOnError: true,
    );
    timer = Timer(_requestTimeout, () {
      unawaited(subscription.cancel());
      finish(_PullFailure(
          'blob $digest error response body stalled for ${_requestTimeout.inMilliseconds}ms'));
    });

    job.abort = () {
      unawaited(subscription.cancel());
      finish(const _Cancelled());
    };

    try {
      await completer.future;
    } finally {
      timer?.cancel();
      job.abort = null;
    }
  }

  // -------------------------------------------------------------------------
  // Registry
  // -------------------------------------------------------------------------

  Future<_Manifest> _fetchManifest(ModelRef ref, {_PullJob? job}) async {
    final client = job?.client ?? http.Client();
    final ownedClient = job == null;
    try {
      final request = http.Request('GET', _manifestUri(ref))
        ..headers[HttpHeaders.acceptHeader] = _manifestMediaType;
      final response = await _sendRequest(client, request, job: job);

      final String body;
      try {
        body = await response.stream.bytesToString().timeout(_requestTimeout);
      } on TimeoutException {
        client.close();
        throw _PullFailure(
            'registry response for $ref stalled for ${_requestTimeout.inMilliseconds}ms');
      } catch (error) {
        if (job?.cancelled ?? false) throw const _Cancelled();
        throw _PullFailure('could not read registry response for $ref: $error');
      }

      if (response.statusCode != HttpStatus.ok) {
        throw _PullFailure('registry returned HTTP ${response.statusCode} for $ref');
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(body);
      } on FormatException {
        throw _PullFailure('registry returned invalid JSON for $ref');
      }
      if (decoded is! Map<String, dynamic>) {
        throw _PullFailure('registry returned an unexpected manifest for $ref');
      }
      final layers = <_Layer>[];
      final rawLayers = decoded['layers'];
      if (rawLayers is List) {
        for (final item in rawLayers) {
          if (item is! Map) continue;
          final layer = _Layer.fromJson(Map<String, dynamic>.from(item));
          if (layer.mediaType.isEmpty) continue;
          layers.add(layer);
        }
      }
      return _Manifest(raw: decoded, layers: layers);
    } finally {
      if (ownedClient) client.close();
    }
  }

  /// Sends a registry request, bounding the wait for response headers. A timeout closes the
  /// (per-job) client so the socket cannot linger; cancellation is surfaced as [_Cancelled].
  Future<http.StreamedResponse> _sendRequest(
    http.Client client,
    http.BaseRequest request, {
    _PullJob? job,
  }) async {
    try {
      return await client.send(request).timeout(_requestTimeout);
    } on TimeoutException {
      client.close();
      throw _PullFailure(
          'registry request timed out after ${_requestTimeout.inMilliseconds}ms');
    } catch (error) {
      if (job?.cancelled ?? false) throw const _Cancelled();
      throw _PullFailure('could not reach registry: $error');
    }
  }

  // -------------------------------------------------------------------------
  // Filesystem helpers
  // -------------------------------------------------------------------------

  String _manifestPath(ModelRef ref) =>
      p.join(_manifestsDir, ref.namespace, ref.name, '${ref.tag}.json');

  String _blobPath(String digest) => p.join(_blobsDir, 'sha256-${_digestHex(digest)}');

  Uri _manifestUri(ModelRef ref) => Uri.parse(
      '$_registryBase/v2/${Uri.encodeComponent(ref.namespace)}/${Uri.encodeComponent(ref.name)}'
      '/manifests/${Uri.encodeComponent(ref.tag)}');

  Uri _blobUri(ModelRef ref, String digest) => Uri.parse(
      '$_registryBase/v2/${Uri.encodeComponent(ref.namespace)}/${Uri.encodeComponent(ref.name)}'
      '/blobs/${Uri.encodeComponent(digest)}');

  ModelRef? _refFromManifestPath(String path) {
    final relative = p.relative(path, from: _manifestsDir);
    final parts = p.split(relative);
    if (parts.length != 3) return null;
    final tag = parts[2].endsWith('.json')
        ? parts[2].substring(0, parts[2].length - '.json'.length)
        : parts[2];
    try {
      return ModelRef(parts[1], namespace: parts[0], tag: tag);
    } on FormatException {
      return null;
    }
  }

  Future<void> _writeManifest(ModelRef ref, Map<String, dynamic> raw) async {
    final file = File(_manifestPath(ref));
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(raw));
  }

  Future<_Manifest?> _readManifestFile(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final layers = <_Layer>[];
      final rawLayers = decoded['layers'];
      if (rawLayers is List) {
        for (final item in rawLayers) {
          if (item is! Map) continue;
          layers.add(_Layer.fromJson(Map<String, dynamic>.from(item)));
        }
      }
      return _Manifest(raw: decoded, layers: layers);
    } catch (_) {
      return null;
    }
  }

  Future<void> _removeEmptyDirs(Directory directory) async {
    var current = directory;
    while (p.isWithin(_manifestsDir, current.path) || current.path == _manifestsDir) {
      if (!await current.exists()) break;
      final entries = await current.list(followLinks: false).toList();
      if (entries.isNotEmpty) break;
      await current.delete();
      if (current.path == _manifestsDir) break;
      current = current.parent;
    }
  }

  Future<void> _collectGarbage() async {
    final referenced = <String>{};
    final dir = Directory(_manifestsDir);
    if (await dir.exists()) {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final manifest = await _readManifestFile(entity);
        if (manifest == null) continue;
        for (final layer in manifest.layers) {
          if (layer.digest != null) referenced.add('sha256-${_digestHex(layer.digest!)}');
        }
      }
    }

    final blobs = Directory(_blobsDir);
    if (await blobs.exists()) {
      await for (final entity in blobs.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith('sha256-')) continue;
        // Partial downloads follow their blob's reference: an in-flight pull writes its
        // manifest first, so a referenced digest is never collected.
        final base = name.endsWith('.partial')
            ? name.substring(0, name.length - '.partial'.length)
            : name;
        if (referenced.contains(base)) continue;
        await entity.delete();
        if (base == name) _metadataCache.remove(name);
      }
      await _saveMetadataCache();
    }
  }

  Future<GgufMetadata?> _metadataFor(String digest, File blob) async {
    final key = 'sha256-${_digestHex(digest)}';
    final length = await blob.length();
    final cached = _metadataCache[key];
    if (cached != null && cached.size == length) return cached.metadata;
    GgufMetadata metadata;
    try {
      metadata = await _inspector.read(blob.path);
    } catch (_) {
      return null;
    }
    _metadataCache[key] = _CachedMetadata(size: length, metadata: metadata);
    await _saveMetadataCache();
    return metadata;
  }

  Future<void> _loadMetadataCache() async {
    if (_metadataLoaded) return;
    _metadataLoaded = true;
    final file = File(_metadataCachePath);
    if (!await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      final entries = decoded['entries'];
      if (entries is! Map) return;
      for (final entry in entries.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final metadata = value['metadata'];
        if (metadata is! Map) continue;
        _metadataCache[entry.key as String] = _CachedMetadata(
          size: (value['size'] as num?)?.toInt() ?? 0,
          metadata: GgufMetadata.fromJson(Map<String, dynamic>.from(metadata)),
        );
      }
    } catch (_) {
      // A corrupt cache is not fatal: it is rebuilt on demand.
    }
  }

  Future<void> _saveMetadataCache() async {
    try {
      final file = File(_metadataCachePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'version': 1,
        'entries': {
          for (final entry in _metadataCache.entries)
            entry.key: {'size': entry.value.size, 'metadata': entry.value.metadata.toJson()},
        },
      }));
    } catch (_) {
      // Cache writes are best effort.
    }
  }

  static Future<String> _sha256File(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  static String _normalizeBase(String base) {
    var value = base.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  static String _digestHex(String digest) {
    final colon = digest.indexOf(':');
    return (colon >= 0 ? digest.substring(colon + 1) : digest).toLowerCase();
  }
}

// ---------------------------------------------------------------------------
// Manifest helpers
// ---------------------------------------------------------------------------

class _Layer {
  final String mediaType;
  final String? digest;
  final int size;

  const _Layer({required this.mediaType, required this.digest, required this.size});

  factory _Layer.fromJson(Map<String, dynamic> json) {
    final digest = json['digest'];
    return _Layer(
      mediaType: json['mediaType'] as String? ?? '',
      digest: digest is String && digest.isNotEmpty ? digest : null,
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  }

  /// Hex part of a `sha256:<hex>` digest, or null when the digest is another algorithm.
  String? get digestSha256 {
    final value = digest;
    if (value == null) return null;
    final colon = value.indexOf(':');
    final algorithm = colon >= 0 ? value.substring(0, colon) : 'sha256';
    if (algorithm != 'sha256') return null;
    return (colon >= 0 ? value.substring(colon + 1) : value).toLowerCase();
  }
}

class _Manifest {
  final Map<String, dynamic> raw;
  final List<_Layer> layers;
  const _Manifest({required this.raw, required this.layers});

  _Layer? get modelLayer {
    for (final layer in layers) {
      if (layer.mediaType == kMediaTypeModel) return layer;
    }
    // Be forgiving with mirrors that use a different model media type.
    for (final layer in layers) {
      if (layer.digest != null && layer.mediaType.contains('image.model')) return layer;
    }
    return null;
  }
}

class _CachedMetadata {
  final int size;
  final GgufMetadata metadata;
  const _CachedMetadata({required this.size, required this.metadata});
}

class _PullJob {
  _PullJob(this.ref) : current = DownloadProgress(ref, DownloadState.queued);

  final ModelRef ref;
  final Set<StreamController<DownloadProgress>> listeners = {};
  final Completer<void> finished = Completer<void>();
  // One client per pull so cancel() can abort that job's request(s) without affecting others.
  final http.Client client = http.Client();
  DownloadProgress current;
  DateTime? lastEmit;
  bool cancelled = false;
  bool closed = false;
  void Function()? abort;
}

class _PullFailure implements Exception {
  final String message;
  const _PullFailure(this.message);
  @override
  String toString() => message;
}

class _Cancelled implements Exception {
  const _Cancelled();
}

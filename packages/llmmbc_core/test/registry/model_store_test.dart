import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'gguf_fixture.dart';
import 'mock_registry.dart';

const _modelMedia = 'application/vnd.ollama.image.model';
const _templateMedia = 'application/vnd.ollama.image.template';
const _configMedia = 'application/vnd.docker.container.image.v1+json';

String _hex(Uint8List bytes) => sha256.convert(bytes).toString();

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  late Directory tempDir;
  late MockRegistry registry;
  late FileModelStore store;

  String blobPath(String hex) => p.join(store.modelsDir, 'blobs', 'sha256-$hex');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('llmmbc_store_');
    registry = MockRegistry();
    await registry.start();
    store = FileModelStore(tempDir.path, registry: registry.baseUrl);
  });

  tearDown(() async {
    await registry.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Registers `library/qwen3:0.6b` with a valid GGUF model layer and returns the bytes.
  Uint8List addQwen({String name = 'qwen3', String tag = '0.6b'}) {
    final gguf = denseFixture().build();
    registry.addModel('library', name, tag, {
      _configMedia: _bytes('{"architecture":"amd64","os":"linux"}'),
      _modelMedia: gguf,
      _templateMedia: _bytes('{{ .Prompt }}'),
    });
    return gguf;
  }

  test('modelsDir lives under <dataDir>/models', () {
    expect(store.modelsDir, p.join(tempDir.path, 'models'));
  });

  test('catalog is curated, MoE first, with unique refs', () {
    final catalog = store.catalog();
    expect(catalog, hasLength(14));
    expect(catalog.take(7).every((entry) => entry.isMoe), isTrue,
        reason: 'MoE entries must come first');
    expect(catalog.skip(7).any((entry) => entry.isMoe), isFalse);

    final refs = catalog.map((entry) => entry.ref.toString()).toList();
    expect(refs.toSet(), hasLength(refs.length));
    expect(
        refs,
        containsAll([
          'qwen3:30b-a3b',
          'granite3.1-moe:1b',
          'granite3.1-moe:3b',
          'gpt-oss:20b',
          'deepseek-v2:16b',
          'mixtral:8x7b',
          'qwen3-coder:30b',
          'qwen3:0.6b',
          'qwen3:1.7b',
          'qwen3:4b',
          'llama3.2:1b',
          'llama3.2:3b',
          'gemma3:1b',
          'phi4-mini:latest',
        ]));
    for (final entry in catalog) {
      expect(entry.approxSizeBytes, greaterThan(0));
      expect(entry.title, isNotEmpty);
      expect(entry.description, isNotEmpty);
    }
  });

  test('pulls a model, verifies blobs and reports GGUF metadata', () async {
    final gguf = addQwen();
    final ref = ModelRef.parse('qwen3:0.6b');

    final progress = await store.pull(ref).toList();
    final states = progress.map((event) => event.state).toList();
    expect(states.first, DownloadState.resolving);
    expect(states, contains(DownloadState.downloading));
    expect(states, contains(DownloadState.verifying));
    expect(states.last, DownloadState.done);
    expect(progress.last.receivedBytes, progress.last.totalBytes);
    expect(progress.last.receivedBytes,
        gguf.length + _bytes('{"architecture":"amd64","os":"linux"}').length + _bytes('{{ .Prompt }}').length);

    final manifestFile = File(p.join(
        store.modelsDir, 'manifests', 'library', 'qwen3', '0.6b.json'));
    expect(await manifestFile.exists(), isTrue);
    expect(await File(blobPath(_hex(gguf))).exists(), isTrue);

    final models = await store.list();
    expect(models, hasLength(1));
    final model = models.single;
    expect(model.ref, ref);
    expect(model.ggufPath, blobPath(_hex(gguf)));
    expect(model.sizeBytes, progress.last.totalBytes);
    expect(model.metadata, isNotNull);
    expect(model.metadata!.architecture, 'qwen3');
    expect(model.metadata!.blockCount, 28);
    expect(model.metadata!.contextLength, 40960);
    expect(model.metadata!.embeddingLength, 1024);

    final found = await store.find(ref);
    expect(found?.ref, ref);
    expect(await store.find(const ModelRef('other')), isNull);

    // Metadata is cached in <models>/meta-cache.json.
    final cache = jsonDecode(
        await File(p.join(store.modelsDir, 'meta-cache.json')).readAsString()) as Map<String, dynamic>;
    final entries = cache['entries'] as Map<String, dynamic>;
    expect(entries, isNotEmpty);
    expect(
        ((entries.values.first as Map<String, dynamic>)['metadata'] as Map<String, dynamic>)['architecture'],
        'qwen3');
  });

  test('remoteSize sums manifest layer sizes without downloading', () async {
    final gguf = addQwen();
    final expected = gguf.length +
        _bytes('{"architecture":"amd64","os":"linux"}').length +
        _bytes('{{ .Prompt }}').length;
    expect(await store.remoteSize(ModelRef.parse('qwen3:0.6b')), expected);
    expect(registry.blobRequests, 0);
    expect(await store.list(), isEmpty);
  });

  test('pulling a complete model emits done immediately', () async {
    final ref = ModelRef.parse('qwen3:0.6b');
    addQwen();
    await store.pull(ref).drain<void>();
    final requestsAfterFirstPull = registry.blobRequests;

    final second = await store.pull(ref).toList();
    expect(second, hasLength(1));
    expect(second.single.state, DownloadState.done);
    expect(second.single.receivedBytes, second.single.totalBytes);
    expect(registry.blobRequests, requestsAfterFirstPull);
  });

  test('resumes a partial download with an HTTP Range request', () async {
    final gguf = addQwen();
    final ref = ModelRef.parse('qwen3:0.6b');
    final hex = _hex(gguf);
    final partial = File('${blobPath(hex)}.partial');
    await partial.parent.create(recursive: true);
    final half = gguf.length ~/ 2;
    await partial.writeAsBytes(gguf.sublist(0, half), flush: true);

    final states = await store.pull(ref).map((event) => event.state).toList();
    expect(states.last, DownloadState.done);
    expect(registry.rangeHeaders.whereType<String>(), contains('bytes=$half-'));
    expect(await partial.exists(), isFalse);
    expect(await File(blobPath(hex)).readAsBytes(), gguf);
    expect((await store.list()).single.metadata!.blockCount, 28);
  });

  test('recovers from a stale full-size partial that the server rejects', () async {
    final gguf = addQwen();
    final ref = ModelRef.parse('qwen3:0.6b');
    final hex = _hex(gguf);
    final partial = File('${blobPath(hex)}.partial');
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(gguf, flush: true);

    final states = await store.pull(ref).map((event) => event.state).toList();
    expect(states.last, DownloadState.done);
    expect(await partial.exists(), isFalse);
    expect(await File(blobPath(hex)).readAsBytes(), gguf);
  });

  test('rejects a blob whose sha256 does not match the manifest', () async {
    addQwen();
    registry.corruptBlobs = true;
    final ref = ModelRef.parse('qwen3:0.6b');

    final progress = await store.pull(ref).toList();
    expect(progress.last.state, DownloadState.failed);
    expect(progress.last.error, contains('sha256'));
    expect(await store.list(), isEmpty);

    final gguf = denseFixture().build();
    expect(await File(blobPath(_hex(gguf))).exists(), isFalse);
    expect(await File('${blobPath(_hex(gguf))}.partial').exists(), isFalse,
        reason: 'corrupt partial data must be discarded');
  });

  test('cancel stops the download, keeps the partial and resumes later', () async {
    final gguf = addQwen();
    final ref = ModelRef.parse('qwen3:0.6b');
    final hex = _hex(gguf);
    registry.chunkDelay = const Duration(milliseconds: 40);
    registry.chunkSize = 1024;

    final states = <DownloadState>[];
    var cancelRequested = false;
    await for (final progress in store.pull(ref)) {
      states.add(progress.state);
      if (!cancelRequested &&
          progress.state == DownloadState.downloading &&
          progress.receivedBytes > 0) {
        cancelRequested = true;
        unawaited(store.cancel(ref));
      }
    }
    expect(states.last, DownloadState.cancelled);

    final partial = File('${blobPath(hex)}.partial');
    expect(await partial.exists(), isTrue);
    final partialLength = await partial.length();
    expect(partialLength, greaterThan(0));
    expect(partialLength, lessThan(gguf.length));

    registry.chunkDelay = Duration.zero;
    final resumed = await store.pull(ref).map((event) => event.state).toList();
    expect(resumed.last, DownloadState.done);
    expect(await partial.exists(), isFalse);
    expect(await File(blobPath(hex)).readAsBytes(), gguf);
  });

  test('concurrent pulls of the same ref share a single download', () async {
    final gguf = addQwen();
    registry.chunkDelay = const Duration(milliseconds: 5);
    registry.chunkSize = 1024;
    final ref = ModelRef.parse('qwen3:0.6b');

    final first = store.pull(ref).map((event) => event.state).toList();
    final second = store.pull(ref).map((event) => event.state).toList();
    final results = await Future.wait([first, second]);

    expect(results[0].last, DownloadState.done);
    expect(results[1].last, DownloadState.done);
    expect(registry.manifestRequests, 1);
    expect(registry.blobRequestCounts[_hex(gguf)], 1);
  });

  test('throttles progress events to at most ten per second', () async {
    final gguf = denseFixture().build();
    registry.addModel('library', 'qwen3', '0.6b', {
      _configMedia: _bytes('{}'),
      _modelMedia: gguf,
      _templateMedia: _bytes('t'),
    });
    registry.chunkDelay = const Duration(milliseconds: 5);
    registry.chunkSize = 256;

    final events = await store.pull(ModelRef.parse('qwen3:0.6b')).toList();
    final downloadingEvents =
        events.where((event) => event.state == DownloadState.downloading).length;
    final chunks = (gguf.length / 256).ceil();
    expect(chunks, greaterThan(15));
    expect(downloadingEvents, lessThanOrEqualTo(10),
        reason: 'expected throttling, got $downloadingEvents of $chunks chunks');
    expect(events.last.state, DownloadState.done);
  });

  test('delete removes the manifest and garbage-collects unreferenced blobs', () async {
    final shared = _bytes('{"config":"shared"}');
    final ggufA = denseFixture().build();
    final ggufB = (GgufFixture()
          ..kvString('general.architecture', 'llama')
          ..kvUint32('llama.block_count', 2)
          ..tensor('token_embd.weight', [16], 0, 64))
        .build();

    registry.addModel('library', 'a', '1b', {
      _configMedia: shared,
      _modelMedia: ggufA,
      _templateMedia: _bytes('a'),
    });
    registry.addModel('library', 'b', '1b', {
      _configMedia: shared,
      _modelMedia: ggufB,
      _templateMedia: _bytes('b'),
    });

    final refA = ModelRef.parse('a:1b');
    final refB = ModelRef.parse('b:1b');
    await store.pull(refA).drain<void>();
    await store.pull(refB).drain<void>();
    expect(await store.list(), hasLength(2));

    final orphanPartial = File(p.join(store.modelsDir, 'blobs', 'sha256-${'0' * 64}.partial'));
    await orphanPartial.parent.create(recursive: true);
    await orphanPartial.writeAsString('stale');

    final sharedBlob = File(blobPath(_hex(shared)));
    final blobA = File(blobPath(_hex(ggufA)));
    final blobB = File(blobPath(_hex(ggufB)));
    expect(await sharedBlob.exists(), isTrue);

    await store.delete(refA);
    expect(await File(p.join(store.modelsDir, 'manifests', 'library', 'a', '1b.json')).exists(),
        isFalse);
    expect(await blobA.exists(), isFalse);
    expect(await blobB.exists(), isTrue);
    expect(await sharedBlob.exists(), isTrue, reason: 'shared blob is still referenced');
    expect(await orphanPartial.exists(), isFalse, reason: 'unreferenced partial is garbage');
    expect((await store.list()).single.ref, refB);

    await store.delete(refB);
    expect(await blobB.exists(), isFalse);
    expect(await sharedBlob.exists(), isFalse);
    expect(await store.list(), isEmpty);
  });

  test('deleting a model that is not present is a no-op', () async {
    await store.delete(ModelRef.parse('missing:latest'));
    expect(await store.list(), isEmpty);
  });

  test('list only reports complete models', () async {
    final gguf = addQwen();
    final ref = ModelRef.parse('qwen3:0.6b');
    await store.pull(ref).drain<void>();
    expect(await store.list(), hasLength(1));

    await File(blobPath(_hex(gguf))).delete();
    expect(await store.list(), isEmpty);
    expect(await store.find(ref), isNull);
    expect(await store.remoteSize(ref), greaterThan(0));
  });

  test('a corrupt metadata cache is ignored and rebuilt', () async {
    addQwen();
    final ref = ModelRef.parse('qwen3:0.6b');
    await store.pull(ref).drain<void>();
    expect(await store.list(), hasLength(1));

    final cacheFile = File(p.join(store.modelsDir, 'meta-cache.json'));
    await cacheFile.writeAsString('{not json');
    // A fresh store instance must not trust the broken cache.
    final fresh = FileModelStore(tempDir.path, registry: registry.baseUrl);
    final models = await fresh.list();
    expect(models, hasLength(1));
    expect(models.single.metadata!.architecture, 'qwen3');
    expect(jsonDecode(await cacheFile.readAsString()), isA<Map<String, dynamic>>());
  });

  test('a missing manifest fails the pull with the HTTP status', () async {
    final progress = await store.pull(ModelRef.parse('nope:latest')).toList();
    expect(progress.last.state, DownloadState.failed);
    expect(progress.last.error, contains('404'));
    expect(await store.list(), isEmpty);
  });

  test('cancelling an idle pull is a no-op', () async {
    await store.cancel(ModelRef.parse('qwen3:0.6b'));
  });
}

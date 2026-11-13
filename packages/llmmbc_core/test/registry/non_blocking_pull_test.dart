import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'mock_registry.dart';

const _modelMedia = 'application/vnd.ollama.image.model';

/// 200 MB is the size the "never freeze during a pull" regression must cover.
const int _blobBytes = 200 << 20;

/// Deterministic, cheap-to-generate blob content (sha256 is indifferent to repetition).
Uint8List _generatedBytes(int size) {
  final unit = Uint8List(64 * 1024);
  var state = 0x9E3779B9;
  for (var i = 0; i < unit.length; i++) {
    state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
    unit[i] = (state >> 24) & 0xFF;
  }
  final out = Uint8List(size);
  for (var offset = 0; offset < size; offset += unit.length) {
    out.setRange(offset, min(offset + unit.length, size), unit);
  }
  return out;
}

/// Samples event-loop latency of the isolate that drives the pull, the way a Flutter UI
/// isolate would notice a frozen frame.
class _StallProbe {
  _StallProbe() {
    _last = DateTime.now();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final now = DateTime.now();
      gapsMs.add(now.difference(_last).inMilliseconds);
      _last = now;
    });
  }

  final List<int> gapsMs = [];
  late final Timer _timer;
  late DateTime _last;

  void stop() => _timer.cancel();

  int get maxGapMs => gapsMs.isEmpty ? 0 : gapsMs.reduce(max);
}

int _maxGap(List<Duration> times) {
  var maxGapMs = 0;
  for (var i = 1; i < times.length; i++) {
    maxGapMs = max(maxGapMs, (times[i] - times[i - 1]).inMilliseconds);
  }
  return maxGapMs;
}

void main() {
  late Directory tempDir;
  late MockRegistry registry;
  late FileModelStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('llmmbc_nonblocking_');
    registry = MockRegistry();
    await registry.start();
    store = FileModelStore(tempDir.path, registry: registry.baseUrl);
  });

  tearDown(() async {
    await registry.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  String blobPath(String hex) => p.join(store.modelsDir, 'blobs', 'sha256-$hex');

  test('a 200 MB pull never stalls the calling isolate, including verify/finish', () async {
    final blob = _generatedBytes(_blobBytes);
    final hex = registry.addModel('library', 'big', '1b', {_modelMedia: blob});
    // Pace the mock a little so the probe observes a real transfer (and a real window of
    // timer ticks) rather than an instantaneous loopback copy.
    registry.chunkSize = 64 * 1024;
    registry.chunkDelay = const Duration(milliseconds: 1);

    final ref = ModelRef.parse('big:1b');
    final events = <DownloadProgress>[];
    final timeline = <(Duration, DownloadState)>[];
    final elapsed = Stopwatch()..start();
    final probe = _StallProbe();
    try {
      await for (final progress in store.pull(ref)) {
        events.add(progress);
        timeline.add((elapsed.elapsed, progress.state));
      }
    } finally {
      probe.stop();
      elapsed.stop();
    }
    print('200 MB pull: ${elapsed.elapsedMilliseconds}ms, '
        'max event-loop gap ${probe.maxGapMs}ms over ${probe.gapsMs.length} ticks, '
        'max progress gap ${_maxGap(timeline.map((entry) => entry.$1).toList())}ms');

    expect(events.last.state, DownloadState.done);
    expect(events.last.percent, 100);
    expect(events.map((event) => event.state), contains(DownloadState.downloading));
    expect(events.map((event) => event.state), contains(DownloadState.verifying));

    final downloading =
        events.where((event) => event.state == DownloadState.downloading).toList();
    expect(downloading.any((event) => event.bytesPerSecond > 0), isTrue,
        reason: 'progress must report a transfer rate');
    expect(downloading.any((event) => event.eta != null), isTrue,
        reason: 'progress must report an ETA once the rate is known');

    expect(probe.gapsMs.length, greaterThan(100),
        reason: 'the probe must have run for the whole pull');
    expect(probe.maxGapMs, lessThan(250),
        reason: 'event loop stalled for ${probe.maxGapMs}ms during a 200 MB pull');

    // The strongest signal that nothing full-file happens on the calling isolate: progress
    // keeps flowing. The old implementation silently re-read and re-hashed the blob at 100%
    // (~3.5 s of no events for 200 MB here); incremental hashing leaves at most the 100 ms
    // throttle between events.
    final maxEventGapMs = _maxGap(timeline.map((entry) => entry.$1).toList());
    expect(maxEventGapMs, lessThan(1000),
        reason: 'no progress for ${maxEventGapMs}ms during a 200 MB pull; '
            'the pull must not re-read the blob');

    final target = File(blobPath(hex));
    expect(await target.length(), _blobBytes);
    expect(await File('${blobPath(hex)}.partial').exists(), isFalse);

    // Requirement §5: list() must not do full-file work on the calling isolate either. The
    // blob is not a valid GGUF, so metadata inspection only reads a header and fails fast.
    final listProbe = _StallProbe();
    late final List<LocalModel> models;
    try {
      models = await store.list();
    } finally {
      listProbe.stop();
    }
    expect(models.single.sizeBytes, _blobBytes);
    expect(listProbe.maxGapMs, lessThan(250),
        reason: 'event loop stalled for ${listProbe.maxGapMs}ms during list()');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a resumed pull verifies a 200 MB partial off-isolate without stalls', () async {
    final blob = _generatedBytes(_blobBytes);
    final hex = registry.addModel('library', 'big', '1b', {_modelMedia: blob});
    const prefix = 190 << 20;
    final partial = File('${blobPath(hex)}.partial');
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(Uint8List.sublistView(blob, 0, prefix), flush: true);

    final ref = ModelRef.parse('big:1b');
    final events = <DownloadProgress>[];
    final timeline = <Duration>[];
    final elapsed = Stopwatch()..start();
    final probe = _StallProbe();
    try {
      await for (final progress in store.pull(ref)) {
        events.add(progress);
        timeline.add(elapsed.elapsed);
      }
    } finally {
      probe.stop();
      elapsed.stop();
    }
    print('resumed 190 MB/200 MB pull: '
        'max event-loop gap ${probe.maxGapMs}ms over ${probe.gapsMs.length} ticks, '
        'max progress gap ${_maxGap(timeline)}ms');

    expect(events.last.state, DownloadState.done);

    final verifying = events.where((event) => event.state == DownloadState.verifying).toList();
    expect(verifying, isNotEmpty, reason: 'resume must report verifying progress');
    expect(verifying.any((event) => event.totalBytes == prefix), isTrue,
        reason: 'verifying progress is reported against the hashed prefix size');
    expect(verifying.any((event) => event.receivedBytes > prefix ~/ 2), isTrue,
        reason: 'verifying progress must advance through the prefix');
    expect(verifying.any((event) => event.bytesPerSecond > 0), isTrue,
        reason: 'verifying must report its own hashing rate');
    expect(verifying.any((event) => event.eta != null), isTrue,
        reason: 'verifying must report its own ETA');

    expect(probe.gapsMs.length, greaterThan(100),
        reason: 'the probe must have run for the whole resumed pull');
    expect(probe.maxGapMs, lessThan(250),
        reason: 'event loop stalled for ${probe.maxGapMs}ms during a 200 MB resumed pull');

    // The resumed prefix must be hashed with progress flowing: re-hashing it on the calling
    // isolate would leave a silent gap of seconds.
    final maxEventGapMs = _maxGap(timeline);
    expect(maxEventGapMs, lessThan(1000),
        reason: 'no progress for ${maxEventGapMs}ms while resuming a 200 MB pull');

    expect(registry.rangeHeaders.whereType<String>(), contains('bytes=$prefix-'));
    expect(await partial.exists(), isFalse);
    final target = File(blobPath(hex));
    expect(await target.length(), _blobBytes);
    // The resumed blob must be byte-identical, i.e. prefix + new bytes hashed as one stream.
    final bytes = await target.readAsBytes();
    expect(bytes.length, _blobBytes);
    expect(bytes.sublist(0, 1024), blob.sublist(0, 1024));
    expect(bytes.sublist(_blobBytes - 1024), blob.sublist(_blobBytes - 1024));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a corrupt resumed prefix fails verification and is discarded', () async {
    final blob = _generatedBytes(8 << 20);
    const prefix = 4 << 20;
    final hex = registry.addModel('library', 'big', '1b', {_modelMedia: blob});
    final partial = File('${blobPath(hex)}.partial');
    await partial.parent.create(recursive: true);
    // A truncated prefix with wrong content: the resumed digest can only match the manifest
    // if every byte, hashed through the background worker, is the real one.
    final corrupt = blob.sublist(0, prefix);
    corrupt[0] ^= 0xFF;
    await partial.writeAsBytes(corrupt, flush: true);

    final events = await store.pull(ModelRef.parse('big:1b')).toList();
    expect(events.last.state, DownloadState.failed);
    expect(events.last.error, contains('sha256'));
    expect(await partial.exists(), isFalse, reason: 'corrupt data must never be promoted');
    expect(await File(blobPath(hex)).exists(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a resumed pull outpaces the hasher without unbounded queueing', () async {
    // 120 MB still to download arrives over loopback much faster than sha256 can hash it, so
    // the store must apply back-pressure to the body and still verify the whole blob.
    final blob = _generatedBytes(128 << 20);
    const prefix = 8 << 20;
    final hex = registry.addModel('library', 'big', '1b', {_modelMedia: blob});
    final partial = File('${blobPath(hex)}.partial');
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(blob.sublist(0, prefix), flush: true);

    final events = await store.pull(ModelRef.parse('big:1b')).toList();
    expect(events.last.state, DownloadState.done);
    expect(events.last.percent, 100);
    expect(await partial.exists(), isFalse);
    final bytes = await File(blobPath(hex)).readAsBytes();
    expect(bytes.length, blob.length);
    expect(bytes.sublist(0, 1024), blob.sublist(0, 1024));
    expect(bytes.sublist(blob.length - 1024), blob.sublist(blob.length - 1024));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a registry that ignores Range restarts the blob from zero', () async {
    final blob = _generatedBytes(4 << 20);
    const half = 2 << 20;
    final hex = registry.addModel('library', 'big', '1b', {_modelMedia: blob});
    registry.supportsRange = false;
    final partial = File('${blobPath(hex)}.partial');
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(blob.sublist(0, half), flush: true);

    final events = await store.pull(ModelRef.parse('big:1b')).toList();
    expect(events.last.state, DownloadState.done);
    // The prefix was hashed in the background and then thrown away when the 200 response
    // arrived; the blob is fetched from zero and verified incrementally.
    expect(registry.rangeHeaders.whereType<String>(), contains('bytes=$half-'));
    expect(await File(blobPath(hex)).readAsBytes(), blob);
    expect(await partial.exists(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('cancel during prefix verification stops promptly and keeps the partial', () async {
    final blob = _generatedBytes(200 << 20);
    final hex = registry.addModel('library', 'big', '1b', {_modelMedia: blob});
    const prefix = 190 << 20;
    final partial = File('${blobPath(hex)}.partial');
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(Uint8List.sublistView(blob, 0, prefix), flush: true);

    final ref = ModelRef.parse('big:1b');
    final states = <DownloadState>[];
    final stopwatch = Stopwatch();
    var cancelRequested = false;
    await for (final progress in store.pull(ref)) {
      states.add(progress.state);
      if (!cancelRequested && progress.state == DownloadState.verifying) {
        cancelRequested = true;
        stopwatch.start();
        await store.cancel(ref).timeout(const Duration(seconds: 3));
        stopwatch.stop();
      }
    }
    expect(cancelRequested, isTrue);
    expect(states.last, DownloadState.cancelled);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
    expect(await partial.exists(), isTrue, reason: 'cancelling keeps the partial for resume');
    expect(await partial.length(), prefix);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

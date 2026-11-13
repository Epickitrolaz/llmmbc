import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'large_blob_server.dart' as fixture;

/// Runs [large_pull_probe.dart] in its own process and returns its `RESULT` fields.
Future<Map<String, int>> _runProbe(String registry, String dataDir, String ref,
    {String mode = 'fresh'}) async {
  final result = await Process.run(Platform.resolvedExecutable, [
    File('test/registry/large_pull_probe.dart').absolute.path,
    registry,
    dataDir,
    ref,
    mode,
  ]);
  if (result.exitCode != 0) {
    fail('probe failed (${result.exitCode}): ${result.stderr}\n${result.stdout}');
  }
  final line = const LineSplitter()
      .convert(result.stdout as String)
      .firstWhere((line) => line.startsWith('RESULT '));
  return {
    for (final field in line.substring('RESULT '.length).split(' '))
      field.substring(0, field.indexOf('=')):
          int.parse(field.substring(field.indexOf('=') + 1)),
  };
}

void main() {
  late Process serverProcess;
  late String baseUrl;

  setUpAll(() async {
    // The registry runs in its own OS process: its 1 GiB body must not count against the
    // RSS of the pulling process.
    serverProcess = await Process.start(
      Platform.resolvedExecutable,
      [File('test/registry/large_blob_server.dart').absolute.path],
    );
    final lines = serverProcess.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
    final portLine = await lines
        .firstWhere((line) => line.startsWith('PORT='))
        .timeout(const Duration(seconds: 30));
    baseUrl = 'http://127.0.0.1:${portLine.substring('PORT='.length)}';
    unawaited(serverProcess.stderr.drain<void>());
  });

  tearDownAll(() async {
    serverProcess.kill();
    await serverProcess.exitCode.timeout(const Duration(seconds: 10), onTimeout: () => -1);
  });

  test('a 1 GiB loopback pull bounds RSS and calling-isolate work', () async {
    final dataDir = await Directory.systemTemp.createTemp('llmmbc_large_');
    try {
      final result = await _runProbe(baseUrl, dataDir.path, 'huge:1b');

      final baseline = result['baselineRss']!;
      final peak = result['peakRss']!;
      final growth = peak - baseline;
      final steps = result['steps']!;
      final p50 = result['p50us']!;
      final p99 = result['p99us']!;
      final maxStep = result['maxus']!;
      // ignore: avoid_print
      print('1 GiB pull: $steps chunk steps, p50 ${p50 / 1000} ms, p99 ${p99 / 1000} ms, '
          'max ${maxStep / 1000} ms, RSS ${baseline >> 20} -> ${peak >> 20} MiB '
          '(+${growth >> 20} MiB)');

      expect(result['bytes'], fixture.blobBytes);
      expect(steps, greaterThan(20), reason: 'the observer must see real chunk steps');

      // Issue #63: no sha256 (or other multi-MB work) on the calling isolate. Hashing a
      // body chunk there costs ~40 ms per MiB, so it would dominate the typical step as
      // well as the tail; the store only enqueues a write and forwards the bytes.
      expect(p50, lessThan(10 * 1000),
          reason: 'typical calling-isolate step was ${p50 / 1000}ms');
      expect(p99, lessThan(50 * 1000),
          reason: 'p99 calling-isolate step was ${p99 / 1000}ms');
      expect(maxStep, lessThan(50 * 1000),
          reason: 'largest synchronous caller step was ${maxStep / 1000}ms; body chunks '
              'must be written and forwarded only, hashing runs off-isolate');

      // Issue #64: the body is pulled slice by slice with awaited file writes and the hash
      // isolate's mailbox is kept small, so a 1 GiB pull must not be buffered in memory.
      if (Platform.isLinux) {
        expect(growth, lessThan(150 << 20),
            reason: 'RSS grew by ${growth >> 20} MiB during a 1 GiB pull; '
                'in-flight bytes must stay bounded');
      }
    } finally {
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('the same large pull supports cancel and resume', () async {
    final dataDir = await Directory.systemTemp.createTemp('llmmbc_large_resume_');
    try {
      // The probe cancels after 8 MiB and then resumes; its numbers cover the resumed pull.
      final result = await _runProbe(baseUrl, dataDir.path, 'huge:1b', mode: 'resume');
      final growth = result['peakRss']! - result['baselineRss']!;
      // ignore: avoid_print
      print('resumed 1 GiB pull: max step ${result['maxus']! / 1000} ms, '
          'RSS +${growth >> 20} MiB, partial ${result['partialBefore']} -> '
          '${result['partialAfter']}');

      expect(result['bytes'], fixture.blobBytes);
      expect(result['partialBefore'], greaterThan(0),
          reason: 'cancelling must keep the partial for the resume');
      expect(result['partialAfter'], 0, reason: 'the resumed blob is promoted');
      expect(result['maxus'], lessThan(50 * 1000),
          reason: 'resumed pull did ${result['maxus']! / 1000}ms of synchronous work');
      if (Platform.isLinux) {
        expect(growth, lessThan(150 << 20),
            reason: 'RSS grew ${growth >> 20} MiB during the resumed pull');
      }
    } finally {
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

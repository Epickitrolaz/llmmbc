import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:llmmbc_core/src/registry/transfer_stats.dart';
import 'package:test/test.dart';

/// Deterministic clock so the rate/ETA math can be tested without real time.
class _FakeClock {
  DateTime now = DateTime.utc(2026, 1, 1, 12);

  DateTime call() => now;

  void advance(Duration delta) => now = now.add(delta);
}

void main() {
  const mib = 1 << 20;

  group('TransferStats', () {
    late _FakeClock clock;
    late TransferStats stats;

    setUp(() {
      clock = _FakeClock();
      stats = TransferStats(clock: clock.call);
    });

    test('rate is unknown before two samples span time', () {
      expect(stats.bytesPerSecond, 0);
      expect(stats.etaFor(100 * mib), isNull);

      stats.record(0);
      expect(stats.bytesPerSecond, 0);
      expect(stats.etaFor(100 * mib), isNull);

      // Same instant: still unknown, never a division by zero or infinity.
      stats.record(5 * mib);
      expect(stats.bytesPerSecond, 0);
      expect(stats.etaFor(100 * mib), isNull);
    });

    test('rate and eta follow the transferred bytes', () {
      clock.advance(const Duration(milliseconds: 100));
      stats.record(1 * mib);
      expect(stats.bytesPerSecond, closeTo(10 * mib, 1));
      final eta = stats.etaFor(10 * mib);
      expect(eta, isNotNull);
      expect(eta!.inMilliseconds, closeTo(1000, 5));

      clock.advance(const Duration(milliseconds: 900));
      stats.record(10 * mib);
      // 10 MiB over 1 s.
      expect(stats.bytesPerSecond, closeTo(10 * mib, 1));
      expect(stats.etaFor(5 * mib)!.inMilliseconds, closeTo(500, 5));
      expect(stats.etaFor(0), Duration.zero);
      expect(stats.etaFor(-1), Duration.zero);
    });

    test('smooths over a five second window', () {
      for (var tick = 0; tick < 12; tick++) {
        clock.advance(const Duration(milliseconds: 500));
        stats.record((tick + 1) * mib); // 2 MiB/s
      }
      expect(stats.bytesPerSecond, closeTo(2 * mib, 2));

      // Transfer stops: after a full window of idling the rate decays to 0 and ETA is
      // unknown again instead of reporting stale speed forever.
      for (var tick = 0; tick < 12; tick++) {
        clock.advance(const Duration(milliseconds: 500));
        stats.record(12 * mib);
      }
      expect(stats.bytesPerSecond, 0);
      expect(stats.etaFor(100 * mib), isNull);
    });

    test('reset rebases so untransferred bytes do not count as speed', () {
      clock.advance(const Duration(seconds: 1));
      stats.record(8 * mib);
      expect(stats.bytesPerSecond, greaterThan(0));

      stats.reset(500 * mib); // e.g. a blob that was already on disk
      expect(stats.bytesPerSecond, 0);
      expect(stats.etaFor(10 * mib), isNull);

      clock.advance(const Duration(milliseconds: 500));
      stats.record(500 * mib + 5 * mib);
      expect(stats.bytesPerSecond, closeTo(10 * mib, 1));
    });
  });

  group('DownloadProgress percent', () {
    const ref = ModelRef('qwen3', tag: '0.6b');

    test('percent is fraction × 100 and clamps to 0..100', () {
      expect(const DownloadProgress(ref, DownloadState.downloading).percent, 0);
      expect(
          const DownloadProgress(ref, DownloadState.downloading, receivedBytes: 5, totalBytes: 20)
              .percent,
          25);
      expect(
          const DownloadProgress(ref, DownloadState.downloading,
                  receivedBytes: 200 * mib, totalBytes: 200 * mib)
              .percent,
          100);
      // A server that overshoots the advertised size must not report > 100%.
      expect(
          const DownloadProgress(ref, DownloadState.downloading,
                  receivedBytes: 210 * mib, totalBytes: 200 * mib)
              .percent,
          100);
      expect(
          const DownloadProgress(ref, DownloadState.downloading, receivedBytes: 0, totalBytes: 0)
              .percent,
          0);
    });
  });
}

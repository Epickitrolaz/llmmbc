import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:llmmbc_core/src/node/cli_memory.dart';
import 'package:llmmbc_core/src/node/cli_progress.dart';
import 'package:test/test.dart';

const int _mib = 1024 * 1024;
const int _gib = 1024 * 1024 * 1024;

DownloadProgress _progress(
  DownloadState state, {
  int received = 0,
  int total = 0,
  double bytesPerSecond = 0,
  Duration? eta,
  String? error,
}) =>
    DownloadProgress(
      ModelRef.parse('qwen3:0.6b'),
      state,
      receivedBytes: received,
      totalBytes: total,
      bytesPerSecond: bytesPerSecond,
      eta: eta,
      error: error,
    );

void main() {
  group('size/rate/eta formatting', () {
    test('binary units keep one decimal', () {
      expect(formatByteSize(0), '0 B');
      expect(formatByteSize(1023), '1023 B');
      expect(formatByteSize(1024), '1.0 KiB');
      expect(formatByteSize((1.5 * _gib).round()), '1.5 GiB');
    });

    test('unknown rate and eta render placeholders', () {
      expect(formatRate(0), '--');
      expect(formatRate(double.nan), '--');
      expect(formatRate(18.2 * _mib), '18.2 MiB/s');
      expect(formatEta(null), '--:--');
      expect(formatEta(const Duration(seconds: 16)), '0:16');
      expect(formatEta(const Duration(minutes: 1, seconds: 5)), '1:05');
      expect(formatEta(const Duration(hours: 1, minutes: 2, seconds: 3)),
          '1:02:03');
    });
  });

  group('pull progress line', () {
    test('downloading matches the documented single-line shape', () {
      final line = formatPullProgress(_progress(
        DownloadState.downloading,
        received: (211.0 * _mib).round(),
        total: (498.4 * _mib).round(),
        bytesPerSecond: 18.2 * _mib,
        eta: const Duration(seconds: 16),
      ));
      expect(line,
          'qwen3:0.6b  downloading  42.3%  211.0 MiB/498.4 MiB  18.2 MiB/s  ETA 0:16');
    });

    test('unknown speed and eta are explicit', () {
      final line = formatPullProgress(_progress(
        DownloadState.downloading,
        received: _mib,
        total: 2 * _mib,
      ));
      expect(line,
          'qwen3:0.6b  downloading  50.0%  1.0 MiB/2.0 MiB  --  ETA --:--');
    });

    test('verifying, failed and resolving lines', () {
      expect(
          formatPullProgress(_progress(DownloadState.verifying,
              received: _mib, total: 4 * _mib)),
          'qwen3:0.6b  verifying  25.0%  1.0 MiB/4.0 MiB');
      expect(
          formatPullProgress(
              _progress(DownloadState.failed, error: 'connection reset')),
          'qwen3:0.6b  failed  connection reset');
      expect(formatPullProgress(_progress(DownloadState.resolving)),
          'qwen3:0.6b  resolving');
    });

    test('summary reports size, elapsed and average speed', () {
      final line = formatPullSummary(
        ref: ModelRef.parse('qwen3:0.6b'),
        totalBytes: (498.4 * _mib).round(),
        elapsed: const Duration(seconds: 27),
        averageBytesPerSecond: 18.4 * _mib,
      );
      expect(line, 'qwen3:0.6b  done  498.4 MiB in 0:27 (18.4 MiB/s)');
    });
  });

  group('progress printer', () {
    test('TTY mode rewrites one line with carriage returns', () {
      final writes = <String>[];
      final printer = PullProgressPrinter(
        write: writes.add,
        isTty: true,
      );
      printer.update(_progress(DownloadState.resolving));
      printer.update(_progress(DownloadState.downloading,
          received: _mib, total: 2 * _mib));
      printer.finish('qwen3:0.6b  done');
      expect(writes, hasLength(3));
      expect(writes[0], startsWith('\rqwen3:0.6b  resolving'));
      expect(writes[0], endsWith('\x1b[K'));
      expect(writes[1], startsWith('\rqwen3:0.6b  downloading'));
      expect(writes[2], '\rqwen3:0.6b  done\x1b[K\n');
    });

    test('non-TTY mode throttles to one plain line per 2 s', () {
      var now = DateTime(2026, 1, 1);
      final writes = <String>[];
      final printer = PullProgressPrinter(
        write: writes.add,
        isTty: false,
        now: () => now,
      );
      printer.update(_progress(DownloadState.downloading,
          received: _mib, total: 4 * _mib));
      expect(writes, hasLength(1));
      expect(writes.single, endsWith('\n'));
      expect(writes.single, isNot(contains('\r')));

      now = now.add(const Duration(seconds: 1));
      printer.update(_progress(DownloadState.downloading,
          received: 2 * _mib, total: 4 * _mib));
      expect(writes, hasLength(1), reason: 'throttled inside 2 s');

      now = now.add(const Duration(seconds: 2));
      printer.update(_progress(DownloadState.downloading,
          received: 3 * _mib, total: 4 * _mib));
      expect(writes, hasLength(2));

      // A phase change is always printed, even inside the throttle window.
      now = now.add(const Duration(milliseconds: 100));
      printer.update(_progress(DownloadState.verifying,
          received: 4 * _mib, total: 4 * _mib));
      expect(writes, hasLength(3));

      printer.finish('qwen3:0.6b  done  4.0 MiB');
      expect(writes.last, 'qwen3:0.6b  done  4.0 MiB\n');
    });

    test('terminal states are left to the caller', () {
      final writes = <String>[];
      final printer = PullProgressPrinter(write: writes.add, isTty: false);
      printer
          .update(_progress(DownloadState.done, received: _mib, total: _mib));
      printer.update(_progress(DownloadState.failed, error: 'x'));
      expect(writes, isEmpty);
    });
  });

  group('memory option parsing', () {
    test('no flag or environment means no override', () {
      final overrides = parseMemoryOverrides();
      expect(overrides.isEmpty, isTrue);
      expect(overrides.basis, isNull);
      expect(overrides.share, isNull);
    });

    test('reads the environment', () {
      final overrides = parseMemoryOverrides(environment: {
        'LLMMBC_MEMORY_BASIS': 'available',
        'LLMMBC_MEMORY_SHARE': '0.5',
      });
      expect(overrides.basis, MemoryBasis.available);
      expect(overrides.share, 0.5);
    });

    test('flags win over the environment', () {
      final overrides = parseMemoryOverrides(
        basisFlag: 'total',
        shareFlag: '0.25',
        environment: {
          'LLMMBC_MEMORY_BASIS': 'available',
          'LLMMBC_MEMORY_SHARE': '0.5',
        },
      );
      expect(overrides.basis, MemoryBasis.total);
      expect(overrides.share, 0.25);
    });

    test('one field can be overridden without the other', () {
      final overrides =
          parseMemoryOverrides(basisFlag: 'available', environment: const {});
      expect(overrides.basis, MemoryBasis.available);
      expect(overrides.share, isNull);
      expect(overrides.isEmpty, isFalse);
    });

    test('basis is case-insensitive', () {
      expect(parseMemoryBasis('AVAILABLE'), MemoryBasis.available);
      expect(parseMemoryBasis(' total '), MemoryBasis.total);
    });

    test('rejects unknown bases and out-of-range shares', () {
      expect(() => parseMemoryBasis('free'), throwsFormatException);
      for (final share in ['0', '-0.1', '1.1', 'abc', '']) {
        expect(() => parseMemoryShare(share), throwsFormatException,
            reason: 'share "$share"');
      }
      expect(parseMemoryShare('1'), 1.0);
      expect(parseMemoryShare('0.7'), 0.7);
    });

    test('hw reads only the environment share', () {
      expect(memoryShareFromEnvironment(const {}), kDefaultMemoryShare);
      expect(memoryShareFromEnvironment(const {'LLMMBC_MEMORY_SHARE': '0.4'}),
          0.4);
      expect(
          () => memoryShareFromEnvironment(const {'LLMMBC_MEMORY_SHARE': 'x'}),
          throwsFormatException);
    });
  });
}

// core-net: pure pull-progress formatting + the CLI's single-line renderer (§5, §8).
import '../models.dart';

const List<String> _kUnits = ['KiB', 'MiB', 'GiB', 'TiB', 'PiB'];

/// Human-readable binary size, e.g. `211.0 MiB`. Values below 1 KiB keep bytes.
String formatByteSize(int bytes) {
  final value = bytes < 0 ? -bytes : bytes;
  if (value < 1024) return '$bytes B';
  var scaled = value.toDouble();
  var unit = -1;
  while (scaled >= 1024 && unit < _kUnits.length - 1) {
    scaled /= 1024;
    unit++;
  }
  final text = '${scaled.toStringAsFixed(1)} ${_kUnits[unit]}';
  return bytes < 0 ? '-$text' : text;
}

/// Transfer rate, e.g. `18.2 MiB/s`; `--` when the rate is unknown.
String formatRate(double bytesPerSecond) {
  if (bytesPerSecond.isNaN ||
      bytesPerSecond.isInfinite ||
      bytesPerSecond <= 0) {
    return '--';
  }
  return '${formatByteSize(bytesPerSecond.round())}/s';
}

/// `m:ss` (or `h:mm:ss` for long waits); `--:--` when unknown.
String formatEta(Duration? eta) {
  if (eta == null) return '--:--';
  final seconds = eta.inSeconds < 0 ? 0 : eta.inSeconds;
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  final hours = minutes ~/ 60;
  if (hours > 0) {
    return '$hours:${(minutes % 60).toString().padLeft(2, '0')}:'
        '${rest.toString().padLeft(2, '0')}';
  }
  return '$minutes:${rest.toString().padLeft(2, '0')}';
}

/// One progress line, e.g.
/// `qwen3:0.6b  downloading  42.3%  211.0/498.4 MiB  18.2 MiB/s  ETA 0:16`.
String formatPullProgress(DownloadProgress progress) {
  final ref = progress.ref.toString();
  switch (progress.state) {
    case DownloadState.queued:
      return '$ref  queued';
    case DownloadState.resolving:
      return '$ref  resolving';
    case DownloadState.downloading:
      return '$ref  downloading  ${progress.percent.toStringAsFixed(1)}%  '
          '${formatByteSize(progress.receivedBytes)}/'
          '${formatByteSize(progress.totalBytes)}  '
          '${formatRate(progress.bytesPerSecond)}  ETA ${formatEta(progress.eta)}';
    case DownloadState.verifying:
      return '$ref  verifying  ${progress.percent.toStringAsFixed(1)}%  '
          '${formatByteSize(progress.receivedBytes)}/'
          '${formatByteSize(progress.totalBytes)}';
    case DownloadState.done:
      return '$ref  done';
    case DownloadState.failed:
      return '$ref  failed  ${progress.error ?? 'download failed'}';
    case DownloadState.cancelled:
      return '$ref  cancelled';
  }
}

/// Final summary line: total size, elapsed time and average transfer rate.
String formatPullSummary({
  required ModelRef ref,
  required int totalBytes,
  required Duration elapsed,
  double? averageBytesPerSecond,
}) {
  final millis = elapsed.inMilliseconds;
  final average =
      averageBytesPerSecond ?? (millis <= 0 ? 0.0 : totalBytes * 1000 / millis);
  return '$ref  done  ${formatByteSize(totalBytes)} in ${formatEta(elapsed)} '
      '(${formatRate(average)})';
}

/// Renders pull progress to a single line on a TTY (`\r`) and as throttled plain
/// lines otherwise (at most one every [minInterval]).
class PullProgressPrinter {
  final void Function(String text) _write;
  final bool isTty;
  final Duration minInterval;
  final DateTime Function() _now;

  DateTime? _lastPrintedAt;
  DownloadState? _lastState;
  bool _closed = false;

  PullProgressPrinter({
    required void Function(String text) write,
    required this.isTty,
    DateTime Function()? now,
    this.minInterval = const Duration(seconds: 2),
  })  : _write = write,
        _now = now ?? DateTime.now;

  /// Prints a line for a non-terminal state. Terminal states are rendered with
  /// [finish] so the caller can attach the summary or the error.
  void update(DownloadProgress progress) {
    if (_closed) return;
    switch (progress.state) {
      case DownloadState.done:
      case DownloadState.failed:
      case DownloadState.cancelled:
        return;
      case DownloadState.queued:
      case DownloadState.resolving:
      case DownloadState.downloading:
      case DownloadState.verifying:
        break;
    }
    final now = _now();
    final stateChanged = _lastState != progress.state;
    final last = _lastPrintedAt;
    // Always show the first event and every phase change; throttle the noisy
    // byte-level updates when the output is not a terminal.
    if (!isTty &&
        !stateChanged &&
        last != null &&
        now.difference(last) < minInterval) {
      return;
    }
    _lastPrintedAt = now;
    _lastState = progress.state;
    final line = formatPullProgress(progress);
    _write(isTty ? '\r$line\x1b[K' : '$line\n');
  }

  /// Prints the closing line (summary, failure or cancellation) and newline.
  void finish(String line) {
    if (_closed) return;
    _closed = true;
    _write(isTty ? '\r$line\x1b[K\n' : '$line\n');
  }
}

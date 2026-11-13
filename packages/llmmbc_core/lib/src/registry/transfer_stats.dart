// Transfer-rate / ETA estimation for model pulls. Owned by core-data (§5).
import 'dart:collection';

/// Sliding-window transfer rate and ETA driven by cumulative byte counts.
///
/// [TransferStats] is fed the total number of bytes transferred so far (across all layers of
/// a pull) and reports the rate smoothed over [window] (~5 s), which is what
/// `DownloadProgress.bytesPerSecond` and `.eta` expose. The clock is injectable so the
/// arithmetic can be tested without waiting for real time.
///
/// The rate is 0 until there are at least two samples spanning a positive interval, so the
/// very first progress event after a pull starts reports "unknown" rather than a bogus
/// speed. [etaFor] returns null while the rate is unknown.
class TransferStats {
  TransferStats({
    this.window = const Duration(seconds: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    reset();
  }

  /// Smoothing window. Samples older than this are dropped, except that the most recent
  /// sample at or before the window start is kept as the rate baseline.
  final Duration window;

  final DateTime Function() _clock;
  final Queue<_Sample> _samples = Queue<_Sample>();

  /// Forget all history and start counting from [bytes] (default 0).
  ///
  /// Used when a pull starts, and to rebase after bytes that were *not* transferred (a blob
  /// that was already complete) so they do not inflate the measured speed.
  void reset([int bytes = 0]) {
    _samples
      ..clear()
      ..add(_Sample(_clock(), bytes));
  }

  /// Record that [cumulativeBytes] have been transferred in total so far.
  void record(int cumulativeBytes) {
    final now = _clock();
    _samples.add(_Sample(now, cumulativeBytes));
    final cutoff = now.subtract(window);
    while (_samples.length >= 2 && !_samples.elementAt(1).time.isAfter(cutoff)) {
      _samples.removeFirst();
    }
  }

  /// Current smoothed transfer rate in bytes per second; 0 while unknown.
  double get bytesPerSecond {
    if (_samples.length < 2) return 0;
    final first = _samples.first;
    final last = _samples.last;
    final micros = last.time.difference(first.time).inMicroseconds;
    if (micros <= 0) return 0;
    final bytes = last.bytes - first.bytes;
    if (bytes <= 0) return 0;
    return bytes * 1000000 / micros;
  }

  /// Estimated time to move [remainingBytes] at the current rate; null while unknown.
  Duration? etaFor(int remainingBytes) {
    if (remainingBytes <= 0) return Duration.zero;
    final rate = bytesPerSecond;
    if (rate <= 0 || !rate.isFinite) return null;
    return Duration(microseconds: (remainingBytes * 1000000 / rate).round());
  }
}

class _Sample {
  const _Sample(this.time, this.bytes);

  final DateTime time;
  final int bytes;
}

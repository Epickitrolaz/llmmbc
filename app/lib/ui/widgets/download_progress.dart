/// Download progress UI: a per-row throttle and the stats tile shared by the
/// catalog rows and name pulls.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:llmmbc_core/llmmbc_core.dart';

import '../../util/format.dart';

/// Coalesces [DownloadProgress] events into at most ten UI updates per second.
///
/// The screen keeps one of these per pulled model; each one owns a
/// [ValueNotifier] so only the widget that listens to it rebuilds while bytes
/// keep arriving. State changes (resolving → downloading → verifying → done)
/// are forwarded immediately so labels never lag behind, byte counters are
/// throttled to [interval].
class DownloadThrottle {
  DownloadThrottle(this.ref);

  final ModelRef ref;

  /// Latest progress, or null before the pull starts.
  final ValueNotifier<DownloadProgress?> progress = ValueNotifier<DownloadProgress?>(null);

  static const Duration interval = Duration(milliseconds: 100);

  DownloadProgress? _pending;
  DownloadProgress? _emitted;
  Timer? _timer;

  DownloadProgress? get value => progress.value;

  bool get isActive {
    final state = progress.value?.state;
    return state != null && !_isTerminal(state);
  }

  /// Replaces the shown state without coalescing (used when a pull starts).
  void reset(DownloadProgress next) {
    _pending = null;
    _timer?.cancel();
    _timer = null;
    _emitted = next;
    progress.value = next;
  }

  void push(DownloadProgress next) {
    final previous = _emitted;
    if (previous == null || previous.state != next.state || _isTerminal(next.state)) {
      _pending = null;
      _timer?.cancel();
      _timer = null;
      _emitted = next;
      progress.value = next;
      return;
    }
    _pending = next;
    _timer ??= Timer(interval, () {
      _timer = null;
      final pending = _pending;
      _pending = null;
      if (pending == null) return;
      _emitted = pending;
      progress.value = pending;
    });
  }

  void dispose() {
    _timer?.cancel();
    progress.dispose();
  }

  static bool _isTerminal(DownloadState state) =>
      state == DownloadState.done ||
      state == DownloadState.failed ||
      state == DownloadState.cancelled;
}

/// Label for a pull: `Resolving`, `Downloading`, `Verifying 42.3%`, `Done`…
String downloadStateLabel(DownloadProgress progress) {
  switch (progress.state) {
    case DownloadState.queued:
      return 'Queued';
    case DownloadState.resolving:
      return 'Resolving';
    case DownloadState.downloading:
      return 'Downloading';
    case DownloadState.verifying:
      return 'Verifying ${formatDownloadPercent(progress.fraction)}';
    case DownloadState.done:
      return 'Done';
    case DownloadState.failed:
      return 'Failed';
    case DownloadState.cancelled:
      return 'Cancelled';
  }
}

/// Progress bar, state, percentage, byte counters, speed and ETA for one pull.
///
/// [onCancel] is shown while the pull runs; [onRestart] takes over for failed or
/// cancelled pulls. The widget is deliberately small so a throttled parent can
/// rebuild it without touching the rest of the Models screen.
class DownloadStatusTile extends StatelessWidget {
  const DownloadStatusTile({
    super.key,
    required this.progress,
    this.onCancel,
    this.onRestart,
    this.restartLabel,
    this.compact = false,
  });

  final DownloadProgress progress;
  final VoidCallback? onCancel;
  final VoidCallback? onRestart;
  final String? restartLabel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final key = progress.ref.toString();
    final state = progress.state;
    final active = !DownloadThrottle._isTerminal(state);
    final hasTotal = progress.totalBytes > 0;
    final fraction = hasTotal ? progress.fraction : null;

    final stats = <Widget>[
      Text(
        formatDownloadPercent(progress.fraction),
        key: Key('download-percent-$key'),
        style: theme.textTheme.labelMedium?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
      if (hasTotal)
        Text(
          '${formatBytes(progress.receivedBytes)} / ${formatBytes(progress.totalBytes)}',
          key: Key('download-bytes-$key'),
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      if (state == DownloadState.downloading && progress.bytesPerSecond > 0)
        Text(
          formatSpeed(progress.bytesPerSecond),
          key: Key('download-speed-$key'),
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      if (state == DownloadState.downloading && progress.eta != null)
        Text(
          'ETA ${formatEta(progress.eta)}',
          key: Key('download-eta-$key'),
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                downloadStateLabel(progress),
                key: Key('download-state-$key'),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: state == DownloadState.failed ? scheme.error : scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (active && onCancel != null)
              IconButton(
                key: Key('download-cancel-$key'),
                tooltip: 'Cancel',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: onCancel,
              )
            else if (!active && onRestart != null && state != DownloadState.done)
              FilledButton.tonal(
                key: Key('download-btn-$key'),
                onPressed: onRestart,
                child: Text(restartLabel ?? (state == DownloadState.cancelled ? 'Resume' : 'Retry')),
              ),
          ],
        ),
        const SizedBox(height: 2),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            key: Key('download-progress-$key'),
            value: fraction,
            minHeight: compact ? 4 : 6,
          ),
        ),
        const SizedBox(height: 4),
        Wrap(spacing: 10, runSpacing: 2, children: stats),
        if (state == DownloadState.failed && progress.error != null) ...[
          const SizedBox(height: 4),
          Text(
            progress.error!,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ],
      ],
    );
  }
}

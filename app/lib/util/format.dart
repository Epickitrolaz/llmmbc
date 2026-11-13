/// Small formatting helpers shared by the app screens.
library;

/// Formats a byte count with binary units, e.g. `1.4 GiB`.
String formatBytes(int bytes, {int decimals = 1}) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 ? 0 : decimals;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// `80%`
String formatPercent(double fraction) => '${(fraction * 100).round()}%';

/// `82%` with a fraction such as `0.824`.
String formatFraction(double fraction) => '${(fraction * 100).round()}%';

/// `42.3%` — download progress keeps one decimal place.
String formatDownloadPercent(double fraction) {
  final clamped = fraction.isFinite ? fraction.clamp(0.0, 1.0) : 0.0;
  return '${(clamped * 100).toStringAsFixed(1)}%';
}

/// Transfer rate in decimal (SI) units, e.g. `18.2 MB/s`.
String formatSpeed(double bytesPerSecond) {
  if (!bytesPerSecond.isFinite || bytesPerSecond <= 0) return '0 B/s';
  const units = ['B/s', 'kB/s', 'MB/s', 'GB/s', 'TB/s'];
  var value = bytesPerSecond;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final digits = unit == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Short ETA: `1:23` below an hour, `1 h 05 m` from an hour up, `—` when unknown.
String formatEta(Duration? eta) {
  if (eta == null || eta.isNegative) return '—';
  final seconds = eta.inSeconds;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final rest = seconds % 60;
  if (hours > 0) {
    return '$hours h ${minutes.toString().padLeft(2, '0')} m';
  }
  return '$minutes:${rest.toString().padLeft(2, '0')}';
}

/// Human friendly relative time for heartbeat columns.
String formatRelativeTime(DateTime? time, {DateTime? now}) {
  if (time == null) return 'never';
  final reference = now ?? DateTime.now();
  final delta = reference.difference(time);
  if (delta.isNegative) return 'just now';
  if (delta.inSeconds < 5) return 'just now';
  if (delta.inSeconds < 60) return '${delta.inSeconds}s ago';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  return '${delta.inDays}d ago';
}

/// `12:04`
String formatClock(DateTime time) {
  final h = time.hour.toString().padLeft(2, '0');
  final m = time.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

/// Shortens a node UUID for dense chips.
String shortId(String id) {
  final trimmed = id.trim();
  if (trimmed.length <= 8) return trimmed;
  return trimmed.substring(0, 8);
}

/// `1 node` / `3 nodes`
String pluralize(int count, String singular, [String? plural]) =>
    count == 1 ? '$count $singular' : '$count ${plural ?? '${singular}s'}';

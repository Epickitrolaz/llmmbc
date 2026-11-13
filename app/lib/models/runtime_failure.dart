/// Captures a node-runtime failure so the UI can show why the app fell back to
/// UI-only mode and offer a retry.
library;

/// One failure of the real [NodeService] runtime (construction or startup).
class RuntimeFailure {
  /// Where it happened: `create`, `start` or `retry`.
  final String phase;

  /// Runtime type of the error, e.g. `FileSystemException`.
  final String type;

  /// `error.toString()`.
  final String message;

  /// Stack trace, trimmed to keep the details panel readable.
  final String? stack;

  /// `InferenceEngine.logTail` at the time of the failure (may be empty).
  final List<String> logTail;

  final DateTime at;

  const RuntimeFailure({
    required this.phase,
    required this.type,
    required this.message,
    required this.at,
    this.stack,
    this.logTail = const [],
  });

  factory RuntimeFailure.capture(
    Object error,
    StackTrace? stack, {
    required String phase,
    List<String> logTail = const [],
  }) {
    final trace = stack?.toString().trim();
    return RuntimeFailure(
      phase: phase,
      type: error.runtimeType.toString(),
      message: error.toString(),
      at: DateTime.now(),
      stack: trace == null || trace.isEmpty
          ? null
          : (trace.length <= 6000 ? trace : '${trace.substring(0, 6000)}\n…'),
      logTail: List.unmodifiable(logTail),
    );
  }

  /// One-line summary used in banners.
  String get summary => message.trim().isEmpty ? '$type ($phase)' : message.trim();

  /// Copy-ready details for bug reports.
  String get detailsText {
    final buffer = StringBuffer()
      ..writeln('phase: $phase')
      ..writeln('type:  $type')
      ..writeln('time:  ${at.toIso8601String()}')
      ..writeln('error: $message');
    if (stack != null) {
      buffer
        ..writeln()
        ..writeln('stack:')
        ..writeln(stack);
    }
    if (logTail.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('engine log tail:')
        ..writeln(logTail.join('\n'));
    }
    return buffer.toString();
  }
}

import 'dart:io';

import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:test/test.dart';

/// Opt-in end-to-end check against the real Ollama registry:
///
/// ```
/// LLMMBC_LIVE=1 dart test test/registry/live_registry_test.dart
/// ```
///
/// Downloads `qwen3:0.6b` (~520 MB) into a temporary model store, then verifies the GGUF
/// metadata through the same code path the node uses.
void main() {
  final live = Platform.environment['LLMMBC_LIVE'] == '1';

  test(
    'live: pull qwen3:0.6b from registry.ollama.ai and read its GGUF metadata',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('llmmbc_live_');
      try {
        final store = FileModelStore(tempDir.path);
        final ref = ModelRef.parse('qwen3:0.6b');
        final states = <DownloadState>[];

        var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
        await for (final progress in store.pull(ref)) {
          if (states.isEmpty || states.last != progress.state) states.add(progress.state);
          // Print a progress line about twice a second, always for state changes.
          final now = DateTime.now();
          if (progress.state != DownloadState.downloading ||
              now.difference(lastReport) >= const Duration(milliseconds: 500)) {
            lastReport = now;
            stdout.writeln('live progress: ${progress.state.name} '
                '${progress.receivedBytes}/${progress.totalBytes} '
                '${progress.percent.toStringAsFixed(1)}% '
                '${(progress.bytesPerSecond / (1 << 20)).toStringAsFixed(2)} MiB/s '
                'eta ${progress.eta == null ? 'unknown' : '${progress.eta!.inSeconds}s'}'
                '${progress.error == null ? '' : ' error=${progress.error}'}');
          }
        }

        expect(states.last, DownloadState.done);
        final model = await store.find(ref);
        expect(model, isNotNull, reason: 'model must be complete after pull');
        final metadata = model!.metadata;
        expect(metadata, isNotNull, reason: 'GGUF metadata must be readable');
        expect(metadata!.architecture, 'qwen3');
        expect(metadata.blockCount, 28);

        stdout.writeln('live result: ref=${model.ref} '
            'sizeBytes=${model.sizeBytes} '
            'architecture=${metadata.architecture} '
            'blockCount=${metadata.blockCount} '
            'expertCount=${metadata.expertCount} '
            'contextLength=${metadata.contextLength} '
            'embeddingLength=${metadata.embeddingLength} '
            'fileType=${metadata.fileType} '
            'totalTensorBytes=${metadata.totalTensorBytes}');
        stdout.writeln('live states: ${states.map((s) => s.name).join(' -> ')}');
      } finally {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
    skip: live ? false : 'set LLMMBC_LIVE=1 to run the real registry pull',
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

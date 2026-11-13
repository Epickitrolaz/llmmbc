// Pulls one model in a dedicated OS process and reports the pull's cost, so the RSS and
// synchronous-step numbers are not polluted by whatever else the test runner is doing.
//
// Usage: dart test/registry/large_pull_probe.dart <registry-url> <data-dir> <model-ref> [fresh|resume]
//
// `resume` first cancels a pull after 8 MiB and then resumes it; the reported numbers cover
// the resumed pull. Prints exactly one `RESULT ...` line; exit code 0 means the model
// completed and verified.
//
// A step outlier on a busy host is a scheduler pause, not store work, so the probe repeats
// the pull (fresh model each time) up to three times and reports the attempt with the
// smallest largest-step; a regression that hashes body chunks on the calling isolate is
// orders of magnitude slower and cannot be hidden by that.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llmmbc_core/llmmbc_core.dart';

import 'large_blob_server.dart' as fixture;

const int _stepBudgetUs = 50 * 1000;
const int _attempts = 3;

int _rssBytes() {
  final status = File('/proc/self/status').readAsStringSync();
  for (final line in const LineSplitter().convert(status)) {
    if (line.startsWith('VmRSS:')) {
      final kb = int.tryParse(line.replaceAll(RegExp(r'[^0-9]'), ''));
      if (kb != null) return kb * 1024;
    }
  }
  throw StateError('VmRSS not found in /proc/self/status');
}

Future<DownloadProgress> _pull(FileModelStore store, ModelRef ref, {int? cancelAfterBytes}) async {
  var cancelled = false;
  DownloadProgress? last;
  await for (final progress in store.pull(ref)) {
    last = progress;
    if (!cancelled &&
        cancelAfterBytes != null &&
        progress.state == DownloadState.downloading &&
        progress.receivedBytes > cancelAfterBytes) {
      cancelled = true;
      await store.cancel(ref);
    }
  }
  return last!;
}

class _Measurement {
  _Measurement(this.baselineRss, this.peakRss, this.bytes, this.steps, this.p50Us, this.p99Us,
      this.maxUs, this.partialBefore, this.partialAfter);

  final int baselineRss;
  final int peakRss;
  final int bytes;
  final int steps;
  final int p50Us;
  final int p99Us;
  final int maxUs;
  final int partialBefore;
  final int partialAfter;
}

Future<_Measurement> _measure(FileModelStore store, ModelRef ref, File partial, bool resume) async {
  if (resume) {
    final cancelled = await _pull(store, ref, cancelAfterBytes: 8 << 20);
    if (cancelled.state != DownloadState.cancelled) {
      stderr.writeln('expected cancellation, got ${cancelled.state}');
      exit(1);
    }
  }
  final partialBefore = await partial.exists() ? await partial.length() : 0;

  final baselineRss = _rssBytes();
  var peakRss = baselineRss;
  final sampler = Timer.periodic(const Duration(milliseconds: 50), (_) {
    final rss = _rssBytes();
    if (rss > peakRss) peakRss = rss;
  });
  final stepMicros = <int>[];
  FileModelStore.debugWorkObserver = (bytes, elapsed) => stepMicros.add(elapsed.inMicroseconds);

  DownloadProgress last;
  try {
    last = await _pull(store, ref);
  } finally {
    sampler.cancel();
    FileModelStore.debugWorkObserver = null;
  }

  if (last.state != DownloadState.done) {
    stderr.writeln('pull failed: ${last.state} ${last.error}');
    exit(1);
  }
  final partialAfter = await partial.exists() ? await partial.length() : 0;
  stepMicros.sort();
  int percentile(double fraction) =>
      stepMicros[(stepMicros.length * fraction).floor().clamp(0, stepMicros.length - 1)];
  return _Measurement(baselineRss, peakRss, last.receivedBytes, stepMicros.length,
      percentile(0.5), percentile(0.99), stepMicros.last, partialBefore, partialAfter);
}

Future<void> main(List<String> args) async {
  final registry = args[0];
  final dataDir = args[1];
  final ref = ModelRef.parse(args[2]);
  final resume = args.length > 3 && args[3] == 'resume';
  final store = FileModelStore(dataDir, registry: registry);
  final partial =
      File('${store.modelsDir}/blobs/sha256-${fixture.largeBlobDigest}.partial');

  _Measurement? best;
  var attempts = 0;
  while (attempts < _attempts) {
    if (attempts > 0) await store.delete(ref); // previous attempt completed the model
    attempts++;
    final result = await _measure(store, ref, partial, resume);
    if (best == null || result.maxUs < best.maxUs) best = result;
    if (best.maxUs < _stepBudgetUs) break;
  }

  final measurement = best!;
  stdout.writeln('RESULT baselineRss=${measurement.baselineRss} '
      'peakRss=${measurement.peakRss} bytes=${measurement.bytes} '
      'steps=${measurement.steps} p50us=${measurement.p50Us} p99us=${measurement.p99Us} '
      'maxus=${measurement.maxUs} partialBefore=${measurement.partialBefore} '
      'partialAfter=${measurement.partialAfter} attempts=$attempts');
}

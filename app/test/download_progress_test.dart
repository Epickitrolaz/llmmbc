import 'package:app/ui/widgets/download_progress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llmmbc_core/llmmbc_core.dart';

void main() {
  const ref = ModelRef('qwen3', tag: '0.6b');

  DownloadProgress at(DownloadState state, int received, {String? error}) => DownloadProgress(
        ref,
        state,
        receivedBytes: received,
        totalBytes: 1000,
        error: error,
      );

  testWidgets('DownloadThrottle forwards state changes immediately and caps byte updates', (tester) async {
    final throttle = DownloadThrottle(ref);
    addTearDown(throttle.dispose);
    var updates = 0;
    throttle.progress.addListener(() => updates++);

    throttle.push(at(DownloadState.resolving, 0));
    expect(updates, 1, reason: 'first event is shown at once');
    throttle.push(at(DownloadState.downloading, 10));
    expect(updates, 2, reason: 'state change is never delayed');

    for (var received = 11; received <= 900; received++) {
      throttle.push(at(DownloadState.downloading, received));
    }
    expect(updates, 2, reason: 'byte events are coalesced');

    await tester.pump(const Duration(milliseconds: 99));
    expect(updates, 2);
    await tester.pump(const Duration(milliseconds: 1));
    expect(updates, 3);
    expect(throttle.value!.receivedBytes, 900, reason: 'latest sample wins, not a stale one');

    for (var received = 901; received <= 1000; received++) {
      throttle.push(at(DownloadState.downloading, received));
    }
    throttle.push(at(DownloadState.done, 1000));
    expect(updates, 4, reason: 'terminal state flushes without waiting');
    expect(throttle.value!.state, DownloadState.done);
  });

  testWidgets('labels cover resolving, downloading, verifying, done and failed', (tester) async {
    expect(downloadStateLabel(at(DownloadState.resolving, 0)), 'Resolving');
    expect(downloadStateLabel(at(DownloadState.downloading, 100)), 'Downloading');
    expect(downloadStateLabel(at(DownloadState.verifying, 250)), 'Verifying 25.0%');
    expect(downloadStateLabel(at(DownloadState.done, 1000)), 'Done');
    expect(downloadStateLabel(at(DownloadState.failed, 0, error: 'boom')), 'Failed');
  });
}

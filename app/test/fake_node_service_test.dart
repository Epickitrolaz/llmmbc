import 'package:app/dev/fake_node_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llmmbc_core/llmmbc_core.dart';

void main() {
  test('fake chat streams deltas and cancel completes', () async {
    final fake = FakeNodeService(tokenDelay: const Duration(milliseconds: 5));
    final sub = fake
        .chat(ModelRef.parse('qwen3:0.6b'), const [ChatMessage('user', 'hi')])
        .listen((delta) {});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await sub.cancel().timeout(const Duration(seconds: 2));
  });

  test('fake pull simulates speed, ETA and verifying progress', () async {
    final fake = FakeNodeService(
      downloadTick: const Duration(milliseconds: 5),
      verifyDuration: const Duration(milliseconds: 20),
    );
    final events = <DownloadProgress>[];
    await fake.models.pull(ModelRef.parse('mixtral:8x7b')).forEach(events.add);

    final downloading = events.where((e) => e.state == DownloadState.downloading).toList();
    expect(downloading, isNotEmpty);
    expect(downloading.first.bytesPerSecond, greaterThan(0));
    expect(downloading.first.eta, isNotNull);
    expect(downloading.last.receivedBytes, greaterThan(0));

    final verifying = events.where((e) => e.state == DownloadState.verifying).toList();
    expect(verifying.length, greaterThanOrEqualTo(2), reason: 'verifying progress is reported in steps');
    expect(
      verifying.map((e) => e.receivedBytes).toSet().length,
      greaterThan(1),
      reason: 'the verifying bar moves instead of jumping to 100%',
    );
    expect(events.last.state, DownloadState.done);
    expect((await fake.models.list()).any((m) => m.ref.toString() == 'mixtral:8x7b'), isTrue);
  });

  test('fake self advertises the budget for the selected basis', () async {
    final fake = FakeNodeService();
    expect(
      fake.self.memoryBudgetBytes,
      fake.hardware.memoryBudgetBytes(MemoryBasis.total, kDefaultMemoryShare),
    );

    await fake.updateSettings(fake.settings.copyWith(memoryBasis: MemoryBasis.available));
    expect(
      fake.self.memoryBudgetBytes,
      fake.hardware.memoryBudgetBytes(MemoryBasis.available, kDefaultMemoryShare),
    );
    expect(fake.self.effectiveBudgetBytes, fake.self.memoryBudgetBytes);
    expect(fake.clusterModels(), isNotEmpty);
  });
}

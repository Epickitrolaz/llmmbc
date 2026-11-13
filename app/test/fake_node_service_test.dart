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
}

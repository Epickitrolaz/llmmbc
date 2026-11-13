import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_app.dart';

void main() {
  testWidgets('models screen shows the MoE-first catalog and local store', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session);
    await openTab(tester, 'Models');

    expect(find.text('Catalog'), findsOneWidget);
    expect(find.text('Qwen3 30B A3B'), findsOneWidget);
    expect(find.text('Granite 3.1 MoE 1B'), findsOneWidget);
    expect(find.text('MoE'), findsWidgets);
    expect(find.text('dense'), findsWidgets);

    // Local models are listed with their GGUF metadata.
    expect(find.byKey(const Key('local-model-qwen3:0.6b')), findsOneWidget);
    expect(find.byKey(const Key('local-model-granite3.1-moe:1b')), findsOneWidget);
    expect(find.textContaining('experts'), findsWidgets);
    expect(find.textContaining('layers'), findsWidgets);
  });

  testWidgets('download runs with progress, then lands in the local store', (tester) async {
    final session = await testSession(downloadTick: const Duration(milliseconds: 10));
    await pumpApp(tester, session);
    await openTab(tester, 'Models');

    final ref = session.service.models.catalog().firstWhere((entry) => entry.ref.toString() == 'qwen3:30b-a3b');
    expect(find.byKey(Key('download-btn-${ref.ref}')), findsOneWidget);

    await tapVisible(tester, find.byKey(Key('download-btn-${ref.ref}')));
    await tester.pump();
    expect(find.byKey(Key('download-cancel-${ref.ref}')), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('download-cancel-${ref.ref}')), findsNothing);
    expect(find.byKey(const Key('local-model-qwen3:30b-a3b')), findsOneWidget);
    final stored = await session.service.models.list();
    expect(stored.any((model) => model.ref.toString() == 'qwen3:30b-a3b'), isTrue);
  });

  testWidgets('download row shows percent, speed, ETA and verifying progress', (tester) async {
    final session = await testSession(
      downloadTick: const Duration(milliseconds: 10),
      verifyDuration: const Duration(milliseconds: 400),
    );
    await pumpApp(tester, session);
    await openTab(tester, 'Models');

    const key = 'qwen3:30b-a3b';
    await tapVisible(tester, find.byKey(const Key('download-btn-$key')));
    await tester.pump();
    expect(find.text('Resolving'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('Downloading'), findsOneWidget);
    final percent = tester.widget<Text>(find.byKey(const Key('download-percent-$key'))).data!;
    expect(RegExp(r'^\d+\.\d%$').hasMatch(percent), isTrue, reason: 'one decimal place: $percent');
    expect(find.byKey(const Key('download-bytes-$key')), findsOneWidget);
    expect(find.textContaining('/ 18.0 GiB'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('download-speed-$key'))).data, '18.2 MB/s');
    final eta = tester.widget<Text>(find.byKey(const Key('download-eta-$key'))).data!;
    expect(eta, startsWith('ETA '));

    // Reaching 100% enters verifying, which still shows a moving bar plus its own %.
    await tester.pump(const Duration(milliseconds: 140));
    final verifying = tester.widget<Text>(find.byKey(const Key('download-state-$key'))).data!;
    expect(verifying, startsWith('Verifying '));
    expect(verifying, endsWith('%'));
    final bar = tester.widget<LinearProgressIndicator>(find.byKey(const Key('download-progress-$key')));
    expect(bar.value, isNotNull);
    expect(bar.value, greaterThan(0));
    expect(bar.value, lessThan(1));
    // Cancel stays available while verifying.
    expect(find.byKey(const Key('download-cancel-$key')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('local-model-qwen3:30b-a3b')), findsOneWidget);
  });

  testWidgets('download can be cancelled', (tester) async {
    final session = await testSession(downloadTick: const Duration(milliseconds: 10));
    await pumpApp(tester, session);
    await openTab(tester, 'Models');

    const key = 'download-btn-mixtral:8x7b';
    await tapVisible(tester, find.byKey(const Key(key)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tapVisible(tester, find.byKey(const Key('download-cancel-mixtral:8x7b')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    // The row offers Resume after a cancel.
    expect(find.byKey(const Key('download-btn-mixtral:8x7b')), findsOneWidget);
    expect(find.text('Resume'), findsWidgets);
    expect((await session.service.models.list()).any((m) => m.ref.toString() == 'mixtral:8x7b'), isFalse);
  });

  testWidgets('pull by name validates the reference and starts a download', (tester) async {
    final session = await testSession(downloadTick: const Duration(milliseconds: 10));
    await pumpApp(tester, session);
    await openTab(tester, 'Models');

    await tester.enterText(find.byKey(const Key('models-pull-field')), 'not a valid ref');
    await tester.tap(find.byKey(const Key('models-pull-button')));
    await tester.pump();
    expect(find.byKey(const Key('models-pull-error')), findsOneWidget);
    expect(find.textContaining('Not a valid model reference'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('models-pull-field')), 'llama3.2:1b');
    await tester.tap(find.byKey(const Key('models-pull-button')));
    await tester.pump();
    expect(find.byKey(const Key('download-cancel-llama3.2:1b')), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  });

  testWidgets('delete removes a local model after confirmation', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session);
    await openTab(tester, 'Models');

    await tapVisible(tester, find.byKey(const Key('delete-model-granite3.1-moe:1b')));
    await tester.pumpAndSettle();
    expect(find.text('Delete granite3.1-moe:1b?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('confirm-delete')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('local-model-granite3.1-moe:1b')), findsNothing);
    final stored = await session.service.models.list();
    expect(stored.any((model) => model.ref.toString() == 'granite3.1-moe:1b'), isFalse);
  });
}

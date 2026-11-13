import 'package:app/services/degraded_node_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llmmbc_core/llmmbc_core.dart';

import 'helpers/test_app.dart';

void main() {
  testWidgets('chat streams a markdown answer with served-by and session details', (tester) async {
    final session = await testSession(tokenDelay: const Duration(milliseconds: 1));
    await pumpApp(tester, session);

    expect(find.text('Ask the cluster anything'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('chat-input')), 'Which models fit my cluster?');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pump();

    expect(find.byKey(const Key('chat-stop')), findsOneWidget);
    expect(find.text('Which models fit my cluster?'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat-stop')), findsNothing);
    expect(find.textContaining('simulated answer', findRichText: true), findsOneWidget);
    expect(find.textContaining('How this request was served', findRichText: true), findsOneWidget);
    expect(find.textContaining('served by'), findsOneWidget);
    expect(find.textContaining('coordinator Studio PC'), findsOneWidget);
    expect(session.history, hasLength(1));
    expect(session.history.first.title, contains('Which models fit'));

    // The conversation list survives a reload from disk.
    final stored = await session.conversations.load();
    expect(stored, hasLength(1));
    expect(stored.first.entries.length, 2);
  });

  testWidgets('stop cancels the stream and marks the answer as stopped', (tester) async {
    final session = await testSession(tokenDelay: const Duration(milliseconds: 40));
    await pumpApp(tester, session);

    await tester.enterText(find.byKey(const Key('chat-input')), 'Tell me a long story');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.byKey(const Key('chat-stop')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat-stop')), findsNothing);
    expect(find.text('stopped'), findsOneWidget);
  });

  testWidgets('shows the no_candidates error with actionable copy', (tester) async {
    final session = await testSession();
    fakeOf(session).chatFailure = LlmmbcException('no_candidates', 'no worker has it');
    await pumpApp(tester, session);

    await tester.enterText(find.byKey(const Key('chat-input')), 'hello');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat-error')), findsOneWidget);
    expect(find.text('No node can serve this model'), findsOneWidget);
    expect(find.text('no_candidates'), findsOneWidget);
  });

  testWidgets('shows the busy error copy', (tester) async {
    final session = await testSession();
    fakeOf(session).chatFailure = LlmmbcException('busy', 'coordinator busy');
    await pumpApp(tester, session);

    await tester.enterText(find.byKey(const Key('chat-input')), 'hello');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();

    expect(find.text('Coordinator is busy'), findsOneWidget);
  });

  testWidgets('model picker lists cluster models with MoE badge and memory', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session);

    expect(find.byKey(const Key('chat-model-picker')), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-model-picker')));
    await tester.pumpAndSettle();

    expect(find.text('Cluster models'), findsOneWidget);
    expect(find.text('qwen3:30b-a3b'), findsWidgets);
    expect(find.text('MoE'), findsWidgets);

    await tester.tap(find.byKey(const Key('model-option-granite3.1-moe:1b')));
    await tester.pumpAndSettle();

    expect(find.text('granite3.1-moe:1b'), findsWidgets);
  });

  testWidgets('empty cluster explains what to do', (tester) async {
    final session = await testSession();
    fakeOf(session).debugClearCluster();
    await pumpApp(tester, session);

    expect(find.text('No models in the cluster'), findsOneWidget);
    expect(find.text('No model available'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('chat-input'))).enabled, isFalse);
  });

  testWidgets('degraded mode disables chat with an explanation', (tester) async {
    final session = await testSessionWith(
      await DegradedNodeService.create(
        settingsPath: '/tmp/llmmbc-test-degraded/settings.json',
        defaultDataDir: '/tmp/llmmbc-test-degraded',
      ),
      fake: false,
      degraded: true,
    );
    await pumpApp(tester, session);

    expect(find.textContaining('node runtime is unavailable'), findsWidgets);
    expect(tester.widget<TextField>(find.byKey(const Key('chat-input'))).enabled, isFalse);
  });
}

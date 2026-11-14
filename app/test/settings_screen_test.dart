import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/dev/fake_node_service.dart';
import 'package:app/util/format.dart';
import 'package:llmmbc_core/llmmbc_core.dart';

import 'helpers/test_app.dart';

void main() {
  testWidgets('worker mode toggle persists and flips the status pill', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session);
    await openTab(tester, 'Settings');

    expect(fakeOf(session).settings.workerEnabled, isTrue);
    await tapVisible(tester, find.byKey(const Key('worker-toggle')));
    await tester.pumpAndSettle();

    expect(fakeOf(session).settings.workerEnabled, isFalse);
    expect(
      find.descendant(of: find.byKey(const Key('worker-toggle')), matching: find.text('OFF')),
      findsOneWidget,
    );
    // The expert streaming toggle has its own status pill and stays off.
    expect(fakeOf(session).settings.allowExpertStreaming, isFalse);
    expect(
      find.descendant(
        of: find.byKey(const Key('expert-streaming-toggle')),
        matching: find.text('OFF'),
      ),
      findsOneWidget,
    );
    // Own models are no longer candidates when worker mode is off.
    final granite = session.service.clusterModels().where((m) => m.ref.toString() == 'granite3.1-moe:1b');
    expect(granite.first.candidates.any((node) => node.isSelf), isFalse);
  });

  testWidgets('node name is saved through updateSettings', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session);
    await openTab(tester, 'Settings');

    await tester.enterText(find.byKey(const Key('settings-name')), 'Cluster Queen');
    await tapVisible(tester, find.byKey(const Key('settings-name-save')));
    await tester.pumpAndSettle();

    expect(fakeOf(session).settings.name, 'Cluster Queen');
    expect(find.textContaining('Cluster Queen'), findsWidgets);
  });

  testWidgets('memory basis defaults to Total RAM and the preview follows the slider', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session);
    await openTab(tester, 'Settings');

    // Defaults from the contract: total basis, 70%.
    expect(fakeOf(session).settings.memoryBasis, MemoryBasis.total);
    expect(fakeOf(session).settings.memoryShare, kDefaultMemoryShare);
    expect(find.text('Total RAM'), findsWidgets);
    expect(find.text('Free RAM estimate'), findsOneWidget);
    expect(find.textContaining('Lends a share of all installed memory'), findsOneWidget);
    // Android demo hardware shows the over-promise warning.
    expect(find.byKey(const Key('memory-basis-warning')), findsOneWidget);

    final hardware = session.hardware;
    final expected = hardware.memoryBudgetBytes(MemoryBasis.total, kDefaultMemoryShare);
    expect(find.textContaining('Lends ${formatBytes(expected)} of'), findsOneWidget);
    expect(find.textContaining('(Total RAM)'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('memory-slider')));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const Key('memory-slider')), const Offset(-160, 0));
    await tester.pumpAndSettle();

    expect(fakeOf(session).settings.memoryShare, lessThan(kDefaultMemoryShare));
    final share = fakeOf(session).settings.memoryShare;
    final budget = hardware.memoryBudgetBytes(MemoryBasis.total, share);
    expect(find.textContaining('Lends ${formatBytes(budget)} of'), findsOneWidget);
  });

  testWidgets('switching to Free RAM estimate persists and updates the preview', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session);
    await openTab(tester, 'Settings');

    await tapVisible(tester, find.text('Free RAM estimate'));
    await tester.pumpAndSettle();

    expect(fakeOf(session).settings.memoryBasis, MemoryBasis.available);
    expect(find.textContaining('Lends a share of what is free right now'), findsOneWidget);
    expect(find.byKey(const Key('memory-basis-warning')), findsNothing);

    final hardware = session.hardware;
    final budget = hardware.memoryBudgetBytes(MemoryBasis.available, session.service.settings.memoryShare);
    expect(find.textContaining('Lends ${formatBytes(budget)} of'), findsOneWidget);
    expect(find.textContaining('(Free RAM estimate)'), findsOneWidget);

    // Switching back round-trips through updateSettings too.
    await tapVisible(tester, find.text('Total RAM'));
    await tester.pumpAndSettle();
    expect(fakeOf(session).settings.memoryBasis, MemoryBasis.total);
  });

  testWidgets('memory share slider updates the memory share', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session);
    await openTab(tester, 'Settings');

    expect(fakeOf(session).settings.memoryShare, kDefaultMemoryShare);
    await tester.ensureVisible(find.byKey(const Key('memory-slider')));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const Key('memory-slider')), const Offset(-160, 0));
    await tester.pumpAndSettle();

    expect(fakeOf(session).settings.memoryShare, lessThan(kDefaultMemoryShare));
  });

  testWidgets('expert streaming toggle is off by default, persists and explains the trade-off', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session);
    await openTab(tester, 'Settings');

    expect(fakeOf(session).settings.allowExpertStreaming, isFalse);
    final toggle = find.byKey(const Key('expert-streaming-toggle'));
    expect(toggle, findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(find.text('Allow MoE models larger than cluster memory'), findsOneWidget);
    expect(find.textContaining("Expert weights stream from each worker's own storage"), findsOneWidget);
    expect(find.textContaining('Applies when this device coordinates'), findsOneWidget);
    expect(find.textContaining('MoE models only'), findsOneWidget);

    await tapVisible(tester, toggle);
    await tester.pumpAndSettle();

    expect(fakeOf(session).settings.allowExpertStreaming, isTrue);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

    // Turning it off again goes through updateSettings as well.
    await tapVisible(tester, toggle);
    await tester.pumpAndSettle();
    expect(fakeOf(session).settings.allowExpertStreaming, isFalse);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
  });

  testWidgets('manual peers can be added and removed', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session);
    await openTab(tester, 'Settings');

    await tester.enterText(find.byKey(const Key('settings-peer-field')), '10.0.2.2:47101');
    await tapVisible(tester, find.byKey(const Key('settings-peer-add')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('manual-peer-10.0.2.2:47101')), findsOneWidget);
    expect(fakeOf(session).settings.manualPeers, contains('10.0.2.2:47101'));

    await tapVisible(
      tester,
      find.descendant(
        of: find.byKey(const Key('manual-peer-10.0.2.2:47101')),
        matching: find.byTooltip('Delete'),
      ),
    );
    await tester.pumpAndSettle();
    expect(fakeOf(session).settings.manualPeers, isNot(contains('10.0.2.2:47101')));
  });

  testWidgets('engine log tail and paths are shown', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session);
    await openTab(tester, 'Settings');

    expect(find.text('Engine'), findsOneWidget);
    expect(find.textContaining('llama_model_load'), findsOneWidget);
    expect(find.textContaining('/models/blobs'), findsWidgets);
    await tapVisible(tester, find.byKey(const Key('engine-log-refresh')));
    await tester.pumpAndSettle();
    expect(find.textContaining('llama_model_load'), findsOneWidget);
  });

  testWidgets('appearance switches the theme mode', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session);
    await openTab(tester, 'Settings');

    await tapVisible(tester, find.text('Dark'));
    await tester.pumpAndSettle();
    expect(session.themeMode, ThemeMode.dark);

    await tapVisible(tester, find.text('Light'));
    await tester.pumpAndSettle();
    expect(session.themeMode, ThemeMode.light);
  });

  testWidgets('iOS client-only mode forces worker mode off with an explanation', (tester) async {
    final session = await testSession(clientOnly: true);
    await pumpApp(tester, session);
    await openTab(tester, 'Settings');

    final tile = tester.widget<SwitchListTile>(find.byKey(const Key('worker-toggle')));
    expect(tile.value, isFalse);
    expect(tile.onChanged, isNull);
    expect(find.textContaining('iOS cannot spawn'), findsOneWidget);
  });

  testWidgets('Android starts the worker foreground service without engine binaries', (tester) async {
    final controller = FakeWorkerServiceController();
    final session = await testSessionWith(
      FakeNodeService(engineAvailable: false),
      android: true,
      workerService: controller,
    );
    await pumpApp(tester, session);
    expect(controller.calls, isNotEmpty);
    expect(controller.calls.last, isTrue);
    expect(session.workerServiceActive, isTrue);

    await openTab(tester, 'Settings');
    expect(find.textContaining('Worker foreground service is running'), findsOneWidget);

    await tapVisible(tester, find.byKey(const Key('worker-toggle')));
    await tester.pumpAndSettle();
    expect(controller.calls.last, isFalse);
    expect(find.textContaining('no foreground service runs'), findsOneWidget);
  });

  testWidgets('denied POST_NOTIFICATIONS is explained accurately', (tester) async {
    final controller = FakeWorkerServiceController(permitted: false);
    final session = await testSessionWith(
      FakeNodeService(),
      android: true,
      workerService: controller,
    );
    await pumpApp(tester, session);
    await openTab(tester, 'Settings');

    expect(session.notificationsAllowed, isFalse);
    expect(find.textContaining('Notifications are disabled'), findsOneWidget);
  });

  testWidgets('degraded builds show the runtime notice', (tester) async {
    final session = await testSession();
    expect(session.notice, isNull);
    await pumpApp(tester, session);
    expect(find.textContaining('Simulated cluster'), findsOneWidget);
  });
}

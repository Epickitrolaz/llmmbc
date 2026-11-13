import 'dart:io';

import 'package:app/dev/fake_node_service.dart';
import 'package:app/services/degraded_node_service.dart';
import 'package:app/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_app.dart';

/// Starts fine but the real node service is broken during startup.
class _FailingStartService extends FakeNodeService {
  @override
  Future<void> start() async {
    throw StateError('engine locate exploded: /engine/llama-server missing');
  }
}

void main() {
  testWidgets('degraded fallback surfaces the real error, details and retry', (tester) async {
    final support = Directory.systemTemp.createTempSync('llmmbc_failure_');
    addTearDown(() => support.deleteSync(recursive: true));
    final degraded = await tester.runAsync(
      () => DegradedNodeService.create(
        settingsPath: '${support.path}/settings.json',
        defaultDataDir: support.path,
        initialName: 'Test device',
        modelStore: TestModelStore(entries: testCatalog),
      ),
    );
    expect(degraded, isNotNull);

    final recovered = FakeNodeService();
    var runtimeFactoryCalls = 0;
    final session = await testSessionWith(
      _FailingStartService(),
      fake: false,
      degradedFactory: () async => degraded!,
      runtimeFactory: () async {
        runtimeFactoryCalls++;
        return recovered;
      },
    );

    await pumpApp(tester, session);

    // The UI-only fallback is active and shows the underlying error, not a generic notice.
    expect(session.degraded, isTrue);
    expect(find.byKey(const Key('runtime-failure')), findsOneWidget);
    expect(find.textContaining('engine locate exploded'), findsOneWidget);
    expect(find.textContaining('UI-only mode'), findsWidgets);

    // Details open in a scrollable dialog with phase/type, stack and copy action.
    await tester.tap(find.byKey(const Key('runtime-failure-details')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('runtime-failure-dialog')), findsOneWidget);
    expect(find.textContaining('phase: start'), findsOneWidget);
    expect(find.textContaining('StateError'), findsWidgets);
    expect(find.text('Stack trace'), findsOneWidget);
    expect(find.text('Copy details'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // Retry rebuilds the real runtime and starts it.
    await tester.tap(find.byKey(const Key('runtime-failure-retry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(runtimeFactoryCalls, 1);
    expect(session.degraded, isFalse);
    expect(session.runtimeFailure, isNull);
    expect(find.byKey(const Key('runtime-failure')), findsNothing);
    expect(session.ready, isTrue);
    expect(find.byType(HomeShell), findsOneWidget);
  });

  testWidgets('a failed retry keeps the degraded mode and the new error', (tester) async {
    final support = Directory.systemTemp.createTempSync('llmmbc_failure2_');
    addTearDown(() => support.deleteSync(recursive: true));
    final degraded = await tester.runAsync(
      () => DegradedNodeService.create(
        settingsPath: '${support.path}/settings.json',
        defaultDataDir: support.path,
        modelStore: TestModelStore(entries: testCatalog),
      ),
    );

    final session = await testSessionWith(
      _FailingStartService(),
      fake: false,
      degradedFactory: () async => degraded!,
      runtimeFactory: () async => throw const FileSystemException('settings.json is a directory'),
    );

    await pumpApp(tester, session);
    expect(find.byKey(const Key('runtime-failure')), findsOneWidget);

    await tester.tap(find.byKey(const Key('runtime-failure-retry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(session.degraded, isTrue);
    expect(session.runtimeFailure, isNotNull);
    expect(find.textContaining('settings.json is a directory'), findsOneWidget);
  });

  testWidgets('degraded mode uses core catalog and core hardware probe', (tester) async {
    final support = Directory.systemTemp.createTempSync('llmmbc_failure3_');
    addTearDown(() => support.deleteSync(recursive: true));
    final degraded = await tester.runAsync(
      () => DegradedNodeService.create(
        settingsPath: '${support.path}/settings.json',
        defaultDataDir: support.path,
        initialName: 'Named device',
        modelStore: TestModelStore(entries: testCatalog),
      ),
    );

    // Name seeding, core hardware probe and core catalog (no app-side duplicate).
    expect(degraded!.settings.name, 'Named device');
    expect(degraded.hardware.cpuCores, greaterThan(0));
    expect(degraded.hardware.totalRamBytes, greaterThan(0));

    final coreCatalog = FileModelStore(support.path).catalog();
    expect(coreCatalog.length, greaterThan(4));
    expect(coreCatalog.any((entry) => entry.ref.toString() == 'gpt-oss:20b'), isTrue);
    expect(degraded.models.catalog().any((entry) => entry.ref.toString() == 'gpt-oss:20b'), isTrue);

    final session = await testSessionWith(degraded, fake: false, degraded: true);
    await pumpApp(tester, session);
    await openTab(tester, 'Models');
    expect(find.text('Catalog'), findsOneWidget);
    expect(find.textContaining('gpt-oss:20b'), findsWidgets);
  });
}

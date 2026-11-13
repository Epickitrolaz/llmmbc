import 'dart:io';

import 'package:app/app/app_session.dart';
import 'package:app/app/llmmbc_app.dart';
import 'package:app/dev/fake_node_service.dart';
import 'package:app/services/bootstrap.dart';
import 'package:app/models/runtime_failure.dart';
import 'package:app/services/store.dart';
import 'package:app/services/worker_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llmmbc_core/llmmbc_core.dart';

/// Builds a session backed by [FakeNodeService] and a throwaway support dir.
Future<AppSession> testSession({
  bool clientOnly = false,
  Duration phaseDelay = Duration.zero,
  Duration tokenDelay = const Duration(milliseconds: 2),
  Duration downloadTick = const Duration(milliseconds: 20),
  Duration scanLatency = const Duration(milliseconds: 20),
}) async {
  final fake = FakeNodeService(
    phaseDelay: phaseDelay,
    tokenDelay: tokenDelay,
    downloadTick: downloadTick,
    scanLatency: scanLatency,
  );
  return testSessionWith(fake, clientOnly: clientOnly);
}

/// Wraps an arbitrary service in an [AppSession] for widget tests.
Future<AppSession> testSessionWith(
  NodeService service, {
  bool clientOnly = false,
  bool fake = true,
  bool degraded = false,
  RuntimeFailure? runtimeFailure,
  Future<NodeService> Function()? degradedFactory,
  Future<NodeService> Function()? runtimeFactory,
  WorkerServiceController? workerService,
  bool android = false,
  bool workerServiceActive = false,
  bool notificationsAllowed = true,
}) async {
  final dir = Directory.systemTemp.createTempSync('llmmbc_test_');
  return AppSession(
    service: service,
    conversations: ConversationStore(dir),
    prefs: AppPreferences(dir),
    fake: fake,
    degraded: degraded,
    runtimeFailure: runtimeFailure,
    clientOnly: clientOnly,
    android: android,
    degradedFactory: degradedFactory,
    runtimeFactory: runtimeFactory,
    workerService: workerService ?? FakeWorkerServiceController(),
    workerServiceActive: workerServiceActive,
    notificationsAllowed: notificationsAllowed,
  );
}

/// In-memory [ModelStore] for degraded-mode widget tests (no file I/O under the
/// fake-async test clock).
class TestModelStore implements ModelStore {
  TestModelStore({this.entries = const []});

  final List<CatalogEntry> entries;

  @override
  String get modelsDir => '/tmp/llmmbc-test/models';

  @override
  Future<List<LocalModel>> list() async => const [];

  @override
  Future<LocalModel?> find(ModelRef ref) async => null;

  @override
  Stream<DownloadProgress> pull(ModelRef ref) =>
      Stream.error(LlmmbcException('internal', 'downloads are disabled in UI-only mode'));

  @override
  Future<void> cancel(ModelRef ref) async {}

  @override
  Future<void> delete(ModelRef ref) async {}

  @override
  List<CatalogEntry> catalog() => entries;

  @override
  Future<int> remoteSize(ModelRef ref) async => 0;
}

/// Core-shaped catalog fixture (a subset of `FileModelStore.catalog()`).
const List<CatalogEntry> testCatalog = [
  CatalogEntry(
    ref: ModelRef('qwen3', tag: '30b-a3b'),
    title: 'Qwen3 30B-A3B',
    description: 'MoE flagship',
    isMoe: true,
    approxSizeBytes: 18600000000,
  ),
  CatalogEntry(
    ref: ModelRef('gpt-oss', tag: '20b'),
    title: 'GPT-OSS 20B',
    description: 'MoE reference model',
    isMoe: true,
    approxSizeBytes: 12000000000,
  ),
  CatalogEntry(
    ref: ModelRef('qwen3', tag: '0.6b'),
    title: 'Qwen3 0.6B',
    description: 'Tiny dense model',
    isMoe: false,
    approxSizeBytes: 520000000,
  ),
];

/// Records foreground-service calls without touching the platform channel.
class FakeWorkerServiceController implements WorkerServiceController {
  FakeWorkerServiceController({this.permitted = true, this.running = true});

  bool permitted;
  bool running;
  final List<bool> calls = [];

  @override
  Future<bool> requestNotificationPermission() async => permitted;

  @override
  Future<bool> setEnabled(bool enabled) async {
    calls.add(enabled);
    running = enabled;
    return running;
  }
}

FakeNodeService fakeOf(AppSession session) => session.service as FakeNodeService;

/// Pumps the app and waits for the startup sequence to finish.
Future<void> pumpApp(WidgetTester tester, AppSession session, {Size size = const Size(430, 900)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    LlmmbcApp(
      bootstrap: AppBootstrap(session: session, fake: true, degraded: false, dataDir: '/tmp/llmmbc-test'),
    ),
  );
  await tester.pump();
  // Startup may animate indeterminate progress spinners, so advance fixed steps
  // instead of relying on pumpAndSettle while the gate is visible.
  for (var i = 0; i < 14; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

/// Taps a bottom navigation destination by label.
Future<void> openTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// Scrolls [finder] into view (LongList inside ListView) and taps it.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

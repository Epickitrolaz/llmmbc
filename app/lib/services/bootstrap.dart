/// Builds the [AppSession]: fake cluster, live node runtime, or UI-only mode.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:llmmbc_core/llmmbc_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app/app_session.dart';
import '../dev/fake_node_service.dart';
import 'degraded_node_service.dart';
import 'platform_bridge.dart';
import 'store.dart';

/// `--dart-define=LLMMBC_FAKE=1` selects the simulated cluster.
const String _fakeFlag = String.fromEnvironment('LLMMBC_FAKE');

/// Optional pacing of the fake startup phases (screenshots/demos):
/// `--dart-define=LLMMBC_FAKE_PHASE_MS=5000`.
const int _fakePhaseMs = int.fromEnvironment('LLMMBC_FAKE_PHASE_MS', defaultValue: 420);

bool get fakeRequested {
  final value = _fakeFlag.trim().toLowerCase();
  return value == '1' || value == 'true' || value == 'yes';
}

class AppBootstrap {
  final AppSession session;
  final bool fake;
  final bool degraded;
  final String dataDir;

  AppBootstrap({required this.session, required this.fake, required this.degraded, required this.dataDir});
}

/// Resolves the support directory, the node service and persisted stores.
///
/// Order of preference:
/// 1. `LLMMBC_FAKE=1` → [FakeNodeService] (simulated peers/models/chat).
/// 2. `LocalNodeService.create(...)` from `llmmbc_core` (real LAN node).
/// 3. [DegradedNodeService] when the core runtime is not available yet.
Future<AppBootstrap> bootstrapApp({Directory? supportDirOverride, bool? forceFake}) async {
  final fake = forceFake ?? fakeRequested;
  final supportDir = supportDirOverride ?? await getApplicationSupportDirectory();
  await supportDir.create(recursive: true);
  final conversations = ConversationStore(supportDir);
  final prefs = AppPreferences(supportDir);

  var themeMode = ThemeMode.system;
  final stored = await prefs.load();
  final storedTheme = stored['themeMode'];
  if (storedTheme is String) {
    themeMode = ThemeMode.values.where((mode) => mode.name == storedTheme).firstOrNull ?? ThemeMode.system;
  }

  if (fake) {
    final session = AppSession(
      service: FakeNodeService(phaseDelay: Duration(milliseconds: _fakePhaseMs)),
      conversations: conversations,
      prefs: prefs,
      fake: true,
      themeMode: themeMode,
    );
    return AppBootstrap(session: session, fake: true, degraded: false, dataDir: supportDir.path);
  }

  final hooks = PlatformBridge.hooks();
  final settingsPath = p.join(supportDir.path, 'settings.json');

  Future<DegradedNodeService> buildDegraded() => DegradedNodeService.create(
        settingsPath: settingsPath,
        defaultDataDir: supportDir.path,
        platform: hooks,
      );

  try {
    final service = await LocalNodeService.create(
      settingsPath: settingsPath,
      defaultDataDir: supportDir.path,
      platform: hooks,
    );
    final session = AppSession(
      service: service,
      conversations: conversations,
      prefs: prefs,
      themeMode: themeMode,
      clientOnly: hooks.clientOnly,
      degradedFallback: buildDegraded,
    );
    return AppBootstrap(session: session, fake: false, degraded: false, dataDir: supportDir.path);
  } catch (error) {
    final service = await buildDegraded();
    final session = AppSession(
      service: service,
      conversations: conversations,
      prefs: prefs,
      themeMode: themeMode,
      clientOnly: hooks.clientOnly,
      degraded: true,
      notice: 'The core node runtime is not available in this build '
          '(${error.runtimeType}). Running in UI-only mode: real hardware data, '
          'settings and manual peers work, engine and downloads do not.',
      degradedFallback: buildDegraded,
    );
    return AppBootstrap(session: session, fake: false, degraded: true, dataDir: supportDir.path);
  }
}

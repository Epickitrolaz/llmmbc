/// Bridge to the platform specific Android code in `MainActivity.kt`.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:llmmbc_core/llmmbc_core.dart';

/// Channel implemented by `android/app/src/main/kotlin/dev/llmmbc/app/MainActivity.kt`.
/// Methods:
///  * `nativeLibraryDir` -> String (directory holding `libllama_server.so`)
///  * `multicastLock(bool)` -> bool (WifiManager.MulticastLock acquire/release)
///  * `gpuRenderer` -> String?
///  * `deviceTags` -> List of strings (`["emulator"]`; not used by the core)
///  * `deviceName` -> String? (`Build.MODEL`, used for the first-run node name)
///  * `requestNotificationPermission` -> bool (POST_NOTIFICATIONS on Android 13+)
///  * `startForeground` / `stopForeground` -> bool (keeps the node alive as a worker)
class PlatformBridge {
  PlatformBridge._();

  static const MethodChannel channel = MethodChannel('dev.llmmbc/platform');

  static bool get isAndroid => Platform.isAndroid;

  /// Hooks handed to `LocalNodeService.create`.
  static PlatformHooks hooks() => PlatformHooks(
        nativeLibraryDir: isAndroid ? nativeLibraryDir : null,
        multicastLock: isAndroid ? setMulticastLock : null,
        gpuRenderer: isAndroid ? gpuRenderer : null,
        clientOnly: Platform.isIOS,
      );

  static Future<String?> nativeLibraryDir() async {
    if (!isAndroid) return null;
    return _invoke<String>('nativeLibraryDir');
  }

  static Future<void> setMulticastLock(bool acquire) async {
    if (!isAndroid) return;
    await _invoke<bool>('multicastLock', acquire);
  }

  static Future<String?> gpuRenderer() async {
    if (!isAndroid) return null;
    return _invoke<String>('gpuRenderer');
  }

  /// Android `Build.MODEL`, e.g. `Pixel 8`. Null elsewhere.
  static Future<String?> deviceName() async {
    if (!isAndroid) return null;
    final value = await _invoke<String>('deviceName');
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// Requests POST_NOTIFICATIONS on Android 13+. True when notifications are
  /// allowed (also true on platforms without the permission).
  static Future<bool> requestNotificationPermission() async {
    if (!isAndroid) return true;
    return await _invoke<bool>('requestNotificationPermission') ?? false;
  }

  /// Extra tags reported by Android (`emulator`). Missing on other platforms.
  static Future<List<String>> deviceTags() async {
    if (!isAndroid) return const [];
    try {
      final tags = await channel.invokeMethod<List<Object?>>('deviceTags');
      return [for (final tag in tags ?? const <Object?>[]) if (tag is String) tag];
    } catch (_) {
      return const [];
    }
  }

  /// Starts/stops the foreground service that keeps the node reachable while
  /// worker mode is on. Returns whether the service is now running as asked.
  static Future<bool> setWorkerNotification(bool enabled) async {
    if (!isAndroid) return false;
    try {
      final running = await channel.invokeMethod<bool>(enabled ? 'startForeground' : 'stopForeground');
      return running ?? false;
    } catch (_) {
      // Without a working channel the node still runs in the foreground.
      return false;
    }
  }

  static Future<T?> _invoke<T>(String method, [Object? argument]) async {
    try {
      return await channel.invokeMethod<T>(method, argument);
    } catch (_) {
      // MissingPluginException on desktop/tests, or a plugin level failure.
      return null;
    }
  }
}

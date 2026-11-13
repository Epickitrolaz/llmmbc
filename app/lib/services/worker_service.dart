/// Keeps the Android node alive while worker mode is on.
library;

import 'platform_bridge.dart';

/// Injectable seam so widget tests can observe foreground-service calls
/// without a platform channel.
abstract class WorkerServiceController {
  /// Asks for POST_NOTIFICATIONS on Android 13+; returns whether notifications
  /// are allowed (true on platforms without the permission).
  Future<bool> requestNotificationPermission();

  /// Starts/stops the foreground service; returns whether it is running.
  Future<bool> setEnabled(bool enabled);
}

class PlatformWorkerServiceController implements WorkerServiceController {
  const PlatformWorkerServiceController();

  @override
  Future<bool> requestNotificationPermission() => PlatformBridge.requestNotificationPermission();

  @override
  Future<bool> setEnabled(bool enabled) => PlatformBridge.setWorkerNotification(enabled);
}

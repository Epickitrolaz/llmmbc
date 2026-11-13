package dev.llmmbc.app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.opengl.EGL14
import android.opengl.GLES20
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Platform channel `dev.llmmbc/platform` used by `lib/services/platform_bridge.dart`.
 *
 * Also owns the foreground service that keeps the node alive while worker mode is on.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "dev.llmmbc/platform"
    private val notificationPermissionRequest = 47102
    private var multicastLock: WifiManager.MulticastLock? = null
    private var notificationPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "nativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)
                    "multicastLock" -> handleMulticastLock(call.arguments as? Boolean ?: false, result)
                    "gpuRenderer" -> result.success(gpuRenderer())
                    "deviceTags" -> result.success(deviceTags())
                    "deviceName" -> result.success(deviceName())
                    "requestNotificationPermission" -> requestNotificationPermission(result)
                    "startForeground" -> {
                        val started = startWorkerService()
                        result.success(started)
                    }
                    "stopForeground" -> {
                        stopWorkerService()
                        result.success(false)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** WifiManager.MulticastLock keeps UDP broadcast/multicast discovery alive. */
    private fun handleMulticastLock(acquire: Boolean, result: MethodChannel.Result) {
        try {
            if (multicastLock == null) {
                val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                multicastLock = wifi.createMulticastLock("llmmbc-discovery").apply { setReferenceCounted(false) }
            }
            val lock = multicastLock
            if (acquire) {
                lock?.acquire()
            } else if (lock?.isHeld == true) {
                lock.release()
            }
            result.success(true)
        } catch (error: Exception) {
            result.error("multicast_lock", error.message, null)
        }
    }

    /** GPU renderer string via a throwaway EGL pbuffer context. */
    private fun gpuRenderer(): String? {
        val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (display == EGL14.EGL_NO_DISPLAY) return null
        val version = IntArray(2)
        var surface = EGL14.EGL_NO_SURFACE
        var context = EGL14.EGL_NO_CONTEXT
        try {
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) return null
            val attributes = intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_NONE
            )
            val configs = arrayOfNulls<android.opengl.EGLConfig>(1)
            val configCount = IntArray(1)
            if (!EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, configCount, 0) || configCount[0] == 0) {
                return null
            }
            val config = configs[0] ?: return null
            context = EGL14.eglCreateContext(
                display, config, EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0
            )
            surface = EGL14.eglCreatePbufferSurface(
                display, config,
                intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0
            )
            if (context == EGL14.EGL_NO_CONTEXT || surface == EGL14.EGL_NO_SURFACE) return null
            if (!EGL14.eglMakeCurrent(display, surface, surface, context)) return null
            return GLES20.glGetString(GLES20.GL_RENDERER)
        } catch (_: Throwable) {
            return null
        } finally {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (surface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface)
            if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
            EGL14.eglTerminate(display)
        }
    }

    /** Hardware tags the core probe cannot read from Dart (emulator detection). */
    private fun deviceTags(): List<String> {
        val tags = mutableListOf<String>()
        val fingerprint = Build.FINGERPRINT ?: ""
        val model = Build.MODEL ?: ""
        val product = Build.PRODUCT ?: ""
        val hardware = Build.HARDWARE ?: ""
        val emulator = fingerprint.startsWith("generic") ||
            fingerprint.contains("emulator") ||
            fingerprint.contains("unknown") ||
            model.contains("sdk_gphone") ||
            model.contains("Emulator") ||
            product.contains("sdk") ||
            product.contains("emulator") ||
            hardware.contains("ranchu") ||
            hardware.contains("goldfish")
        if (emulator) tags.add("emulator")
        return tags
    }

    /** Human readable device model used for the first-run node name. */
    private fun deviceName(): String? {
        val model = Build.MODEL?.trim().orEmpty()
        if (model.isNotEmpty()) return model
        val device = Build.DEVICE?.trim().orEmpty()
        return device.ifEmpty { null }
    }

    /** POST_NOTIFICATIONS on Android 13+; older API levels are always allowed. */
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        if (notificationPermissionResult != null) {
            // A request is already in flight; do not stack dialogs.
            result.success(false)
            return
        }
        notificationPermissionResult = result
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), notificationPermissionRequest)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != notificationPermissionRequest) return
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        notificationPermissionResult?.success(granted)
        notificationPermissionResult = null
    }

    private fun startWorkerService(): Boolean {
        return try {
            val intent = Intent(this, WorkerService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun stopWorkerService() {
        stopService(Intent(this, WorkerService::class.java))
    }

    override fun onDestroy() {
        if (multicastLock?.isHeld == true) multicastLock?.release()
        super.onDestroy()
    }
}

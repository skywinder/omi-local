package org.omilocal.next

import android.content.pm.ApplicationInfo
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.time.ZoneId

class MainActivity : FlutterActivity() {
    private var cv1: NextCV1? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        cv1 = NextCV1(applicationContext, engine.dartExecutor.binaryMessenger) { awake ->
            val flag = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            if (awake) window.addFlags(flag) else window.clearFlags(flag)
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.omilocal.next/capture")
            .setMethodCallHandler { call, result ->
                val service = when (call.method) {
                    "startPhone", "stopPhone" -> NextPhoneCaptureService::class.java
                    "startCv1", "stopCv1" -> NextCv1CaptureService::class.java
                    else -> {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                }
                val intent = Intent(this, service)
                try {
                    if (call.method.startsWith("start")) startForegroundService(intent) else stopService(intent)
                    result.success(null)
                } catch (_: IllegalStateException) {
                    result.error("foreground_capture_unavailable", null, null)
                } catch (_: SecurityException) {
                    result.error("foreground_capture_unavailable", null, null)
                }
            }
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.omilocal.next/reminders")
            .setMethodCallHandler { call, result ->
                val reminders = NextReminders(applicationContext)
                try {
                    when (call.method) {
                        "timezone" -> result.success(ZoneId.systemDefault().id)
                        "status" -> result.success(reminders.status())
                        "replace" -> result.success(reminders.replace(call.arguments))
                        "clear" -> {
                            reminders.clear()
                            result.success(null)
                        }
                        "exactSettings" -> {
                            startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    result.error("local_task_reminders_unavailable", null, null)
                }
            }
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.omilocal.next/environment")
            .setMethodCallHandler { call, result ->
                if (call.method != "takeLocalMacSettings") {
                    result.notImplemented()
                } else {
                    result.success(takeDebugPreset()?.let { mapOf("server_presets_b64" to it) })
                }
            }
    }

    override fun cleanUpFlutterEngine(engine: FlutterEngine) {
        stopService(Intent(this, NextPhoneCaptureService::class.java))
        stopService(Intent(this, NextCv1CaptureService::class.java))
        cv1?.dispose()
        cv1 = null
        super.cleanUpFlutterEngine(engine)
    }

    private fun takeDebugPreset(): String? {
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) return null
        val preset = File(cacheDir, "omilocal-next-server-preset.b64")
        if (!preset.isFile) return null
        return try {
            if (preset.length() !in 1..43692) null else preset.readText(Charsets.US_ASCII)
        } finally {
            preset.delete()
        }
    }
}

package org.omilocal.next

import android.content.pm.ApplicationInfo
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.omilocal.next/environment")
            .setMethodCallHandler { call, result ->
                if (call.method != "takeLocalMacSettings") {
                    result.notImplemented()
                } else {
                    result.success(takeDebugPreset()?.let { mapOf("server_presets_b64" to it) })
                }
            }
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

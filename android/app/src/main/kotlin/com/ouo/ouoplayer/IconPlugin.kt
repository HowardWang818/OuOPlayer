package com.ouo.ouoplayer

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 設定 → 關於與更新 → App 圖示: switches the home screen entry between the
 * dark and the light icon (two activity-aliases of MainActivity, one enabled).
 */
class IconPlugin(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val dark = ComponentName(context, "${context.packageName}.DarkIcon")
    private val light = ComponentName(context, "${context.packageName}.LightIcon")

    init {
        MethodChannel(messenger, "ouo/icon").setMethodCallHandler(this)
    }

    private fun enabled(c: ComponentName, default: Boolean): Boolean =
        when (context.packageManager.getComponentEnabledSetting(c)) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED -> false
            else -> default
        }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isLight" -> result.success(enabled(light, false) && !enabled(dark, true))
            "setLight" -> {
                val on = call.arguments == true
                val pm = context.packageManager
                // The new entry first, so there is always one on the home screen.
                val (show, hide) = if (on) light to dark else dark to light
                try {
                    pm.setComponentEnabledSetting(show, PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
                    pm.setComponentEnabledSetting(hide, PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("icon", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }
}

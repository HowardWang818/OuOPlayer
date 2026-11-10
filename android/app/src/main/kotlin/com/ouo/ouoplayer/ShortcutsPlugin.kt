package com.ouo.ouoplayer

import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Long-press shortcuts on the home-screen icon: 隨機播放全部, 繼續播放, 搜尋.
 * Set at runtime (not in XML) so the demo copy's package name works too.
 * A tapped shortcut opens MainActivity with [EXTRA]; Dart asks for it.
 */
class ShortcutsPlugin(private val context: Context, messenger: BinaryMessenger) {
    companion object {
        const val EXTRA = "ouo_shortcut"
    }

    private val channel = MethodChannel(messenger, "ouo/shortcuts")
    var pending: String? = null

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "initial") {
                result.success(pending)
                pending = null
            } else {
                result.notImplemented()
            }
        }
        publish()
    }

    fun deliver(action: String) = channel.invokeMethod("open", action)

    private fun publish() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return
        val manager = context.getSystemService(ShortcutManager::class.java) ?: return
        fun item(id: String, label: String, icon: Int) = ShortcutInfo.Builder(context, id)
            .setShortLabel(label)
            .setIcon(Icon.createWithResource(context, icon))
            .setIntent(
                Intent(context, MainActivity::class.java)
                    .setAction(Intent.ACTION_VIEW)
                    .putExtra(EXTRA, id)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            )
            .build()
        try {
            manager.dynamicShortcuts = listOf(
                item("shuffle", "隨機播放全部", R.drawable.shortcut_shuffle),
                item("resume", "繼續播放", R.drawable.shortcut_play),
                item("search", "搜尋", R.drawable.shortcut_search),
            )
        } catch (_: Exception) {
        }
    }
}

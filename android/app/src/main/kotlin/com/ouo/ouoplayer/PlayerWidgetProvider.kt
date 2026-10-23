package com.ouo.ouoplayer

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.os.SystemClock
import android.view.KeyEvent
import android.widget.RemoteViews
import com.ryanheise.audioservice.MediaButtonReceiver
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Home screen widget: cover, title, artist and previous / play-pause / next.
 * The buttons send media key events to audio_service, like headset buttons.
 * What is playing comes from Dart (PlayerWidgetPlugin) and is kept in
 * preferences so the widget can redraw while the app is closed.
 */
class PlayerWidgetProvider : AppWidgetProvider() {
    companion object {
        private const val PREFS = "ouo_widget"

        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, PlayerWidgetProvider::class.java))
            if (ids.isNotEmpty()) manager.updateAppWidget(ids, views(context))
        }

        fun save(context: Context, title: String?, artist: String?, art: String?, playing: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("title", title)
                .putString("artist", artist)
                .putString("art", art)
                .putBoolean("playing", playing)
                .apply()
            refresh(context)
        }

        private fun views(context: Context): RemoteViews {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val v = RemoteViews(context.packageName, R.layout.widget_player)
            v.setTextViewText(R.id.widget_title, prefs.getString("title", null) ?: "OuOPlayer")
            v.setTextViewText(R.id.widget_artist, prefs.getString("artist", null) ?: "沒有播放中的歌曲")
            v.setImageViewResource(
                R.id.widget_play,
                if (prefs.getBoolean("playing", false)) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
            )
            val art = prefs.getString("art", null)?.let { loadArt(it) }
            if (art != null) v.setImageViewBitmap(R.id.widget_art, art) else v.setImageViewResource(R.id.widget_art, R.mipmap.ic_launcher)

            val open = PendingIntent.getActivity(
                context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            v.setOnClickPendingIntent(R.id.widget_art, open)
            v.setOnClickPendingIntent(R.id.widget_text, open)
            v.setOnClickPendingIntent(R.id.widget_prev, mediaKey(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS))
            v.setOnClickPendingIntent(R.id.widget_play, mediaKey(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
            v.setOnClickPendingIntent(R.id.widget_next, mediaKey(context, KeyEvent.KEYCODE_MEDIA_NEXT))
            return v
        }

        private fun mediaKey(context: Context, code: Int): PendingIntent {
            val now = SystemClock.uptimeMillis()
            val intent = Intent(Intent.ACTION_MEDIA_BUTTON)
                .setClass(context, MediaButtonReceiver::class.java)
                .putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0))
            return PendingIntent.getBroadcast(context, code, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }

        /** Covers are local files (the art cache); scaled down to widget size. */
        private fun loadArt(path: String) = try {
            if (!File(path).exists()) null else {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(path, bounds)
                var sample = 1
                while (bounds.outWidth / (sample * 2) >= 192) sample *= 2
                BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
            }
        } catch (_: Exception) {
            null
        }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        manager.updateAppWidget(ids, views(context))
    }
}

/** Dart → widget: the current song and whether it is playing. */
class PlayerWidgetPlugin(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "ouo/widget").also { it.setMethodCallHandler(this) }

    override fun onMethodCall(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        if (call.method != "update") return result.notImplemented()
        PlayerWidgetProvider.save(
            context,
            call.argument<String>("title"),
            call.argument<String>("artist"),
            call.argument<String>("art"),
            call.argument<Boolean>("playing") ?: false,
        )
        result.success(null)
    }
}

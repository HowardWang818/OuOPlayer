package com.ouo.ouoplayer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps OuOPlayer alive while downloads run, including after the app is
 * swiped away, and shows their progress in a notification.
 */
class DownloadForegroundService : Service() {
    companion object {
        private const val CHANNEL = "com.ouo.ouoplayer.downloads"
        private const val NOTIFICATION_ID = 7001
        private const val DONE_ID = 7002
        const val EXTRA_OPEN = "ouo_open"
        const val OPEN_DOWNLOADS = "downloads"
        const val CANCEL_ALL = "cancel_downloads"

        @Volatile
        private var running = false
        private var title = ""
        private var text = ""
        private var progress = -1

        /** Show or update progress; starts the service on the first call. */
        fun update(context: Context, title: String, text: String, progress: Int) {
            this.title = title
            this.text = text
            this.progress = progress
            if (running) {
                // Already in the foreground: just refresh the notification. Starting
                // the service again isn't allowed once the app is in the background.
                manager(context).notify(NOTIFICATION_ID, build(context))
                return
            }
            try {
                val intent = Intent(context, DownloadForegroundService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent) else context.startService(intent)
            } catch (_: Exception) {
                // Refused (e.g. app already in the background): downloads still run while the process lives.
            }
        }

        /** All downloads finished: stop, and leave a dismissible summary if [doneText] is given. */
        fun stop(context: Context, doneText: String?) {
            context.stopService(Intent(context, DownloadForegroundService::class.java))
            running = false
            if (doneText != null) {
                ensureChannel(context)
                manager(context).notify(DONE_ID, builder(context)
                    .setSmallIcon(android.R.drawable.stat_sys_download_done)
                    .setContentTitle("OuOPlayer 下載完成")
                    .setContentText(doneText)
                    .setContentIntent(openIntent(context, OPEN_DOWNLOADS, 1))
                    .setAutoCancel(true)
                    .build())
            }
        }

        private fun manager(context: Context) = context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager(context).createNotificationChannel(NotificationChannel(CHANNEL, "下載", NotificationManager.IMPORTANCE_LOW))
            }
        }

        private fun builder(context: Context): Notification.Builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(context, CHANNEL)
            else @Suppress("DEPRECATION") Notification.Builder(context)

        /** Opens the app on the downloads page (or asks to cancel everything). */
        private fun openIntent(context: Context, action: String, requestCode: Int): PendingIntent {
            val intent = Intent(context, MainActivity::class.java)
                .putExtra(EXTRA_OPEN, action)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)
            return PendingIntent.getActivity(context, requestCode, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }

        private fun build(context: Context): Notification {
            ensureChannel(context)
            val cancel = Notification.Action.Builder(null, "全部取消", openIntent(context, CANCEL_ALL, 2)).build()
            return builder(context)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(title.ifEmpty { "OuOPlayer 正在下載" })
                .setContentText(text)
                .setProgress(100, progress.coerceIn(0, 100), progress < 0)
                .setContentIntent(openIntent(context, OPEN_DOWNLOADS, 1))
                .addAction(cancel)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = build(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        running = true
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }
}

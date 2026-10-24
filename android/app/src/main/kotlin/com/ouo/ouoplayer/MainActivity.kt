package com.ouo.ouoplayer

import android.content.Intent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var ytDlp: YtDlpPlugin? = null
    private var bluetooth: BluetoothPlugin? = null
    private var normalizer: NormalizerPlugin? = null
    private var trash: TrashPlugin? = null
    private var downloads: DownloadNotifierPlugin? = null
    private var widget: PlayerWidgetPlugin? = null
    private var share: MethodChannel? = null
    private var pendingShare: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        ytDlp = YtDlpPlugin(applicationContext, messenger)
        bluetooth = BluetoothPlugin(applicationContext, messenger)
        normalizer = NormalizerPlugin(messenger)
        trash = TrashPlugin(applicationContext, messenger).also { it.activity = this }
        widget = PlayerWidgetPlugin(applicationContext, messenger)
        UpdatePlugin(applicationContext, messenger)
        // Download notification: progress from Dart; taps open the downloads page.
        downloads = DownloadNotifierPlugin(applicationContext, messenger).also {
            it.pendingAction = intent?.getStringExtra(DownloadForegroundService.EXTRA_OPEN)
        }
        // Mobile data check before downloads.
        MethodChannel(messenger, "ouo/network").setMethodCallHandler { call, result ->
            if (call.method != "mobileData") return@setMethodCallHandler result.notImplemented()
            val cm = getSystemService(android.net.ConnectivityManager::class.java)
            val caps = cm?.getNetworkCapabilities(cm.activeNetwork)
            result.success(
                caps != null &&
                    caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) &&
                    !caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) &&
                    !caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET),
            )
        }
        // Lyrics can keep the screen on while they are shown.
        MethodChannel(messenger, "ouo/screen").setMethodCallHandler { call, result ->
            if (call.method != "keepOn") return@setMethodCallHandler result.notImplemented()
            if (call.arguments == true) {
                window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
            result.success(null)
        }
        // Links shared from other apps (YouTube, browser…) go to the downloader.
        pendingShare = sharedText(intent)
        share = MethodChannel(messenger, "ouo/share").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "initialText") {
                    result.success(pendingShare)
                    pendingShare = null
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        sharedText(intent)?.let { share?.invokeMethod("shared", it) }
        intent.getStringExtra(DownloadForegroundService.EXTRA_OPEN)?.let { downloads?.deliver(it) }
    }

    @Deprecated("Needed for the system delete confirmation (MediaStore trash request)")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (trash?.onActivityResult(requestCode, resultCode) == true) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun sharedText(intent: Intent?): String? =
        if (intent?.action == Intent.ACTION_SEND) intent.getStringExtra(Intent.EXTRA_TEXT) else null

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bluetooth?.dispose()
        trash?.activity = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

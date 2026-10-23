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
    private var share: MethodChannel? = null
    private var pendingShare: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        ytDlp = YtDlpPlugin(applicationContext, messenger)
        bluetooth = BluetoothPlugin(applicationContext, messenger)
        normalizer = NormalizerPlugin(messenger)
        trash = TrashPlugin(applicationContext, messenger).also { it.activity = this }
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

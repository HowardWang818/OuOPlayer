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
    private var backupTree: BackupTreePlugin? = null
    private var downloads: DownloadNotifierPlugin? = null
    private var widget: PlayerWidgetPlugin? = null
    private var share: MethodChannel? = null
    private var shortcuts: ShortcutsPlugin? = null
    private var pendingShare: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        ytDlp = YtDlpPlugin(applicationContext, messenger)
        bluetooth = BluetoothPlugin(applicationContext, messenger)
        normalizer = NormalizerPlugin(messenger)
        trash = TrashPlugin(applicationContext, messenger).also { it.activity = this }
        backupTree = BackupTreePlugin(applicationContext, messenger).also { it.activity = this }
        widget = PlayerWidgetPlugin(applicationContext, messenger)
        UpdatePlugin(applicationContext, messenger)
        IconPlugin(applicationContext, messenger)
        CarConnectionPlugin(applicationContext, messenger)
        shortcuts = ShortcutsPlugin(applicationContext, messenger).also {
            it.pending = intent?.getStringExtra(ShortcutsPlugin.EXTRA)
        }
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
        // 回報問題: the phone model and Android version for the report.
        MethodChannel(messenger, "ouo/device").setMethodCallHandler { call, result ->
            if (call.method != "info") return@setMethodCallHandler result.notImplemented()
            result.success(
                mapOf(
                    "model" to "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}",
                    "os" to "Android ${android.os.Build.VERSION.RELEASE} (API ${android.os.Build.VERSION.SDK_INT})",
                ),
            )
        }
        // 不受省電限制: off the battery optimisation list, so power saving
        // doesn't cut the network while the app is in the background.
        MethodChannel(messenger, "ouo/power").setMethodCallHandler { call, result ->
            val power = getSystemService(android.os.PowerManager::class.java)
            when (call.method) {
                "unrestricted" -> result.success(power?.isIgnoringBatteryOptimizations(packageName) == true)
                "ask" -> try {
                    @android.annotation.SuppressLint("BatteryLife")
                    val intent = Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, android.net.Uri.parse("package:$packageName"))
                    startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("power", e.message, null)
                }
                else -> result.notImplemented()
            }
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
        // 打開資料夾 (1.20.9): the system Files app at a folder of the phone's
        // storage. Not every phone's Files app takes it: false then.
        MethodChannel(messenger, "ouo/folder").setMethodCallHandler { call, result ->
            if (call.method != "open") return@setMethodCallHandler result.notImplemented()
            val path = call.argument<String>("path") ?: return@setMethodCallHandler result.success(false)
            val root = android.os.Environment.getExternalStorageDirectory().absolutePath
            if (!path.startsWith(root)) return@setMethodCallHandler result.success(false)
            val rel = path.removePrefix(root).trim('/')
            val uri = android.provider.DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", "primary:$rel")
            val open = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, android.provider.DocumentsContract.Document.MIME_TYPE_DIR)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            try {
                startActivity(open)
                result.success(true)
            } catch (e: Exception) {
                result.success(false)
            }
        }
        // Links shared from other apps (YouTube, browser…) go to the downloader.
        pendingShare = sharedText(intent)
        share = MethodChannel(messenger, "ouo/share").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "initialText") {
                    result.success(pendingShare)
                    pendingShare = null
                } else if (call.method == "image") {
                    // 分享 card: a PNG in cache/share, sent to the app the user picks.
                    try {
                        val file = java.io.File(call.argument<String>("path")!!)
                        val uri = androidx.core.content.FileProvider.getUriForFile(this@MainActivity, "$packageName.updates", file)
                        val send = Intent(Intent.ACTION_SEND)
                            .setType("image/png")
                            .putExtra(Intent.EXTRA_STREAM, uri)
                            .putExtra(Intent.EXTRA_TEXT, call.argument<String>("text"))
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        send.clipData = android.content.ClipData.newRawUri(null, uri)
                        startActivity(Intent.createChooser(send, null))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("share", e.message, null)
                    }
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
        intent.getStringExtra(ShortcutsPlugin.EXTRA)?.let { shortcuts?.deliver(it) }
    }

    @Deprecated("Needed for the system delete confirmation (MediaStore trash request)")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (trash?.onActivityResult(requestCode, resultCode) == true) return
        if (backupTree?.onActivityResult(requestCode, resultCode, data) == true) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun sharedText(intent: Intent?): String? =
        if (intent?.action == Intent.ACTION_SEND) intent.getStringExtra(Intent.EXTRA_TEXT) else null

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bluetooth?.dispose()
        trash?.activity = null
        backupTree?.activity = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

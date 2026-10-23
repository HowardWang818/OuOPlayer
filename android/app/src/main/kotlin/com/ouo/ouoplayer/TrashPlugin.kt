package com.ouo.ouoplayer

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Moves a music file to the system trash (Android 11+), so a deletion can be
 * undone from the Files app for about 30 days. Files OuOPlayer created are
 * trashed directly; for others Android shows its own confirmation dialog.
 */
class TrashPlugin(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    companion object {
        const val REQUEST_CODE = 4711
    }

    private val method = MethodChannel(messenger, "ouo/trash")
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    var activity: Activity? = null

    init {
        method.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "trash") return result.notImplemented()
        val path = call.argument<String>("path") ?: return result.error("args", "path missing", null)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            // No system trash before Android 11.
            return result.success(File(path).delete())
        }
        // The scanner returns the file's MediaStore URI, indexing it first if needed.
        MediaScannerConnection.scanFile(context, arrayOf(path), null) { _, uri ->
            main.post { trash(uri, path, result) }
        }
    }

    private fun trash(uri: Uri?, path: String, result: MethodChannel.Result) {
        if (uri == null) return result.error("notFound", "系統找不到這個檔案", null)
        try {
            // Allowed without asking for files this app created (e.g. downloads).
            val values = ContentValues().apply { put(MediaStore.MediaColumns.IS_TRASHED, 1) }
            if (context.contentResolver.update(uri, values, null, null) > 0) return result.success(true)
        } catch (_: SecurityException) {
            // Not our file: fall through to the system confirmation dialog.
        }
        val act = activity ?: return result.error("noActivity", "無法顯示確認視窗", null)
        try {
            val request = MediaStore.createTrashRequest(context.contentResolver, listOf(uri), true)
            pending?.success(false)
            pending = result
            act.startIntentSenderForResult(request.intentSender, REQUEST_CODE, null, 0, 0, 0)
        } catch (e: Exception) {
            pending = null
            result.error("trash", e.message, null)
        }
    }

    /** Called from MainActivity with the result of the system dialog. */
    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != REQUEST_CODE) return false
        pending?.success(resultCode == Activity.RESULT_OK)
        pending = null
        return true
    }
}

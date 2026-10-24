package com.ouo.ouoplayer

import android.app.Activity
import android.content.ContentValues
import android.content.Context
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
 * Moves music files to the system trash (Android 11+), so a deletion can be
 * undone from the Files app for about 30 days, or ("delete") removes them
 * for good. Files OuOPlayer created are handled directly; for the others
 * Android shows one confirmation dialog.
 */
class TrashPlugin(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    companion object {
        const val REQUEST_CODE = 4711
    }

    private val method = MethodChannel(messenger, "ouo/trash")
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null

    /** Runs once the user allowed a write request, before [pending] answers. */
    private var afterGrant: (() -> Unit)? = null
    var activity: Activity? = null

    init {
        method.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "overwrite") return overwrite(call, result)
        if (call.method == "move") return move(call, result)
        // 媒體管理 (Android 12+): once allowed, trash / delete / write
        // requests go through without the system's confirmation dialog.
        if (call.method == "canManageMedia") {
            return result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && MediaStore.canManageMedia(context))
        }
        if (call.method == "openManageMedia") {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return result.success(false)
            val intent = android.content.Intent(android.provider.Settings.ACTION_REQUEST_MANAGE_MEDIA, Uri.parse("package:${context.packageName}"))
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            return try {
                context.startActivity(intent)
                result.success(true)
            } catch (e: Exception) {
                result.error("settings", e.message, null)
            }
        }
        if (call.method != "trash" && call.method != "delete") return result.notImplemented()
        val forever = call.method == "delete"
        val paths = call.argument<List<String>>("paths") ?: return result.error("args", "paths missing", null)
        if (paths.isEmpty()) return result.success(true)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            // No system trash (and no scoped storage) before Android 11.
            return result.success(paths.all { File(it).delete() })
        }
        if (forever) {
            // Files this app created can simply be deleted; ask only for the rest.
            val rest = paths.filter { !File(it).delete() && File(it).exists() }
            if (rest.isEmpty()) return result.success(true)
            return withUris(rest) { uris -> deleteForever(uris, result) }
        }
        withUris(paths) { uris -> trash(uris, result) }
    }

    /**
     * Moves music files (資料夾 →「移到資料夾」/「重新命名」). Files this app
     * may write are renamed directly; the others are moved through MediaStore
     * (RELATIVE_PATH), after one system confirmation unless 媒體管理 is on.
     */
    private fun move(call: MethodCall, result: MethodChannel.Result) {
        val moves = call.argument<List<Map<String, String>>>("moves") ?: return result.error("args", "moves missing", null)
        val rest = moves.filter { m ->
            val to = File(m["to"]!!)
            to.parentFile?.mkdirs()
            !(try { File(m["from"]!!).renameTo(to) } catch (_: Exception) { false })
        }
        if (rest.isEmpty()) return result.success(true)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return result.error("move", "無法移動檔案", null)
        val root = android.os.Environment.getExternalStorageDirectory().absolutePath.trimEnd('/') + "/"
        if (rest.any { !it["to"]!!.startsWith(root) }) return result.error("move", "只能在手機內部儲存空間裡移動", null)
        withPathUris(rest.map { it["from"]!! }) { uris ->
            val todo = rest.mapNotNull { m -> uris[m["from"]]?.let { it to m["to"]!! } }
            if (todo.size < rest.size) return@withPathUris result.error("notFound", "系統找不到部分檔案", null)
            fun values(to: String) = ContentValues().apply {
                put(MediaStore.MediaColumns.RELATIVE_PATH, File(to).parent!!.removePrefix(root).trimEnd('/') + "/")
                put(MediaStore.MediaColumns.DISPLAY_NAME, File(to).name)
            }
            val needGrant = todo.filter { (uri, to) ->
                try {
                    context.contentResolver.update(uri, values(to), null, null) == 0
                } catch (_: SecurityException) {
                    true
                }
            }
            if (needGrant.isEmpty()) return@withPathUris result.success(true)
            val act = activity ?: return@withPathUris result.error("noActivity", "無法顯示確認視窗", null)
            try {
                val request = MediaStore.createWriteRequest(context.contentResolver, needGrant.map { it.first })
                pending?.success(false)
                pending = result
                afterGrant = {
                    for ((uri, to) in needGrant) {
                        if (context.contentResolver.update(uri, values(to), null, null) == 0) throw Exception("無法移動 ${File(to).name}")
                    }
                }
                act.startIntentSenderForResult(request.intentSender, REQUEST_CODE, null, 0, 0, 0)
            } catch (e: Exception) {
                pending = null
                afterGrant = null
                result.error("move", e.message, null)
            }
        }
    }

    /** Like [withUris], keyed by path. */
    private fun withPathUris(paths: List<String>, then: (Map<String, Uri>) -> Unit) {
        val uris = mutableMapOf<String, Uri>()
        var count = 0
        MediaScannerConnection.scanFile(context, paths.toTypedArray(), null) { path, uri ->
            val done = synchronized(uris) {
                if (uri != null) uris[path] = uri
                ++count == paths.size
            }
            if (done) main.post { then(uris) }
        }
    }

    /** The scanner returns each file's MediaStore URI, indexing it first if needed. */
    private fun withUris(paths: List<String>, then: (List<Uri>) -> Unit) {
        val uris = mutableListOf<Uri?>()
        MediaScannerConnection.scanFile(context, paths.toTypedArray(), null) { _, uri ->
            val done = synchronized(uris) {
                uris.add(uri)
                uris.size == paths.size
            }
            if (done) main.post { then(uris.filterNotNull()) }
        }
    }

    /**
     * Replaces a music file's contents with [temp] (edited tags). Files this
     * app created are written directly; for the others Android asks first.
     */
    private fun overwrite(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path") ?: return result.error("args", "path missing", null)
        val temp = call.argument<String>("temp") ?: return result.error("args", "temp missing", null)
        try {
            File(temp).copyTo(File(path), overwrite = true)
            return result.success(true)
        } catch (e: Exception) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return result.error("write", e.message, null)
        }
        withUris(listOf(path)) { uris ->
            val uri = uris.firstOrNull() ?: return@withUris result.error("notFound", "系統找不到這個檔案", null)
            val act = activity ?: return@withUris result.error("noActivity", "無法顯示確認視窗", null)
            try {
                val request = MediaStore.createWriteRequest(context.contentResolver, listOf(uri))
                pending?.success(false)
                pending = result
                afterGrant = {
                    context.contentResolver.openOutputStream(uri, "wt")!!.use { out -> File(temp).inputStream().use { it.copyTo(out) } }
                }
                act.startIntentSenderForResult(request.intentSender, REQUEST_CODE, null, 0, 0, 0)
            } catch (e: Exception) {
                pending = null
                afterGrant = null
                result.error("write", e.message, null)
            }
        }
    }

    private fun deleteForever(uris: List<Uri>, result: MethodChannel.Result) {
        if (uris.isEmpty()) return result.error("notFound", "系統找不到這些檔案", null)
        val act = activity ?: return result.error("noActivity", "無法顯示確認視窗", null)
        try {
            val request = MediaStore.createDeleteRequest(context.contentResolver, uris)
            pending?.success(false)
            pending = result
            act.startIntentSenderForResult(request.intentSender, REQUEST_CODE, null, 0, 0, 0)
        } catch (e: Exception) {
            pending = null
            result.error("delete", e.message, null)
        }
    }

    private fun trash(uris: List<Uri>, result: MethodChannel.Result) {
        if (uris.isEmpty()) return result.error("notFound", "系統找不到這些檔案", null)
        val needConfirm = mutableListOf<Uri>()
        val values = ContentValues().apply { put(MediaStore.MediaColumns.IS_TRASHED, 1) }
        for (uri in uris) {
            try {
                // Allowed without asking for files this app created (e.g. downloads).
                if (context.contentResolver.update(uri, values, null, null) == 0) needConfirm.add(uri)
            } catch (_: SecurityException) {
                needConfirm.add(uri)
            }
        }
        if (needConfirm.isEmpty()) return result.success(true)
        val act = activity ?: return result.error("noActivity", "無法顯示確認視窗", null)
        try {
            val request = MediaStore.createTrashRequest(context.contentResolver, needConfirm, true)
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
        val result = pending
        val after = afterGrant
        pending = null
        afterGrant = null
        if (resultCode != Activity.RESULT_OK || after == null) {
            result?.success(resultCode == Activity.RESULT_OK)
            return true
        }
        Thread {
            val error = try {
                after()
                null
            } catch (e: Exception) {
                e.message ?: "寫入失敗"
            }
            main.post { if (error == null) result?.success(true) else result?.error("write", error, null) }
        }.start()
        return true
    }
}

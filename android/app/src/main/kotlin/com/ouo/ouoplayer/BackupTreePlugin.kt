package com.ouo.ouoplayer

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The backup folder the user picked (system folder picker), remembered with
 * a lasting permission. Android 11+ only lets an app list the files in a
 * shared folder that its current install created; a picked folder shows all
 * of them, so backups left by an earlier install can be restored after a
 * reinstall by picking the same folder again.
 */
class BackupTreePlugin(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    companion object {
        const val REQUEST_CODE = 4712
        private const val FLAGS = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    }

    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    var activity: Activity? = null

    init {
        MethodChannel(messenger, "ouo/backup_tree").setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> pick(result)
            "allowed" -> {
                val tree = call.argument<String>("tree") ?: return result.success(false)
                result.success(context.contentResolver.persistedUriPermissions.any { it.uri.toString() == tree && it.isWritePermission })
            }
            "label" -> result.success(label(Uri.parse(call.argument<String>("tree")!!)))
            "list" -> background(result) { list(Uri.parse(call.argument<String>("tree")!!)) }
            "write" -> background(result) {
                write(Uri.parse(call.argument<String>("tree")!!), call.argument<String>("name")!!, call.argument<ByteArray>("bytes")!!)
            }
            "read" -> background(result) {
                context.contentResolver.openInputStream(Uri.parse(call.argument<String>("doc")!!))!!.use { it.readBytes() }
            }
            "delete" -> background(result) {
                DocumentsContract.deleteDocument(context.contentResolver, Uri.parse(call.argument<String>("doc")!!))
            }
            else -> result.notImplemented()
        }
    }

    private fun pick(result: MethodChannel.Result) {
        val a = activity ?: return result.error("activity", "no activity", null)
        pending?.success(null)
        pending = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(FLAGS or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        // Opens at Documents/OuOPlayer/備份, where backups have always gone.
        intent.putExtra(
            DocumentsContract.EXTRA_INITIAL_URI,
            DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", "primary:Documents/OuOPlayer/備份"),
        )
        try {
            @Suppress("DEPRECATION")
            a.startActivityForResult(intent, REQUEST_CODE)
        } catch (e: Exception) {
            pending = null
            result.error("picker", e.message, null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pending ?: return true
        pending = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) return true.also { result.success(null) }
        try {
            context.contentResolver.takePersistableUriPermission(tree, FLAGS)
            result.success(tree.toString())
        } catch (e: Exception) {
            result.error("permission", e.message, null)
        }
        return true
    }

    /** "primary:Documents/OuOPlayer/備份" → /storage/emulated/0/Documents/OuOPlayer/備份. */
    private fun label(tree: Uri): String {
        val id = DocumentsContract.getTreeDocumentId(tree)
        val (volume, path) = id.split(":", limit = 2).let { it[0] to it.getOrElse(1) { "" } }
        return if (volume == "primary") "/storage/emulated/0/$path".trimEnd('/') else "$volume/$path"
    }

    private fun list(tree: Uri): List<Map<String, Any?>> {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val cols = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        val out = mutableListOf<Map<String, Any?>>()
        context.contentResolver.query(children, cols, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                if (c.getString(4) == DocumentsContract.Document.MIME_TYPE_DIR) continue
                out.add(
                    mapOf(
                        "doc" to DocumentsContract.buildDocumentUriUsingTree(tree, c.getString(0)).toString(),
                        "name" to c.getString(1),
                        "modified" to c.getLong(2),
                        "size" to c.getLong(3),
                    ),
                )
            }
        }
        return out
    }

    private fun write(tree: Uri, name: String, bytes: ByteArray): String {
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val doc = DocumentsContract.createDocument(context.contentResolver, parent, "application/json", name)
            ?: throw IllegalStateException("cannot create $name")
        context.contentResolver.openOutputStream(doc, "wt")!!.use { it.write(bytes) }
        return doc.toString()
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        Thread {
            try {
                val value = work()
                main.post { result.success(if (value is Unit) null else value) }
            } catch (e: Exception) {
                main.post { result.error("backup_tree", e.message, null) }
            }
        }.start()
    }
}

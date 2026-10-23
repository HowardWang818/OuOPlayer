package com.ouo.ouoplayer

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Dart reports download progress here ("update" / "stop"); taps on the
 * notification ("open downloads" / "cancel all") are sent back to Dart.
 */
class DownloadNotifierPlugin(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val method = MethodChannel(messenger, "ouo/downloads")

    /** Notification action that launched the app, until Dart asks for it. */
    var pendingAction: String? = null

    init {
        method.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "update" -> {
                DownloadForegroundService.update(
                    context,
                    call.argument<String>("title") ?: "",
                    call.argument<String>("text") ?: "",
                    call.argument<Int>("progress") ?: -1,
                )
                result.success(null)
            }
            "stop" -> {
                DownloadForegroundService.stop(context, call.argument<String>("doneText"))
                result.success(null)
            }
            "initialAction" -> {
                result.success(pendingAction)
                pendingAction = null
            }
            else -> result.notImplemented()
        }
    }

    /** Forward a notification tap to Dart (app already running). */
    fun deliver(action: String) = method.invokeMethod("action", action)
}

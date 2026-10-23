package com.ouo.ouoplayer

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Bridges youtubedl-android (bundled Python + yt-dlp + ffmpeg) to Dart.
 * Raw output lines are forwarded; parsing happens in ytdlp_downloader.dart.
 */
class YtDlpPlugin(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val method = MethodChannel(messenger, "ouo/ytdlp")
    private val events = EventChannel(messenger, "ouo/ytdlp/events")
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newCachedThreadPool()
    private val active = ConcurrentHashMap.newKeySet<String>()
    private var sink: EventChannel.EventSink? = null

    @Volatile
    private var initialized = false

    init {
        method.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    private fun ensureInit() {
        synchronized(this) {
            if (!initialized) {
                YoutubeDL.getInstance().init(context)
                FFmpeg.getInstance().init(context)
                initialized = true
            }
        }
    }

    private fun emit(data: Map<String, Any?>) = main.post { sink?.success(data) }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        executor.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error("ytdlp", e.message ?: e.toString(), null) }
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> background(result) { ensureInit(); true }
            "version" -> background(result) { ensureInit(); YoutubeDL.getInstance().version(context) }
            "update" -> background(result) {
                ensureInit()
                when (YoutubeDL.getInstance().updateYoutubeDL(context, YoutubeDL.UpdateChannel.STABLE)) {
                    YoutubeDL.UpdateStatus.ALREADY_UP_TO_DATE -> "已是最新版本"
                    else -> "已更新到 ${YoutubeDL.getInstance().version(context)}"
                }
            }
            "download" -> {
                val id = call.argument<String>("id")!!
                val url = call.argument<String>("url")!!
                val args = call.argument<List<String>>("args") ?: emptyList()
                result.success(true)
                startDownload(id, url, args)
            }
            "cancel" -> {
                val id = call.argument<String>("id")!!
                active.remove(id)
                YoutubeDL.getInstance().destroyProcessById(id)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun startDownload(id: String, url: String, args: List<String>) {
        active.add(id)
        executor.execute {
            try {
                ensureInit()
                val request = YoutubeDLRequest(url)
                var i = 0
                while (i < args.size) {
                    val opt = args[i]
                    val next = args.getOrNull(i + 1)
                    if (next != null && !next.startsWith("-")) {
                        request.addOption(opt, next)
                        i += 2
                    } else {
                        request.addOption(opt)
                        i += 1
                    }
                }
                val response = YoutubeDL.getInstance().execute(request, id) { _, _, line ->
                    emit(mapOf("id" to id, "type" to "line", "line" to line))
                }
                emit(mapOf("id" to id, "type" to "done", "success" to (response.exitCode == 0), "out" to response.out, "error" to response.err.lines().lastOrNull { it.contains("ERROR") }))
            } catch (e: YoutubeDL.CanceledException) {
                emit(mapOf("id" to id, "type" to "done", "success" to false, "error" to "已取消"))
            } catch (e: Throwable) {
                emit(mapOf("id" to id, "type" to "done", "success" to false, "error" to (e.message ?: e.toString()).lines().lastOrNull { it.isNotBlank() }))
            } finally {
                active.remove(id)
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }
}

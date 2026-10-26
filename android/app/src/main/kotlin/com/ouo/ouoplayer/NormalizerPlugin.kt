package com.ouo.ouoplayer

import android.media.audiofx.DynamicsProcessing
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Volume normalization, one fixed gain per song (Android 9+): the gain the
 * song's measured loudness calls for, then a limiter that only acts on peaks
 * that would clip. Nothing in between, so a song keeps its own quiet and loud
 * parts (the compressor used before v1.5.0 flattened them).
 *
 * Also measures songs ([LoudnessAnalyzer]) on a background thread.
 */
class NormalizerPlugin(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val method = MethodChannel(messenger, "ouo/normalize")
    private var effect: DynamicsProcessing? = null
    private var sessionId = 0
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init {
        method.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "gain" -> {
                val session = call.argument<Int>("sessionId") ?: 0
                val enabled = call.argument<Boolean>("enabled") ?: false
                val gain = (call.argument<Double>("gainDb") ?: 0.0).toFloat()
                result.success(apply(session, enabled, gain))
            }
            "measure" -> {
                val path = call.argument<String>("path") ?: return result.success(null)
                worker.execute {
                    val r = LoudnessAnalyzer.measure(path)
                    main.post { result.success(r?.let { mapOf("lufs" to it.lufs, "peak" to it.peakDb) }) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun apply(session: Int, enabled: Boolean, gainDb: Float): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P || session == 0) return false
        try {
            if (session != sessionId || effect == null) {
                release()
                effect = create(session)
                sessionId = session
            }
            effect?.setInputGainAllChannelsTo(if (enabled) gainDb else 0f)
            effect?.enabled = enabled
            return effect != null
        } catch (_: Exception) {
            release()
            return false
        }
    }

    private fun create(session: Int): DynamicsProcessing {
        val config = DynamicsProcessing.Config.Builder(
            DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION,
            2, // channels
            false, 0, // pre-EQ
            false, 0, // no compressor
            false, 0, // post-EQ
            true, // limiter
        ).build()
        val fx = DynamicsProcessing(0, session, config)
        // Catches only what would clip: fast attack, short release, at -1 dBFS.
        fx.setLimiterAllChannelsTo(
            DynamicsProcessing.Limiter(true, true, 0, 1f, 60f, 10f, -1f, 0f),
        )
        return fx
    }

    private fun release() {
        effect?.release()
        effect = null
        sessionId = 0
    }
}

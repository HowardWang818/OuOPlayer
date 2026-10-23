package com.ouo.ouoplayer

import android.media.audiofx.DynamicsProcessing
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Volume normalization: a compressor that lifts quiet passages and tames loud
 * ones, followed by a limiter, on the player's audio session (Android 9+).
 */
class NormalizerPlugin(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val method = MethodChannel(messenger, "ouo/normalize")
    private var effect: DynamicsProcessing? = null
    private var sessionId = 0
    private var level = ""

    init {
        method.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "set" -> {
                val session = call.argument<Int>("sessionId") ?: 0
                val enabled = call.argument<Boolean>("enabled") ?: false
                val lvl = call.argument<String>("level") ?: "normal"
                result.success(apply(session, enabled, lvl))
            }
            else -> result.notImplemented()
        }
    }

    private fun apply(session: Int, enabled: Boolean, lvl: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P || session == 0) return false
        try {
            if (session != sessionId || lvl != level) {
                release()
                effect = create(session, lvl)
                sessionId = session
                level = lvl
            }
            effect?.enabled = enabled
            return effect != null
        } catch (_: Exception) {
            release()
            return false
        }
    }

    /** Compressor settings per strength: threshold (dB), ratio, make-up gain (dB). */
    private fun params(lvl: String): Triple<Float, Float, Float> = when (lvl) {
        "quiet" -> Triple(-24f, 2.5f, 3f)
        "loud" -> Triple(-30f, 4f, 12f)
        else -> Triple(-26f, 3f, 8f)
    }

    private fun create(session: Int, lvl: String): DynamicsProcessing {
        val (threshold, ratio, makeUp) = params(lvl)
        val config = DynamicsProcessing.Config.Builder(
            DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION,
            2, // channels
            false, 0, // pre-EQ
            true, 1, // one full-range compressor band
            false, 0, // post-EQ
            true, // limiter
        ).build()
        val fx = DynamicsProcessing(0, session, config)
        fx.setMbcBandAllChannelsTo(
            0,
            DynamicsProcessing.MbcBand(
                true, 20000f, // enabled, cutoff (Hz)
                30f, 400f, // attack, release (ms)
                ratio, threshold, 8f, // ratio, threshold (dB), knee (dB)
                -90f, 1f, // noise gate threshold, expander ratio
                0f, makeUp, // pre-gain, make-up gain (dB)
            ),
        )
        fx.setLimiterAllChannelsTo(
            DynamicsProcessing.Limiter(true, true, 0, 1f, 60f, 10f, -1f, 0f),
        )
        return fx
    }

    private fun release() {
        effect?.release()
        effect = null
        sessionId = 0
        level = ""
    }
}

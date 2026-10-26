package com.ouo.ouoplayer

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.tan

/**
 * A song's integrated loudness (EBU R128 / ITU-R BS.1770, the LUFS Spotify
 * and YouTube use) and sample peak, from decoding the whole file. Used to
 * give every song one fixed gain, so songs play equally loud while each keeps
 * its own quiet and loud parts.
 */
object LoudnessAnalyzer {
    data class Result(val lufs: Double, val peakDb: Double)

    /** Null when the file can't be decoded or is silent. */
    fun measure(path: String): Result? {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            val trackIndex = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: return null
            extractor.selectTrack(trackIndex)
            val format = extractor.getTrackFormat(trackIndex)
            val dec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec = dec
            dec.configure(format, null, null, 0)
            dec.start()

            var meter: Meter? = null
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var encoding = AudioFormat.ENCODING_PCM_16BIT
            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = dec.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val buf = dec.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(buf, 0)
                        if (size < 0) {
                            dec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            dec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = dec.dequeueOutputBuffer(info, 10_000)
                when {
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = dec.outputFormat
                        if (f.containsKey(MediaFormat.KEY_PCM_ENCODING)) encoding = f.getInteger(MediaFormat.KEY_PCM_ENCODING)
                        meter = Meter(f.getInteger(MediaFormat.KEY_SAMPLE_RATE), f.getInteger(MediaFormat.KEY_CHANNEL_COUNT))
                    }
                    outIndex >= 0 -> {
                        if (meter == null) {
                            val f = dec.outputFormat
                            meter = Meter(f.getInteger(MediaFormat.KEY_SAMPLE_RATE), f.getInteger(MediaFormat.KEY_CHANNEL_COUNT))
                        }
                        val out = dec.getOutputBuffer(outIndex)!!.order(ByteOrder.nativeOrder())
                        out.position(info.offset)
                        out.limit(info.offset + info.size)
                        if (encoding == AudioFormat.ENCODING_PCM_FLOAT) {
                            val fb = out.asFloatBuffer()
                            while (fb.hasRemaining()) meter.add(fb.get().toDouble())
                        } else {
                            val sb = out.asShortBuffer()
                            while (sb.hasRemaining()) meter.add(sb.get() / 32768.0)
                        }
                        dec.releaseOutputBuffer(outIndex, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                    }
                }
            }
            return meter?.result()
        } catch (_: Exception) {
            return null
        } finally {
            try {
                codec?.stop()
            } catch (_: Exception) {
            }
            codec?.release()
            extractor.release()
        }
    }

    /** Interleaved samples in; K-weighting, 400 ms blocks every 100 ms, gating. */
    class Meter(rate: Int, private val channels: Int) {
        private val filters = Array(channels) { KWeighting(rate.toDouble()) }
        private val hop = rate / 10 // 100 ms
        private val subBlocks = ArrayList<Double>() // channel-summed mean square per 100 ms
        private var sum = 0.0
        private var count = 0
        private var channel = 0
        private var peak = 0.0

        fun add(sample: Double) {
            peak = max(peak, abs(sample))
            val y = filters[channel].process(sample)
            sum += y * y
            channel++
            if (channel == channels) {
                channel = 0
                count++
                if (count == hop) {
                    subBlocks.add(sum / hop)
                    sum = 0.0
                    count = 0
                }
            }
        }

        fun result(): Result? {
            if (subBlocks.size < 4 || peak <= 0.0) return null
            val blocks = (0..subBlocks.size - 4).map { i -> (subBlocks[i] + subBlocks[i + 1] + subBlocks[i + 2] + subBlocks[i + 3]) / 4 }
            fun loudness(z: Double) = -0.691 + 10 * log10(z)
            val aboveAbsolute = blocks.filter { it > 0 && loudness(it) > -70.0 }
            if (aboveAbsolute.isEmpty()) return null
            val relative = loudness(aboveAbsolute.average()) - 10.0
            val gated = aboveAbsolute.filter { loudness(it) > relative }
            if (gated.isEmpty()) return null
            return Result(loudness(gated.average()), 20 * log10(peak))
        }
    }

    /** BS.1770 pre-filter (high shelf) followed by the RLB high-pass, for any sample rate. */
    class KWeighting(rate: Double) {
        private val b: DoubleArray
        private val a: DoubleArray
        private val hb: DoubleArray
        private val ha: DoubleArray
        private var x1 = 0.0; private var x2 = 0.0; private var y1 = 0.0; private var y2 = 0.0
        private var u1 = 0.0; private var u2 = 0.0; private var v1 = 0.0; private var v2 = 0.0

        init {
            var f0 = 1681.974450955533
            val g = 3.999843853973347
            var q = 0.7071752369554196
            var k = tan(PI * f0 / rate)
            val vh = 10.0.pow(g / 20.0)
            val vb = vh.pow(0.4996667741545416)
            var a0 = 1.0 + k / q + k * k
            b = doubleArrayOf((vh + vb * k / q + k * k) / a0, 2.0 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0)
            a = doubleArrayOf(1.0, 2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0)
            f0 = 38.13547087602444
            q = 0.5003270373238773
            k = tan(PI * f0 / rate)
            a0 = 1.0 + k / q + k * k
            hb = doubleArrayOf(1.0, -2.0, 1.0)
            ha = doubleArrayOf(1.0, 2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0)
        }

        fun process(x: Double): Double {
            val y = b[0] * x + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            val v = hb[0] * y + hb[1] * u1 + hb[2] * u2 - ha[1] * v1 - ha[2] * v2
            u2 = u1; u1 = y; v2 = v1; v1 = v
            return v
        }
    }
}

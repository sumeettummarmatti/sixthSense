package `in`.sixthsense.sixthsense_app

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import java.io.ByteArrayOutputStream

/**
 * 16 kHz mono PCM → AAC-LC at 24 kbps, cut into self-contained ~5 s ADTS clips (~15 KB each).
 * Each clip plays on its own, and clips joined end to end are one valid .aac file (the evidence
 * export just concatenates them). Called from the microphone thread only.
 */
internal class AacChunkEncoder(
    private val clipSeconds: Int = 5,
    private val onClip: (ByteArray) -> Unit,
) {
    private val codec: MediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
    private val info = MediaCodec.BufferInfo()
    private val current = ByteArrayOutputStream()
    private var samplesInClip = 0L
    private var presentationUs = 0L
    private var finished = false

    init {
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, 1)
        format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        format.setInteger(MediaFormat.KEY_BIT_RATE, 24_000)
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16_384)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
    }

    fun feed(samples: ShortArray, count: Int) {
        if (finished) return
        var offset = 0
        while (offset < count) {
            val index = codec.dequeueInputBuffer(10_000)
            if (index < 0) {
                drain()
                continue
            }
            val input = codec.getInputBuffer(index) ?: continue
            input.clear()
            val n = minOf(count - offset, input.remaining() / 2)
            for (i in 0 until n) {
                val s = samples[offset + i].toInt()
                input.put((s and 0xFF).toByte())
                input.put(((s shr 8) and 0xFF).toByte())
            }
            codec.queueInputBuffer(index, 0, n * 2, presentationUs, 0)
            presentationUs += n * 1_000_000L / SAMPLE_RATE
            offset += n
            samplesInClip += n
            drain()
            if (samplesInClip >= clipSeconds * SAMPLE_RATE.toLong()) {
                emit()
                samplesInClip = 0
            }
        }
    }

    /** Flushes what is left as a last (shorter) clip and releases the codec. */
    fun finish() {
        if (finished) return
        finished = true
        try {
            val index = codec.dequeueInputBuffer(10_000)
            if (index >= 0) {
                codec.queueInputBuffer(index, 0, 0, presentationUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            }
            drain(untilEnd = true)
            emit()
        } finally {
            try {
                codec.stop()
            } catch (_: IllegalStateException) {
            }
            codec.release()
        }
    }

    private fun drain(untilEnd: Boolean = false) {
        var idleRounds = 0
        while (true) {
            val index = codec.dequeueOutputBuffer(info, if (untilEnd) 10_000 else 0)
            if (index < 0) {
                if (!untilEnd || ++idleRounds > 20) return
                continue
            }
            val output = codec.getOutputBuffer(index)
            if (output != null && info.size > 0 &&
                info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0
            ) {
                val frame = ByteArray(info.size)
                output.position(info.offset)
                output.get(frame)
                current.write(adtsHeader(frame.size))
                current.write(frame)
            }
            val end = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
            codec.releaseOutputBuffer(index, false)
            if (end) return
        }
    }

    private fun emit() {
        if (current.size() == 0) return
        val clip = current.toByteArray()
        current.reset()
        onClip(clip)
    }

    companion object {
        const val SAMPLE_RATE = 16_000
        private const val PROFILE_LC = 2
        private const val FREQ_INDEX_16K = 8
        private const val CHANNELS = 1

        fun adtsHeader(payloadLength: Int): ByteArray {
            val length = payloadLength + 7
            return byteArrayOf(
                0xFF.toByte(),
                0xF1.toByte(), // MPEG-4, layer 0, no CRC
                (((PROFILE_LC - 1) shl 6) or (FREQ_INDEX_16K shl 2) or (CHANNELS shr 2)).toByte(),
                (((CHANNELS and 3) shl 6) or (length shr 11)).toByte(),
                ((length and 0x7FF) shr 3).toByte(),
                (((length and 7) shl 5) or 0x1F).toByte(),
                0xFC.toByte(),
            )
        }
    }
}

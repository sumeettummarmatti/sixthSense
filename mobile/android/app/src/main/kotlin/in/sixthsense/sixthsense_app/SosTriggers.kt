package `in`.sixthsense.sixthsense_app

import kotlin.math.log10
import kotlin.math.sqrt

/** Volume Down pressed [presses] times within [windowMillis] (holding the key counts too). */
internal class VolumePressCounter(
    private val presses: Int = 5,
    private val windowMillis: Long = 3_000L,
) {
    private val times = ArrayDeque<Long>()

    fun onPress(nowMillis: Long): Boolean {
        times.addLast(nowMillis)
        while (times.isNotEmpty() && nowMillis - times.first() > windowMillis) times.removeFirst()
        if (times.size >= presses) {
            times.clear()
            return true
        }
        return false
    }

    fun reset() = times.clear()
}

/**
 * Distress words in what the on-phone recognisers heard. The Hindi model writes Devanagari
 * (it also catches "bachao" said in an English sentence); the Indian-English model writes Latin.
 * Matching whole words in a full transcript keeps false alarms low: "healthy", "hello", "bachelor"
 * and "bacchon" never match (tested in SosTriggersTest and the laptop spike).
 */
internal object DistressWords {
    private val single = setOf(
        "बचाओ", "बचाओं", "बचाव", "मदद", "हेल्प", // bachao, bachao, bachav, madad, help (Hindi model)
        "help", "bachao", "madad", // Indian-English model
    )

    /** The first distress word in [text], or null. "बचा लो" (bacha lo) counts as one phrase. */
    fun find(text: String): String? {
        val words = text.lowercase().split(Regex("\\s+")).filter(String::isNotBlank)
        for ((index, word) in words.withIndex()) {
            if (word in single) return word
            if (word == "बचा" && words.getOrNull(index + 1) == "लो") return "बचा लो"
        }
        return null
    }
}

internal enum class TriggerSource(val wire: String) { BUTTON("button"), VOICE("voice") }

/**
 * How long the silent countdown runs before the SOS goes out (cancellable with the PIN).
 * A button gets 5 s. A voice trigger gets 3–9 s: shorter when the word was shouted or the phone
 * is being shaken (a struggle), longer when the phone lies still (likely a TV). A whisper never
 * makes anyone wait longer.
 */
internal object CountdownPolicy {
    const val BUTTON_SECONDS = 5
    private const val SHOUT_DBFS = -12.0
    private const val WHISPER_DBFS = -35.0
    private const val STRUGGLE_MOTION = 3.0 // m/s² standard deviation over ~2 s
    private const val STILL_MOTION = 0.15

    fun seconds(source: TriggerSource, loudestDbfs: Double, motion: Double): Int {
        if (source == TriggerSource.BUTTON) return BUTTON_SECONDS
        val shouted = loudestDbfs >= SHOUT_DBFS
        val struggling = motion >= STRUGGLE_MOTION
        val whisper = loudestDbfs <= WHISPER_DBFS
        val still = motion <= STILL_MOTION
        return when {
            shouted && struggling -> 3
            shouted || struggling -> 4
            still && !whisper -> 9
            else -> 5
        }
    }
}

/** Loudness of a block of 16-bit PCM in dBFS (0 = full scale, about -90 = silence). */
internal fun dbfs(samples: ShortArray, count: Int): Double {
    if (count <= 0) return -96.0
    var sum = 0.0
    for (i in 0 until count) {
        val s = samples[i] / 32768.0
        sum += s * s
    }
    val rms = sqrt(sum / count)
    return if (rms <= 0.0) -96.0 else 20 * log10(rms)
}

/** The last [seconds] of 16 kHz mono audio, in memory only, constantly overwritten. */
internal class PcmRing(seconds: Int = 15, sampleRate: Int = 16_000) {
    private val buffer = ShortArray(seconds * sampleRate)
    private var position = 0
    private var filled = false

    @Synchronized
    fun write(samples: ShortArray, count: Int) {
        for (i in 0 until count) {
            buffer[position] = samples[i]
            position = (position + 1) % buffer.size
            if (position == 0) filled = true
        }
    }

    /** Oldest first. */
    @Synchronized
    fun snapshot(): ShortArray =
        if (!filled) buffer.copyOfRange(0, position)
        else buffer.copyOfRange(position, buffer.size) + buffer.copyOfRange(0, position)

    @Synchronized
    fun clear() {
        buffer.fill(0)
        position = 0
        filled = false
    }
}

/** Standard deviation of acceleration magnitude over a sliding window (motion energy). */
internal class MotionMeter(private val windowMillis: Long = 2_000L) {
    private val samples = ArrayDeque<Pair<Long, Double>>()

    @Synchronized
    fun add(nowMillis: Long, x: Float, y: Float, z: Float) {
        samples.addLast(nowMillis to sqrt((x * x + y * y + z * z).toDouble()))
        while (samples.isNotEmpty() && nowMillis - samples.first().first > windowMillis) {
            samples.removeFirst()
        }
    }

    @Synchronized
    fun motion(): Double {
        if (samples.size < 2) return 0.0
        val mean = samples.sumOf { it.second } / samples.size
        return sqrt(samples.sumOf { (it.second - mean) * (it.second - mean) } / samples.size)
    }
}

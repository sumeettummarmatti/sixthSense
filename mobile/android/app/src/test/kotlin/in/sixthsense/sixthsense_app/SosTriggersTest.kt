package `in`.sixthsense.sixthsense_app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SosTriggersTest {
    @Test
    fun fivePressesWithinThreeSecondsTrigger() {
        val counter = VolumePressCounter()
        repeat(4) { assertFalse(counter.onPress(1_000L + it * 400)) }
        assertTrue(counter.onPress(2_600))
        // Counting starts again after a trigger.
        assertFalse(counter.onPress(2_700))
    }

    @Test
    fun slowPressesNeverTrigger() {
        val counter = VolumePressCounter()
        for (i in 0 until 20) assertFalse(counter.onPress(i * 900L))
    }

    @Test
    fun holdingTheKeyCountsAsPresses() {
        // Android repeats a held key about every 50–100 ms.
        val counter = VolumePressCounter()
        val fired = (0 until 10).map { counter.onPress(it * 80L) }
        assertTrue(fired.contains(true))
    }

    @Test
    fun distressWordsInHindiAndEnglish() {
        assertEquals("बचाओ", DistressWords.find("बचाओ बचाओ"))
        assertEquals("बचाव", DistressWords.find("बचाव"))
        assertEquals("मदद", DistressWords.find("मदद करो"))
        assertEquals("हेल्प", DistressWords.find("हेल्प मी"))
        assertEquals("बचा लो", DistressWords.find("बचा लो"))
        assertEquals("help", DistressWords.find("please help me"))
        assertEquals("help", DistressWords.find("HELP"))
    }

    @Test
    fun everydaySpeechDoesNotMatch() {
        // Transcripts the models produced for normal sentences in the laptop test.
        for (text in listOf(
            "hello how are you doing today",
            "the bachelor made a healthy meal",
            "द बैटल अमीर हेल्थी में",
            "मैं घर जा रही हूँ खाना बना लो",
            "बच्चों को स्कूल से ले आना",
            "हेल्थ",
            "बचा हुआ खाना",
            "",
        )) {
            assertNull(text, DistressWords.find(text))
        }
    }

    @Test
    fun buttonCountdownIsAlwaysFiveSeconds() {
        assertEquals(5, CountdownPolicy.seconds(TriggerSource.BUTTON, -5.0, 10.0))
        assertEquals(5, CountdownPolicy.seconds(TriggerSource.BUTTON, -60.0, 0.0))
    }

    @Test
    fun voiceCountdownAdapts() {
        val voice = TriggerSource.VOICE
        assertEquals(3, CountdownPolicy.seconds(voice, -6.0, 5.0)) // shout + struggle
        assertEquals(4, CountdownPolicy.seconds(voice, -6.0, 1.0)) // shout
        assertEquals(4, CountdownPolicy.seconds(voice, -25.0, 5.0)) // struggle
        assertEquals(9, CountdownPolicy.seconds(voice, -25.0, 0.05)) // lying still: maybe a TV
        assertEquals(5, CountdownPolicy.seconds(voice, -25.0, 1.0)) // normal
    }

    @Test
    fun aWhisperNeverWaitsLonger() {
        assertEquals(5, CountdownPolicy.seconds(TriggerSource.VOICE, -40.0, 0.0))
    }

    @Test
    fun loudnessInDbfs() {
        assertEquals(-96.0, dbfs(ShortArray(100), 100), 0.01)
        val full = ShortArray(100) { if (it % 2 == 0) Short.MAX_VALUE else Short.MIN_VALUE }
        assertEquals(0.0, dbfs(full, 100), 0.1)
    }

    @Test
    fun ringKeepsOnlyTheLastSeconds() {
        val ring = PcmRing(seconds = 1, sampleRate = 4)
        ring.write(shortArrayOf(1, 2, 3), 3)
        assertArrayEquals(shortArrayOf(1, 2, 3), ring.snapshot())
        ring.write(shortArrayOf(4, 5, 6), 3)
        assertArrayEquals(shortArrayOf(3, 4, 5, 6), ring.snapshot())
        ring.clear()
        assertEquals(0, ring.snapshot().size)
    }

    @Test
    fun motionMeterSeesShakingNotStillness() {
        val still = MotionMeter()
        for (i in 0 until 50) still.add(i * 20L, 0f, 0f, 9.81f)
        assertTrue(still.motion() < 0.01)
        val shaken = MotionMeter()
        for (i in 0 until 50) shaken.add(i * 20L, if (i % 2 == 0) 15f else 0f, 3f, 9.81f)
        assertTrue(shaken.motion() > 3.0)
    }

    @Test
    fun adtsHeaderDescribesAacLc16kMono() {
        val header = AacChunkEncoder.adtsHeader(100)
        assertEquals(7, header.size)
        assertEquals(0xFF, header[0].toInt() and 0xFF)
        assertEquals(0xF1, header[1].toInt() and 0xFF)
        // profile LC (1), frequency index 8 (16 kHz), mono
        assertEquals(0x60, header[2].toInt() and 0xFF)
        val length = ((header[3].toInt() and 0x3) shl 11) or ((header[4].toInt() and 0xFF) shl 3) or
            ((header[5].toInt() and 0xFF) shr 5)
        assertEquals(107, length)
    }
}

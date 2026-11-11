package `in`.sixthsense.sixthsense_app

import android.view.KeyEvent

/** Recognizes Volume Up → Volume Down → Volume Up within four seconds. */
internal class VolumeSosPattern {
    private val expectedKeys = intArrayOf(
        KeyEvent.KEYCODE_VOLUME_UP,
        KeyEvent.KEYCODE_VOLUME_DOWN,
        KeyEvent.KEYCODE_VOLUME_UP,
    )
    private var nextKeyIndex = 0
    private var startedAtMillis = 0L

    fun onVolumeKey(keyCode: Int, eventTimeMillis: Long): Boolean {
        if (keyCode != KeyEvent.KEYCODE_VOLUME_UP && keyCode != KeyEvent.KEYCODE_VOLUME_DOWN) {
            return false
        }
        if (nextKeyIndex > 0 && eventTimeMillis - startedAtMillis > WINDOW_MILLIS) {
            reset()
        }
        if (keyCode == expectedKeys[nextKeyIndex]) {
            if (nextKeyIndex == 0) startedAtMillis = eventTimeMillis
            nextKeyIndex++
            if (nextKeyIndex == expectedKeys.size) {
                reset()
                return true
            }
        } else {
            nextKeyIndex = if (keyCode == expectedKeys[0]) 1 else 0
            startedAtMillis = if (nextKeyIndex == 1) eventTimeMillis else 0L
        }
        return false
    }

    private fun reset() {
        nextKeyIndex = 0
        startedAtMillis = 0L
    }

    private companion object {
        const val WINDOW_MILLIS = 4_000L
    }
}

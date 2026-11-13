package `in`.sixthsense.sixthsense_app

import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import java.io.File

/**
 * Plays received live-audio clips one after another (listener side). Each clip file is deleted
 * right after it plays, so nothing heard stays on the listener's phone.
 */
internal object ClipPlayer {
    private val queue = ArrayDeque<File>()
    private var player: MediaPlayer? = null
    private val main = Handler(Looper.getMainLooper())

    fun enqueue(path: String) = main.post {
        queue.addLast(File(path))
        if (player == null) playNext()
    }

    fun stop() = main.post {
        player?.release()
        player = null
        queue.forEach(File::delete)
        queue.clear()
    }

    private fun playNext() {
        val file = queue.removeFirstOrNull() ?: return
        val next = MediaPlayer()
        player = next
        try {
            next.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            next.setDataSource(file.path)
            next.setOnCompletionListener { done(it, file) }
            next.setOnErrorListener { mp, _, _ -> done(mp, file); true }
            next.prepare()
            next.start()
        } catch (_: Exception) {
            done(next, file)
        }
    }

    private fun done(mp: MediaPlayer, file: File) {
        mp.release()
        file.delete()
        if (player === mp) player = null
        playNext()
    }
}

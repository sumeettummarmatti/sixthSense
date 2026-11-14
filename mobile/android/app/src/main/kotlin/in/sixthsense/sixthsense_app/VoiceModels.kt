package `in`.sixthsense.sixthsense_app

import android.content.Context
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipInputStream

/**
 * The free, offline Vosk speech models (Apache 2.0), downloaded once on request (~80 MB):
 * Hindi (also hears "bachao", "madad", "bacha lo") and Indian English ("help").
 * Listening itself never needs the internet and nothing heard ever leaves the phone.
 */
internal object VoiceModels {
    val MODELS = linkedMapOf(
        "hi" to "vosk-model-small-hi-0.22",
        "en" to "vosk-model-small-en-in-0.4",
    )
    private const val BASE_URL = "https://alphacephei.com/vosk/models/"

    @Volatile var downloading = false
        private set

    fun dir(context: Context, language: String) = File(context.filesDir, "vosk/$language")

    fun installed(context: Context): List<String> =
        MODELS.keys.filter { File(dir(context, it), "am").isDirectory }

    /** Downloads the missing models. [progress] gets 0..100 overall. Blocking; run off the UI. */
    fun download(context: Context, progress: (Int) -> Unit): Boolean {
        if (downloading) return false
        downloading = true
        try {
            val missing = MODELS.filterKeys { it !in installed(context) }
            missing.entries.forEachIndexed { index, (language, name) ->
                val target = dir(context, language)
                val temp = File(context.filesDir, "vosk/.tmp-$language").apply { deleteRecursively(); mkdirs() }
                val connection = URL("$BASE_URL$name.zip").openConnection() as HttpURLConnection
                connection.connectTimeout = 15_000
                connection.readTimeout = 30_000
                val total = connection.contentLengthLong.coerceAtLeast(1)
                var read = 0L
                ZipInputStream(connection.inputStream.buffered()).use { zip ->
                    var entry = zip.nextEntry
                    val buffer = ByteArray(64 * 1024)
                    while (entry != null) {
                        // Strip the top folder ("vosk-model-.../am/final.mdl" → "am/final.mdl").
                        val relative = entry.name.substringAfter('/', "")
                        val out = File(temp, relative)
                        if (!out.canonicalPath.startsWith(temp.canonicalPath)) throw SecurityException("bad zip")
                        if (relative.isEmpty() || entry.isDirectory) {
                            out.mkdirs()
                        } else {
                            out.parentFile?.mkdirs()
                            out.outputStream().use { stream ->
                                while (true) {
                                    val n = zip.read(buffer)
                                    if (n < 0) break
                                    stream.write(buffer, 0, n)
                                    read += n
                                    // Uncompressed bytes run ~1.3× the zip size; good enough for a bar.
                                    val part = (read * 100 / (total * 13 / 10)).coerceAtMost(99)
                                    progress(((index * 100 + part) / missing.size).toInt())
                                }
                            }
                        }
                        entry = zip.nextEntry
                    }
                }
                connection.disconnect()
                target.deleteRecursively()
                if (!temp.renameTo(target)) throw IllegalStateException("could not install $language")
            }
            progress(100)
            return true
        } catch (_: Exception) {
            return false
        } finally {
            downloading = false
        }
    }
}

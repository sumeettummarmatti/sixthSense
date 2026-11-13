package `in`.sixthsense.sixthsense_app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Audio clips on this phone, encrypted with an Android Keystore key.
 *
 * - `sos`: the SOS recording, kept as evidence until the owner deletes it; it can be exported as
 *   one .aac file for an FIR. The app hands each clip to the relay once (tracked by [taken]).
 * - `escort`: Audio Escort clips, deleted as soon as the app has sent them.
 */
internal object EvidenceStore {
    private const val KEY_ALIAS = "sixthsense_audio_evidence"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val IV_BYTES = 12

    data class Clip(val session: String, val kind: String, val sequence: Int, val bytes: ByteArray)

    private fun root(context: Context) = File(context.filesDir, "audio")

    private fun dir(context: Context, kind: String, session: String) =
        File(root(context), "$kind/$session").apply { mkdirs() }

    @Synchronized
    fun save(context: Context, kind: String, session: String, bytes: ByteArray): Int {
        val folder = dir(context, kind, session)
        val next = (folder.list()?.mapNotNull { it.substringBefore('.').toIntOrNull() }?.maxOrNull() ?: -1) + 1
        File(folder, "%06d.clip".format(next)).writeBytes(encrypt(bytes))
        return next
    }

    /** Clips not handed to the app yet (escort clips are deleted once handed over). */
    @Synchronized
    fun take(context: Context, kind: String, max: Int = 6): List<Clip> {
        val kindDir = File(root(context), kind)
        val clips = mutableListOf<Clip>()
        for (session in kindDir.listFiles().orEmpty().sortedBy { it.name }) {
            for (file in session.listFiles { f -> f.name.endsWith(".clip") }.orEmpty().sortedBy { it.name }) {
                if (clips.size >= max) return clips
                val sequence = file.name.substringBefore('.').toInt()
                val bytes = decrypt(file.readBytes()) ?: continue
                clips += Clip(session.name, kind, sequence, bytes)
                if (kind == "escort") file.delete() else file.renameTo(File(session, "%06d.sent".format(sequence)))
            }
        }
        return clips
    }

    /** SOS recordings on this phone: session id → (clip count, newest file time). */
    @Synchronized
    fun recordings(context: Context): List<Map<String, Any>> =
        File(root(context), "sos").listFiles().orEmpty().mapNotNull { session ->
            val files = session.listFiles().orEmpty()
            if (files.isEmpty()) null
            else mapOf(
                "session" to session.name,
                "clips" to files.size,
                "seconds" to files.size * 5,
                "lastModifiedMillis" to files.maxOf { it.lastModified() },
            )
        }.sortedByDescending { it["lastModifiedMillis"] as Long }

    /** Decrypts a recording into one .aac file in the cache (for sharing); the caller deletes it. */
    @Synchronized
    fun export(context: Context, session: String): File? {
        val folder = File(root(context), "sos/$session")
        val files = folder.listFiles().orEmpty().sortedBy { it.name }
        if (files.isEmpty()) return null
        clearExports(context) // only the export being shared exists, decrypted
        val out = File(File(context.cacheDir, "evidence").apply { mkdirs() }, "sixthsense-sos-$session.aac")
        out.outputStream().use { stream ->
            files.forEach { file -> decrypt(file.readBytes())?.let(stream::write) }
        }
        return out
    }

    /** Decrypted exports are only for the moment of sharing; removed at the next export or app start. */
    fun clearExports(context: Context) {
        File(context.cacheDir, "evidence").deleteRecursively()
    }

    @Synchronized
    fun delete(context: Context, kind: String, session: String?) {
        if (session == null) File(root(context), kind).deleteRecursively()
        else File(root(context), "$kind/$session").deleteRecursively()
    }

    private fun encrypt(bytes: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        return cipher.iv + cipher.doFinal(bytes)
    }

    private fun decrypt(payload: ByteArray): ByteArray? = try {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, payload.copyOfRange(0, IV_BYTES)))
        cipher.doFinal(payload, IV_BYTES, payload.size - IV_BYTES)
    } catch (_: Exception) {
        null
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return generator.generateKey()
    }
}

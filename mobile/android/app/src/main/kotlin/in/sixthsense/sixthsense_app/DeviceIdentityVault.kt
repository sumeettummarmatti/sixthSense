package `in`.sixthsense.sixthsense_app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Device-bound sign-in key and encrypted short-lived API session. */
internal object DeviceIdentityVault {
    private const val SIGNING_KEY_ALIAS = "sixthsense_device_signin_p256"
    private const val SESSION_KEY_ALIAS = "sixthsense_api_session_aes"
    private const val PREFS = "sixthsense_device_identity"
    private const val SESSION = "encrypted_session"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"

    fun publicKey(): String {
        val key = keyPair().public
        return Base64.encodeToString(key.encoded, Base64.NO_WRAP)
    }

    fun sign(deviceId: String, nonce: String): String {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val privateKey = store.getKey(SIGNING_KEY_ALIAS, null) as? java.security.PrivateKey
            ?: throw IllegalStateException("Device sign-in key is missing")
        val message = "sixthsense-device-auth-v1|$deviceId|$nonce".toByteArray(Charsets.UTF_8)
        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initSign(privateKey)
        signature.update(message)
        return Base64.encodeToString(signature.sign(), Base64.NO_WRAP)
    }

    fun saveSession(context: Context, deviceId: String, accountId: String, accessToken: String) {
        val plain = JSONObject()
            .put("device_id", deviceId)
            .put("account_id", accountId)
            .put("access_token", accessToken)
            .toString()
            .toByteArray(Charsets.UTF_8)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, sessionKey())
        val encrypted = cipher.iv + cipher.doFinal(plain)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(SESSION, Base64.encodeToString(encrypted, Base64.NO_WRAP))
            .apply()
    }

    fun sessionValue(context: Context, field: String): String? {
        val encoded = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(SESSION, null) ?: return null
        return try {
            val bytes = Base64.decode(encoded, Base64.NO_WRAP)
            val iv = bytes.copyOfRange(0, GCM_IV_LENGTH_BYTES)
            val ciphertext = bytes.copyOfRange(GCM_IV_LENGTH_BYTES, bytes.size)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                sessionKey(),
                GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv),
            )
            JSONObject(String(cipher.doFinal(ciphertext), Charsets.UTF_8)).optString(field)
                .takeIf(String::isNotEmpty)
        } catch (_: Exception) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(SESSION).apply()
            null
        }
    }

    /** Small app values kept only on this phone (E2E key seeds, contact names), AES-GCM with a Keystore key. */
    fun saveValue(context: Context, name: String, value: String?) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        if (value == null) {
            prefs.remove("value_$name").apply()
            return
        }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, sessionKey())
        val encrypted = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        prefs.putString("value_$name", Base64.encodeToString(encrypted, Base64.NO_WRAP)).apply()
    }

    fun readValue(context: Context, name: String): String? {
        val encoded = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString("value_$name", null) ?: return null
        return try {
            val bytes = Base64.decode(encoded, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                sessionKey(),
                GCMParameterSpec(GCM_TAG_LENGTH_BITS, bytes.copyOfRange(0, GCM_IV_LENGTH_BYTES)),
            )
            String(cipher.doFinal(bytes.copyOfRange(GCM_IV_LENGTH_BYTES, bytes.size)), Charsets.UTF_8)
        } catch (_: Exception) {
            null
        }
    }

    fun clearSession(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(SESSION).apply()
    }

    /** Logout: drop the session and every saved value, and delete the device sign-in key. */
    fun signOut(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().commit()
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (store.containsAlias(SIGNING_KEY_ALIAS)) store.deleteEntry(SIGNING_KEY_ALIAS)
    }

    private fun keyPair(): java.security.KeyPair {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getCertificate(SIGNING_KEY_ALIAS)
        if (existing != null) {
            return java.security.KeyPair(
                existing.publicKey,
                store.getKey(SIGNING_KEY_ALIAS, null) as java.security.PrivateKey,
            )
        }
        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        generator.initialize(
            KeyGenParameterSpec.Builder(SIGNING_KEY_ALIAS, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .build(),
        )
        return generator.generateKeyPair()
    }

    private fun sessionKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(SESSION_KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                SESSION_KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private const val GCM_IV_LENGTH_BYTES = 12
    private const val GCM_TAG_LENGTH_BITS = 128
}

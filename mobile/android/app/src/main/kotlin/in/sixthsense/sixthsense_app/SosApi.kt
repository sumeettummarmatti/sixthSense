package `in`.sixthsense.sixthsense_app

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Sends the SOS to the server from native code, so a trigger works even when the Flutter UI is
 * gone (app swiped away, screen off). Signs in again with the device key if the token expired.
 * Never call on the main thread.
 */
internal object SosApi {
    private const val TAG = "SixthSenseSos"
    const val KEY_API_BASE = "api_base_url"
    const val KEY_JOURNEY_ID = "server_journey_id"

    /** True when the server accepted the SOS (or the journey is already escalated). */
    fun fire(context: Context, covert: Boolean = false): Boolean {
        val prefs = context.getSharedPreferences(JourneyTimerService.PREFERENCES_NAME, Context.MODE_PRIVATE)
        val base = prefs.getString(KEY_API_BASE, null) ?: return false
        val journeyId = prefs.getString(KEY_JOURNEY_ID, null) ?: return false
        val status = call(context, base, "POST", "/journeys/$journeyId/sos", JSONObject().put("covert", covert))
        val accepted = status in 200..299 || status == 409
        if (accepted) {
            OfflineSafetyDispatcher.recentLocation(context)?.let { location ->
                // Rough area for asking verified responders nearby; the server rounds it further.
                call(
                    context,
                    base,
                    "PUT",
                    "/escalations/area/$journeyId",
                    JSONObject().put("latitude", location.latitude).put("longitude", location.longitude),
                )
            }
        }
        return accepted
    }

    private fun call(
        context: Context,
        base: String,
        method: String,
        path: String,
        body: JSONObject?,
        retry: Boolean = true,
    ): Int {
        val token = DeviceIdentityVault.sessionValue(context, "access_token")
        val (status, _) = request(base, method, path, body, token)
        if (status == 401 && retry && signIn(context, base)) {
            return call(context, base, method, path, body, retry = false)
        }
        return status
    }

    private fun signIn(context: Context, base: String): Boolean {
        val deviceId = DeviceIdentityVault.sessionValue(context, "device_id") ?: return false
        return try {
            val (status, challenge) = request(
                base, "POST", "/auth/device/challenge", JSONObject().put("device_id", deviceId), null,
            )
            if (status != 200 || challenge == null) return false
            val nonce = challenge.getString("nonce")
            val (verified, session) = request(
                base,
                "POST",
                "/auth/device/verify",
                JSONObject()
                    .put("device_id", deviceId)
                    .put("nonce", nonce)
                    .put("signature", DeviceIdentityVault.sign(deviceId, nonce)),
                null,
            )
            if (verified != 200 || session == null) return false
            DeviceIdentityVault.saveSession(
                context,
                session.getString("device_id"),
                session.getString("account_id"),
                session.getString("access_token"),
            )
            true
        } catch (error: Exception) {
            Log.w(TAG, "Device sign-in failed", error)
            false
        }
    }

    private fun request(
        base: String,
        method: String,
        path: String,
        body: JSONObject?,
        token: String?,
    ): Pair<Int, JSONObject?> = try {
        val connection = URL(base.trimEnd('/') + path).openConnection() as HttpURLConnection
        connection.requestMethod = method
        connection.connectTimeout = 8_000
        connection.readTimeout = 8_000
        connection.setRequestProperty("Content-Type", "application/json")
        if (token != null) connection.setRequestProperty("Authorization", "Bearer $token")
        if (body != null) {
            connection.doOutput = true
            connection.outputStream.use { it.write(body.toString().toByteArray()) }
        }
        val status = connection.responseCode
        val text = (if (status < 400) connection.inputStream else connection.errorStream)
            ?.bufferedReader()?.use { it.readText() }
        connection.disconnect()
        status to text?.takeIf { it.startsWith("{") }?.let(::JSONObject)
    } catch (error: Exception) {
        Log.w(TAG, "SOS request failed: ${error.javaClass.simpleName}")
        -1 to null
    }
}

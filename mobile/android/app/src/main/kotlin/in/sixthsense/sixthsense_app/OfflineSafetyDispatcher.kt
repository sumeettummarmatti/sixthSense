package `in`.sixthsense.sixthsense_app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.telephony.SmsManager
import android.util.Log
import androidx.core.content.ContextCompat

/** Sends a user-authorized, journey-scoped SMS when alerts need the phone network. */
internal object OfflineSafetyDispatcher {
    private const val TAG = "SixthSenseSms"
    private const val MAX_LOCATION_AGE_MILLIS = 30 * 60 * 1000L

    fun isOffline(context: Context): Boolean {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val network = manager.activeNetwork ?: return true
        val capabilities = manager.getNetworkCapabilities(network) ?: return true
        return !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    fun sendSosIfConfigured(context: Context, reason: String): Boolean {
        val preferences = journeyPreferences(context)
        if (!preferences.getBoolean(JourneyTimerService.KEY_ACTIVE, false) ||
            !preferences.getBoolean(JourneyTimerService.KEY_SMS_FALLBACK_ENABLED, false)
        ) return false
        val lowBatteryMode = preferences.getBoolean(JourneyTimerService.KEY_LOW_BATTERY_MODE, false)
        return if (lowBatteryMode || isOffline(context)) send(context, reason) else false
    }

    fun sendLowBatteryOnce(context: Context): Boolean {
        val preferences = journeyPreferences(context)
        if (!preferences.getBoolean(JourneyTimerService.KEY_ACTIVE, false) ||
            !preferences.getBoolean(JourneyTimerService.KEY_SMS_FALLBACK_ENABLED, false) ||
            preferences.getBoolean(JourneyTimerService.KEY_LOW_BATTERY_MODE, false)
        ) return false

        preferences.edit().putBoolean(JourneyTimerService.KEY_LOW_BATTERY_MODE, true).apply()
        val sent = send(context, "Battery at 10% or lower. Low-battery mode is on")
        if (sent) preferences.edit().putBoolean(JourneyTimerService.KEY_LOW_BATTERY_SMS_SENT, true).apply()
        return true
    }

    fun sendMissedCheckIn(context: Context) {
        val preferences = journeyPreferences(context)
        if (preferences.getBoolean(JourneyTimerService.KEY_ACTIVE, false) &&
            preferences.getBoolean(JourneyTimerService.KEY_SMS_FALLBACK_ENABLED, false)
        ) {
            val lowBatteryMode = preferences.getBoolean(JourneyTimerService.KEY_LOW_BATTERY_MODE, false)
            if (lowBatteryMode || isOffline(context)) send(context, "Journey check-in missed")
        }
    }

    private fun send(context: Context, reason: String): Boolean {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.SEND_SMS) !=
            PackageManager.PERMISSION_GRANTED
        ) return false
        val preferences = journeyPreferences(context)
        val numbers = JourneyContactVault.decrypt(
            preferences.getString(JourneyTimerService.KEY_SMS_NUMBERS_ENCRYPTED, null),
        )
        if (numbers.isEmpty()) return false

        val locationText = recentLocation(context)?.let { location ->
            " https://maps.google.com/?q=${location.latitude},${location.longitude}"
        } ?: " Location unavailable."
        val body = "SixthSense: $reason.$locationText"
        return try {
            val manager = context.getSystemService(SmsManager::class.java)
            numbers.forEach { number ->
                manager.sendTextMessage(number, null, body, null, null)
            }
            true
        } catch (error: Exception) {
            Log.w(TAG, "Could not submit safety SMS to Android's SMS service", error)
            false
        }
    }

    private fun recentLocation(context: Context): Location? {
        val hasFineLocation = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        val hasCoarseLocation = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        if (!hasFineLocation && !hasCoarseLocation) return null
        return try {
            val locationManager = context.getSystemService(LocationManager::class.java)
            val candidates = listOfNotNull(
                if (hasFineLocation) {
                    locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER)
                } else null,
                locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER),
            )
            candidates
                .filter { System.currentTimeMillis() - it.time <= MAX_LOCATION_AGE_MILLIS }
                .maxByOrNull(Location::getTime)
        } catch (error: SecurityException) {
            Log.w(TAG, "Location permission was revoked before the SMS was prepared", error)
            null
        }
    }

    private fun journeyPreferences(context: Context) = context.getSharedPreferences(
        JourneyTimerService.PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )
}

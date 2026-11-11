package `in`.sixthsense.sixthsense_app

import android.app.Notification
import android.app.Service
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

class JourneyTimerService : Service() {
    private var batteryReceiver: android.content.BroadcastReceiver? = null

    override fun onCreate() {
        super.onCreate()
        JourneyNotifications.createChannels(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val preferences = getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE)
        if (intent?.action == ACTION_STOP) {
            preferences.edit().clear().apply()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf(startId)
            return START_NOT_STICKY
        }

        val deadlineMillis = if (intent?.hasExtra(EXTRA_DEADLINE) == true) {
            intent.getLongExtra(EXTRA_DEADLINE, 0L)
        } else {
            preferences.getLong(KEY_DEADLINE, 0L)
        }
        val isNewJourney = intent?.action == ACTION_START
        val journeyIsActive = isNewJourney || preferences.getBoolean(KEY_ACTIVE, false)
        if (!journeyIsActive || deadlineMillis <= 0L) {
            stopSelf(startId)
            return START_NOT_STICKY
        }

        preferences.edit()
            .putBoolean(KEY_ACTIVE, true)
            .putLong(KEY_DEADLINE, deadlineMillis)
            .putString(
                KEY_SMS_NUMBERS_ENCRYPTED,
                JourneyContactVault.encrypt(
                    intent?.getStringArrayListExtra(EXTRA_SMS_NUMBERS)?.toSet()
                        ?: JourneyContactVault.decrypt(
                            preferences.getString(KEY_SMS_NUMBERS_ENCRYPTED, null),
                        ),
                ),
            )
            .putBoolean(
                KEY_SMS_FALLBACK_ENABLED,
                // A resume after reboot carries no extras: keep the saved choice.
                if (intent?.hasExtra(EXTRA_SMS_FALLBACK_ENABLED) == true) {
                    intent.getBooleanExtra(EXTRA_SMS_FALLBACK_ENABLED, false)
                } else {
                    preferences.getBoolean(KEY_SMS_FALLBACK_ENABLED, false)
                },
            )
            .apply {
                if (isNewJourney && intent?.getBooleanExtra(EXTRA_IS_CHECK_IN, false) != true) {
                    putBoolean(KEY_LOW_BATTERY_MODE, false)
                    putBoolean(KEY_LOW_BATTERY_SMS_SENT, false)
                    putLong(KEY_LOW_BATTERY_LAST_ATTEMPT, 0L)
                }
            }
            .apply()

        registerBatteryReceiver()

        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                JourneyNotifications.SERVICE_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(JourneyNotifications.SERVICE_NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    private fun buildNotification(): Notification {
        val lowBatteryMode = getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE)
            .getBoolean(KEY_LOW_BATTERY_MODE, false)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, JourneyNotifications.SERVICE_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("SixthSense journey active")
            .setContentText(
                if (lowBatteryMode) "Low-battery mode is on; safety alerts use SMS."
                else "Your on-device check-in timer is running.",
            )
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setOngoing(true)
            .setContentIntent(JourneyNotifications.openAppIntent(this))
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        batteryReceiver?.let { unregisterReceiver(it) }
        batteryReceiver = null
        super.onDestroy()
    }

    private fun registerBatteryReceiver() {
        if (batteryReceiver != null) return
        batteryReceiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: android.content.Context, intent: Intent) {
                if (intent.action != Intent.ACTION_BATTERY_CHANGED) return
                val level = intent.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL, -1)
                val scale = intent.getIntExtra(android.os.BatteryManager.EXTRA_SCALE, -1)
                if (level >= 0 && scale > 0 && level * 100 / scale <= LOW_BATTERY_PERCENT) {
                    if (OfflineSafetyDispatcher.onLowBattery(this@JourneyTimerService)) {
                        val notification = buildNotification()
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                            startForeground(
                                JourneyNotifications.SERVICE_NOTIFICATION_ID,
                                notification,
                                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                            )
                        } else {
                            startForeground(JourneyNotifications.SERVICE_NOTIFICATION_ID, notification)
                        }
                    }
                }
            }
        }
        registerReceiver(
            batteryReceiver,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED),
        )
    }

    companion object {
        const val ACTION_START = "in.sixthsense.sixthsense_app.START_JOURNEY_TIMER"
        const val ACTION_STOP = "in.sixthsense.sixthsense_app.STOP_JOURNEY_TIMER"
        const val ACTION_RESUME = "in.sixthsense.sixthsense_app.RESUME_JOURNEY_TIMER"
        const val EXTRA_DEADLINE = "deadline_millis"
        const val EXTRA_SMS_NUMBERS = "sms_numbers"
        const val EXTRA_SMS_FALLBACK_ENABLED = "sms_fallback_enabled"
        const val EXTRA_IS_CHECK_IN = "is_check_in"
        const val PREFERENCES_NAME = "journey_timer"
        const val KEY_ACTIVE = "active"
        const val KEY_DEADLINE = "deadline_millis"
        const val KEY_SMS_NUMBERS_ENCRYPTED = "sms_numbers_encrypted"
        const val KEY_SMS_FALLBACK_ENABLED = "sms_fallback_enabled"
        const val KEY_LOW_BATTERY_MODE = "low_battery_mode"
        const val KEY_LOW_BATTERY_SMS_SENT = "low_battery_sms_sent"
        const val KEY_LOW_BATTERY_LAST_ATTEMPT = "low_battery_last_attempt"
        private const val LOW_BATTERY_PERCENT = 10
    }
}

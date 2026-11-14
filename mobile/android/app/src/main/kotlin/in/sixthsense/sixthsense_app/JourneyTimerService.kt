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
    private var micGranted = false

    override fun onCreate() {
        super.onCreate()
        JourneyNotifications.createChannels(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val preferences = getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE)
        if (intent?.action == ACTION_STOP) {
            stopGuard()
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
                // Sudden SOS settings and where to send it from native code.
                intent?.getStringExtra(EXTRA_API_BASE)?.let { putString(SosApi.KEY_API_BASE, it) }
                intent?.getStringExtra(EXTRA_JOURNEY_ID)?.let { putString(SosApi.KEY_JOURNEY_ID, it) }
                if (intent?.hasExtra(EXTRA_LISTEN_FOR_WORDS) == true) {
                    putBoolean(KEY_LISTEN_FOR_WORDS, intent.getBooleanExtra(EXTRA_LISTEN_FOR_WORDS, false))
                }
                if (isNewJourney && intent?.getBooleanExtra(EXTRA_IS_CHECK_IN, false) != true) {
                    putBoolean(KEY_LOW_BATTERY_MODE, false)
                    putBoolean(KEY_LOW_BATTERY_SMS_SENT, false)
                    putLong(KEY_LOW_BATTERY_LAST_ATTEMPT, 0L)
                }
            }
            .apply()

        registerBatteryReceiver()

        // The microphone may only be claimed while the app is on screen (Android 14+), which is
        // when a journey starts or a check-in happens. A resume after reboot runs without it.
        val fromApp = intent?.action == ACTION_START
        goForeground(withMic = micGranted || (fromApp && SosGuard.micAllowed(this)))
        startGuard()
        return START_STICKY
    }

    private fun goForeground(withMic: Boolean) {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val types = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
                if (withMic) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0
            try {
                startForeground(JourneyNotifications.SERVICE_NOTIFICATION_ID, notification, types)
                micGranted = withMic
            } catch (_: SecurityException) {
                startForeground(
                    JourneyNotifications.SERVICE_NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
                micGranted = false
            }
        } else {
            startForeground(JourneyNotifications.SERVICE_NOTIFICATION_ID, notification)
            micGranted = withMic
        }
    }

    private fun startGuard() {
        val listen = getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE).getBoolean(KEY_LISTEN_FOR_WORDS, false)
        val existing = SosGuard.current
        if (existing != null && existing.listenForWordsSetting == listen && existing.hasMic == micGranted) return
        existing?.stop()
        SosGuard.current = SosGuard(this, practice = false, listenForWords = listen, useMic = micGranted)
            .also { it.start() }
    }

    private fun stopGuard() {
        SosGuard.current?.stop()
        SosGuard.current = null
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
                when {
                    lowBatteryMode -> "Low-battery mode is on; safety alerts use SMS."
                    micGranted -> "Check-in timer running. Microphone on for sudden SOS."
                    else -> "Your on-device check-in timer is running."
                },
            )
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setOngoing(true)
            .setContentIntent(JourneyNotifications.openAppIntent(this))
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopGuard()
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
                        // Just update the text: re-calling startForeground from the background
                        // could drop the microphone permission the guard needs.
                        getSystemService(android.app.NotificationManager::class.java)
                            .notify(JourneyNotifications.SERVICE_NOTIFICATION_ID, buildNotification())
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
        const val EXTRA_API_BASE = "api_base_url"
        const val EXTRA_JOURNEY_ID = "server_journey_id"
        const val EXTRA_LISTEN_FOR_WORDS = "listen_for_words"
        const val KEY_LISTEN_FOR_WORDS = "listen_for_words"
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

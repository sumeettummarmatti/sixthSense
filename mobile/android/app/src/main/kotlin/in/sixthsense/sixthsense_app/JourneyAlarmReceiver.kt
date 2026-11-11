package `in`.sixthsense.sixthsense_app

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * On-phone escalation, mirroring the server's protocol (journey/schemas.py):
 * check-in due -> private prompt (notification) -> no check-in after
 * [JourneyAlarm.ESCALATE_AFTER_DUE_MILLIS] (grace 2 min + prompt 2 min) -> SMS to contacts.
 * Checking in moves the saved deadline, so a stale escalation alarm does nothing.
 */
class JourneyAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED -> JourneyAlarm.resumeAfterBoot(context)
            ACTION_CHECK_IN_DUE -> onCheckInDue(context)
            ACTION_ESCALATE -> onEscalate(context, intent)
        }
    }

    private fun onCheckInDue(context: Context) {
        val preferences = JourneyAlarm.preferences(context)
        if (!preferences.getBoolean(JourneyTimerService.KEY_ACTIVE, false)) return
        val deadlineMillis = preferences.getLong(JourneyTimerService.KEY_DEADLINE, 0L)
        if (deadlineMillis <= 0L || deadlineMillis > System.currentTimeMillis()) return

        showDueNotification(context)
        // Normally deadline + 4 min. If the phone was off past that, still give a short prompt.
        val escalateAt = maxOf(
            deadlineMillis + JourneyAlarm.ESCALATE_AFTER_DUE_MILLIS,
            System.currentTimeMillis() + JourneyAlarm.MIN_PROMPT_AFTER_LATE_MILLIS,
        )
        JourneyAlarm.scheduleEscalation(context, deadlineMillis, escalateAt)
    }

    private fun onEscalate(context: Context, intent: Intent) {
        val preferences = JourneyAlarm.preferences(context)
        val scheduledFor = intent.getLongExtra(JourneyAlarm.EXTRA_FOR_DEADLINE, -1L)
        val currentDeadline = preferences.getLong(JourneyTimerService.KEY_DEADLINE, 0L)
        if (!preferences.getBoolean(JourneyTimerService.KEY_ACTIVE, false) ||
            scheduledFor != currentDeadline
        ) return // ended, or checked in since (deadline moved)
        OfflineSafetyDispatcher.sendMissedCheckIn(context)
    }

    private fun showDueNotification(context: Context) {
        JourneyNotifications.createChannels(context)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, JourneyNotifications.DUE_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("Journey check-in due")
            .setContentText("Open SixthSense to check in.")
            .setCategory(Notification.CATEGORY_REMINDER)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setAutoCancel(true)
            .setContentIntent(JourneyNotifications.openAppIntent(context))
            .build()
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(JourneyNotifications.DUE_NOTIFICATION_ID, notification)
    }

    companion object {
        const val ACTION_CHECK_IN_DUE =
            "in.sixthsense.sixthsense_app.CHECK_IN_DUE"
        const val ACTION_ESCALATE =
            "in.sixthsense.sixthsense_app.CHECK_IN_ESCALATE"
    }
}

internal object JourneyAlarm {
    private const val DUE_REQUEST_CODE = 4104
    private const val ESCALATE_REQUEST_CODE = 4105
    const val EXTRA_FOR_DEADLINE = "for_deadline_millis"

    /** Server defaults: check_in_grace_min 2 + prompt_timeout_min 2. */
    const val ESCALATE_AFTER_DUE_MILLIS = 4 * 60 * 1000L
    const val MIN_PROMPT_AFTER_LATE_MILLIS = 2 * 60 * 1000L
    private const val BOOT_DUE_DELAY_MILLIS = 5 * 1000L

    fun preferences(context: Context) = context.getSharedPreferences(
        JourneyTimerService.PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    private fun duePendingIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        DUE_REQUEST_CODE,
        Intent(context, JourneyAlarmReceiver::class.java).apply {
            action = JourneyAlarmReceiver.ACTION_CHECK_IN_DUE
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun escalatePendingIntent(context: Context, forDeadline: Long): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            ESCALATE_REQUEST_CODE,
            Intent(context, JourneyAlarmReceiver::class.java).apply {
                action = JourneyAlarmReceiver.ACTION_ESCALATE
                putExtra(EXTRA_FOR_DEADLINE, forDeadline)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /** Returns false only when exact alarms are not allowed (the app asks for that access). */
    fun schedule(context: Context, deadlineMillis: Long): Boolean {
        cancelEscalation(context) // a check-in replaces any pending escalation
        return setAlarm(context, deadlineMillis, duePendingIntent(context), requireExact = true)
    }

    fun scheduleEscalation(context: Context, forDeadline: Long, atMillis: Long) {
        // Never skip the safety SMS: fall back to an inexact alarm if exact ones were revoked.
        setAlarm(context, atMillis, escalatePendingIntent(context, forDeadline), requireExact = false)
    }

    private fun setAlarm(
        context: Context,
        atMillis: Long,
        operation: PendingIntent,
        requireExact: Boolean,
    ): Boolean {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val exactAllowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            manager.canScheduleExactAlarms()
        if (exactAllowed) {
            manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, operation)
            return true
        }
        if (requireExact) return false
        manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, operation)
        return true
    }

    private fun cancelEscalation(context: Context) {
        (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
            .cancel(escalatePendingIntent(context, 0L))
    }

    fun cancel(context: Context) {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        manager.cancel(duePendingIntent(context))
        manager.cancel(escalatePendingIntent(context, 0L))
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .cancel(JourneyNotifications.DUE_NOTIFICATION_ID)
    }

    /**
     * After a restart: bring back the foreground service and the timer. If the check-in
     * time passed while the phone was off, fire the due step now (prompt, then SMS).
     */
    fun resumeAfterBoot(context: Context) {
        val preferences = preferences(context)
        if (!preferences.getBoolean(JourneyTimerService.KEY_ACTIVE, false)) return
        val deadlineMillis = preferences.getLong(JourneyTimerService.KEY_DEADLINE, 0L)
        if (deadlineMillis <= 0L) return

        val serviceIntent = Intent(context, JourneyTimerService::class.java)
            .setAction(JourneyTimerService.ACTION_RESUME)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } catch (_: IllegalStateException) {
            // Some OEMs block this; the alarms below still deliver the prompt and SMS.
        } catch (_: SecurityException) {
        }

        val dueAt = maxOf(deadlineMillis, System.currentTimeMillis() + BOOT_DUE_DELAY_MILLIS)
        setAlarm(context, dueAt, duePendingIntent(context), requireExact = false)
    }
}

package `in`.sixthsense.sixthsense_app

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class JourneyAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            JourneyAlarm.scheduleSavedDeadline(context)
            return
        }
        if (intent.action != ACTION_CHECK_IN_DUE) return

        OfflineSafetyDispatcher.sendMissedCheckIn(context)
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
    }
}

internal object JourneyAlarm {
    private const val REQUEST_CODE = 4104

    fun pendingIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        REQUEST_CODE,
        Intent(context, JourneyAlarmReceiver::class.java).apply {
            action = JourneyAlarmReceiver.ACTION_CHECK_IN_DUE
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    fun schedule(context: Context, deadlineMillis: Long): Boolean {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            !manager.canScheduleExactAlarms()
        ) {
            return false
        }
        manager.setExactAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            deadlineMillis,
            pendingIntent(context),
        )
        return true
    }

    fun cancel(context: Context) {
        (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
            .cancel(pendingIntent(context))
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .cancel(JourneyNotifications.DUE_NOTIFICATION_ID)
    }

    fun scheduleSavedDeadline(context: Context) {
        val preferences = context.getSharedPreferences(
            JourneyTimerService.PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        )
        val deadlineMillis = preferences.getLong(JourneyTimerService.KEY_DEADLINE, 0L)
        if (deadlineMillis > System.currentTimeMillis()) {
            schedule(context, deadlineMillis)
        }
    }
}

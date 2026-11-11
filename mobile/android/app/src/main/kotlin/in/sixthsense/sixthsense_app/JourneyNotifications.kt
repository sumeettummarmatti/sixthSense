package `in`.sixthsense.sixthsense_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

internal object JourneyNotifications {
    const val SERVICE_CHANNEL_ID = "journey_status"
    const val DUE_CHANNEL_ID = "journey_check_in"
    const val SERVICE_NOTIFICATION_ID = 4101
    const val DUE_NOTIFICATION_ID = 4102

    fun createChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                SERVICE_CHANNEL_ID,
                "Journey status",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shows when a journey check-in timer is running."
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(
                DUE_CHANNEL_ID,
                "Journey check-ins",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Alerts you when a journey check-in is due."
            },
        )
    }

    fun openAppIntent(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            context,
            4103,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

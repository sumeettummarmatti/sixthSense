package `in`.sixthsense.sixthsense_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat

/** Shows local feedback and optionally submits an SMS through the phone's carrier. */
internal object LocalSosNotifier {
    private const val CHANNEL_ID = "sos_requests"
    private const val NOTIFICATION_ID = 4104

    fun show(context: Context): Boolean {
        val smsSubmitted = OfflineSafetyDispatcher.sendSosIfConfigured(
            context,
            "SOS requested",
        )
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "SOS requests",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Local confirmation when an SOS trigger is used."
                },
            )
        }
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle("SOS requested")
            .setContentText(
                if (smsSubmitted) "A safety SMS was submitted to Android for sending."
                else "No SMS sent. Call 112 if you need emergency help.",
            )
            .setStyle(
                NotificationCompat.BigTextStyle().bigText(
                    if (smsSubmitted) {
                        "A safety SMS was submitted to Android for sending. If you need emergency help, call 112."
                    } else {
                        "No SMS was sent. If you need emergency help, call 112 from your phone."
                    },
                ),
            )
            .setContentIntent(JourneyNotifications.openAppIntent(context))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        manager.notify(NOTIFICATION_ID, notification)
        return smsSubmitted
    }
}

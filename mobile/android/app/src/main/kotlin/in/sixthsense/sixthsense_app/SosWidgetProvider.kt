package `in`.sixthsense.sixthsense_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

class SosWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        appWidgetIds.forEach { widgetId ->
            val intent = Intent(context, SosWidgetProvider::class.java).apply {
                action = ACTION_REQUEST_SOS
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                widgetId,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val views = RemoteViews(context.packageName, R.layout.sos_widget).apply {
                setOnClickPendingIntent(R.id.sos_widget_button, pendingIntent)
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_REQUEST_SOS) {
            SosGuard.current?.trigger(TriggerSource.BUTTON, "widget") ?: LocalSosNotifier.show(context)
        }
    }

    private companion object {
        const val ACTION_REQUEST_SOS = "in.sixthsense.sixthsense_app.REQUEST_SOS_FROM_WIDGET"
    }
}

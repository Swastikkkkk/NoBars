package app.nobars.android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/** Notifications for chat, SOS and the always-on mesh service. */
class Notifier(private val context: Context) {

    companion object {
        const val SERVICE_CHANNEL = "mesh"
        const val MESSAGE_CHANNEL = "messages"
        const val SOS_CHANNEL = "sos"
        const val SERVICE_ID = 1

        fun createChannels(context: Context) {
            val nm = context.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(NotificationChannel(SERVICE_CHANNEL, "Mesh running", NotificationManager.IMPORTANCE_LOW))
            nm.createNotificationChannel(NotificationChannel(MESSAGE_CHANNEL, "Messages", NotificationManager.IMPORTANCE_HIGH))
            nm.createNotificationChannel(NotificationChannel(SOS_CHANNEL, "SOS alerts", NotificationManager.IMPORTANCE_HIGH))
        }

        fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }

    private var nextId = 100

    fun message(from: String, text: String) = post(MESSAGE_CHANNEL, from, text)

    fun sos(from: String) = post(SOS_CHANNEL, "SOS from $from", "Open NoBars to see where they are.")

    private fun post(channel: String, title: String, body: String) {
        val n = NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_mesh)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setContentIntent(openApp(context))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(nextId++, n) }
    }
}

package app.nobars.android

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Keeps the mesh running with the screen off or the app closed, so this phone
 * keeps relaying chat and SOS for everyone around it.
 */
class MeshService : Service() {

    companion object {
        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, MeshService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MeshService::class.java))
        }

        fun refreshNotification(context: Context) {
            if (MeshEngine.instance?.state?.value?.live != true) return
            runCatching { NotificationManagerCompat.from(context).notify(Notifier.SERVICE_ID, build(context)) }
        }

        private fun build(context: Context): Notification {
            val s = MeshEngine.get(context).state.value
            val text = when {
                s.sos -> "Sharing your SOS location"
                s.connected.isEmpty() -> "Looking for buddies nearby"
                else -> "${s.connected.size} nearby" + if (s.viaMesh.isNotEmpty()) ", ${s.viaMesh.size} via mesh" else ""
            }
            return NotificationCompat.Builder(context, Notifier.SERVICE_CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_mesh)
                .setContentTitle("NoBars mesh is live")
                .setContentText(text)
                .setOngoing(true)
                .setContentIntent(Notifier.openApp(context))
                .build()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val engine = MeshEngine.get(this)
        val types = if (Build.VERSION.SDK_INT >= 30)
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0
        runCatching { ServiceCompat.startForeground(this, Notifier.SERVICE_ID, build(this), types) }
            .onFailure {
                // Location permission missing: run as connected-device only.
                if (Build.VERSION.SDK_INT >= 30) ServiceCompat.startForeground(this, Notifier.SERVICE_ID, build(this),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            }
        engine.start()
        return START_STICKY
    }

    override fun onDestroy() {
        MeshEngine.instance?.stop()
        super.onDestroy()
    }
}

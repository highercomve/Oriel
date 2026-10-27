package dev.oriel

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder

/**
 * A foreground service of type `specialUse`: the app keeps running with no
 * window in front (a sync engine, a server for the user's other devices),
 * with an ongoing notification. Declared by `.android.keep_running` in
 * build.zig, whose text is the reason Google Play reviews. Its notification
 * can carry action buttons (system event "action"). Started and stopped from
 * Zig with `oriel.android.setKeepRunning(...)`.
 */
class OrielKeepRunningService : Service() {
    companion object {
        const val EXTRA_TITLE = "dev.oriel.title"
        const val EXTRA_TEXT = "dev.oriel.text"
        const val EXTRA_ACTIONS = "dev.oriel.actions"
        private const val CHANNEL = "oriel.keep_running"
        private const val ID = 0x4F5B
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Running in the background", NotificationManager.IMPORTANCE_LOW))
        }
        val builder = Notification.Builder(this, CHANNEL)
            .setSmallIcon(OrielRuntime.notificationIcon())
            .setContentTitle(intent?.getStringExtra(EXTRA_TITLE) ?: OrielRuntime.appLabel())
            .setContentText(intent?.getStringExtra(EXTRA_TEXT) ?: "")
            .setContentIntent(OrielRuntime.openAppIntent())
            .setOngoing(true)
        // Codes from 101: the audio service's buttons use 1, 2, ...
        var code = 101
        intent?.getStringExtra(EXTRA_ACTIONS)?.lineSequence()?.forEach { line ->
            val tab = line.indexOf('\t')
            if (tab <= 0) return@forEach
            val action = Intent(this, OrielActionReceiver::class.java).putExtra(OrielActionReceiver.EXTRA_ACTION, line.substring(0, tab))
            val pi = PendingIntent.getBroadcast(this, code++, action, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            builder.addAction(Notification.Action.Builder(Icon.createWithResource(this, OrielRuntime.notificationIcon()), line.substring(tab + 1), pi).build())
        }
        val notification = builder.build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(ID, notification)
        }
        // The app starts in its Activity: a service restarted on its own
        // would have no app behind it.
        return START_NOT_STICKY
    }
}

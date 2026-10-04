package dev.oriel

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.media.session.MediaSession
import android.os.Build
import android.os.IBinder
import android.view.KeyEvent

/**
 * A foreground service of type `microphone`: while it runs, the app keeps
 * capturing audio in the background, with an ongoing notification (Android
 * requires both). Its notification can carry action buttons (system event
 * "action"), and a media session hands the headset button to the app
 * ("media-button": push-to-talk). Started and stopped from Zig with
 * `oriel.android.setForegroundService(...)`.
 */
class OrielAudioService : Service() {
    companion object {
        const val EXTRA_TITLE = "dev.oriel.title"
        const val EXTRA_TEXT = "dev.oriel.text"
        const val EXTRA_ACTIONS = "dev.oriel.actions"
        private const val CHANNEL = "oriel.foreground"
        private const val ID = 0x4F5A
    }

    private var session: MediaSession? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Recording", NotificationManager.IMPORTANCE_LOW))
        }
        val builder = Notification.Builder(this, CHANNEL)
            .setSmallIcon(OrielRuntime.notificationIcon())
            .setContentTitle(intent?.getStringExtra(EXTRA_TITLE) ?: OrielRuntime.appLabel())
            .setContentText(intent?.getStringExtra(EXTRA_TEXT) ?: "")
            .setContentIntent(OrielRuntime.openAppIntent())
            .setOngoing(true)
        var code = 1
        intent?.getStringExtra(EXTRA_ACTIONS)?.lineSequence()?.forEach { line ->
            val tab = line.indexOf('\t')
            if (tab <= 0) return@forEach
            val action = Intent(this, OrielActionReceiver::class.java).putExtra(OrielActionReceiver.EXTRA_ACTION, line.substring(0, tab))
            val pi = PendingIntent.getBroadcast(this, code++, action, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            builder.addAction(Notification.Action.Builder(Icon.createWithResource(this, OrielRuntime.notificationIcon()), line.substring(tab + 1), pi).build())
        }
        if (Build.VERSION.SDK_INT >= 30) {
            startForeground(ID, builder.build(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(ID, builder.build())
        }
        if (session == null) session = MediaSession(this, "oriel").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onMediaButtonEvent(intent: Intent): Boolean {
                    @Suppress("DEPRECATION")
                    val key = intent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT) ?: return false
                    if (key.action == KeyEvent.ACTION_DOWN && key.repeatCount == 0) OrielSystem.send("media-button", key.keyCode.toString())
                    return true
                }
            })
            isActive = true
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        session?.release()
        session = null
        super.onDestroy()
    }
}

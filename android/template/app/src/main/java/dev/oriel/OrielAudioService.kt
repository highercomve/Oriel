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
        /** MediaProjection's consent (OrielSystemAudio): the service takes the projection. */
        const val EXTRA_PROJECTION_CODE = "dev.oriel.projection.code"
        const val EXTRA_PROJECTION_DATA = "dev.oriel.projection.data"

        /** A projection is live: every startForeground keeps the mediaProjection type. */
        @Volatile private var projecting = false
        /** The service runs only for a projection (Zig didn't ask for it): it goes with it. */
        @Volatile private var onlyForProjection = false
        private var instance: OrielAudioService? = null

        /**
         * Zig stops the service (setForegroundService(false)) while a
         * projection is live: it stays, for the projection only, and goes with it.
         * False when there's no projection (the caller stops the service).
         */
        fun keepForProjection(): Boolean {
            if (!projecting || instance == null) return false
            onlyForProjection = true
            return true
        }

        /** The projection ended (OrielSystemAudio): drop the type, or the service. */
        fun projectionEnded() {
            projecting = false
            val s = instance ?: return
            if (onlyForProjection) s.stopSelf() else s.restartForeground()
        }
        private const val CHANNEL = "oriel.foreground"
        private const val ID = 0x4F5A
    }

    private var session: MediaSession? = null
    private var lastNotification: Notification? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        instance = this
        val projectionCode = intent?.getIntExtra(EXTRA_PROJECTION_CODE, 0) ?: 0
        if (projectionCode != 0) {
            // Started for a projection: keep the current notification (or a plain one).
            onlyForProjection = lastNotification == null
            projecting = true
            startForegroundTyped(lastNotification ?: baseNotification(null).build())
            @Suppress("DEPRECATION")
            val data = intent?.getParcelableExtra<Intent>(EXTRA_PROJECTION_DATA)
            val p = try {
                if (data == null) null else getSystemService(android.media.projection.MediaProjectionManager::class.java).getMediaProjection(projectionCode, data)
            } catch (e: Exception) {
                android.util.Log.e("OrielAudioService", "no media projection", e)
                null
            }
            OrielSystemAudio.onProjection(p)
            return START_NOT_STICKY
        }
        onlyForProjection = false
        val builder = baseNotification(intent)
        var code = 1
        intent?.getStringExtra(EXTRA_ACTIONS)?.lineSequence()?.forEach { line ->
            val tab = line.indexOf('\t')
            if (tab <= 0) return@forEach
            val action = Intent(this, OrielActionReceiver::class.java).putExtra(OrielActionReceiver.EXTRA_ACTION, line.substring(0, tab))
            val pi = PendingIntent.getBroadcast(this, code++, action, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            builder.addAction(Notification.Action.Builder(Icon.createWithResource(this, OrielRuntime.notificationIcon()), line.substring(tab + 1), pi).build())
        }
        val notification = builder.build()
        lastNotification = notification
        startForegroundTyped(notification)
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

    private fun baseNotification(intent: Intent?): Notification.Builder {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Recording", NotificationManager.IMPORTANCE_LOW))
        }
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(OrielRuntime.notificationIcon())
            .setContentTitle(intent?.getStringExtra(EXTRA_TITLE) ?: OrielRuntime.appLabel())
            .setContentText(intent?.getStringExtra(EXTRA_TEXT) ?: "")
            .setContentIntent(OrielRuntime.openAppIntent())
            .setOngoing(true)
    }

    /** The microphone type, plus mediaProjection while a projection is live. */
    private fun startForegroundTyped(n: Notification) {
        if (Build.VERSION.SDK_INT >= 30) {
            var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            if (projecting) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            startForeground(ID, n, type)
        } else if (Build.VERSION.SDK_INT >= 29 && projecting) {
            startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(ID, n)
        }
    }

    internal fun restartForeground() {
        startForegroundTyped(lastNotification ?: baseNotification(null).build())
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        lastNotification = null
        session?.release()
        session = null
        super.onDestroy()
    }
}

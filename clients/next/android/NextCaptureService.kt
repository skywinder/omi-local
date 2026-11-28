package org.omilocal.next

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** Keeps the Flutter capture process eligible to receive audio with the screen off. */
abstract class NextCaptureService : Service() {
    protected abstract val foregroundType: Int
    protected abstract val notificationId: Int
    protected abstract val source: String

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val channel = NotificationChannel("next_recording", "Omi Next recording", NotificationManager.IMPORTANCE_LOW)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(this, channel.id)
            .setContentTitle("Omi Next")
            .setContentText("Recording with $source")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(notificationId, notification, foregroundType)
            } else {
                startForeground(notificationId, notification)
            }
        } catch (_: SecurityException) {
            stopSelf(startId)
        }
        // Capture intent is restored when the app opens, with the correct server and input.
        return START_NOT_STICKY
    }
}

class NextPhoneCaptureService : NextCaptureService() {
    override val foregroundType = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
    override val notificationId = 2101
    override val source = "the phone microphone"
}

class NextCv1CaptureService : NextCaptureService() {
    override val foregroundType = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
    override val notificationId = 2102
    override val source = "Omi CV1"
}

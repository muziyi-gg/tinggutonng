package com.tingutong.app

import android.app.*
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity

class TtsForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "tingutong_tts_channel"
        const val NOTIFICATION_ID = 20001
        const val ACTION_START = "com.tingutong.app.ACTION_START_TTS_SERVICE"
        const val ACTION_STOP = "com.tingutong.app.ACTION_STOP_TTS_SERVICE"

        var isRunning = false
            private set

        fun stopService(context: android.content.Context) {
            val intent = Intent(context, TtsForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                // START: 启动前台服务防止后台被杀死
                startForeground(NOTIFICATION_ID, buildNotification("后台播报服务运行中"))
                isRunning = true
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "听股通播报服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "保持 App 在后台持续运行，确保 TTS 播报不被系统中断"
                setShowBadge(false)
                setSound(null, null)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, FlutterActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("听股通")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_tts_notification)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }
}
package com.tingutong.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity

/**
 * 前台保活服务 — 标记 App 为"音频类"，提升系统优先级
 *
 * 作用：
 * - 持续显示前台通知，标记 App 为"音频/媒体"类应用
 * - 系统对音频类 App 有更高优先级，不轻易杀死
 * - 配合 START_STICKY，重生后继续保活
 *
 * 注意：
 * - 此服务只负责保活，不做 TTS 播报
 * - 播报由 TtsBroadcastService 处理
 * - 用户关闭播报时，此服务也停止
 */
class TtsForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "tingutong_foreground_channel"
        const val NOTIFICATION_ID = 20001
        const val ACTION_START = "com.tingutong.app.ACTION_START_FOREGROUND_SERVICE"
        const val ACTION_STOP = "com.tingutong.app.ACTION_STOP_FOREGROUND_SERVICE"

        var isRunning = false
            private set

        /**
         * 启动前台保活服务
         */
        fun startService(context: android.content.Context) {
            val intent = Intent(context, TtsForegroundService::class.java).apply {
                action = ACTION_START
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /**
         * 停止前台保活服务
         */
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
                isRunning = false
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START, else -> {
                // 启动前台服务，显示持续通知
                isRunning = true
                startForeground(NOTIFICATION_ID, buildNotification("听股通后台持续运行中"))
                // START_STICKY：系统杀死后重生，继续保活
                return START_STICKY
            }
        }
    }

    override fun onDestroy() {
        isRunning = false
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // 用户从 Recent Apps 滑动清理时，尝试重启服务
        android.util.Log.d("TtsForegroundService", ">>> onTaskRemoved, restarting...")
        val restartIntent = Intent(this, TtsForegroundService::class.java).apply {
            action = ACTION_START
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(restartIntent)
        } else {
            startService(restartIntent)
        }
        super.onTaskRemoved(rootIntent)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "听股通后台服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "保持 App 在后台持续运行"
                setShowBadge(false)
                setSound(null, null)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): android.app.Notification {
        // 点击通知打开 App
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, FlutterActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // 停止按钮
        val stopIntent = Intent(this, TtsForegroundService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("听股通")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(android.R.drawable.ic_media_pause, "停止后台", stopPendingIntent)
            .build()
    }
}
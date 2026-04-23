package com.tingutong.app

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * AlarmManager 定时触发时唤醒 App，执行播报。
 *
 * 触发路径：
 *   AlarmManager.setExactAndAllowWhileIdle() → TtsAlarmReceiver.onReceive()
 *   → 启动 TtsBroadcastService（前台服务）→ 原生 TextToSpeech 播报
 *
 * 这样即使 Flutter Dart isolate 在熄屏时被暂停，Alarm 也能通过系统唤醒来触发播报。
 */
class TtsAlarmReceiver : BroadcastReceiver() {

    companion object {
        const val TAG = "TtsAlarmReceiver"
        const val ACTION_TTS_ALARM = "com.tingutong.app.TTS_ALARM"
        const val EXTRA_REPORT_TEXT = "report_text"
        const val EXTRA_REPORT_INTERVAL = "report_interval"

        const val REQUEST_CODE = 10001
        private const val DEBUG_CHANNEL_ID = "alarm_debug_channel"
        private const val DEBUG_NOTIFICATION_ID = 888

        /**
         * 设置下一轮播报的 Alarm（熄屏后通过系统闹钟唤醒）
         * intervalSec: 距现在多少秒后触发
         *
         * 权限策略：
         * - Android 12+ 有 SCHEDULE_EXACT_ALARM 权限 → setExactAndAllowWhileIdle（精确）
         * - 无精确闹钟权限 → setAndAllowWhileIdle（不精确，但系统会尽量在窗口内触发）
         * - 重启后 Alarm 会丢失，由 TtsBootReceiver 恢复
         */
        fun scheduleNextReport(context: Context, intervalSec: Int) {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, TtsAlarmReceiver::class.java).apply {
                action = ACTION_TTS_ALARM
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val triggerTime = System.currentTimeMillis() + (intervalSec * 1000L)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (alarmManager.canScheduleExactAlarms()) {
                    alarmManager.setExactAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        triggerTime,
                        pendingIntent
                    )
                    Log.d(TAG, "Alarm scheduled (exact) in ${intervalSec}s")
                } else {
                    // 无精确闹钟权限，降级到 setAndAllowWhileIdle（不精确但可工作）
                    // 误差可能在分钟级别，但熄屏播报场景仍可接受
                    alarmManager.setAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        triggerTime,
                        pendingIntent
                    )
                    Log.w(TAG, "Exact alarm permission denied, falling back to setAndAllowWhileIdle")
                }
            } else {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerTime,
                    pendingIntent
                )
                Log.d(TAG, "Alarm scheduled (pre-Android12 exact) in ${intervalSec}s")
            }
            Log.d(TAG, "Alarm scheduled in ${intervalSec}s (at ${java.text.SimpleDateFormat("HH:mm:ss").format(java.util.Date(triggerTime))})")
        }

        /**
         * 取消所有待执行的 Alarm
         */
        fun cancelAlarm(context: Context) {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, TtsAlarmReceiver::class.java).apply {
                action = ACTION_TTS_ALARM
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            alarmManager.cancel(pendingIntent)
            Log.d(TAG, "Alarm cancelled")
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        android.util.Log.d(TAG, ">>> TtsAlarmReceiver onReceive: action=${intent.action}")

        if (intent.action != ACTION_TTS_ALARM) {
            android.util.Log.d(TAG, ">>> TtsAlarmReceiver: unknown action, return")
            return
        }

        android.util.Log.d(TAG, ">>> TtsAlarmReceiver: starting TtsBroadcastService")

        // 发送调试通知确认 Alarm 触发
        showAlarmTriggeredNotification(context)

        // 启动前台服务执行 TTS 播报
        // 注意：这里 Intent 只带 action，播报内容从 SharedPreferences 读取
        // （因为 Alarm 触发时 App 可能已被系统杀死，Intent extra 不可靠）
        val serviceIntent = Intent(context, TtsBroadcastService::class.java).apply {
            action = TtsBroadcastService.ACTION_SPEAK_REPORT
            putExtra(EXTRA_REPORT_INTERVAL, intent.getIntExtra(EXTRA_REPORT_INTERVAL, 60))
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }

        // 设置下一次 Alarm（播完后安排下一轮）
        // TtsBroadcastService 在播完后会自己调用 scheduleNextReport
    }

    // ═══════════════════════════════════════════
    // 调试用通知（无 adb 日志时的诊断）
    // ═══════════════════════════════════════════

    private fun showAlarmTriggeredNotification(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                DEBUG_CHANNEL_ID,
                "Alarm调试",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Alarm触发调试通知"
                enableVibration(true)
            }
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notification = android.app.Notification.Builder(context, DEBUG_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("🔔 【听股通】Alarm 触发！")
            .setContentText("正在启动 TtsBroadcastService 播报...")
            .setPriority(android.app.Notification.PRIORITY_MAX)
            .setAutoCancel(false)
            .setOngoing(true)
            .build()
        nm.notify(DEBUG_NOTIFICATION_ID, notification)
        android.util.Log.d(TAG, ">>> DEBUG NOTIF: Alarm triggered!")
    }
}
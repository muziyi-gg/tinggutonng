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
 * 即使 Flutter Dart isolate 在熄屏时被暂停，Alarm 也能通过系统唤醒来触发播报。
 */
class TtsAlarmReceiver : BroadcastReceiver() {

    companion object {
        const val TAG = "TtsAlarmReceiver"
        const val ACTION_TTS_ALARM = "com.tingutong.app.TTS_ALARM"
        const val EXTRA_REPORT_INTERVAL = "report_interval"
        const val REQUEST_CODE = 10001

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
                putExtra(EXTRA_REPORT_INTERVAL, intervalSec)
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
        if (intent.action != ACTION_TTS_ALARM) return

        Log.d(TAG, ">>> TtsAlarmReceiver triggered, starting TtsBroadcastService")

        // 启动前台服务执行 TTS 播报
        // 播报内容从 SharedPreferences 读取（Alarm 触发时 App 可能已被系统杀死）
        val serviceIntent = Intent(context, TtsBroadcastService::class.java).apply {
            action = TtsBroadcastService.ACTION_SPEAK_REPORT
            putExtra(EXTRA_REPORT_INTERVAL, intent.getIntExtra(EXTRA_REPORT_INTERVAL, 60))
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }
        // TtsBroadcastService 播完后会调用 scheduleNextReport 设置下一次 Alarm
    }
}
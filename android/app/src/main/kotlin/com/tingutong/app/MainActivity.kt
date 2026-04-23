package com.tingutong.app

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.net.Uri
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.tingutong.app/tts_service"
    private val DEBUG_CHANNEL_ID = "debug_channel"
    private val DEBUG_NOTIFICATION_ID = 999

    // SharedPreferences key for stock names (used by TtsBroadcastService)
    companion object {
        const val PREFS_NAME = "FlutterSharedPreferences"
        const val KEY_STOCK_NAMES = "tingutong_stock_names"
        const val KEY_STOCK_CODES = "tingutong_stock_codes"
        const val KEY_REPORT_INTERVAL = "tingutong_report_interval"
        const val KEY_BACKGROUND_ACTIVE = "tingutong_background_active"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                // ─────────────────────────────────────────
                // 定时器管理（熄屏后由 AlarmManager 唤醒）
                // ─────────────────────────────────────────
                "startBackgroundReporting" -> {
                    try {
                        val interval = call.argument<Int>("intervalSec") ?: 60
                        val stockNamesJson = call.argument<String>("stockNamesJson") ?: "{}"
                        val stockCodesJson = call.argument<String>("stockCodesJson") ?: "[]"

                        android.util.Log.d("MainActivity", ">>> startBackgroundReporting called")
                        createDebugNotificationChannel()
                        showDebugNotification("✅ startBackgroundReporting 调用成功！间隔=${interval}秒")

                        saveReportingConfig(interval, stockNamesJson, stockCodesJson)
                        scheduleNextReport(interval)

                        android.util.Log.d("MainActivity", ">>> startBackgroundReporting done")
                        result.success(true)
                    } catch (e: Exception) {
                        android.util.Log.e("MainActivity", "!!! startBackgroundReporting EXCEPTION: ${e.message}")
                        showDebugNotification("❌ startBackgroundReporting 异常：${e.message}")
                        result.error("NATIVE_ERROR", e.message, null)
                    }
                }
                "stopBackgroundReporting" -> {
                    cancelBackgroundReporting()
                    result.success(true)
                }
                "updateBackgroundReporting" -> {
                    // 播报配置变更（间隔/股票列表变化）
                    val interval = call.argument<Int>("intervalSec") ?: 60
                    val stockNamesJson = call.argument<String>("stockNamesJson") ?: "{}"
                    val stockCodesJson = call.argument<String>("stockCodesJson") ?: "[]"
                    saveReportingConfig(interval, stockNamesJson, stockCodesJson)
                    // Alarm 已在 scheduleNextReport 中更新，不需要重新设置
                    result.success(true)
                }
                "openExactAlarmSettings" -> {
                    // 打开精确闹钟权限设置页面
                    try {
                        val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_SETTINGS_ERROR", e.message, null)
                    }
                }

                // ─────────────────────────────────────────
                // 前台播报（App 在前台时由 Flutter 控制）
                // ─────────────────────────────────────────
                "triggerBackgroundSpeak" -> {
                    // Flutter 切后台时触发一次熄屏播报
                    val interval = call.argument<Int>("intervalSec") ?: 60
                    val intent = Intent(this, TtsBroadcastService::class.java).apply {
                        action = TtsBroadcastService.ACTION_SPEAK_REPORT
                        putExtra("report_interval", interval)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }

                "stopTtsService" -> {
                    TtsBroadcastService.stopService(this)
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (!Settings.canDrawOverlays(this)) {
                val intent = Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName")
                )
                startActivity(intent)
            }
        }
    }

    // ═══════════════════════════════════════════
    // 私有方法
    // ═══════════════════════════════════════════

    /**
     * 保存播报配置到 SharedPreferences，TtsBroadcastService 通过 Alarm 唤醒后从这里读取。
     * 为什么要存 SharedPreferences？
     * Alarm 触发时 App 可能已被系统杀死（Flutter 被卸载或进程被杀），
     * 此时 Intent extra 不可靠，需要从持久化存储读取。
     */
    private fun saveReportingConfig(intervalSec: Int, stockNamesJson: String, stockCodesJson: String) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit()
            .putInt(KEY_REPORT_INTERVAL, intervalSec)
            .putString(KEY_STOCK_NAMES, stockNamesJson)
            .putString(KEY_STOCK_CODES, stockCodesJson)
            .putBoolean(KEY_BACKGROUND_ACTIVE, true)
            .apply()
        android.util.Log.d("MainActivity", ">>> saveReportingConfig: interval=$intervalSec, namesLen=${stockNamesJson.length}, codesLen=${stockCodesJson.length}, active=true")
    }

    private fun clearReportingConfig() {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit()
            .putBoolean(KEY_BACKGROUND_ACTIVE, false)
            .apply()
    }

    /**
     * 设置 AlarmManager 精确定时器（熄屏后由系统唤醒）
     * 使用 setExactAndAllowWhileIdle 保证 Doze 模式下也能触发
     */
    private fun scheduleNextReport(intervalSec: Int) {
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(this, TtsAlarmReceiver::class.java).apply {
            action = TtsAlarmReceiver.ACTION_TTS_ALARM
            putExtra(TtsAlarmReceiver.EXTRA_REPORT_INTERVAL, intervalSec)
        }
        val pendingIntent = PendingIntent.getBroadcast(
            this,
            TtsAlarmReceiver.REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Android 12+ 检查精确闹钟权限
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (!alarmManager.canScheduleExactAlarms()) {
                android.util.Log.w("MainActivity", "SCHEDULE_EXACT_ALARM permission not granted")
                android.util.Log.d("MainActivity", "scheduleNextReport: SKIPPED (no permission)")
                createDebugNotificationChannel()
                showDebugNotification("❌ 精确闹钟权限被拒！熄屏播报无法工作，请去系统设置开启")
                // 返回错误码，由 Flutter 端弹对话框引导用户
                result.error("EXACT_ALARM_PERMISSION_DENIED", "SCHEDULE_EXACT_ALARM permission denied", null)
                return
            } else {
                android.util.Log.d("MainActivity", "SCHEDULE_EXACT_ALARM permission OK")
            }
        }

        val triggerTime = System.currentTimeMillis() + (intervalSec * 1000L)
        val triggerDate = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.US).format(java.util.Date(triggerTime))
        android.util.Log.d("MainActivity", "scheduleNextReport: calling setExactAndAllowWhileIdle, now=${System.currentTimeMillis()/1000}s, trigger=${triggerTime/1000}s ($triggerDate), interval=${intervalSec}s")

        alarmManager.setExactAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            triggerTime,
            pendingIntent
        )
        android.util.Log.d("MainActivity", "scheduleNextReport: setExactAndAllowWhileIdle called OK")

        showDebugNotification("⏰ Alarm 已设置！熄屏后将于 $triggerDate 触发第1次播报")

        android.util.Log.d("MainActivity", "scheduleNextReport: done, scheduling next at $triggerDate")
    }

    /**
     * 取消 AlarmManager 定时器（用户关闭播报时）
     */
    private fun cancelBackgroundReporting() {
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(this, TtsAlarmReceiver::class.java).apply {
            action = TtsAlarmReceiver.ACTION_TTS_ALARM
        }
        val pendingIntent = PendingIntent.getBroadcast(
            this,
            TtsAlarmReceiver.REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        alarmManager.cancel(pendingIntent)
        TtsBroadcastService.stopService(this)
        clearReportingConfig()
        android.util.Log.d("MainActivity", "Background reporting cancelled")
    }

    // ═══════════════════════════════════════════
    // 调试用通知（用于无 adb 日志时的诊断）
    // ═══════════════════════════════════════════

    private fun createDebugNotificationChannel() {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                DEBUG_CHANNEL_ID,
                "调试通知",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "熄屏播报调试用通知"
                enableLights(true)
                enableVibration(true)
            }
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }

    private fun showDebugNotification(message: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // 取消旧通知（每次更新）
        nm.cancel(DEBUG_NOTIFICATION_ID)
        // 发送新通知
        val notification = android.app.Notification.Builder(this, DEBUG_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("【听股通调试】")
            .setContentText(message)
            .setPriority(android.app.Notification.PRIORITY_HIGH)
            .setAutoCancel(false)
            .setOngoing(true)
            .build()
        nm.notify(DEBUG_NOTIFICATION_ID, notification)
        android.util.Log.d("MainActivity", ">>> DEBUG NOTIF: $message")
    }
}
package com.tingutong.app

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
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.tingutong.app/tts_service"
    private val DEBUG_CHANNEL_ID = "debug_channel"
    private val DEBUG_NOTIFICATION_ID = 999

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

                        // ─── 关键：启动前台保活服务 ───
                        // 系统对音频/媒体类应用有更高优先级，不轻易杀死
                        // TtsBroadcastService 播完后延迟 5 分钟才销毁，这段时间由 TtsForegroundService 承接保活
                        TtsForegroundService.startService(this)

                        createDebugNotificationChannel()
                        showDebugNotification("✅ 熄屏播报已开启，间隔=${interval}秒")

                        saveReportingConfig(interval, stockNamesJson, stockCodesJson)
                        scheduleNextReport(interval)

                        result.success(true)
                    } catch (e: SecurityException) {
                        showDebugNotification("⚠️ 精确闹钟权限被拒，请去系统设置开启")
                        result.error("EXACT_ALARM_PERMISSION_DENIED", "SCHEDULE_EXACT_ALARM permission denied", null)
                    } catch (e: Exception) {
                        showDebugNotification("❌ 熄屏播报异常：${e.message}")
                        result.error("NATIVE_ERROR", e.message, null)
                    }
                }
                "stopBackgroundReporting" -> {
                    cancelBackgroundReporting()
                    result.success(true)
                }
                "updateBackgroundReporting" -> {
                    val interval = call.argument<Int>("intervalSec") ?: 60
                    val stockNamesJson = call.argument<String>("stockNamesJson") ?: "{}"
                    val stockCodesJson = call.argument<String>("stockCodesJson") ?: "[]"
                    saveReportingConfig(interval, stockNamesJson, stockCodesJson)
                    result.success(true)
                }
                "openExactAlarmSettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_SETTINGS_ERROR", e.message, null)
                    }
                }
                // ─────────────────────────────────────────
                // 电池优化白名单引导（国产手机必须）
                // ─────────────────────────────────────────
                "guideBatteryOptimization" -> {
                    guideBatteryOptimization()
                    result.success(true)
                }
                "openBatteryOptimizationSettings" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                            startActivity(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_SETTINGS_ERROR", e.message, null)
                    }
                }
                "isManufacturerWithRestrictiveBackground" -> {
                    result.success(isRestrictiveManufacturer())
                }

                // ─────────────────────────────────────────
                // 前台播报（App 在前台时由 Flutter 控制）
                // ─────────────────────────────────────────
                "triggerBackgroundSpeak" -> {
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
        // 检测是否有悬浮窗权限（部分厂商需要）
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
     */
    private fun saveReportingConfig(intervalSec: Int, stockNamesJson: String, stockCodesJson: String) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit()
            .putInt(KEY_REPORT_INTERVAL, intervalSec)
            .putString(KEY_STOCK_NAMES, stockNamesJson)
            .putString(KEY_STOCK_CODES, stockCodesJson)
            .putBoolean(KEY_BACKGROUND_ACTIVE, true)
            .apply()
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
                createDebugNotificationChannel()
                showDebugNotification("❌ 精确闹钟权限被拒！熄屏播报无法工作，请去系统设置开启")
                throw SecurityException("SCHEDULE_EXACT_ALARM permission denied")
            }
        }

        val triggerTime = System.currentTimeMillis() + (intervalSec * 1000L)

        alarmManager.setExactAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            triggerTime,
            pendingIntent
        )

        val triggerDate = java.text.SimpleDateFormat("HH:mm", java.util.Locale.US).format(java.util.Date(triggerTime))
        showDebugNotification("⏰ 已设置熄屏播报，下次 ${triggerDate} 触发")

        android.util.Log.d("MainActivity", "scheduleNextReport: next at $triggerDate")
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
        // 停止前台保活服务
        TtsForegroundService.stopService(this)
        clearReportingConfig()
        showDebugNotification("🛑 熄屏播报已关闭")
    }

    // ═══════════════════════════════════════════
    // 厂商电池优化引导（国产手机必须）
    // ═══════════════════════════════════════════

    /**
     * 检测是否为后台限制严格的厂商（小米/华为/OPPO/vivo/三星等）
     */
    private fun isRestrictiveManufacturer(): Boolean {
        val manufacturer = Build.MANUFACTURER.lowercase()
        return manufacturer.contains("xiaomi") ||
               manufacturer.contains("huawei") ||
               manufacturer.contains("honor") ||
               manufacturer.contains("oppo") ||
               manufacturer.contains("realme") ||
               manufacturer.contains("oneplus") ||
               manufacturer.contains("vivo") ||
               manufacturer.contains("samsung") ||
               manufacturer.contains("meizu") ||
               manufacturer.contains("letv") ||
               manufacturer.contains("coolpad")
    }

    /**
     * 引导用户到厂商电池/自启动设置页面
     * 这是确保熄屏播报在国产手机上正常工作的关键步骤
     */
    private fun guideBatteryOptimization() {
        if (!isRestrictiveManufacturer()) {
            // 非限制性厂商，跳转到通用电池优化设置
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                try { startActivity(intent) } catch (e: Exception) { }
            }
            return
        }

        val manufacturer = Build.MANUFACTURER.lowercase()
        val intent = Intent().apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }

        when {
            manufacturer.contains("xiaomi") -> {
                intent.setComponent(android.content.ComponentName(
                    "com.miui.powerkeeper",
                    "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"
                ))
                intent.putExtra("package_name", packageName)
                intent.putExtra("package_label", "听股通")
            }
            manufacturer.contains("huawei") || manufacturer.contains("honor") -> {
                intent.setComponent(android.content.ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"
                ))
            }
            manufacturer.contains("oppo") || manufacturer.contains("realme") -> {
                intent.setComponent(android.content.ComponentName(
                    "com.coloros.safecenter",
                    "com.coloros.safecenter.permission.startup.StartupAppListActivity"
                ))
            }
            manufacturer.contains("vivo") -> {
                intent.setComponent(android.content.ComponentName(
                    "com.vivo.permissionmanager",
                    "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"
                ))
            }
            manufacturer.contains("samsung") -> {
                intent.setComponent(android.content.ComponentName(
                    "com.samsung.android.lool",
                    "com.samsung.android.sm.ui.battery.BatteryActivity"
                ))
            }
            else -> {
                // 兜底：通用电池优化设置
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    val fallback = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    try { startActivity(fallback) } catch (e: Exception) { }
                }
                return
            }
        }

        try {
            startActivity(intent)
        } catch (e: android.content.ActivityNotFoundException) {
            // 找不到对应 Activity，降级到通用设置
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val fallback = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                try { startActivity(fallback) } catch (e2: Exception) { }
            }
        }
    }

    // ═══════════════════════════════════════════
    // 调试用通知（用于无 adb 日志时的诊断）
    // ═══════════════════════════════════════════

    private fun createDebugNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                DEBUG_CHANNEL_ID,
                "调试通知",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "熄屏播报调试用通知"
                enableLights(true)
                enableVibration(false)
            }
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }

    private fun showDebugNotification(message: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // 取消旧通知，发送新通知（每次更新，不累积）
        nm.cancel(DEBUG_NOTIFICATION_ID)
        val notification = android.app.Notification.Builder(this, DEBUG_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("【听股通】")
            .setContentText(message)
            .setPriority(android.app.Notification.PRIORITY_HIGH)
            .setAutoCancel(true)
            .build()
        nm.notify(DEBUG_NOTIFICATION_ID, notification)
    }
}
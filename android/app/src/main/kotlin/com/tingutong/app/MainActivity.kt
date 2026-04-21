package com.tingutong.app

import android.app.AlarmManager
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
                    // 用户开启播报，同时启动 AlarmManager 定时器
                    // 前后台统一入口：前台走 Flutter 逻辑，后台走 Android 原生
                    val interval = call.argument<Int>("intervalSec") ?: 60
                    val stockNamesJson = call.argument<String>("stockNamesJson") ?: "{}"
                    val stockCodesJson = call.argument<String>("stockCodesJson") ?: "[]"

                    android.util.Log.d("MainActivity", ">>> startBackgroundReporting called: interval=$interval, namesLen=${stockNamesJson.length}, codesLen=${stockCodesJson.length}")

                    // 保存播报配置（TtsBroadcastService 熄屏后从这里读取）
                    saveReportingConfig(interval, stockNamesJson, stockCodesJson)

                    // 设置 AlarmManager 定时器（熄屏后唤醒）
                    scheduleNextReport(interval)

                    android.util.Log.d("MainActivity", ">>> startBackgroundReporting done")
                    result.success(true)
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

        val triggerTime = System.currentTimeMillis() + (intervalSec * 1000L)

        // Android 12+ 检查精确闹钟权限
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (!alarmManager.canScheduleExactAlarms()) {
                android.util.Log.w("MainActivity", "SCHEDULE_EXACT_ALARM permission not granted")
                return
            }
        }

        alarmManager.setExactAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            triggerTime,
            pendingIntent
        )
        android.util.Log.d("MainActivity", "Alarm scheduled in ${intervalSec}s")
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
}
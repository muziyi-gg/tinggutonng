package com.tingutong.app

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.tingutong.app/tts_service"
    private val SERVICE_EVENTS_CHANNEL = "com.tingutong.app/tts_service_events"
    private val DEBUG_CHANNEL_ID = "debug_channel"
    private val DEBUG_NOTIFICATION_ID = 999
    private var screenStateEventSink: EventChannel.EventSink? = null
    private var screenReceiver: BroadcastReceiver? = null

    companion object {
        const val PREFS_NAME = "FlutterSharedPreferences"
        const val KEY_REPORT_INTERVAL = "tingutong_report_interval"
        const val KEY_STOCK_CODES = "tingutong_stock_codes"
        const val KEY_STOCK_NAMES = "tingutong_stock_names"
        private const val TAG = "TingutongMain"
    }

    private var pendingStartCallback: (() -> Unit)? = null

    override fun onDestroy() {
        screenReceiver?.let { unregisterReceiver(it) }
        screenReceiver = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {

                "startBackgroundReporting" -> {
                    val interval = call.argument<Int>("intervalSec") ?: 60
                    val stockNamesJson = call.argument<String>("stockNamesJson") ?: "{}"
                    val stockCodesJson = call.argument<String>("stockCodesJson") ?: "[]"
                    saveReportingConfig(interval, stockNamesJson, stockCodesJson)
                    checkPermissionsAndStart(interval)
                    result.success(true)
                }

                "stopBackgroundReporting" -> {
                    stopAllServices()
                    result.success(true)
                }

                "updateBackgroundReporting" -> {
                    val interval = call.argument<Int>("intervalSec") ?: 60
                    val stockNamesJson = call.argument<String>("stockNamesJson") ?: "{}"
                    val stockCodesJson = call.argument<String>("stockCodesJson") ?: "[]"
                    saveReportingConfig(interval, stockNamesJson, stockCodesJson)
                    result.success(true)
                }

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

                "triggerBackgroundSpeak" -> {
                    triggerBroadcastService()
                    result.success(true)
                }

                "openExactAlarmSettings" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                            startActivity(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_SETTINGS_ERROR", e.message, null)
                    }
                }

                "stopTtsService" -> {
                    Intent(this, TtsBroadcastService::class.java).also { act -> act.action = TtsBroadcastService.TTS_ACTION_STOP; startService(act) }
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        // ─── 屏幕状态 EventChannel ─────────────────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.tingutong.app/screen_state")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    screenStateEventSink = events
                    // 通知 Flutter 当前屏幕状态
                    events?.success(mapOf("screenOff" to DebugLogger._screenOn))
                }
                override fun onCancel(args: Any?) {
                    screenStateEventSink = null
                }
            })

        // ─── 播报服务状态 EventChannel（TtsBroadcastService 写入状态，Flutter 监听）──
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SERVICE_EVENTS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    TtsBroadcastService.serviceEventSink = events
                    Log.d(TAG, "tts_service_events: listener registered, sink=$events")
                }
                override fun onCancel(args: Any?) {
                    TtsBroadcastService.serviceEventSink = null
                    Log.d(TAG, "tts_service_events: listener cancelled")
                }
            })

        // ─── Debug MethodChannel ───────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.tingutong.app/debug").setMethodCallHandler { call, result ->
            when (call.method) {
                "getDebugLogs" -> {
                    val entries = DebugLogger.getLogEntries()
                    val text = entries.joinToString("\n") { "${it.tag}|${it.msg}" }
                    result.success(text)
                }
                "getComponentStatus" -> {
                    val status = DebugLogger.getFullStatus()
                    result.success(status.toString())
                }
                "clearDebugLogs" -> {
                    DebugLogger.clearLogs()
                    result.success(null)
                }
                "enableDebug" -> {
                    DebugLogger.init(this@MainActivity)
                    DebugLogger.enable()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // ─── 屏幕广播监听：向 Flutter 推送状态 ───────
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        screenReceiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                when (intent?.action) {
                    Intent.ACTION_SCREEN_OFF -> {
                        DebugLogger.log("SYSTEM", "屏幕熄灭")
                        screenStateEventSink?.success(mapOf("screenOff" to true))
                    }
                    Intent.ACTION_SCREEN_ON, Intent.ACTION_USER_PRESENT -> {
                        DebugLogger.log("SYSTEM", "屏幕点亮")
                        screenStateEventSink?.success(mapOf("screenOff" to false))
                    }
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(screenReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(screenReceiver, filter)
        }

        // 初始化 DebugLogger（注册屏幕监听）
        DebugLogger.init(this@MainActivity)
    }

    // ═══════════════════════════════════════════
    // 权限检查 & 启动服务
    // ═══════════════════════════════════════════

    private fun checkPermissionsAndStart(interval: Int) {
        pendingStartCallback = { startAllServices(interval) }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                android.app.AlertDialog.Builder(this)
                    .setTitle("通知权限")
                    .setMessage("听股通需要通知权限以在锁屏时显示播报状态。点击确定跳转设置开启。")
                    .setPositiveButton("确定") { _, _ ->
                        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                        intent.data = android.net.Uri.fromParts("package", packageName, null)
                        startActivity(intent)
                    }
                    .setNegativeButton("取消") { _, _ ->
                        // 即使没权限也继续启动（音频播报不依赖通知权限）
                        pendingStartCallback?.invoke()
                    }
                    .show()
                return
            }
        }
        pendingStartCallback?.invoke()
        pendingStartCallback = null
    }

    private fun startAllServices(interval: Int) {
        createDebugNotificationChannel()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                try {
                    showDebugNotification("📢 通知权限缺失，部分功能受限")
                } catch (e: Exception) { Log.e(TAG, "showDebugNotification failed: $e") }
            }
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val powerManager = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
                if (!powerManager.isIgnoringBatteryOptimizations(packageName)) {
                    try { showDebugNotification("⚠️ 请在设置中加入电池白名单，否则熄屏可能中断") } catch (e: Exception) { Log.e(TAG, "showDebug failed: $e") }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "startAllServices failed: $e")
            return
        }

        val dataIntent = Intent(this, TtsDataService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(dataIntent)
        } else {
            startService(dataIntent)
        }

        val broadcastIntent = Intent(this, TtsBroadcastService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(broadcastIntent)
        } else {
            startService(broadcastIntent)
        }

        showDebugNotification("✅ 熄屏播报已开启，间隔=${interval}秒")
        Log.d(TAG, "All services started")
    }

    private fun stopAllServices() {
        Intent(this, TtsDataService::class.java).also { act -> act.action = TtsDataService.ACTION_STOP; startService(act) }
        Intent(this, TtsBroadcastService::class.java).also { act -> act.action = TtsBroadcastService.TTS_ACTION_STOP; startService(act) }
        clearReportingConfig()
        createDebugNotificationChannel()
        showDebugNotification("🛑 熄屏播报已关闭")
        Log.d(TAG, "All services stopped")
    }

    private fun triggerBroadcastService() {
        val intent = Intent(this, TtsBroadcastService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    // ═══════════════════════════════════════════
    // 配置保存
    // ═══════════════════════════════════════════

    private fun saveReportingConfig(intervalSec: Int, stockNamesJson: String, stockCodesJson: String) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit()
            .putInt(KEY_REPORT_INTERVAL, intervalSec)
            .putString(KEY_STOCK_CODES, stockCodesJson)
            .putString(KEY_STOCK_NAMES, stockNamesJson)
            .apply()
    }

    private fun clearReportingConfig() {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit()
            .remove(KEY_REPORT_INTERVAL)
            .remove(KEY_STOCK_CODES)
            .remove(KEY_STOCK_NAMES)
            .apply()
    }

    // ═══════════════════════════════════════════
    // 电池优化引导
    // ═══════════════════════════════════════════

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
               manufacturer.contains("meizu")
    }

    private fun guideBatteryOptimization() {
        if (!isRestrictiveManufacturer()) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                try {
                    val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    startActivity(intent)
                } catch (e: Exception) { }
            }
            return
        }

        val manufacturer = Build.MANUFACTURER.lowercase()
        val intent = Intent().apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK }

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
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    try {
                        val fallback = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        startActivity(fallback)
                    } catch (e: Exception) { }
                }
                return
            }
        }

        try {
            startActivity(intent)
        } catch (e: android.content.ActivityNotFoundException) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                try {
                    val fallback = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    startActivity(fallback)
                } catch (e2: Exception) { }
            }
        }
    }

    // ═══════════════════════════════════════════
    // 调试通知
    // ═══════════════════════════════════════════

    private fun createDebugNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                DEBUG_CHANNEL_ID,
                "调试通知",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "听股通调试用通知"
                enableLights(true)
                enableVibration(false)
            }
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }

    private fun showDebugNotification(message: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(DEBUG_NOTIFICATION_ID)
        val notification = NotificationCompat.Builder(this, DEBUG_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentTitle("【听股通】")
            .setContentText(message)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .build()
        nm.notify(DEBUG_NOTIFICATION_ID, notification)
    }
}
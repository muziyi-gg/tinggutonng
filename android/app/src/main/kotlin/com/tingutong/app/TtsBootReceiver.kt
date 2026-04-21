package com.tingutong.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.util.Log

/**
 * 设备重启后恢复熄屏播报定时器。
 *
 * 背景：setExactAndAllowWhileIdle 在重启后不会自动恢复（系统会清除），
 * 所以需要在 BOOT_COMPLETED 时手动重建 AlarmManager 定时器。
 *
 * 逻辑：
 * 1. 读取 SharedPreferences 中的播报配置
 * 2. 如果 _backgroundReportingActive == true，重新设置 AlarmManager
 * 3. 让 TtsBroadcastService 在下次 Alarm 触发时自动读取最新价格
 */
class TtsBootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "TtsBootReceiver"
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val KEY_REPORT_INTERVAL = "tingutong_report_interval"
        private const val KEY_BACKGROUND_ACTIVE = "tingutong_background_active"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val backgroundActive = prefs.getBoolean(KEY_BACKGROUND_ACTIVE, false)
        val interval = prefs.getInt(KEY_REPORT_INTERVAL, 60)

        if (!backgroundActive) {
            Log.d(TAG, "Background reporting not active, skipping restore")
            return
        }

        Log.d(TAG, "Restoring background reporting: interval=${interval}s")

        // 恢复 AlarmManager 定时器
        TtsAlarmReceiver.scheduleNextReport(context, interval)

        // 同时将激活标志写入一个持久化位置
        //（Flutter 的 SharedPreferences 在重启后仍然存在，这里只是额外确认）
        Log.d(TAG, "Background reporting restored successfully")
    }
}

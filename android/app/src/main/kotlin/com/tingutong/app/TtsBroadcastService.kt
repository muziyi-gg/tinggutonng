package com.tingutong.app

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import org.json.JSONArray
import java.util.*

/**
 * Android 原生前台服务，使用系统 TextToSpeech 执行播报。
 *
 * 相比 Flutter flutter_tts 的优势：
 * - 不依赖 Dart isolate，在 Flutter 被系统暂停时仍能正常工作
 * - 使用 PARTIAL_WAKE_LOCK 保证 CPU 持续工作到播报完成
 *
 * 触发路径：
 *   TtsAlarmReceiver.onReceive() → startForegroundService(this)
 *   → TtsBroadcastService.onStartCommand() → TextToSpeech.speak()
 */
class TtsBroadcastService : Service() {

    companion object {
        const val TAG = "TtsBroadcastService"
        const val ACTION_SPEAK_REPORT = "com.tingutong.app.ACTION_SPEAK_REPORT"
        const val ACTION_STOP = "com.tingutong.app.ACTION_STOP_TTS_SERVICE"

        const val CHANNEL_ID = "tingutong_tts_channel"
        const val NOTIFICATION_ID = 20002

        // SharedPreferences keys（与 Flutter stock_provider 保持一致）
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val KEY_WATCHLIST = "flutter.VGhpZ1VuaXQyX3ZhMg==" // watchlist_v2 base64 encoded
        private const val KEY_REPORT_INTERVAL = "tingutong_report_interval"
        private const val KEY_STOCK_NAMES = "tingutong_stock_names" // JSON: {"code": "name", ...}

        private const val WAKE_LOCK_TAG = "Tingutong:TTSWakeLock"

        // 播报间隔（秒），熄屏时由 AlarmManager 精确控制
        var defaultIntervalSec = 60

        fun stopService(context: Context) {
            val intent = Intent(context, TtsBroadcastService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }
    }

    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var wakeLock: PowerManager.WakeLock? = null
    private var pendingAlarms: MutableList<String> = mutableListOf()
    private var speakQueue: MutableList<String> = mutableListOf()
    private var currentIndex = 0
    private var reportInterval = 60

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "TtsBroadcastService onCreate")
        createNotificationChannel()
        initTTS()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand action=${intent?.action}")

        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_SPEAK_REPORT -> {
                reportInterval = intent.getIntExtra("report_interval", defaultIntervalSec)
                // 立即显示前台通知
                startForeground(NOTIFICATION_ID, buildNotification("正在播报行情..."))

                // 读取需要播报的内容
                loadAndSpeakStocks()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        Log.d(TAG, "TtsBroadcastService onDestroy")
        releaseWakeLock()
        tts?.stop()
        tts?.shutdown()
        tts = null
        ttsReady = false
        // 取消下次 Alarm（如果有）
        TtsAlarmReceiver.cancelAlarm(this)
        super.onDestroy()
    }

    // ═══════════════════════════════════════════
    // TTS 初始化（原生 Android TextToSpeech）
    // ═══════════════════════════════════════════
    private fun initTTS() {
        tts = TextToSpeech(this) { status ->
            if (status == TextToSpeech.SUCCESS) {
                val result = tts?.setLanguage(Locale.CHINESE)
                if (result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED) {
                    Log.w(TAG, "Chinese TTS not supported, falling back to default")
                    tts?.setLanguage(Locale.getDefault())
                } else {
                    ttsReady = true
                    Log.d(TAG, "TTS initialized: Chinese available")
                }
            } else {
                Log.e(TAG, "TTS init failed: status=$status")
            }
        }
    }

    // ═══════════════════════════════════════════
    // 加载股票数据并开始播报
    // ═══════════════════════════════════════════
    private fun loadAndSpeakStocks() {
        // 从 SharedPreferences 读取自选股列表
        // 由于熄屏后 Flutter 可能已被杀死，直接读取 Flutter 的存储
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val stockNamesRaw = prefs.getString(KEY_STOCK_NAMES, null)

        var stocks: List<Pair<String, String>> = emptyList()

        if (stockNamesRaw != null) {
            try {
                val json = org.json.JSONObject(stockNamesRaw)
                stocks = json.keys().asSequence().map { code ->
                    code to json.getString(code)
                }.toList()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to parse stock names: $e")
            }
        }

        // 如果 SharedPreferences 没有，尝试从 watchlist_v2 读取
        if (stocks.isEmpty()) {
            val watchlistRaw = prefs.getString(KEY_WATCHLIST, null)
            if (watchlistRaw != null) {
                try {
                    val arr = JSONArray(watchlistRaw)
                    stocks = (0 until arr.length()).map { i ->
                        val obj = arr.getJSONObject(i)
                        obj.getString("code") to obj.getString("name")
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to parse watchlist: $e")
                }
            }
        }

        if (stocks.isEmpty()) {
            Log.w(TAG, "No stocks to report, stopping service")
            // 播报空状态仍然触发下一次 Alarm（保持定时器活跃）
            scheduleNextAlarm()
            stopSelf()
            return
        }

        // 获取实时价格（通过腾讯 API，不依赖 Flutter）
        fetchPricesAndSpeak(stocks)
    }

    private fun fetchPricesAndSpeak(stocks: List<Pair<String, String>>) {
        // 使用同步 HTTP 获取价格（Alarm 触发时可以接受少量阻塞）
        // 但考虑到 Alarm 可能在任何时候触发，我们用异步 + WakeLock 的方式
        Thread {
            try {
                val codes = stocks.joinToString(",") { it.first }
                val url = "https://qt.gtimg.cn/q=$codes"
                val conn = java.net.URL(url).openConnection() as java.net.HttpURLConnection
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                conn.setRequestProperty("Referer", "https://gu.qq.com")
                conn.setRequestProperty("Accept", "*/*")

                val responseCode = conn.responseCode
                if (responseCode == 200) {
                    val reader = java.io.BufferedReader(
                        java.io.InputStreamReader(conn.inputStream, "gbk")
                    )
                    val body = reader.readText()
                    reader.close()
                    conn.disconnect()

                    val texts = parseAndBuildReport(body, stocks)
                    if (texts.isNotEmpty()) {
                        // 获得 WakeLock 开始播报
                        acquireWakeLock()
                        speakQueue = texts.toMutableList()
                        currentIndex = 0
                        speakNext()
                    } else {
                        Log.w(TAG, "No price data parsed, scheduling next alarm anyway")
                        scheduleNextAlarm()
                        stopSelf()
                    }
                } else {
                    Log.e(TAG, "Failed to fetch prices: HTTP $responseCode")
                    scheduleNextAlarm()
                    stopSelf()
                }
            } catch (e: Exception) {
                Log.e(TAG, "fetchPricesAndSpeak error: $e")
                // 网络失败仍然设置下一轮 Alarm
                scheduleNextAlarm()
                stopSelf()
            }
        }.start()
    }

    private fun parseAndBuildReport(body: String, stocks: List<Pair<String, String>>): List<String> {
        val texts = mutableListOf<String>()
        val re = Regex("""v_(\w+)="([^"]+)"""")

        for (match in re.findAll(body)) {
            val code = match.groupValues[1]
            val fields = match.groupValues[2].split("~")
            if (fields.size < 36) continue

            val stockInfo = stocks.find { it.first == code } ?: continue
            val name = stockInfo.second

            val price = fields.getOrNull(3)?.toDoubleOrNull() ?: continue
            val change = fields.getOrNull(31)?.toDoubleOrNull() ?: 0.0
            val changePct = fields.getOrNull(32)?.toDoubleOrNull() ?: 0.0

            val dir = if (changePct >= 0) "涨" else "跌"
            texts.add("$name，报${String.format("%.2f", price)}元，$dir${String.format("%.2f", kotlin.math.abs(changePct))}%")
        }

        return texts
    }

    private fun speakNext() {
        if (currentIndex >= speakQueue.size) {
            // 所有播报完成
            Log.d(TAG, "All stocks reported. Scheduling next alarm in ${reportInterval}s")
            releaseWakeLock()
            scheduleNextAlarm()
            stopSelf()
            return
        }

        val text = speakQueue[currentIndex]
        Log.d(TAG, "Speaking [$currentIndex/${speakQueue.size}]: $text")

        if (!ttsReady || tts == null) {
            Log.e(TAG, "TTS not ready, cannot speak")
            releaseWakeLock()
            scheduleNextAlarm()
            stopSelf()
            return
        }

        // 更新通知
        updateNotification("正在播报 ${currentIndex + 1}/${speakQueue.size}")

        val params = android.os.Bundle()
        tts?.setSpeechRate(0.85f)
        tts?.speak(text, TextToSpeech.QUEUE_ADD, params, "tts_utterance_$currentIndex")

        // 监听播报完成，播下一句
        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {
                Log.d(TAG, "TTS started: $utteranceId")
            }

            override fun onDone(utteranceId: String?) {
                currentIndex++
                // 句间停顿 800ms
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    speakNext()
                }, 800)
            }

            override fun onError(utteranceId: String?) {
                Log.e(TAG, "TTS error: $utteranceId")
                currentIndex++
                speakNext()
            }
        })
    }

    // ═══════════════════════════════════════════
    // WakeLock 管理
    // ═══════════════════════════════════════════
    private fun acquireWakeLock() {
        if (wakeLock != null) return
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            WAKE_LOCK_TAG
        )
        wakeLock?.acquire(120000) // 最多持有 2 分钟（超时保护）
        Log.d(TAG, "WakeLock acquired")
    }

    private fun releaseWakeLock() {
        if (wakeLock != null && wakeLock!!.isHeld) {
            wakeLock?.release()
            Log.d(TAG, "WakeLock released")
        }
        wakeLock = null
    }

    // ═══════════════════════════════════════════
    // 通知频道
    // ═══════════════════════════════════════════
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "听股通播报服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "后台运行时播报股票行情"
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
            Intent(this, MainActivity::class.java),
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
            .build()
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }

    // ═══════════════════════════════════════════
    // 定时器管理
    // ═══════════════════════════════════════════
    private fun scheduleNextAlarm() {
        TtsAlarmReceiver.scheduleNextReport(this, reportInterval)
    }
}
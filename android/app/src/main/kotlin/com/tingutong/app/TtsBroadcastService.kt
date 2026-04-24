package com.tingutong.app
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.media.session.MediaSessionCompat
import androidx.media.session.PlaybackStateCompat
import androidx.media.MediaMetadataCompat
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat.MediaStyle
import org.json.JSONArray
import java.util.*

/**
 * Android 原生前台服务，模拟音频类 App 行为：
 * - foregroundServiceType="mediaPlayback"
 * - MediaSession 注册到系统媒体控制器
 * - 请求音频焦点，防止与其他音乐/导航 App 冲突
 * - 使用 PARTIAL_WAKE_LOCK 保证熄屏时 CPU 持续工作
 *
 * 触发路径：
 *   AlarmManager → TtsAlarmReceiver.onReceive()
 *   → startForegroundService(this) → TextToSpeech.speak()
 */
class TtsBroadcastService : Service() {

    companion object {
        const val TAG = "TtsBroadcastService"
        const val ACTION_SPEAK_REPORT = "com.tingutong.app.ACTION_SPEAK_REPORT"
        const val ACTION_STOP = "com.tingutong.app.ACTION_STOP_TTS_SERVICE"

        const val CHANNEL_ID = "tingutong_tts_channel"
        const val CHANNEL_NAME = "听股通播报服务"
        const val NOTIFICATION_ID = 20002

        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val KEY_WATCHLIST = "flutter.VGhpZ1VuaXQyX3ZhMg=="
        private const val KEY_REPORT_INTERVAL = "tingutong_report_interval"
        private const val KEY_STOCK_NAMES = "tingutong_stock_names"

        private const val WAKE_LOCK_TAG = "Tingutong:TTSWakeLock"
        private const val MEDIA_SESSION_TAG = "TingutongTTS"
        private const val DEBUG_CHANNEL_ID = "service_debug_channel"
        private const val DEBUG_NOTIFICATION_ID = 777

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
    private var speakQueue: MutableList<String> = mutableListOf()
    private var currentIndex = 0
    private var reportInterval = 60

    // ─── 音频焦点 & MediaSession ───
    private var mediaSession: MediaSessionCompat? = null
    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var hasAudioFocus = false

    private val audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                // 获得焦点，恢复播报
                Log.d(TAG, "AudioFocus: GAIN")
                hasAudioFocus = true
            }
            AudioManager.AUDIOFOCUS_LOSS -> {
                // 永久失去焦点，停止
                Log.d(TAG, "AudioFocus: LOSS")
                hasAudioFocus = false
                tts?.stop()
                stopSelf()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // 暂时失去焦点（比如来电），暂停
                Log.d(TAG, "AudioFocus: LOSS_TRANSIENT")
                hasAudioFocus = false
                tts?.stop()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                // 可以降低音量继续
                Log.d(TAG, "AudioFocus: LOSS_TRANSIENT_CAN_DUCK")
                tts?.setSpeechRate(0.6f)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        android.util.Log.d(TAG, ">>> TtsBroadcastService onCreate")

        showServiceStartedNotification()

        // ─── 1. 创建通知渠道 ───
        createNotificationChannel()

        // ─── 2. 注册 MediaSession（系统媒体控制器识别为音频 App）───
        initMediaSession()

        // ─── 3. 请求音频焦点 ───
        requestAudioFocus()

        // ─── 4. 初始化 TTS ───
        initTTS()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        android.util.Log.d(TAG, ">>> TtsBroadcastService onStartCommand: action=${intent?.action}")

        // ─── 立即获取 WakeLock（熄屏保活的关键！）─────────────────
        // 在主线程获取，不依赖子线程。即使手机进入 Doze 深度休眠，
        // WakeLock 也能保证 CPU 持续运行，Service 不会被杀死。
        try {
            acquireWakeLock()
        } catch (e: Throwable) {
            android.util.Log.e(TAG, "acquireWakeLock failed: $e")
        }

        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_SPEAK_REPORT -> {
                reportInterval = intent.getIntExtra("report_interval", defaultIntervalSec)
                startForeground(NOTIFICATION_ID, buildNotification("正在播报行情...", isPlaying = true))
                // 读取股票配置（在主线程同步完成，避免子线程竞态）
                val stocks = loadStocksFromPrefs()
                if (stocks.isEmpty()) {
                    android.util.Log.w(TAG, "No stocks to report")
                    scheduleNextAlarm()
                    // 延迟销毁，不立即 stopSelf
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ stopSelf() }, 60000)
                } else {
                    loadAndSpeakStocks(stocks)
                }
            }
        }
        // START_STICKY：系统杀死后重生，重生时走 ACTION_SPEAK_REPORT 路径重新播报
        return START_STICKY
    }

    override fun onDestroy() {
        Log.d(TAG, "TtsBroadcastService onDestroy")
        releaseAudioFocus()
        releaseMediaSession()
        releaseWakeLock()
        tts?.stop()
        tts?.shutdown()
        tts = null
        ttsReady = false
        TtsAlarmReceiver.cancelAlarm(this)
        super.onDestroy()
    }

    // ═══════════════════════════════════════════
    // MediaSession（音频类 App 必须）
    // ═══════════════════════════════════════════
    private fun initMediaSession() {
        mediaSession = MediaSessionCompat(this, MEDIA_SESSION_TAG).apply {
            setFlags(MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS)

            // 播放状态：播放中
            val state = PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY
                    or PlaybackStateCompat.ACTION_PAUSE
                    or PlaybackStateCompat.ACTION_STOP
                    or PlaybackStateCompat.ACTION_PLAY_PAUSE
                )
                .setState(PlaybackStateCompat.STATE_PLAYING, 0, 1.0f)
                .build()
            setPlaybackState(state)

            // 元数据：播报中
            val metadata = androidx.media.MediaMetadataCompat.Builder()
                .putString(androidx.media.MediaMetadataCompat.METADATA_KEY_TITLE, "听股通播报中")
                .putString(androidx.media.MediaMetadataCompat.METADATA_KEY_ARTIST, "行情播报")
                .build()
            setMetadata(metadata)

            setCallback(object : MediaSessionCompat.Callback() {
                override fun onStop() {
                    Log.d(TAG, "MediaSession: onStop")
                    tts?.stop()
                    stopSelf()
                }

                override fun onPause() {
                    Log.d(TAG, "MediaSession: onPause")
                    tts?.stop()
                }

                override fun onPlay() {
                    Log.d(TAG, "MediaSession: onPlay (ignored - TTS cannot be resumed)")
                }
            })

            setActive(true)
            Log.d(TAG, "MediaSession activated")
        }
    }

    private fun releaseMediaSession() {
        mediaSession?.apply {
            setPlaybackState(PlaybackStateCompat.Builder()
                .setState(PlaybackStateCompat.STATE_STOPPED, 0, 0f)
                .build())
            release()
        }
        mediaSession = null
    }

    // ═══════════════════════════════════════════
    // 音频焦点（防止与其他 App 冲突）
    // ═══════════════════════════════════════════
    private fun requestAudioFocus() {
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        val audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANT)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()

        audioFocusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(audioAttributes)
            .setAcceptsDelayedFocusGain(true)
            .setOnAudioFocusChangeListener(audioFocusChangeListener)
            .build()

        val result = audioManager?.requestAudioFocus(audioFocusRequest!!)
        hasAudioFocus = (result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
        Log.d(TAG, "AudioFocus request result: $result, hasFocus=$hasAudioFocus")
    }

    private fun releaseAudioFocus() {
        if (audioFocusRequest != null && hasAudioFocus) {
            audioManager?.abandonAudioFocusRequest(audioFocusRequest!!)
            hasAudioFocus = false
            Log.d(TAG, "AudioFocus released")
        }
    }

    // ═══════════════════════════════════════════
    // TTS 初始化
    // ═══════════════════════════════════════════
    private fun initTTS() {
        tts = TextToSpeech(this) { status ->
            if (status == TextToSpeech.SUCCESS) {
                val result = tts?.setLanguage(Locale.CHINESE)
                if (result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED) {
                    Log.w(TAG, "Chinese TTS not supported, falling back")
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
    // 加载股票数据（主线程同步读取 SharedPreferences）
    // ═══════════════════════════════════════════
    private fun loadStocksFromPrefs(): List<Pair<String, String>> {
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
                android.util.Log.e(TAG, "Failed to parse stock names: $e")
            }
        }

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
                    android.util.Log.e(TAG, "Failed to parse watchlist: $e")
                }
            }
        }

        return stocks
    }

    // ═══════════════════════════════════════════
    // 加载股票数据并开始播报（从 onStartCommand 传入）
    // WakeLock 已由 onStartCommand 主线程获取，这里只做网络请求
    // ═══════════════════════════════════════════
    private fun loadAndSpeakStocks(stocks: List<Pair<String, String>>) {
        if (stocks.isEmpty()) {
            android.util.Log.w(TAG, "No stocks to report, scheduling next alarm")
            scheduleNextAlarm()
            // 延迟销毁，给用户切回 App 的时间
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ stopSelf() }, 60000)
            return
        }

        fetchPricesAndSpeak(stocks)
    }

    private fun fetchPricesAndSpeak(stocks: List<Pair<String, String>>) {
        Thread {
            try {
                val codes = stocks.joinToString(",") { it.first }
                val url = "https://qt.gtimg.cn/q=$codes"
                val conn = java.net.URL(url).openConnection() as java.net.HttpURLConnection
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                conn.setRequestProperty("Referer", "https://gu.qq.com")
                conn.setRequestProperty("Accept", "*/*")

                if (conn.responseCode == 200) {
                    val reader = java.io.BufferedReader(
                        java.io.InputStreamReader(conn.inputStream, "gbk")
                    )
                    val body = reader.readText()
                    reader.close()
                    conn.disconnect()

                    val texts = parseAndBuildReport(body, stocks)
                    if (texts.isNotEmpty()) {
                        speakQueue = texts.toMutableList()
                        currentIndex = 0
                        speakNext()
                    } else {
                        Log.w(TAG, "No price data parsed")
                        scheduleNextAlarm()
                        stopSelf()
                    }
                } else {
                    Log.e(TAG, "HTTP ${conn.responseCode}")
                    scheduleNextAlarm()
                    stopSelf()
                }
            } catch (e: Exception) {
                Log.e(TAG, "fetchPricesAndSpeak error: $e")
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
            val changePct = fields.getOrNull(32)?.toDoubleOrNull() ?: 0.0

            val dir = if (changePct >= 0) "涨" else "跌"
            texts.add("$name，报${String.format("%.2f", price)}元，$dir${String.format("%.2f", kotlin.math.abs(changePct))}%")
        }

        return texts
    }

    private fun speakNext() {
        if (currentIndex >= speakQueue.size) {
            android.util.Log.d(TAG, "All stocks reported, scheduling next alarm in ${reportInterval}s")
            releaseWakeLock()
            scheduleNextAlarm()
            // ✅ 延迟销毁（不立即 stopSelf）：
            // 保留 Service 实例 5 分钟，给用户切回 App 的时间
            // 如果用户切回前台，Flutter 层的 Timer 会接管，不再需要原生 Service
            // 如果 5 分钟后用户仍未切回，系统会自动销毁此 Service（节省资源）
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                stopSelf()
            }, 300000) // 5 分钟
            // 播完更新通知为非播放状态
            updateNotification("播报完成，等待下次播报", isPlaying = false)
            return
        }

        val text = speakQueue[currentIndex]
        Log.d(TAG, "Speaking [$currentIndex/${speakQueue.size}]: $text")

        if (!ttsReady || tts == null) {
            Log.e(TAG, "TTS not ready")
            releaseWakeLock()
            scheduleNextAlarm()
            stopSelf()
            return
        }

        // 更新 MediaSession 状态
        updateMediaSessionState()

        val params = android.os.Bundle()
        tts?.setSpeechRate(0.85f)
        tts?.speak(text, TextToSpeech.QUEUE_ADD, params, "tts_utterance_$currentIndex")

        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {
                updateNotification("${currentIndex + 1}/${speakQueue.size}: $text", isPlaying = true)
            }

            override fun onDone(utteranceId: String?) {
                currentIndex++
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

    private fun updateMediaSessionState() {
        mediaSession?.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY
                    or PlaybackStateCompat.ACTION_PAUSE
                    or PlaybackStateCompat.ACTION_STOP
                )
                .setState(PlaybackStateCompat.STATE_PLAYING, currentIndex.toLong(), 1.0f)
                .build()
        )
    }

    // ═══════════════════════════════════════════
    // WakeLock
    // ═══════════════════════════════════════════
    private fun acquireWakeLock() {
        if (wakeLock != null) return
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
        // 5分钟（300秒）：覆盖 TTS 冷启动 + 网络请求 + 最长播报的耗时
        // 不使用带超时的 acquire(timeout)，改用无超时的 acquire()，
        // 因为 TTS 播报时长不确定，熄屏播报场景必须保证完整播完。
        wakeLock?.acquire()
        Log.d(TAG, "WakeLock acquired (no timeout)")
    }

    private fun releaseWakeLock() {
        if (wakeLock != null && wakeLock!!.isHeld) {
            wakeLock?.release()
            Log.d(TAG, "WakeLock released")
        }
        wakeLock = null
    }

    // ═══════════════════════════════════════════
    // 通知渠道（音频类 App 规范）
    // ═══════════════════════════════════════════
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "后台播报股票行情"
                setShowBadge(false)
                // 音频类 App：通知静音，不发出声音
                setSound(null, null)
                // 允许在锁屏和媒体控制器上显示
                setLockscreenVisibility(Notification.VISIBILITY_PUBLIC)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String, isPlaying: Boolean): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // 停止按钮
        val stopIntent = Intent(this, TtsBroadcastService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this, 1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(if (isPlaying) "听股通正在播报" else "听股通播报服务")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_tts_notification)
            .setOngoing(isPlaying)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setStyle(
                MediaStyle()
                    .setMediaSession(mediaSession?.sessionToken)
                    .setShowActionsInCompactView(0)
            )
            .addAction(R.drawable.ic_tts_notification, "停止", stopPendingIntent)
            .build()
    }

    private fun updateNotification(text: String, isPlaying: Boolean) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(text, isPlaying))
    }

    private fun scheduleNextAlarm() {
        TtsAlarmReceiver.scheduleNextReport(this, reportInterval)
    }

    // ═══════════════════════════════════════════
    // 调试用通知（无 adb 日志时的诊断）
    // ═══════════════════════════════════════════

    private fun showServiceStartedNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                DEBUG_CHANNEL_ID,
                "服务调试",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "服务启动调试通知"
                enableVibration(true)
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }

        val nm = getSystemService(NotificationManager::class.java)
        val notification = NotificationCompat.Builder(this, DEBUG_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_tts_notification)
            .setContentTitle("🎧 【听股通】TtsBroadcastService 已启动！")
            .setContentText("熄屏播报服务正在运行，正在合成语音...")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setAutoCancel(false)
            .setOngoing(true)
            .build()
        nm.notify(DEBUG_NOTIFICATION_ID, notification)
        android.util.Log.d(TAG, ">>> DEBUG NOTIF: TtsBroadcastService started!")
    }
}

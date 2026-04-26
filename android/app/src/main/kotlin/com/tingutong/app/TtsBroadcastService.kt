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
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.support.v4.media.MediaMetadataCompat
import android.util.Log
import androidx.core.app.NotificationCompat as CoreNotificationCompat
import androidx.media.app.NotificationCompat
import org.json.JSONArray
import java.util.*

/**
 * ================================================================
 * 听股通核心播报服务 —— 参考音乐 App 设计原则重构
 * ================================================================
 *
 * 设计目标：在熄屏、其他App使用、缩屏等场景下，播报不中断。
 *
 * 关键设计（参考音乐 App）：
 * 1. foregroundServiceType="mediaPlayback"    → 系统识别为音频类，不会轻易杀死
 * 2. AudioAttributes.USAGE_MEDIA              → 走媒体音频流，熄屏正常播放
 * 3. WakeLock 在 onCreate 中立即获取          → 从服务启动第一刻起保证CPU
 * 4. MediaSession 注册到系统媒体控制器        → 锁屏媒体控制栏、音频路由
 * 5. 请求 AUDIOFOCUS_GAIN                    → 与其他音乐/导航App互斥
 *
 * 触发路径（熄屏播报）：
 *   AlarmManager.setExactAndAllowWhileIdle() → TtsAlarmReceiver.onReceive()
 *   → startForegroundService() → TtsBroadcastService
 *   → 抓价格 → TTS播报 → 播完 → 延迟 stopSelf
 *
 * 触发路径（前台播报）：
 *   Flutter层 triggerBackgroundSpeak → TtsBroadcastService
 *   → 同上，但可能App还在前台
 */
class TtsBroadcastService : Service() {

    companion object {
        const val TAG = "TtsBroadcastService"
        const val ACTION_SPEAK_REPORT = "com.tingutong.app.ACTION_SPEAK_REPORT"
        const val ACTION_STOP = "com.tingutong.app.ACTION_STOP_TTS_SERVICE"
        const val ACTION_PAUSE = "com.tingutong.app.ACTION_PAUSE_TTS"
        const val ACTION_RESUME = "com.tingutong.app.ACTION_RESUME_TTS"

        const val CHANNEL_ID = "tingutong_tts_channel"
        const val CHANNEL_NAME = "听股通播报服务"
        const val NOTIFICATION_ID = 20002

        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val KEY_WATCHLIST = "flutter.VGhpZ1VuaXQyX3ZhMg=="
        private const val KEY_REPORT_INTERVAL = "tingutong_report_interval"
        private const val KEY_STOCK_NAMES = "tingutong_stock_names"

        private const val WAKE_LOCK_TAG = "Tingutong:TTSWakeLock"
        private const val MEDIA_SESSION_TAG = "TingutongTTS"

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
    // ─── WakeLock：服务生命周期内持有，播完释放 ───
    private var wakeLock: PowerManager.WakeLock? = null

    // ─── 播报队列 ───
    private var speakQueue: MutableList<String> = mutableListOf()
    private var currentIndex = 0
    private var reportInterval = 60
    private var isPaused = false

    // ─── 音频焦点 & MediaSession ───
    private var mediaSession: MediaSessionCompat? = null
    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var hasAudioFocus = false
    // 记录暂停时的位置，用于焦点恢复后自动续播
    private var pausedIndex = -1

    // ═══════════════════════════════════════════
    // 音频焦点回调（参考音乐App设计）
    // ═══════════════════════════════════════════
    private val audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                // 获得焦点（从 LOSS_TRANSIENT 恢复）
                Log.d(TAG, "AudioFocus: GAIN")
                hasAudioFocus = true
                if (pausedIndex >= 0) {
                    // 焦点恢复，自动续播
                    currentIndex = pausedIndex
                    pausedIndex = -1
                    isPaused = false
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                        speakNext()
                    }, 500)
                }
            }
            AudioManager.AUDIOFOCUS_LOSS -> {
                // 永久失去焦点（比如用户打开其他音乐App直接播放）
                Log.d(TAG, "AudioFocus: LOSS (permanent)")
                hasAudioFocus = false
                tts?.stop()
                // 不立即stopSelf，保留服务实例，等 Alarm 重新触发
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // 暂时失去焦点（来电、导航语音）—— 暂停，记录位置
                Log.d(TAG, "AudioFocus: LOSS_TRANSIENT (pausing)")
                if (!isPaused) {
                    pausedIndex = currentIndex
                }
                isPaused = true
                hasAudioFocus = false
                tts?.stop()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                // 可以压低音量继续（音乐App通常是降为30%音量）
                Log.d(TAG, "AudioFocus: LOSS_TRANSIENT_CAN_DUCK (ducking)")
                tts?.setSpeechRate(0.5f)
            }
        }
    }

    // ═══════════════════════════════════════════
    // onCreate：在主线程执行，早于任何业务逻辑
    // 关键：WakeLock 在这里获取，保证服务创建第一时刻就锁定CPU
    // ═══════════════════════════════════════════
    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, ">>> onCreate")

        // ─── 1. 立即获取 WakeLock ───
        // 这是熄屏保活的第一道防线。从 onCreate 开始就锁定 CPU，
        // 不依赖 onStartCommand 的时序。服务被系统杀死后重生时，
        // onCreate 仍会再次执行，WakeLock 重新获取。
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                WAKE_LOCK_TAG
            )
            wakeLock?.acquire()
            Log.d(TAG, "WakeLock acquired in onCreate")
        } catch (e: Throwable) {
            Log.e(TAG, "acquireWakeLock in onCreate failed: $e")
        }

        // ─── 2. 创建通知渠道 ───
        createNotificationChannel()

        // ─── 3. 注册 MediaSession ───
        initMediaSession()

        // ─── 4. 请求音频焦点 ───
        requestAudioFocus()

        // ─── 5. 初始化 TTS ───
        initTTS()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, ">>> onStartCommand: action=${intent?.action}")

        // ─── 防御：onCreate 中 WakeLock 可能失败，onStartCommand 再试一次 ───
        if (wakeLock == null || !wakeLock!!.isHeld) {
            try {
                val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    WAKE_LOCK_TAG
                )
                wakeLock?.acquire()
                Log.d(TAG, "WakeLock acquired in onStartCommand (retry)")
            } catch (e: Throwable) {
                Log.e(TAG, "acquireWakeLock in onStartCommand failed: $e")
            }
        }

        when (intent?.action) {
            ACTION_STOP -> {
                isPaused = false
                pausedIndex = -1
                releaseEverything()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_PAUSE -> {
                isPaused = true
                pausedIndex = currentIndex
                tts?.stop()
                updateMediaSessionState(PlaybackStateCompat.STATE_PAUSED)
                updateNotification("播报已暂停", isPlaying = false)
                Log.d(TAG, "TTS paused at index $currentIndex")
                return START_STICKY
            }
            ACTION_RESUME -> {
                isPaused = false
                if (pausedIndex >= 0) currentIndex = pausedIndex
                pausedIndex = -1
                updateMediaSessionState(PlaybackStateCompat.STATE_PLAYING)
                updateNotification("正在播报...", isPlaying = true)
                speakNext()
                return START_STICKY
            }
            ACTION_SPEAK_REPORT -> {
                // ─── 立即 startForeground，这是前台服务的义务 ───
                reportInterval = intent.getIntExtra("report_interval", defaultIntervalSec)
                startForeground(NOTIFICATION_ID, buildNotification("正在获取行情...", isPlaying = true))

                val stocks = loadStocksFromPrefs()
                if (stocks.isEmpty()) {
                    Log.w(TAG, "No stocks to report")
                    scheduleNextAlarm()
                    // 无股票，延迟停止（给Flutter层切回前台的时间）
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                        stopSelf()
                    }, 30000)
                } else {
                    loadAndSpeakStocks(stocks)
                }
            }
        }
        // START_STICKY：系统杀死后重生，onStartCommand 会被调用，走了 ACTION_SPEAK_REPORT 路径
        return START_STICKY
    }

    override fun onDestroy() {
        Log.d(TAG, ">>> onDestroy")
        releaseEverything()
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.d(TAG, ">>> onTaskRemoved")
        // 用户从 Recent Apps 滑动清理时，不重启（避免循环拉起）
        // 让 AlarmManager 下次触发即可
        super.onTaskRemoved(rootIntent)
    }

    // ═══════════════════════════════════════════
    // 一次性释放所有资源
    // ═══════════════════════════════════════════
    private fun releaseEverything() {
        tts?.stop()
        tts?.shutdown()
        tts = null
        ttsReady = false
        releaseAudioFocus()
        releaseMediaSession()
        releaseWakeLock()
        pausedIndex = -1
    }

    // ═══════════════════════════════════════════
    // MediaSession — 参考 QQ音乐/网易云音乐 设计
    // 作用：
    //   1. 注册到系统媒体控制器 → 锁屏出现媒体控制栏
    //   2. 让系统知道这是"音频App" → 音频路由、蓝牙控制正常
    //   3. 息屏时系统不会把音频当"后台音频"而静默
    // ═══════════════════════════════════════════
    private fun initMediaSession() {
        mediaSession = MediaSessionCompat(this, MEDIA_SESSION_TAG).apply {
            setFlags(
                MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS
                or MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS
            )

            // 播放状态
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

            // 元数据：锁屏媒体栏显示
            val metadata = MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, "听股通播报中")
                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, "行情播报")
                .putString(MediaMetadataCompat.METADATA_KEY_ALBUM, "股票行情")
                .build()
            setMetadata(metadata)

            // 媒体按钮回调
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onStop() {
                    Log.d(TAG, "MediaSession: onStop")
                    releaseEverything()
                    stopSelf()
                }

                override fun onPause() {
                    Log.d(TAG, "MediaSession: onPause")
                    isPaused = true
                    pausedIndex = currentIndex
                    tts?.stop()
                    updateMediaSessionState(PlaybackStateCompat.STATE_PAUSED)
                    updateNotification("播报已暂停", isPlaying = false)
                }

                override fun onPlay() {
                    Log.d(TAG, "MediaSession: onPlay")
                    isPaused = false
                    if (pausedIndex >= 0) currentIndex = pausedIndex
                    pausedIndex = -1
                    updateMediaSessionState(PlaybackStateCompat.STATE_PLAYING)
                    updateNotification("正在播报...", isPlaying = true)
                    speakNext()
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

    private fun updateMediaSessionState(state: Int) {
        mediaSession?.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY
                    or PlaybackStateCompat.ACTION_PAUSE
                    or PlaybackStateCompat.ACTION_STOP
                )
                .setState(state, currentIndex.toLong(), if (state == PlaybackStateCompat.STATE_PLAYING) 1.0f else 0f)
                .build()
        )
    }

    // ═══════════════════════════════════════════
    // 音频焦点 — 参考音乐App：
    //   USAGE_MEDIA + CONTENT_TYPE_MUSIC → 走媒体音频流
    //   请求 AUDIOFOCUS_GAIN → 永久占用，与其他音乐App互斥
    //   setAcceptsDelayedFocusGain(true) → 被其他App抢走后，等它释放再拿回来
    // ═══════════════════════════════════════════
    private fun requestAudioFocus() {
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // 关键修改：USAGE_MEDIA → 系统认为是音乐播放，熄屏正常出声
        // 旧：USAGE_ASSISTANT → 系统认为是语音助手，熄屏容易被静音
        val audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()

        audioFocusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(audioAttributes)
            // 被其他App临时抢走时，等待释放后自动拿回
            .setAcceptsDelayedFocusGain(true)
            .setOnAudioFocusChangeListener(audioFocusChangeListener)
            .build()

        val result = audioManager?.requestAudioFocus(audioFocusRequest!!)
        hasAudioFocus = (result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
        Log.d(TAG, "AudioFocus request: $result, hasFocus=$hasAudioFocus")
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
                    Log.w(TAG, "Chinese TTS not supported, falling back to default")
                    tts?.setLanguage(Locale.getDefault())
                } else {
                    ttsReady = true
                    Log.d(TAG, "TTS ready: Chinese")
                }
            } else {
                Log.e(TAG, "TTS init failed: $status")
            }
        }
    }

    // ═══════════════════════════════════════════
    // 加载股票配置（SharedPreferences 同步读取）
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
                Log.e(TAG, "Parse stock names failed: $e")
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
                    Log.e(TAG, "Parse watchlist failed: $e")
                }
            }
        }

        return stocks
    }

    // ═══════════════════════════════════════════
    // 加载股票数据并开始播报
    // ═══════════════════════════════════════════
    private fun loadAndSpeakStocks(stocks: List<Pair<String, String>>) {
        if (stocks.isEmpty()) {
            Log.w(TAG, "No stocks, scheduling next alarm")
            scheduleNextAlarm()
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ stopSelf() }, 30000)
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

    // ═══════════════════════════════════════════
    // 播报核心：顺序播完队列
    // 每次播完一条，等待800ms，再播下一条
    // 全部播完后：设置下一次Alarm，释放WakeLock，延迟 stopSelf
    // ═══════════════════════════════════════════
    private fun speakNext() {
        // ─── 暂停状态不播 ───
        if (isPaused) {
            Log.d(TAG, "speakNext skipped: paused")
            return
        }

        // ─── 队列播完 ───
        if (currentIndex >= speakQueue.size) {
            Log.d(TAG, "All stocks reported, scheduling next alarm in ${reportInterval}s")
            scheduleNextAlarm()
            updateNotification("播报完成，等待下次播报", isPlaying = false)
            updateMediaSessionState(PlaybackStateCompat.STATE_STOPPED)

            // 播完立即释放 WakeLock（让CPU休息）
            // 保留 Service 实例 5 分钟，给用户切回 App 的时间
            releaseWakeLock()
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                stopSelf()
            }, 300000) // 5 分钟
            return
        }

        // ─── TTS 未就绪 ───
        if (!ttsReady || tts == null) {
            Log.e(TAG, "TTS not ready, aborting")
            releaseEverything()
            stopSelf()
            return
        }

        val text = speakQueue[currentIndex]
        Log.d(TAG, "Speaking [$currentIndex/${speakQueue.size}]: $text")

        // 更新 MediaSession（锁屏媒体栏同步显示）
        updateMediaSessionState(PlaybackStateCompat.STATE_PLAYING)
        updateNotification("${currentIndex + 1}/${speakQueue.size}: $text", isPlaying = true)

        // 语速 0.85
        tts?.setSpeechRate(0.85f)
        tts?.speak(text, TextToSpeech.QUEUE_ADD, null, "tts_$currentIndex")

        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {
                Log.d(TAG, "TTS onStart: $utteranceId")
            }

            override fun onDone(utteranceId: String?) {
                Log.d(TAG, "TTS onDone: $utteranceId, next=$currentIndex")
                currentIndex++
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    speakNext()
                }, 800)
            }

            override fun onError(utteranceId: String?) {
                Log.e(TAG, "TTS onError: $utteranceId")
                currentIndex++
                speakNext()
            }
        })
    }

    // ═══════════════════════════════════════════
    // WakeLock 管理
    // ═══════════════════════════════════════════
    private fun releaseWakeLock() {
        if (wakeLock != null && wakeLock!!.isHeld) {
            wakeLock?.release()
            Log.d(TAG, "WakeLock released")
        }
        wakeLock = null
    }

    // ═══════════════════════════════════════════
    // 通知渠道（前台服务必须）
    // IMPORTANCE_LOW：静默通知（不出声音），只显示状态栏图标
    // setSound(null) 双重确保无声
    // ═══════════════════════════════════════════
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "听股通行情播报服务"
                setShowBadge(false)
                setSound(null, null)       // 强制无声
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                // 音频类服务相关标志
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    setShowBadge(false)
                }
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
            this, 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // 暂停/继续按钮
        val playPauseIntent = Intent(this, TtsBroadcastService::class.java).apply {
            action = if (isPlaying) ACTION_PAUSE else ACTION_RESUME
        }
        val playPausePendingIntent = PendingIntent.getService(
            this, 2, playPauseIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val playPauseIcon = if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        val playPauseTitle = if (isPlaying) "暂停" else "继续"

        return CoreNotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(if (isPlaying) "听股通正在播报" else "听股通播报服务")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_tts_notification)
            .setOngoing(isPlaying)  // 播报时持续显示，播完自动消失
            .setContentIntent(pendingIntent)
            .setPriority(CoreNotificationCompat.PRIORITY_LOW)
            .setCategory(CoreNotificationCompat.CATEGORY_SERVICE)
            .setVisibility(CoreNotificationCompat.VISIBILITY_PUBLIC)
            .setStyle(
                NotificationCompat.MediaStyle()
                    .setMediaSession(mediaSession?.sessionToken)
                    .setShowActionsInCompactView(0, 1)
            )
            .addAction(playPauseIcon, playPauseTitle, playPausePendingIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "停止", stopPendingIntent)
            .build()
    }

    private fun updateNotification(text: String, isPlaying: Boolean) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(text, isPlaying))
    }

    private fun scheduleNextAlarm() {
        TtsAlarmReceiver.scheduleNextReport(this, reportInterval)
    }
}

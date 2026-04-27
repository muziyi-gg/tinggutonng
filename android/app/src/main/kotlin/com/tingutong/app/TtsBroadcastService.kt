package com.tingutong.app

import android.app.*
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.support.v4.media.session.PlaybackStateCompat
import android.support.v4.media.session.MediaSessionCompat
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat.MediaStyle
import io.flutter.plugin.common.EventChannel
import android.util.Log

/**
 * 播报服务 —— 常驻后台，管理优先级播报队列
 *
 * 优先级规则：
 *   同级别不打断（排队等待）
 *   高优先级（数字小）打断低优先级（数字大）
 *   打断后低优先级暂停，播完高优先级后恢复
 *
 * 数据来源：TtsDataService 将数据解析后写入 SharedPrefsHelper.alertQueue
 * 服务启动时从队列读取待播报项，按优先级顺序播报
 *
 * 用户点击「开始播报」时启动，用户点击「停止播报」时停止
 */
class TtsBroadcastService : Service() {

    companion object {
        const val TAG = "TtsBroadcastService"

        const val TTS_ACTION_STOP = "com.tingutong.app.TTS_ACTION_STOP"
        const val TTS_ACTION_PAUSE = "com.tingutong.app.TTS_ACTION_PAUSE"
        const val TTS_ACTION_RESUME = "com.tingutong.app.TTS_ACTION_RESUME"
        const val TTS_ACTION_NEXT = "com.tingutong.app.TTS_ACTION_NEXT"

        const val CHANNEL_ID = "tingutong_broadcast_channel"
        const val CHANNEL_NAME = "听股通播报服务"
        const val NOTIFICATION_ID = 20002

        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val KEY_REPORT_INTERVAL = "tingutong_report_interval"

        private const val WAKE_LOCK_TAG = "Tingutong:TTSWakeLock"

        var defaultIntervalSec = 60

        // 优先级常量（数字越小越高）
        const val PRIORITY_P0 = 0  // 涨停/跌停/炸板
        const val PRIORITY_P1 = 1  // 快速拉升/下跌
        const val PRIORITY_P2 = 2  // 板块异动/集合竞价
        const val PRIORITY_P3 = 3  // 大盘异动
        const val PRIORITY_P4 = 4  // 自选股定时播报

        // MainActivity 注册后持有此引用，Flutter 端监听时写入
        var serviceEventSink: EventChannel.EventSink? = null
    }

    // TTS
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var utteranceId = 0

    // WakeLock
    private var wakeLock: PowerManager.WakeLock? = null

    // 音频焦点
    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var hasAudioFocus = false

    // MediaSession
    private var mediaSession: MediaSessionCompat? = null
    private var currentPlaybackStateCompat = PlaybackStateCompat.STATE_STOPPED

    // 当前播报状态
    private var isPaused = false
    private var currentTexts: List<String> = emptyList()
    private var currentIndex = 0

    // 优先级播报管理
    private var currentBroadcastPriority = -1   // -1=空闲，0-4=当前播报优先级
    private var pausedPriority = -1             // 被打断的优先级（-1=无）
    private var isSpeaking = false

    // 定时播报（仅 P4 selfQuote）
    private var handler: Handler? = null
    private var broadcastRunnable: Runnable? = null
    private var reportIntervalSec = 60

    // ═══════════════════════════════════════════
    // 音频焦点回调
    // ═══════════════════════════════════════════
    private val audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                DebugLogger.log("AUDIO", "AudioFocus GAIN")
                hasAudioFocus = true
                if (isPaused) {
                    isPaused = false
                    handler?.post { resumeFromPause() }
                }
                updatePlaybackStateCompat(PlaybackStateCompat.STATE_PLAYING)
            }
            AudioManager.AUDIOFOCUS_LOSS -> {
                DebugLogger.log("AUDIO", "AudioFocus LOSS → stop TTS")
                hasAudioFocus = false
                tts?.stop()
                updatePlaybackStateCompat(PlaybackStateCompat.STATE_STOPPED)
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                DebugLogger.log("AUDIO", "AudioFocus LOSS_TRANSIENT → pause TTS")
                isPaused = true
                tts?.stop()
                updatePlaybackStateCompat(PlaybackStateCompat.STATE_PAUSED)
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                DebugLogger.log("AUDIO", "AudioFocus LOSS_TRANSIENT_CAN_DUCK → duck 0.5x")
                tts?.setSpeechRate(0.5f)
            }
        }
        DebugLogger.updateComponentStatus("TtsBroadcastService", buildStatusSnapshot())
    }

    // ═══════════════════════════════════════════
    // MediaSession 回调
    // ═══════════════════════════════════════════
    private val mediaSessionCallback = object : MediaSessionCompat.Callback() {
        override fun onPlay() {
            DebugLogger.log("MEDIA", "MediaSession onPlay")
            isPaused = false
            updatePlaybackStateCompat(PlaybackStateCompat.STATE_PLAYING)
            if (!ttsReady) return
            resumeFromPause()
        }

        override fun onPause() {
            DebugLogger.log("MEDIA", "MediaSession onPause")
            isPaused = true
            tts?.stop()
            updatePlaybackStateCompat(PlaybackStateCompat.STATE_PAUSED)
        }

        override fun onStop() {
            DebugLogger.log("MEDIA", "MediaSession onStop")
            isPaused = true
            tts?.stop()
            updatePlaybackStateCompat(PlaybackStateCompat.STATE_STOPPED)
        }

        override fun onSkipToNext() {
            DebugLogger.log("MEDIA", "MediaSession onSkipToNext")
            tts?.stop()
            onCurrentItemComplete()
        }

        override fun onMediaButtonEvent(mediaButtonEvent: Intent): Boolean {
            DebugLogger.log("MEDIA", "MediaButtonEvent: $mediaButtonEvent")
            return super.onMediaButtonEvent(mediaButtonEvent)
        }
    }

    // ═══════════════════════════════════════════
    // Flutter EventChannel：向 Flutter 推送播报状态
    // 模式：静态 EventSink 持有者（MainActivity 注册，TtsBroadcastService 写入）
    // （serviceEventSink 已移至 companion object）

    /**
     * 通过 EventChannel 向 Flutter 推送播报状态
     * Flutter StockProvider 监听此通道，收到后设置 _speaking=true/false
     */
    private fun _syncSpeakingToFlutter() {
        _pushState()
    }

    private fun _pushState() {
        val isPlaying = !isPaused && (isSpeaking || currentBroadcastPriority >= 0)
        val data = mapOf(
            "isPlaying" to isPlaying,
            "isPaused" to isPaused,
            "priority" to currentBroadcastPriority,
            "textIndex" to currentIndex,
            "textCount" to currentTexts.size
        )
        Companion.serviceEventSink?.success(data)
        DebugLogger.log("MEDIA", "_pushState: isPlaying=$isPlaying, isPaused=$isPaused, sink=${Companion.serviceEventSink != null}")
    }

    // ═══════════════════════════════════════════
    // 服务生命周期
    // ═══════════════════════════════════════════

    override fun onCreate() {
        super.onCreate()
        DebugLogger.init(this)
        DebugLogger.log("TTS", ">>> TtsBroadcastService onCreate")
        DebugLogger.log("TTS", "Android SDK=${Build.VERSION.SDK_INT}, manufacturer=${Build.MANUFACTURER}")

        SharedPrefsHelper.init(this)
        acquireWakeLock()
        createNotificationChannel()
        requestAudioFocus()
        initMediaSession()
        initTTS()
        loadReportInterval()

        DebugLogger.log("WAKE", "WakeLock acquired on onCreate")
        DebugLogger.log("MEDIA", "MediaSession initialized")

        val notification = buildNotification("听股通播报服务运行中", null, false)
        startForeground(NOTIFICATION_ID, notification)

        DebugLogger.log("TTS", "startForeground done, NOTIFICATION_ID=$NOTIFICATION_ID")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        DebugLogger.log("TTS", ">>> onStartCommand: action=${intent?.action}, flags=$flags, startId=$startId")

        when (intent?.action) {
            TTS_ACTION_STOP -> {
                DebugLogger.log("TTS", "ACTION_STOP received → releasing everything")
                releaseEverything()
                _syncSpeakingToFlutter()  // 同步 Flutter _speaking 状态
                stopSelf()
                return START_NOT_STICKY
            }
            TTS_ACTION_PAUSE -> {
                isPaused = true
                isSpeaking = false
                tts?.stop()
                updateNotification("播报已暂停", null, false)
                updatePlaybackStateCompat(PlaybackStateCompat.STATE_PAUSED)
                _syncSpeakingToFlutter()  // 同步 Flutter _speaking 状态
                DebugLogger.log("TTS", "TTS paused")
                DebugLogger.updateComponentStatus("TtsBroadcastService", buildStatusSnapshot())
                return START_STICKY
            }
            TTS_ACTION_RESUME -> {
                isPaused = false
                isSpeaking = true
                updateNotification("听股通播报中", null, false)
                updatePlaybackStateCompat(PlaybackStateCompat.STATE_PLAYING)
                _syncSpeakingToFlutter()  // 同步 Flutter _speaking 状态
                resumeFromPause()
                DebugLogger.log("TTS", "TTS resumed")
                DebugLogger.updateComponentStatus("TtsBroadcastService", buildStatusSnapshot())
                return START_STICKY
            }
            TTS_ACTION_NEXT -> {
                DebugLogger.log("TTS", "TTS skip to next")
                tts?.stop()
                onCurrentItemComplete()
                return START_STICKY
            }
        }

        // 系统重建服务时（action=null），tts 对象可能已被 GC 回收
        if (tts == null) {
            DebugLogger.log("TTS", "Service recreation: tts is null, reinitializing")
            ttsReady = false
            isSpeaking = false
            currentIndex = 0
            currentTexts = emptyList()
            currentBroadcastPriority = -1
            pausedPriority = -1
            _syncSpeakingToFlutter()
            acquireWakeLock()
            createNotificationChannel()
            requestAudioFocus()
            initMediaSession()
            initTTS()
            loadReportInterval()
        } else if (broadcastRunnable == null && ttsReady) {
            DebugLogger.log("TTS", "Service recreation: restarting broadcast cycle")
            startBroadcastCycle()
        }

        return START_STICKY
    }

    override fun onDestroy() {
        DebugLogger.log("TTS", ">>> onDestroy")
        releaseEverything()
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        DebugLogger.log("TTS", ">>> onTaskRemoved → restarting service")
        val restartIntent = Intent(this, TtsBroadcastService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(restartIntent)
        } else {
            startService(restartIntent)
        }
        super.onTaskRemoved(rootIntent)
    }

    private fun buildStatusSnapshot(): org.json.JSONObject {
        val o = org.json.JSONObject()
        o.put("serviceAlive", true)
        o.put("ttsReady", ttsReady)
        o.put("isSpeaking", isSpeaking)
        o.put("isPaused", isPaused)
        o.put("hasAudioFocus", hasAudioFocus)
        o.put("reportIntervalSec", reportIntervalSec)
        o.put("currentBroadcastPriority", currentBroadcastPriority)
        o.put("pausedPriority", pausedPriority)
        o.put("currentTextsCount", currentTexts.size)
        o.put("currentIndex", currentIndex)
        o.put("playbackState", currentPlaybackStateCompat)
        o.put("wakeLockHeld", wakeLock?.isHeld == true)
        o.put("queueSize", SharedPrefsHelper.readAlertQueue().size)
        return o
    }

    // ═══════════════════════════════════════════
    // 播报核心逻辑
    // ═══════════════════════════════════════════

    /**
     * 尝试播报：检查队列，如果有待播内容则开始播报
     * 调用时机：定时器触发、播完一条、恢复被打断的优先级
     */
    private fun tryStartBroadcast() {
        if (isSpeaking || isPaused) {
            DebugLogger.log("TTS", "tryStartBroadcast skip: isSpeaking=$isSpeaking, isPaused=$isPaused")
            return
        }

        val nextItem = SharedPrefsHelper.peekAlertQueue()
        if (nextItem == null) {
            // 队列空：只有 P4 才需要重启定时器
            if (currentBroadcastPriority < 0) {
                startBroadcastCycle()
            }
            return
        }

        val newPriority = nextItem.priority.value

        if (currentBroadcastPriority < 0) {
            // 空闲状态：直接播
            DebugLogger.log("TTS", "Idle → start broadcasting priority=$newPriority")
            val item = SharedPrefsHelper.dequeueAlert()
            if (item != null) startBroadcast(item)
        } else if (newPriority < currentBroadcastPriority) {
            // 有播报：新的优先级更高，打断当前
            DebugLogger.log("TTS", "Preempt: current=$currentBroadcastPriority, new=$newPriority")
            pausedPriority = currentBroadcastPriority
            tts?.stop()
            val item = SharedPrefsHelper.dequeueAlert()
            if (item != null) startBroadcast(item)
        } else {
            // 新的优先级 <= 当前优先级，不打断，队列里等着
            DebugLogger.log("TTS", "Queue wait: current=$currentBroadcastPriority, new=$newPriority (same or lower)")
        }
    }

    /**
     * 开始播报一个 AlertItem
     */
    private fun startBroadcast(item: AlertItem) {
        val priority = item.priority.value
        currentBroadcastPriority = priority
        currentTexts = item.texts
        currentIndex = 0
        isSpeaking = true

        val priorityLabel = priorityToLabel(priority)
        val content = if (item.texts.size == 1) {
            "${priorityLabel}：${item.texts[0]}"
        } else {
            "${priorityLabel}：共 ${item.texts.size} 条"
        }

        DebugLogger.log("TTS", "startBroadcast: priority=$priority, texts=${item.texts.size}")
        DebugLogger.log("TTS", "  items: ${item.texts.joinToString(" | ")}")

        updateNotification(content, priority, true)
        updatePlaybackStateCompat(PlaybackStateCompat.STATE_PLAYING)
        speakNext()
    }

    /**
     * 播完当前 AlertItem 的所有文本后，调用此方法决定下一步
     */
    private fun onCurrentItemComplete() {
        DebugLogger.log("TTS", "onCurrentItemComplete: priority=$currentBroadcastPriority, pausedPriority=$pausedPriority")

        isSpeaking = false
        currentTexts = emptyList()
        currentIndex = 0
        _syncSpeakingToFlutter()

        val finishedPriority = currentBroadcastPriority
        currentBroadcastPriority = -1

        // 优先恢复被打断的低优先级
        if (pausedPriority >= 0) {
            val toResume = pausedPriority
            pausedPriority = -1
            // 从队列中找到该优先级的下一条
            DebugLogger.log("TTS", "Resuming paused priority=$toResume")
            tryResumeFromQueue(toResume)
        } else {
            // 没有被打断的，直接从队列取下一个
            tryStartBroadcast()
        }
    }

    /**
     * 从队列中恢复指定优先级的播报（取最新的，不是从中断处继续）
     */
    private fun tryResumeFromQueue(targetPriority: Int) {
        val queue = SharedPrefsHelper.readAlertQueue()
        val item = queue.firstOrNull { it.priority.value == targetPriority }
        if (item != null) {
            // 移出队列并播报（重新读最新数据）
            val updatedQueue = queue.toMutableList()
            updatedQueue.remove(item)
            SharedPrefsHelper.writeAlertQueue(updatedQueue)

            // 对于 P4（定时播报），重新生成最新行情
            if (item.type == AlertType.SELF_QUOTE) {
                val prices = SharedPrefsHelper.readLatestPrices()
                val stockList = SharedPrefsHelper.readStockList()
                if (prices.isNotEmpty() && stockList.isNotEmpty()) {
                    val texts = buildBroadcastTexts(prices, stockList)
                    if (texts.isNotEmpty()) {
                        val newItem = AlertItem(item.type, texts, item.stockCode)
                        startBroadcast(newItem)
                        return
                    }
                }
            }
            // 其他类型直接播
            startBroadcast(item)
        } else {
            // 队列中没有该优先级了，继续取下一个
            DebugLogger.log("TTS", "No item for priority=$targetPriority in queue, try next")
            tryStartBroadcast()
        }
    }

    /**
     * 播下一条文本
     */
    private fun speakNext() {
        if (currentIndex >= currentTexts.size || isPaused) {
            // 当前 AlertItem 播完了
            DebugLogger.log("TTS", "All texts complete for priority=$currentBroadcastPriority")
            onCurrentItemComplete()
            return
        }

        val text = currentTexts[currentIndex]
        val uid = "tts_${utteranceId++}"

        tts?.setSpeechRate(0.85f)
        val params = android.os.Bundle().apply {
            putInt(android.speech.tts.TextToSpeech.Engine.KEY_PARAM_STREAM, android.media.AudioManager.STREAM_MUSIC)
            putFloat(android.speech.tts.TextToSpeech.Engine.KEY_PARAM_VOLUME, 1.0f)
            putFloat(android.speech.tts.TextToSpeech.Engine.KEY_PARAM_PAN, 0.0f)
        }
        tts?.speak(text, TextToSpeech.QUEUE_ADD, params, uid)
        DebugLogger.log("TTS", "Speaking [$currentIndex/${currentTexts.size}]: $text (uid=$uid, priority=$currentBroadcastPriority)")
    }

    /**
     * 恢复播报（暂停后恢复）
     */
    private fun resumeFromPause() {
        if (currentBroadcastPriority < 0) {
            // 当前没有播报，直接从队列取
            tryStartBroadcast()
        } else {
            // 继续播下一条
            speakNext()
        }
    }

    // ═══════════════════════════════════════════
    // 定时播报（P4 selfQuote）
    // ═══════════════════════════════════════════

    private fun loadReportInterval() {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        reportIntervalSec = prefs.getInt(KEY_REPORT_INTERVAL, defaultIntervalSec)
        DebugLogger.log("TTS", "Report interval: ${reportIntervalSec}s")
    }

    private fun startBroadcastCycle() {
        // 幂等检查：已经在播就跳过
        if (currentBroadcastPriority >= 0) {
            DebugLogger.log("TTS", "Broadcast cycle skip: priority=$currentBroadcastPriority is playing")
            return
        }
        // 队列里有东西也不需要定时器
        if (SharedPrefsHelper.peekAlertQueue() != null) {
            DebugLogger.log("TTS", "Broadcast cycle skip: queue has items")
            tryStartBroadcast()
            return
        }

        if (broadcastRunnable != null) {
            DebugLogger.log("TTS", "Broadcast cycle already active, skip")
            return
        }

        handler = Handler(Looper.getMainLooper())
        broadcastRunnable = object : Runnable {
            override fun run() {
                if (!isPaused && ttsReady) {
                    DebugLogger.log("TTS", "Timer trigger → doP4Broadcast")
                    doP4Broadcast()
                }
                handler?.postDelayed(this, (reportIntervalSec * 1000L))
            }
        }
        handler?.post(broadcastRunnable!!)
        DebugLogger.log("TTS", "Broadcast cycle started (every ${reportIntervalSec}s)")
        DebugLogger.updateComponentStatus("TtsBroadcastService", buildStatusSnapshot())
    }

    /**
     * P4 定时播报：读取最新行情，生成 AlertItem 入队列
     * 播完后重设定时器，保证间隔 = 播完到下次开始的空白时长
     */
    private fun doP4Broadcast() {
        if (currentBroadcastPriority >= 0) {
            // 正在播其他优先级，跳过本次定时触发
            DebugLogger.log("TTS", "doP4Broadcast skip: current priority=$currentBroadcastPriority is playing")
            return
        }

        val prices = SharedPrefsHelper.readLatestPrices()
        val stockList = SharedPrefsHelper.readStockList()
        DebugLogger.log("TTS", "doP4Broadcast: prices=${prices.size}, stocks=${stockList.size}")

        if (prices.isEmpty() || stockList.isEmpty()) {
            DebugLogger.log("TTS", "doP4Broadcast SKIP: no data")
            return
        }

        val texts = buildBroadcastTexts(prices, stockList)
        if (texts.isEmpty()) return

        DebugLogger.log("TTS", "doP4Broadcast: ${texts.size} stocks")

        val item = AlertItem(
            type = AlertType.SELF_QUOTE,
            texts = texts
        )
        SharedPrefsHelper.enqueueAlert(item)

        // 播完后再重设定时器（由 onCurrentItemComplete 触发）
        // 这里直接触发播报
        tryStartBroadcast()
    }

    private fun buildBroadcastTexts(
        prices: Map<String, String>,
        stockList: Map<String, String>
    ): List<String> {
        val texts = mutableListOf<String>()

        for ((code, value) in prices) {
            val parts = value.split(",")
            if (parts.size < 4) continue
            val name = stockList[code] ?: parts[0]
            val price = parts[1]
            val changePct = parts[2].toDoubleOrNull() ?: continue

            val dir = if (changePct >= 0) "涨" else "跌"
            val priceVal = price.toDoubleOrNull() ?: 0.0
            val pctAbs = kotlin.math.abs(changePct)
            texts.add("$name，报${String.format("%.2f", priceVal)}元，$dir${String.format("%.2f", pctAbs)}%")
        }

        return texts
    }

    // ═══════════════════════════════════════════
    // 工具方法
    // ═══════════════════════════════════════════

    private fun priorityToLabel(priority: Int): String {
        return when (priority) {
            PRIORITY_P0 -> "⚡紧急预警"
            PRIORITY_P1 -> "📈快速变动"
            PRIORITY_P2 -> "📡板块异动"
            PRIORITY_P3 -> "📊大盘异动"
            PRIORITY_P4 -> "📊定时播报"
            else -> "📢播报"
        }
    }

    // ═══════════════════════════════════════════
    // MediaSession
    // ═══════════════════════════════════════════

    private fun initMediaSession() {
        try {
            mediaSession = MediaSessionCompat(this, "TingutongMediaSession").apply {
                setCallback(mediaSessionCallback)
                isActive = true
                updatePlaybackStateCompat(PlaybackStateCompat.STATE_STOPPED)
                Log.d(TAG, "MediaSession initialized and active")
            }
        } catch (e: Throwable) {
            Log.e(TAG, "initMediaSession failed: $e")
        }
    }

    private fun updatePlaybackStateCompat(state: Int) {
        currentPlaybackStateCompat = state
        mediaSession?.let { session ->
            try {
                val position = if (state == PlaybackStateCompat.STATE_PLAYING) {
                    (currentIndex * 5000L)
                } else {
                    PlaybackStateCompat.PLAYBACK_POSITION_UNKNOWN
                }

                val actions = PlaybackStateCompat.ACTION_PLAY or
                        PlaybackStateCompat.ACTION_PAUSE or
                        PlaybackStateCompat.ACTION_STOP or
                        PlaybackStateCompat.ACTION_SKIP_TO_NEXT

                val playbackState = PlaybackStateCompat.Builder()
                    .setActions(actions)
                    .setState(state, position, 1.0f)
                    .build()

                session.setPlaybackState(playbackState)

                if (state == PlaybackStateCompat.STATE_PLAYING) {
                    val content = "${currentTexts.size}条播报"
                    val notification = buildNotification(content, currentBroadcastPriority, true)
                    val manager = getSystemService(NotificationManager::class.java)
                    manager.notify(NOTIFICATION_ID, notification)
                }

                Log.d(TAG, "PlaybackStateCompat updated: state=$state")
            } catch (e: Throwable) {
                Log.e(TAG, "updatePlaybackStateCompat failed: $e")
            }
        }
        DebugLogger.updateComponentStatus("TtsBroadcastService", buildStatusSnapshot())
    }

    // ═══════════════════════════════════════════
    // TTS 初始化
    // ═══════════════════════════════════════════

    private fun initTTS() {
        tts = TextToSpeech(this) { status ->
            if (status == TextToSpeech.SUCCESS) {
                val result = tts?.setLanguage(java.util.Locale.CHINESE)
                if (result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED) {
                    DebugLogger.log("TTS", "Chinese TTS not supported → fallback to default")
                    tts?.setLanguage(java.util.Locale.getDefault())
                }
                tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {
                        isSpeaking = true
                        DebugLogger.log("TTS", "onStart: $utteranceId (priority=$currentBroadcastPriority)")
                        updatePlaybackStateCompat(PlaybackStateCompat.STATE_PLAYING)
                        _syncSpeakingToFlutter()
                    }
                    override fun onDone(utteranceId: String?) {
                        DebugLogger.log("TTS", "onDone: $utteranceId")
                        Handler(Looper.getMainLooper()).postDelayed({
                            currentIndex++
                            speakNext()
                        }, 800)
                    }
                    override fun onError(utteranceId: String?) {
                        DebugLogger.log("TTS", "onError: $utteranceId → skip to next")
                        Handler(Looper.getMainLooper()).postDelayed({
                            currentIndex++
                            speakNext()
                        }, 800)
                    }
                })
                ttsReady = true
                DebugLogger.log("TTS", "TTS ready, starting broadcast cycle")
                startBroadcastCycle()
            } else {
                DebugLogger.log("TTS", "TTS init FAILED: status=$status")
            }
        }
    }

    // ═══════════════════════════════════════════
    // 通知
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
                setSound(null, null)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String, priority: Int?, isPlaying: Boolean): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val stopIntent = Intent(this, TtsBroadcastService::class.java).apply {
            action = TTS_ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val playPauseIntent = Intent(this, TtsBroadcastService::class.java).apply {
            action = if (isPlaying) TTS_ACTION_PAUSE else TTS_ACTION_RESUME
        }
        val playPausePendingIntent = PendingIntent.getService(
            this, 2, playPauseIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val nextIntent = Intent(this, TtsBroadcastService::class.java).apply {
            action = TTS_ACTION_NEXT
        }
        val nextPendingIntent = PendingIntent.getService(
            this, 3, nextIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val appIcon = try {
            val drawable = packageManager.getApplicationIcon(packageName)
            val bitmap = Bitmap.createBitmap(drawable.intrinsicWidth, drawable.intrinsicHeight, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, canvas.width, canvas.height)
            drawable.draw(canvas)
            bitmap
        } catch (e: Throwable) { null }

        val title = if (priority != null && priority < PRIORITY_P4) {
            "听股通预警播报"
        } else if (isPlaying) {
            "听股通正在播报"
        } else {
            "听股通播报服务"
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setOngoing(isPlaying)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)

        if (isPlaying) {
            builder.setStyle(
                MediaStyle()
                    .setShowActionsInCompactView(0, 1, 2)
                    .setMediaSession(mediaSession?.sessionToken)
            )
        }

        if (isPlaying) {
            builder.addAction(android.R.drawable.ic_media_pause, "暂停", playPausePendingIntent)
        } else {
            builder.addAction(android.R.drawable.ic_media_play, "继续", playPausePendingIntent)
        }
        builder.addAction(android.R.drawable.ic_menu_close_clear_cancel, "停止", stopPendingIntent)
        builder.addAction(android.R.drawable.ic_media_next, "下一轮", nextPendingIntent)

        if (appIcon != null) builder.setLargeIcon(appIcon)

        return builder.build()
    }

    private fun updateNotification(text: String, priority: Int?, isPlaying: Boolean) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(text, priority, isPlaying))
    }

    // ═══════════════════════════════════════════
    // 资源释放
    // ═══════════════════════════════════════════

    private fun releaseEverything() {
        handler?.removeCallbacks(broadcastRunnable ?: Runnable {})
        handler = null
        broadcastRunnable = null

        tts?.stop()
        tts?.shutdown()
        tts = null
        ttsReady = false

        releaseAudioFocus()
        releaseWakeLock()

        mediaSession?.apply {
            updatePlaybackStateCompat(PlaybackStateCompat.STATE_STOPPED)
            release()
        }
        mediaSession = null

        isSpeaking = false
        isPaused = false
        currentBroadcastPriority = -1
        pausedPriority = -1
        _syncSpeakingToFlutter()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) {
            DebugLogger.log("WAKE", "WakeLock already held, skip")
            return
        }
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
            @Suppress("WAKELOCK_TIMEOUT")
            wakeLock?.acquire()
            DebugLogger.log("WAKE", "WakeLock acquired")
        } catch (e: Throwable) {
            DebugLogger.log("WAKE", "acquireWakeLock FAILED: $e")
        }
    }

    private fun releaseWakeLock() {
        if (wakeLock != null && wakeLock!!.isHeld) {
            wakeLock?.release()
            DebugLogger.log("WAKE", "WakeLock released")
            wakeLock = null
        }
    }

    private fun requestAudioFocus() {
        if (hasAudioFocus) {
            DebugLogger.log("AUDIO", "AudioFocus already held, skip")
            return
        }
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
        DebugLogger.log("AUDIO", "AudioFocus request: result=$result, granted=$hasAudioFocus")
    }

    private fun releaseAudioFocus() {
        if (audioFocusRequest != null && hasAudioFocus) {
            audioManager?.abandonAudioFocusRequest(audioFocusRequest!!)
            hasAudioFocus = false
            DebugLogger.log("AUDIO", "AudioFocus released")
        }
    }
}
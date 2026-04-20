import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';

enum TtsState { idle, playing, stopped, error }

/// TTS 异常：播报失败时抛出，供上层 UI 展示错误信息
class TtsException implements Exception {
  final String message;
  TtsException(this.message);
  @override
  String toString() => message;
}

/// TTS 生命周期事件（供调试用）
class TtsLifecycleEvent {
  final String type; // app_lifecycle | tts_event | debug
  final String message;
  final DateTime ts;
  TtsLifecycleEvent(this.type, this.message) : ts = DateTime.now();
  @override
  String toString() => '[${ts.toString().substring(11, 19)}] [$type] $message';
}

/// 外部注入的日志回调（由 StockProvider 注入，用于合并 TTS 日志到 SP.debugLog）
typedef TtsLogCallback = void Function(String tag, String msg);
TtsLogCallback? _externalLogCallback;

class TtsService with WidgetsBindingObserver {
  final FlutterTts _tts = FlutterTts();
  TtsState _state = TtsState.idle;
  Timer? _safetyTimer;
  String _currentLanguage = 'zh-CN';
  Completer<void>? _speakCompleter;
  String? _lastSpeakingText;

  /// 调试事件日志（最多保留100条）
  final List<TtsLifecycleEvent> _debugLog = [];
  static const int _maxLogSize = 100;

  /// 诊断信息（供调试页面展示）
  String _initError = '';
  List<dynamic> _availableEngines = [];
  int _langAvailable = -1;
  bool _isIos = false;
  bool _isAndroid = false;
  String? _lastErrorMessage;
  String? _lastPlatformCode;
  bool _initDone = false;

  /// App 生命周期状态（用于判断切后台/切前台）
  AppLifecycleState _appLifecycle = AppLifecycleState.resumed;

  TtsState get state => _state;
  String get initError => _initError;
  List<dynamic> get availableEngines => _availableEngines;
  int get langAvailable => _langAvailable;
  String get currentLanguage => _currentLanguage;
  String? get lastErrorMessage => _lastErrorMessage;
  String? get lastPlatformCode => _lastPlatformCode;
  bool get initDone => _initDone;
  AppLifecycleState get appLifecycle => _appLifecycle;
  List<TtsLifecycleEvent> get debugLog => List.unmodifiable(_debugLog);
  bool get isPlaying => _state == TtsState.playing;

  /// 注册外部日志回调（由 StockProvider 调用，将 TTS 日志合并到 SP.debugLog）
  void registerLogCallback(TtsLogCallback callback) {
    _externalLogCallback = callback;
    _log('debug', 'TTS log callback registered');
  }

  void _log(String type, String msg) {
    _debugLog.add(TtsLifecycleEvent(type, msg));
    if (_debugLog.length > _maxLogSize) _debugLog.removeAt(0);
    // 根据事件类型映射细分 tag，方便调试页面分色显示
    String spTag;
    if (type == 'tts_event') {
      if (msg.startsWith('handler START')) spTag = 'TTS.START';
      else if (msg.startsWith('handler CANCEL')) spTag = 'TTS.CANCEL';
      else if (msg.startsWith('handler COMPLETION')) spTag = 'TTS.DONE';
      else if (msg.startsWith('handler ERROR')) spTag = 'TTS.ERROR';
      else if (msg.startsWith('speak() CALLED')) spTag = 'TTS.SPEAK';
      else if (msg.startsWith('stop() CALLED')) spTag = 'TTS.STOP';
      else spTag = 'TTS';
    } else if (type == 'app_lifecycle') {
      spTag = 'TTS.APP';
    } else {
      spTag = 'TTS';
    }
    if (_externalLogCallback != null) {
      _externalLogCallback!(spTag, msg);
    }
    debugPrint('TTS [$spTag] $msg');
  }

  void clearLog() => _debugLog.clear();

  /// flutter_tts 4.0 返回 bool，旧版返回 int，兼容处理
  int _normalizeLangAvailable(dynamic val) {
    if (val is bool) return val ? 1 : 0;
    if (val is int) return val;
    return 0;
  }

  /// 初始化 TTS 引擎（诊断模式：记录所有中间状态）
  /// 注意：不使用 audio_session，避免覆盖 flutter_tts 自己的后台音频配置。
  Future<void> init() async {
    try {
      _initError = '';

      _isAndroid = defaultTargetPlatform == TargetPlatform.android;
      _isIos = defaultTargetPlatform == TargetPlatform.iOS;
      _log('debug', 'TTS init: platform=android($_isAndroid) ios($_isIos)');

      // 注册 App 生命周期监听（用于检测切后台/切前台）
      WidgetsBinding.instance.addObserver(this);

      // 关键：Android 需要 setSharedInstance 才能正常工作（4.0+ 有此方法）
      if (_isAndroid) {
        try {
          await _tts.setSharedInstance(true);
          _log('debug', 'TTS setSharedInstance(true) OK');
        } catch (e) {
          _log('debug', 'TTS setSharedInstance not available: $e');
          try {
            await _tts.setSharedInstance(false);
            _log('debug', 'TTS setSharedInstance(false) fallback OK');
          } catch (e2) {
            _log('debug', 'TTS setSharedInstance(false) also failed: $e2');
          }
        }
      }

      // iOS 需要 setIosAudioCategory，让 TTS 在后台音频中继续播
      if (_isIos) {
        try {
          await _tts.setIosAudioCategory(
            IosTextToSpeechAudioCategory.playback,
            [
              IosTextToSpeechAudioCategoryOptions.allowBluetooth,
              IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
              IosTextToSpeechAudioCategoryOptions.mixWithOthers,
            ],
            IosTextToSpeechAudioMode.voicePrompt,
          );
          _log('debug', 'TTS iOS audio category set');
        } catch (e) {
          _log('debug', 'TTS iOS audio category failed: $e');
        }
      }

      // 获取可用引擎（Android）
      if (_isAndroid) {
        try {
          _availableEngines = await _tts.getEngines ?? [];
          _log('debug', 'TTS available engines: $_availableEngines');
        } catch (e) {
          _log('debug', 'TTS getEngines failed: $e');
        }
      }

      // 设置语言
      _currentLanguage = 'zh-CN';
      await _tts.setLanguage('zh-CN');
      try {
        _langAvailable = _normalizeLangAvailable(await _tts.isLanguageAvailable('zh-CN'));
      } catch (e) {
        _langAvailable = 0;
        _log('debug', 'TTS isLanguageAvailable(zh-CN) failed: $e');
      }
      _log('debug', 'TTS zh-CN available: $_langAvailable');

      if (_langAvailable != 1) {
        _log('debug', 'TTS zh-CN not available, trying en-US');
        try {
          await _tts.setLanguage('en-US');
          final availEn = _normalizeLangAvailable(await _tts.isLanguageAvailable('en-US'));
          if (availEn == 1) {
            _currentLanguage = 'en-US';
            _langAvailable = availEn;
            _log('debug', 'TTS en-US available: $availEn');
          }
        } catch (e) {
          _log('debug', 'TTS isLanguageAvailable(en-US) failed: $e');
        }
      }

      // 关键：设置等待播报完成，避免重叠
      await _tts.awaitSpeakCompletion(true);
      _log('debug', 'TTS awaitSpeakCompletion(true) set');

      await _tts.setSpeechRate(0.85);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      // 设置 TTS 回调
      _tts.setStartHandler(() {
        _log('tts_event', 'handler START - state=$_state');
        _state = TtsState.playing;
        _lastErrorMessage = null;
        _resetAfterTimeout();
      });

      _tts.setCompletionHandler(() {
        _log('tts_event', 'handler COMPLETION - state=$_state, appLifecycle=$_appLifecycle');
        _state = TtsState.idle;
        _cancelSafetyTimer();
        _completeSpeak();
      });

      _tts.setErrorHandler((e) {
        _log('tts_event', 'handler ERROR - $e');
        _state = TtsState.error;
        _lastErrorMessage = e.toString();
        _cancelSafetyTimer();
        _completeSpeakError(Exception(e));
      });

      _tts.setCancelHandler(() {
        _log('tts_event', 'handler CANCEL - state=$_state, appLifecycle=$_appLifecycle');
        _state = TtsState.idle;
        _cancelSafetyTimer();
        _completeSpeak();
      });

      _tts.setContinueHandler(() {
        _log('tts_event', 'handler CONTINUE - state=$_state');
      });

      _tts.setProgressHandler((text, start, end, word) {
        _log('tts_event', 'progress: "$text" [$start-$end] word="$word"');
      });

      _log('debug', 'TTS init complete successfully');
      _initDone = true;
    } catch (e, st) {
      _log('debug', 'TTS init FAILED: $e\n$st');
      _initError = '$e';
      _state = TtsState.error;
    }
  }

  // ═══════════════════════════════════════════
  // App 生命周期监听（WidgetsBindingObserver）
  // ═══════════════════════════════════════════
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycle = state;
    _log('app_lifecycle', 'AppLifecycleState changed to: $state, wasSpeaking=${_state == TtsState.playing}');

    if (state == AppLifecycleState.paused) {
      // App 切到后台：记录当前 TTS 状态
      _log('app_lifecycle', 'App paused - TTS state=${_state.name}, will continue if _speaking remains true');
    } else if (state == AppLifecycleState.resumed) {
      // App 切回前台：如果之前 TTS 正在播且被中断，需要通知上层恢复
      // 注意：本回调不直接触发恢复（由 StockProvider 监听此状态决定是否恢复）
      _log('app_lifecycle', 'App resumed - TTS state=${_state.name}');
    }
  }

  /// 检查 TTS 是否在播（用于上层判断是否需要恢复）
  bool get isPlaying => _state == TtsState.playing;

  void _resetAfterTimeout() {
    _safetyTimer?.cancel();
    _safetyTimer = Timer(const Duration(seconds: 10), () {
      _log('debug', 'TTS safety timeout: forcing state reset from $_state');
      _state = TtsState.idle;
    });
  }

  void _cancelSafetyTimer() {
    _safetyTimer?.cancel();
    _safetyTimer = null;
  }

  void _completeSpeak() {
    if (_speakCompleter != null && !_speakCompleter!.isCompleted) {
      _speakCompleter!.complete();
    }
  }

  void _completeSpeakError(Object error) {
    if (_speakCompleter != null && !_speakCompleter!.isCompleted) {
      _speakCompleter!.completeError(error);
    }
  }

  /// 播报文本。抛出 TtsException 表示失败（供 UI 层展示）。
  Future<void> speak(String text) async {
    _log('tts_event', 'speak() called: "$text", current state=$_state, appLifecycle=$_appLifecycle');
    _lastErrorMessage = null;
    _lastPlatformCode = null;

    if (_state == TtsState.playing) {
      _log('tts_event', 'TTS: already playing, skipping "$text"');
      return;
    }

    _state = TtsState.playing;
    _speakCompleter = Completer<void>();

    try {
      await _tts.speak(text);
      // awaitSpeakCompletion(true) 让 speak() 等待真正播完
      // completion handler 会触发 _completeSpeak()
    } on PlatformException catch (e) {
      _log('tts_event', 'TTS PlatformException: code=${e.code} message=${e.message}');
      _state = TtsState.error;
      _lastPlatformCode = e.code;
      _lastErrorMessage = e.message;
      _cancelSafetyTimer();
      _completeSpeakError(e);
      if (e.code == 'not_found' || e.code == 'engine_not_found') {
        throw TtsException('未检测到语音引擎');
      }
      throw TtsException('语音播报失败 (${e.code}): ${e.message}');
    } catch (e) {
      _log('tts_event', 'TTS speak() exception: $e');
      _state = TtsState.error;
      _cancelSafetyTimer();
      _completeSpeakError(e);
      if (e is TtsException) rethrow;
      throw TtsException('语音播报异常: $e');
    }
  }

  Future<void> stop() async {
    _log('tts_event', 'stop() called');
    await _tts.stop();
    _state = TtsState.idle;
    _cancelSafetyTimer();
    _completeSpeak();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelSafetyTimer();
    _tts.stop();
  }
}
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'media_tts_handler.dart';

enum TtsState { idle, playing, stopped, error }

/// TTS 异常：播报失败时抛出，供上层 UI 展示错误信息
class TtsException implements Exception {
  final String message;
  TtsException(this.message);
  @override
  String toString() => message;
}

class TtsService {
  final FlutterTts _tts = FlutterTts();
  TtsState _state = TtsState.idle;
  Timer? _safetyTimer;
  String _currentLanguage = 'zh-CN';

  /// MediaTtsHandler：把 TTS 封装成 foreground service（锁屏/切App时继续播）
  late final MediaTtsHandler _mediaHandler;
  Completer<void>? _speakCompleter;

  /// 诊断信息（供调试页面展示）
  String _initError = '';
  List<dynamic> _availableEngines = [];
  int _langAvailable = -1;
  bool _isIos = false;
  bool _isAndroid = false;
  String? _lastErrorMessage;
  String? _lastPlatformCode;
  bool _initDone = false;

  TtsState get state => _state;
  String get initError => _initError;
  List<dynamic> get availableEngines => _availableEngines;
  int get langAvailable => _langAvailable;
  String get currentLanguage => _currentLanguage;
  String? get lastErrorMessage => _lastErrorMessage;
  String? get lastPlatformCode => _lastPlatformCode;
  bool get initDone => _initDone;

  /// flutter_tts 4.0 返回 bool，旧版返回 int，兼容处理
  int _normalizeLangAvailable(dynamic val) {
    if (val is bool) return val ? 1 : 0;
    if (val is int) return val;
    return 0;
  }

  /// 初始化 TTS 引擎（诊断模式：记录所有中间状态）
  Future<void> init() async {
    try {
      _initError = '';

      _isAndroid = defaultTargetPlatform == TargetPlatform.android;
      _isIos = defaultTargetPlatform == TargetPlatform.iOS;
      debugPrint('TTS init: platform=android($_isAndroid) ios($_isIos)');

      // 关键：Android 需要 setSharedInstance 才能正常工作（4.0+ 有此方法）
      if (_isAndroid) {
        try {
          await _tts.setSharedInstance(true);
          debugPrint('TTS setSharedInstance(true) OK');
        } catch (e) {
          debugPrint('TTS setSharedInstance not available: $e');
          try {
            await _tts.setSharedInstance(false);
            debugPrint('TTS setSharedInstance(false) fallback OK');
          } catch (e2) {
            debugPrint('TTS setSharedInstance(false) also failed: $e2');
          }
        }
      }

      // iOS 需要 setIosAudioCategory
      if (_isIos) {
        await _tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playback,
          [
            IosTextToSpeechAudioCategoryOptions.allowBluetooth,
            IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
            IosTextToSpeechAudioCategoryOptions.mixWithOthers,
          ],
          IosTextToSpeechAudioMode.voicePrompt,
        );
        debugPrint('TTS iOS audio category set');
      }

      // 获取可用引擎
      if (_isAndroid) {
        _availableEngines = await _tts.getEngines ?? [];
        debugPrint('TTS available engines: $_availableEngines');
      }

      // 设置语言
      _currentLanguage = 'zh-CN';
      await _tts.setLanguage('zh-CN');
      try {
        _langAvailable = _normalizeLangAvailable(await _tts.isLanguageAvailable('zh-CN'));
      } catch (e) {
        _langAvailable = 0;
        debugPrint('TTS isLanguageAvailable(zh-CN) failed: $e');
      }
      debugPrint('TTS zh-CN available: $_langAvailable');

      if (_langAvailable != 1) {
        debugPrint('TTS zh-CN not available, trying en-US');
        try {
          await _tts.setLanguage('en-US');
          final availEn = _normalizeLangAvailable(await _tts.isLanguageAvailable('en-US'));
          if (availEn == 1) {
            _currentLanguage = 'en-US';
            _langAvailable = availEn;
            debugPrint('TTS en-US available: $availEn');
          }
        } catch (e) {
          debugPrint('TTS isLanguageAvailable(en-US) failed: $e');
        }
      }

      // 关键：设置等待播报完成，避免重叠
      await _tts.awaitSpeakCompletion(true);
      debugPrint('TTS awaitSpeakCompletion(true) set');

      await _tts.setSpeechRate(0.85);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      // 设置 TTS 回调（completion/error/cancel → 通知 _speakCompleter）
      _tts.setStartHandler(() {
        debugPrint('TTS handler: start');
        _state = TtsState.playing;
        _lastErrorMessage = null;
        _resetAfterTimeout();
      });

      _tts.setCompletionHandler(() {
        debugPrint('TTS handler: completion');
        _state = TtsState.idle;
        _cancelSafetyTimer();
        _completeSpeak();
      });

      _tts.setErrorHandler((e) {
        debugPrint('TTS handler: error - $e');
        _state = TtsState.error;
        _lastErrorMessage = e.toString();
        _cancelSafetyTimer();
        _completeSpeakError(Exception(e));
      });

      _tts.setCancelHandler(() {
        debugPrint('TTS handler: cancelled');
        _state = TtsState.idle;
        _cancelSafetyTimer();
        _completeSpeak();
      });

      _tts.setContinueHandler(() {
        debugPrint('TTS handler: continue');
      });

      _tts.setProgressHandler((text, start, end, word) {
        debugPrint('TTS progress: "$text" [$start-$end] word="$word"');
      });

      // 初始化 foreground service handler（锁屏/切App时继续播）
      _mediaHandler = MediaTtsHandler(_tts);
      await _mediaHandler.init();
      debugPrint('TTS init complete successfully');
      _initDone = true;
    } catch (e, st) {
      debugPrint('TTS init FAILED: $e\n$st');
      _initError = '$e';
      _state = TtsState.error;
    }
  }

  void _resetAfterTimeout() {
    _safetyTimer?.cancel();
    _safetyTimer = Timer(const Duration(seconds: 10), () {
      debugPrint('TTS safety timeout: forcing state reset from $_state');
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
  /// 锁屏和切换 App 时通过 foreground service 保持播报。
  Future<void> speak(String text) async {
    debugPrint('TTS speak() called: "$text", current state=$_state');
    _lastErrorMessage = null;
    _lastPlatformCode = null;

    if (_state == TtsState.playing) {
      debugPrint('TTS: already playing, skipping "$text"');
      return;
    }

    _state = TtsState.playing;
    _speakCompleter = Completer<void>();

    try {
      // 通过 MediaTtsHandler 走 foreground service
      await _mediaHandler.speak(text);
      // 等待 TTS 真正播完（completion handler 会 complete _speakCompleter）
      // 注意：如果 audio_service 初始化失败，speak() 内部会直接调用 flutter_tts
      // flutter_tts 的 awaitSpeakCompletion(true) 让 speak() 本身就会等播完
    } on PlatformException catch (e) {
      debugPrint('TTS PlatformException: code=${e.code} message=${e.message}');
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
      debugPrint('TTS speak() exception: $e');
      _state = TtsState.error;
      _cancelSafetyTimer();
      _completeSpeakError(e);
      if (e is TtsException) rethrow;
      throw TtsException('语音播报异常: $e');
    }
  }

  Future<void> stop() async {
    debugPrint('TTS stop() called');
    await _mediaHandler.stop();
    _state = TtsState.idle;
    _cancelSafetyTimer();
    _completeSpeak();
  }

  void dispose() {
    _cancelSafetyTimer();
    _mediaHandler.dispose();
    _tts.stop();
  }
}

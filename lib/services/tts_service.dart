import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

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

  /// flutter_tts 4.0 返回 bool，旧版返回 int，兼容处理
  int _normalizeLangAvailable(dynamic val) {
    if (val is bool) return val ? 1 : 0;
    if (val is int) return val;
    return 0;
  }
  String get currentLanguage => _currentLanguage;
  String? get lastErrorMessage => _lastErrorMessage;
  String? get lastPlatformCode => _lastPlatformCode;
  bool get initDone => _initDone;

  /// 初始化 TTS 引擎（诊断模式：记录所有中间状态）
  Future<void> init() async {
    try {
      _initError = '';

      _isAndroid = defaultTargetPlatform == TargetPlatform.android;
      _isIos = defaultTargetPlatform == TargetPlatform.iOS;
      debugPrint('TTS init: platform=android($_isAndroid) ios($_isIos)');

      // 关键：Android 需要 setSharedInstance 才能正常工作（4.0+ 有此方法）
      // 注意：某些设备上 setSharedInstance(true) 会导致 isLanguageAvailable 返回 0
      // 所以先直接调用，失败时再 fallback
      if (_isAndroid) {
        try {
          await _tts.setSharedInstance(true);
          debugPrint('TTS setSharedInstance(true) OK');
        } catch (e) {
          debugPrint('TTS setSharedInstance not available: $e');
          // fallback: 尝试直接用系统引擎
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

      // 设置语言（isLanguageAvailable 在某些引擎上返回 0 但实际仍可播报，
      // 所以不以此判断是否可用，只记录供参考）
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

      // 检查是否支持 completion 回调
      if (_isAndroid) {
        try {
          await _tts.isLanguageInstalled('zh-CN');
        } catch (e) {
          debugPrint('TTS isLanguageInstalled: $e');
        }
      }

      await _tts.setSpeechRate(0.85);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      // 设置处理器
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
      });

      _tts.setErrorHandler((e) {
        debugPrint('TTS handler: error - $e');
        _state = TtsState.error;
        _lastErrorMessage = e.toString();
        _cancelSafetyTimer();
      });

      _tts.setCancelHandler(() {
        debugPrint('TTS handler: cancelled');
        _state = TtsState.idle;
        _cancelSafetyTimer();
      });

      _tts.setContinueHandler(() {
        debugPrint('TTS handler: continue');
      });

      _tts.setProgressHandler((text, start, end, word) {
        debugPrint('TTS progress: "$text" [$start-$end] word="$word"');
      });

      _initDone = true;
      debugPrint('TTS init complete successfully');
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

  /// 播报文本。抛出 TtsException 表示失败（供 UI 层展示）。
  Future<void> speak(String text) async {
    debugPrint('TTS speak() called: "$text", current state=$_state');
    _lastErrorMessage = null;
    _lastPlatformCode = null;

    if (_state == TtsState.playing) {
      debugPrint('TTS: already playing, skipping "$text"');
      return;
    }

    _state = TtsState.playing;
    try {
      final result = await _tts.speak(text);
      debugPrint('TTS speak() returned: $result, lang=$_currentLanguage');
      if (result != 1) {
        throw TtsException('语音引擎返回错误码 $result，请检查系统语音设置');
      }
      // 正常情况下，completionHandler 会把 state 改回 idle
      // 这里不主动改，等待 handler 回调
    } on PlatformException catch (e) {
      debugPrint('TTS PlatformException: code=${e.code} message=${e.message}');
      _state = TtsState.error;
      _lastPlatformCode = e.code;
      _lastErrorMessage = e.message;
      _cancelSafetyTimer();
      if (e.code == 'not_found' || e.code == 'engine_not_found') {
        throw TtsException('未检测到语音引擎');
      }
      throw TtsException('语音播报失败 (${e.code}): ${e.message}');
    } catch (e) {
      debugPrint('TTS speak() exception: $e');
      _state = TtsState.error;
      _cancelSafetyTimer();
      if (e is TtsException) rethrow;
      throw TtsException('语音播报异常: $e');
    }
  }

  Future<void> stop() async {
    debugPrint('TTS stop() called');
    await _tts.stop();
    _state = TtsState.idle;
    _cancelSafetyTimer();
  }

  void dispose() {
    _cancelSafetyTimer();
    _tts.stop();
  }
}

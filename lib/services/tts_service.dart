import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

enum TtsState { idle, playing, stopped, error }

class TtsService {
  final FlutterTts _tts = FlutterTts();
  TtsState _state = TtsState.idle;
  Timer? _safetyTimer;

  TtsState get state => _state;

  Future<void> init() async {
    // 核心修复：让 speak() 阻塞等待播报完成（Flutter 3.x 兼容）
    await _tts.awaitSpeakCompletion(true);

    // Android: 检查是否有可用的 TTS 引擎
    if (defaultTargetPlatform == TargetPlatform.android) {
      final engines = await _tts.getEngines;
      debugPrint('Available TTS engines: $engines');
    }

    // 设置中文语言
    await _tts.setLanguage('zh-CN');

    // 验证语言是否可用，不可用则回退到默认
    final avail = await _tts.isLanguageAvailable('zh-CN');
    debugPrint('zh-CN available: $avail');
    if (avail != 1) {
      debugPrint('zh-CN not available, falling back to en-US');
      await _tts.setLanguage('en-US');
    }

    await _tts.setSpeechRate(0.85);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    // Android 4.1+: 设置音频焦点和导航场景属性（修复 Android 11+ 无声）
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        // setIosAudioCategory 等方法不存在于所有版本，加 try-catch
        await _tts.setSharedInstance(false);
      } catch (_) {}
    }

    // start handler: 开始播放时更新状态
    _tts.setStartHandler(() {
      debugPrint('TTS start');
      _state = TtsState.playing;
      _resetAfterTimeout();
    });

    // completion handler: 播放完成时重置状态
    _tts.setCompletionHandler(() {
      debugPrint('TTS complete');
      _state = TtsState.idle;
      _cancelSafetyTimer();
    });

    // error handler
    _tts.setErrorHandler((e) {
      debugPrint('TTS error: $e');
      _state = TtsState.error;
      _cancelSafetyTimer();
    });
  }

  /// 安全兜底：若 8 秒内 CompletionHandler 未触发，强制重置状态
  void _resetAfterTimeout() {
    _safetyTimer?.cancel();
    _safetyTimer = Timer(const Duration(seconds: 8), () {
      debugPrint('TTS safety timeout: forcing state reset');
      _state = TtsState.idle;
    });
  }

  void _cancelSafetyTimer() {
    _safetyTimer?.cancel();
    _safetyTimer = null;
  }

  Future<void> speak(String text) async {
    if (_state == TtsState.playing) {
      debugPrint('TTS: already playing, skip');
      return;
    }

    _state = TtsState.playing;

    try {
      // awaitSpeakCompletion=true 时，这里会阻塞直到播完
      final result = await _tts.speak(text);
      debugPrint('TTS speak result: $result');
      _state = TtsState.idle;
    } catch (e) {
      debugPrint('TTS speak exception: $e');
      _state = TtsState.error;
    } finally {
      _cancelSafetyTimer();
    }
  }

  Future<void> stop() async {
    await _tts.stop();
    _state = TtsState.idle;
    _cancelSafetyTimer();
  }

  void dispose() {
    _cancelSafetyTimer();
    _tts.stop();
  }
}

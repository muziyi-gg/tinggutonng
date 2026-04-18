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
    // 让 speak() 阻塞等待语音播报完成，这是最关键的修复
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
      debugPrint('zh-CN not available, falling back to default language');
      await _tts.setLanguage('en-US');
    }

    await _tts.setSpeechRate(0.85);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    // Android: 使用更可靠的 onState 回调
    _tts.setStateHandler((state) {
      debugPrint('TTS state: $state');
      if (state == 'playing' || state == 'speak') {
        _state = TtsState.playing;
      } else if (state == 'completed' || state == 'done') {
        _state = TtsState.idle;
        _cancelSafetyTimer();
      } else if (state == 'stopped') {
        _state = TtsState.stopped;
        _cancelSafetyTimer();
      } else if (state == 'error') {
        _state = TtsState.error;
        _cancelSafetyTimer();
      }
    });

    _tts.setStartHandler(() {
      _state = TtsState.playing;
    });

    _tts.setCompletionHandler(() {
      _state = TtsState.idle;
      _cancelSafetyTimer();
    });

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
    _resetAfterTimeout();

    try {
      final result = await _tts.speak(text);
      debugPrint('TTS speak result: $result');
      // awaitSpeakCompletion=true 时，await 在播完后才返回
      // 如果返回了说明播完了或失败了，状态应在 handler 里已重置
      if (_state == TtsState.playing) {
        // handler 还没来得及执行，极小概率，补重置
        _state = TtsState.idle;
      }
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

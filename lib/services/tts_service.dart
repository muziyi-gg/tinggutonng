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
  bool _engineAvailable = false;

  TtsState get state => _state;
  bool get isEngineAvailable => _engineAvailable;

  /// 初始化 TTS 引擎
  Future<void> init() async {
    await _tts.awaitSpeakCompletion(true);

    if (defaultTargetPlatform == TargetPlatform.android) {
      final engines = await _tts.getEngines;
      debugPrint('Available TTS engines: $engines');
      if (engines != null && (engines as List).isNotEmpty) {
        _engineAvailable = true;
      }
    }

    // 设置中文语言
    _currentLanguage = 'zh-CN';
    await _tts.setLanguage('zh-CN');

    final avail = await _tts.isLanguageAvailable('zh-CN');
    debugPrint('zh-CN available: $avail');
    if (avail != 1) {
      debugPrint('zh-CN not available, trying en-US fallback');
      final availEn = await _tts.isLanguageAvailable('en-US');
      if (availEn == 1) {
        _currentLanguage = 'en-US';
        await _tts.setLanguage('en-US');
      }
    }

    await _tts.setSpeechRate(0.85);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _tts.setStartHandler(() {
      debugPrint('TTS start');
      _state = TtsState.playing;
      _resetAfterTimeout();
    });

    _tts.setCompletionHandler(() {
      debugPrint('TTS complete');
      _state = TtsState.idle;
      _cancelSafetyTimer();
    });

    _tts.setErrorHandler((e) {
      debugPrint('TTS error: $e');
      _state = TtsState.error;
      _cancelSafetyTimer();
    });

    _tts.setCancelHandler(() {
      debugPrint('TTS cancelled');
      _state = TtsState.idle;
      _cancelSafetyTimer();
    });
  }

  /// 测试播报：调用一次短文本，返回是否成功出声
  Future<bool> testSound() async {
    if (_state == TtsState.playing) return false;
    try {
      final result = await _tts.speak('测');
      await _tts.stop();
      return result == 1;
    } catch (_) {
      return false;
    } finally {
      _state = TtsState.idle;
      _cancelSafetyTimer();
    }
  }

  void _resetAfterTimeout() {
    _safetyTimer?.cancel();
    _safetyTimer = Timer(const Duration(seconds: 10), () {
      debugPrint('TTS safety timeout: forcing state reset');
      _state = TtsState.idle;
    });
  }

  void _cancelSafetyTimer() {
    _safetyTimer?.cancel();
    _safetyTimer = null;
  }

  /// 播报文本。抛出 TtsException 表示失败（供 UI 层展示）。
  /// 注意：本方法不负责发送本地通知，由调用方自行处理。
  Future<void> speak(String text) async {
    if (_state == TtsState.playing) {
      debugPrint('TTS: already playing, skip');
      return;
    }

    _state = TtsState.playing;
    try {
      final result = await _tts.speak(text);
      debugPrint('TTS speak result: $result (lang=$_currentLanguage)');
      if (result != 1) {
        throw TtsException('语音引擎响应失败，请检查系统语音设置');
      }
      _state = TtsState.idle;
      _cancelSafetyTimer();
    } on PlatformException catch (e) {
      debugPrint('TTS PlatformException: ${e.code} ${e.message}');
      _state = TtsState.error;
      _cancelSafetyTimer();
      if (e.code == 'not_found' || e.code == 'engine_not_found') {
        throw TtsException('未检测到语音引擎，请到系统设置中启用');
      }
      throw TtsException('语音播报失败 (${e.code}): ${e.message}');
    } catch (e) {
      debugPrint('TTS speak exception: $e');
      _state = TtsState.error;
      _cancelSafetyTimer();
      if (e is TtsException) rethrow;
      throw TtsException('语音播报异常: $e');
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

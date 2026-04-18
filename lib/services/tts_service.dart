import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

enum TtsState { idle, playing, stopped, error }

/// TTS 异常：引擎不可用时抛出，方便上层捕获并提示用户
class TtsException implements Exception {
  final String message;
  final bool engineMissing; // true=完全没有TTS引擎，需要安装
  TtsException(this.message, {this.engineMissing = false});
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

  /// 初始化并验证 TTS 引擎是否可用
  /// 抛出 TtsException 如果完全没有可用引擎（用户需安装）
  Future<void> init() async {
    await _tts.awaitSpeakCompletion(true);

    if (defaultTargetPlatform == TargetPlatform.android) {
      final engines = await _tts.getEngines;
      debugPrint('Available TTS engines: $engines');
      if (engines == null || (engines as List).isEmpty) {
        debugPrint('WARNING: No TTS engine found on device!');
        // 不抛异常，改为在 speak 时检测
      } else {
        _engineAvailable = true;
      }

      // 优先使用系统默认 TTS 引擎（通常是最好的中文引擎）
      try {
        await _tts.setSharedSession(true);
        debugPrint('TTS shared session enabled');
      } catch (_) {}
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

    // 安卓静默错误（引擎问题最常见）
    _tts.setCancelHandler(() {
      debugPrint('TTS cancelled');
      _state = TtsState.idle;
      _cancelSafetyTimer();
    });
  }

  /// 测试播报：调用一次短文本，返回是否成功出声
  /// 用于初始化后自检
  Future<bool> testSound() async {
    if (_state == TtsState.playing) return false;
    try {
      final result = await _tts.speak('测');
      // flutter_tts: 1 = success, 0 = error
      return result == 1;
    } catch (_) {
      return false;
    } finally {
      await _tts.stop();
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

  /// 播报文本
  /// 抛出 TtsException 如果 TTS 完全不可用
  /// 返回 true/false 表示是否成功出声
  Future<bool> speak(String text) async {
    if (_state == TtsState.playing) {
      debugPrint('TTS: already playing, skip');
      return false;
    }

    _state = TtsState.playing;

    try {
      final result = await _tts.speak(text);
      debugPrint('TTS speak result: $result (lang=$_currentLanguage)');

      // flutter_tts 返回 1 表示成功（引擎已接受），0 表示失败
      // 但注意：返回1不代表一定有声音（可能引擎不可用但API调用成功）
      // 我们依赖 startHandler / errorHandler 来判断真实情况
      _state = TtsState.idle;
      _cancelSafetyTimer();
      return result == 1;
    } on PlatformException catch (e) {
      debugPrint('TTS PlatformException: ${e.code} ${e.message}');
      _state = TtsState.error;
      _cancelSafetyTimer();
      // 常见错误码：not_found = 没有TTS引擎
      if (e.code == 'not_found' || e.code == 'engine_not_found') {
        throw TtsException('未找到 TTS 引擎，请前往应用市场安装"讯飞语音引擎"或"Google 文字转语音"', engineMissing: true);
      }
      throw TtsException('TTS 播报失败: ${e.message}');
    } catch (e) {
      debugPrint('TTS speak exception: $e');
      _state = TtsState.error;
      _cancelSafetyTimer();
      throw TtsException('TTS 播报异常: $e');
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

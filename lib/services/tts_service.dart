import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _isPlaying = false;

  bool get isPlaying => _isPlaying;

  Future<void> init() async {
    await _tts.setLanguage('zh-CN');
    await _tts.setSpeechRate(0.85);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    _tts.setStartHandler(() => _isPlaying = true);
    _tts.setCompletionHandler(() => _isPlaying = false);
    _tts.setErrorHandler((e) { debugPrint('TTS error: $e'); _isPlaying = false; });
  }

  Future<void> speak(String text) async {
    if (_isPlaying) return;
    await _tts.speak(text);
  }

  Future<void> stop() async {
    await _tts.stop();
    _isPlaying = false;
  }

  void dispose() {
    _tts.stop();
  }
}

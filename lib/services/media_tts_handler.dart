import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// 把 flutter_tts 封装成 foreground service（类似音乐 App）的处理器。
/// 使用 TextHandler（TTS 专用），锁屏/切 App 时系统保持 TTS 音频。
class MediaTtsHandler {
  final FlutterTts _tts;
  TextHandler? _audioHandler;
  AudioSession? _session;
  bool _initialized = false;
  StreamSubscription? _speakSub;
  StreamSubscription? _stateSub;
  Completer<void>? _speakCompleter;

  MediaTtsHandler(this._tts);

  /// 初始化 AudioSession 和 foreground service
  Future<void> init() async {
    if (_initialized) return;
    try {
      _session = await AudioSession.instance;
      await _session!.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.mixWithOthers,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.assistant,
        ),
        androidAudioFocusGainType:
            AndroidAudioFocusGainType.gainTransientMayDuck,
        androidWillPauseWhenDucked: false,
      ));

      // TextHandler 是 TTS 专用 handler，有 speak() 方法
      _audioHandler = await AudioService.init(
        builder: () => TextHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.tingutong.app.audio',
          androidNotificationChannelName: '听股通语音播报',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: false,
          androidNotificationIcon: 'mipmap/ic_launcher',
        ),
      );

      // 一次性设置监听器，不要每次 speak 都加新的
      _speakSub = _audioHandler!.onWillSpeak.listen((text) {
        debugPrint('TextHandler onWillSpeak: "$text"');
        _tts.speak(text);
      });

      _stateSub = _audioHandler!.playbackState.listen((state) {
        debugPrint('TextHandler playbackState: playing=${state.playing} processing=${state.processingState}');
        if (state.processingState == AudioProcessingState.idle && !state.playing) {
          if (_speakCompleter != null && !_speakCompleter!.isCompleted) {
            _speakCompleter!.complete();
          }
        }
      });

      _initialized = true;
      debugPrint('MediaTtsHandler init OK');
    } catch (e, st) {
      debugPrint('MediaTtsHandler init failed: $e\n$st');
      _initialized = false;
    }
  }

  Future<void> speak(String text) async {
    if (!_initialized || _audioHandler == null) {
      debugPrint('MediaTtsHandler: not initialized, fallback to direct TTS');
      await _tts.speak(text);
      return;
    }
    _speakCompleter = Completer<void>();
    try {
      await _audioHandler!.speak(text);
      // await 直到 playbackState 变为 idle
      await _speakCompleter!.future;
    } catch (e) {
      debugPrint('MediaTtsHandler speak error: $e, fallback to direct TTS');
      await _tts.speak(text);
    }
  }

  Future<void> stop() async {
    if (!_initialized || _audioHandler == null) {
      await _tts.stop();
      return;
    }
    try {
      await _audioHandler!.stop();
      if (_speakCompleter != null && !_speakCompleter!.isCompleted) {
        _speakCompleter!.complete();
      }
    } catch (e) {
      debugPrint('MediaTtsHandler stop error: $e');
      await _tts.stop();
    }
  }

  Future<void> dispose() async {
    await _speakSub?.cancel();
    await _stateSub?.cancel();
    if (_audioHandler != null) {
      try {
        await _audioHandler!.stop();
      } catch (_) {}
    }
    _initialized = false;
  }
}

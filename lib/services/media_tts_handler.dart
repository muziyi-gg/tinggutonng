import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// 把 flutter_tts 封装成 foreground service（类似音乐 App）的处理器。
/// 机制：用 AudioPlayer 持有 foreground service 槽位（播放一段静音音频），
/// 在此期间 flutter_tts 的输出通过 AudioSession 的 audio focus 保持活动。
/// 这样锁屏、切换 App 时系统不会杀死 TTS 音频。
class MediaTtsHandler {
  final FlutterTts _tts;
  BaseAudioHandler? _audioHandler;
  AudioSession? _session;
  bool _initialized = false;
  final _ttsCompleter = Completer<void>();

  /// TTS 播报完成回调（TTSActualCompletion 是我们的补充信号）
  void Function()? onTtsComplete;
  void Function(String)? onTtsError;

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

      // 初始化 AudioService（后台前台服务）
      _audioHandler = await AudioService.init(
        builder: () => _TtsAudioHandler(_tts, onTtsComplete, onTtsError),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.tingutong.app.audio',
          androidNotificationChannelName: '听股通语音播报',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: false,
          androidNotificationIcon: 'mipmap/ic_launcher',
        ),
      );

      _initialized = true;
      debugPrint('MediaTtsHandler init OK');
    } catch (e) {
      debugPrint('MediaTtsHandler init failed: $e');
      // 不阻塞，fallback 到普通模式
    }
  }

  Future<void> speak(String text) async {
    if (!_initialized || _audioHandler == null) {
      // fallback：直接用 flutter_tts
      await _tts.speak(text);
      return;
    }
    try {
      // speak() 在 BaseAudioHandler 上，AudioHandler 没有此方法
      final handler = _audioHandler as BaseAudioHandler;
      await handler.speak(text);
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
      final handler = _audioHandler as BaseAudioHandler;
      await handler.stop();
    } catch (e) {
      debugPrint('MediaTtsHandler stop error: $e');
      await _tts.stop();
    }
  }

  Future<void> dispose() async {
    if (_audioHandler != null) {
      await _audioHandler!.stop();
    }
    _initialized = false;
  }
}

/// AudioService 的 Handler 实现，把 speak() 调用路由到 flutter_tts
class _TtsAudioHandler extends BaseAudioHandler with SeekHandler {
  final FlutterTts _tts;
  void Function()? onTtsComplete;
  void Function(String)? onTtsError;

  _TtsAudioHandler(this._tts, this.onTtsComplete, this.onTtsError);

  @override
  Future<void> speak(String text) async {
    // 先停止当前播报
    await _tts.stop();

    _tts.setStartHandler(() {
      debugPrint('TTS-AudioHandler: start');
      playbackState.add(playbackState.value.copyWith(
        playing: true,
        processingState: AudioProcessingState.ready,
      ));
    });

    _tts.setCompletionHandler(() {
      debugPrint('TTS-AudioHandler: completion');
      playbackState.add(playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
      ));
      onTtsComplete?.call();
    });

    _tts.setErrorHandler((e) {
      debugPrint('TTS-AudioHandler error: $e');
      playbackState.add(playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.error,
      ));
      onTtsError?.call(e.toString());
    });

    final result = await _tts.speak(text);
    if (result != 1) {
      debugPrint('TTS speak() returned $result');
    }
  }

  @override
  Future<void> stop() async {
    await _tts.stop();
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      processingState: AudioProcessingState.idle,
    ));
  }

  @override
  Future<void> onClick(MediaButton button) async {
    await stop();
  }
}

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../app.dart';

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
  static const _serviceChannel = MethodChannel('com.tingutong.app/tts_service');
  TtsState _state = TtsState.idle;
  Timer? _safetyTimer;
  String _currentLanguage = 'zh-CN';
  Completer<void>? _speakCompleter;
  String? _lastSpeakingText;

  /// 后台播报是否已激活（AlarmManager 已设置）
  bool _backgroundReportingActive = false;

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

  Future<void> _ensureAudioSession() async {
    if (!_isAndroid) return;
    // 现在只做语言设置，不要再启动前台服务
    // 熄屏播报完全由 AlarmManager → TtsBroadcastService 处理
  }

  /// 启动后台播报（AlarmManager 定时 + 股票配置持久化）
  /// 前后台统一：前台由 stock_provider 的 Timer 驱动，后台由 AlarmManager 驱动
  Future<bool> startBackgroundReporting({
    required int intervalSec,
    required List<MapEntry<String, String>> stocks,
  }) async {
    if (!_isAndroid) return false;
    final namesJson = <String, String>{};
    final codesJson = <String>[];
    for (final s in stocks) {
      namesJson[s.key] = s.value;
      codesJson.add(s.key);
    }
    try {
      await _serviceChannel.invokeMethod('startBackgroundReporting', {
        'intervalSec': intervalSec,
        'stockNamesJson': _encodeJsonMap(namesJson),
        'stockCodesJson': _encodeJsonList(codesJson),
      });
      _backgroundReportingActive = true;
      _log('debug', 'startBackgroundReporting: interval=${intervalSec}s, stocks=${stocks.length}');
      return true;
    } on PlatformException catch (e) {
      _log('debug', 'startBackgroundReporting failed: ${e.code} - ${e.message}');
      if (e.code == 'EXACT_ALARM_PERMISSION_DENIED') {
        // 精确闹钟权限缺失，Flutter 端弹对话框引导用户
        _showExactAlarmPermissionDialog();
      }
      return false;
    } catch (e) {
      _log('debug', 'startBackgroundReporting failed: $e');
      return false;
    }
  }

  /// 弹出精确闹钟权限引导对话框
  void _showExactAlarmPermissionDialog() {
    navigatorKey.currentState?.push(
      DialogRoute<void>(
        context: navigatorKey.currentContext!,
        builder: (ctx) => AlertDialog(
          title: const Text('⚠️ 精确闹钟权限被拒'),
          content: const Text(
            '熄屏播报需要「精确闹钟」权限才能在屏幕关闭时触发语音播报。\n\n请在弹出的页面中找到「听股通」，并开启「允许设置精确闹钟」选项。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                _serviceChannel.invokeMethod('openExactAlarmSettings');
                Navigator.of(ctx).pop();
              },
              child: const Text('去设置'),
            ),
          ],
        ),
      ),
    );
  }

  /// 引导用户设置电池优化白名单（国产手机必须）
  /// 这是确保熄屏播报在国产手机上正常工作的关键步骤
  Future<void> guideBatteryOptimization() async {
    if (!_isAndroid) return;
    try {
      // 打开厂商特定电池优化设置页面
      await _serviceChannel.invokeMethod('guideBatteryOptimization');
      _log('debug', 'guideBatteryOptimization: opened');
    } catch (e) {
      _log('debug', 'guideBatteryOptimization failed: $e');
    }
  }

  /// 检测是否为后台限制严格的厂商
  Future<bool> isRestrictiveManufacturer() async {
    if (!_isAndroid) return false;
    try {
      final result = await _serviceChannel.invokeMethod<bool>('isManufacturerWithRestrictiveBackground');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 弹出电池优化引导对话框（首次开启播报时调用）
  Future<void> showBatteryOptimizationDialog() async {
    final isRestrictive = await isRestrictiveManufacturer();
    if (!isRestrictive) return; // 非限制性厂商无需引导

    if (!navigatorKey.currentState.mounted) return;
    final ctx = navigatorKey.currentContext!;

    await showDialog<void>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('🔋 电池优化设置'),
        content: const Text(
          '检测到您使用的是国产手机，这些手机后台管理非常严格。\n\n'
          '为确保熄屏播报正常工作，请完成以下设置：\n\n'
          '1️⃣ 在弹出的页面中，将「听股通」设为「无限制」或「允许后台活动」\n\n'
          '2️⃣ 开启「自启动」权限\n\n'
          '3️⃣ 关闭「省电模式」或将其设为「无限制」\n\n'
          '⚠️ 如果不完成这些设置，熄屏后播报可能被系统自动拦截。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('稍后再说'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(dialogCtx).pop();
              guideBatteryOptimization();
            },
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  /// 停止后台播报（取消 AlarmManager）
  Future<void> stopBackgroundReporting() async {
    if (!_isAndroid) return;
    try {
      await _serviceChannel.invokeMethod('stopBackgroundReporting');
      _backgroundReportingActive = false;
      _log('debug', 'stopBackgroundReporting: done');
    } catch (e) {
      _log('debug', 'stopBackgroundReporting failed: $e');
    }
  }

  /// 更新后台播报配置（间隔/股票列表变化时）
  Future<void> updateBackgroundReporting({
    required int intervalSec,
    required List<MapEntry<String, String>> stocks,
  }) async {
    if (!_isAndroid) return;
    final namesJson = <String, String>{};
    final codesJson = <String>[];
    for (final s in stocks) {
      namesJson[s.key] = s.value;
      codesJson.add(s.key);
    }
    try {
      await _serviceChannel.invokeMethod('updateBackgroundReporting', {
        'intervalSec': intervalSec,
        'stockNamesJson': _encodeJsonMap(namesJson),
        'stockCodesJson': _encodeJsonList(codesJson),
      });
      _log('debug', 'updateBackgroundReporting: done');
    } catch (e) {
      _log('debug', 'updateBackgroundReporting failed: $e');
    }
  }

  String _encodeJsonMap(Map<String, String> map) {
    final sb = StringBuffer('{');
    var first = true;
    for (final e in map.entries) {
      if (!first) sb.write(',');
      first = false;
      sb.write('"${e.key}":"${e.value}"');
    }
    sb.write('}');
    return sb.toString();
  }

  String _encodeJsonList(List<String> list) {
    final sb = StringBuffer('[');
    for (var i = 0; i < list.length; i++) {
      if (i > 0) sb.write(',');
      sb.write('"${list[i]}"');
    }
    sb.write(']');
    return sb.toString();
  }

  /// 播报文本。抛出 TtsException 表示失败（供 UI 层展示）。
  Future<void> speak(String text) async {
    await _ensureAudioSession();
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
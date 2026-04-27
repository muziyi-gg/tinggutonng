import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:charset_converter/charset_converter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/stock.dart';
import '../models/alert_type.dart';
import '../services/tts_service.dart';
import '../services/notification_service.dart';
import '../services/realtime_quote_service.dart';

/// 播报错误信息，用于 UI 层展示
class ReportError {
  final String message;
  ReportError(this.message);
}

/// 调试事件日志项
class DebugLogEntry {
  final String tag; // SP = StockProvider, TTS = TtsService
  final String msg;
  final DateTime ts;
  DebugLogEntry(this.tag, this.msg) : ts = DateTime.now();
  @override
  String toString() => '[${ts.toString().substring(11, 19)}][$tag] $msg';
}

/// 听股通 Phase 1 MVP — 核心播报引擎
/// 数据流：API轮询 → 播报间隔判断 → TTS语音 + 本地通知
class StockProvider extends ChangeNotifier with WidgetsBindingObserver {
  final TtsService _tts = TtsService();
  final NotificationService _notif = NotificationService();
  final RealtimeQuoteService _rtq = RealtimeQuoteService();

  Timer? _reportTimer;
  Timer? _pollTimer;
  StreamSubscription? _rtqSub;
  Map<String, Stock> _stocks = {};
  List<AlertItem> _recentAlerts = [];
  bool _isPolling = false;
  int _reportIntervalSec = 60; // 默认60秒播报一次

  /// 播报开关（用户按按钮开启/关闭循环播报）
  /// true = 循环播报运行中（定时器活跃）
  /// false = 播报停止
  bool _speaking = false;
  /// 标记当前是否正在执行播报（单次循环内，防止重叠）
  bool _isReporting = false;
  /// 原生 TtsBroadcastService 正在播报（锁屏时由 EventChannel 同步）
  bool _nativeTtsPlaying = false;

  /// 当前错误（UI 层负责展示和清除）
  ReportError? _lastError;

  /// App 生命周期（用于检测切后台）
  AppLifecycleState _appLifecycle = AppLifecycleState.resumed;

  /// App 切后台时 TTS 是否在播（用于切回前台判断是否恢复）
  bool _wasPlayingWhenBackgrounded = false;

  /// AlarmManager 后台定时器是否已激活（熄屏后由系统闹钟唤醒）
  bool _backgroundTimerActive = false;

  /// 调试日志（保留最近200条）
  final List<DebugLogEntry> _debugLog = [];
  static const int _maxLog = 200;

  Map<String, Stock> get stocks => _stocks;
  List<Stock> get stockList => _stocks.values.toList();
  List<AlertItem> get recentAlerts => _recentAlerts;
  bool get isPolling => _isPolling;
  int get reportIntervalSec => _reportIntervalSec;
  ReportError? get lastError => _lastError;
  bool get isSpeaking => _speaking || _nativeTtsPlaying;
  List<DebugLogEntry> get debugLog => List.unmodifiable(_debugLog);
  AppLifecycleState get appLifecycle => _appLifecycle;
  bool get ttsIsPlaying => _tts.isPlaying;
  bool get backgroundTimerActive => _backgroundTimerActive;
  bool get realtimeConnected => _rtq.isConnected;

  void _log(String tag, String msg) {
    _debugLog.add(DebugLogEntry(tag, msg));
    if (_debugLog.length > _maxLog) _debugLog.removeAt(0);
    debugPrint('[SP] [$tag] $msg');
  }

  void clearLog() => _debugLog.clear();

  void clearError() {
    _lastError = null;
    notifyListeners();
  }

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    // 将 TTS 内部日志合并到 SP.debugLog，方便调试页面查看完整日志链
    _tts.registerLogCallback((tag, msg) => _log(tag, msg));
    // 接收原生 TtsBroadcastService 推送的播报状态（锁屏时原生 TTS 播报开始/结束）
    _tts.setOnServiceStateChange((isPlaying, isPaused) {
      _nativeTtsPlaying = isPlaying && !isPaused;
      if (!isPlaying && _speaking) {
        // 原生播报结束，但用户未主动停止 → 标记为当前播报周期结束，下次定时器到期继续
        _log('service_events', 'Native TTS finished, isPaused=$isPaused, keeping _speaking=$_speaking');
      }
      notifyListeners();
    });
    // 注册实时行情日志
    _rtq.onLog = (msg) => _log('RTQ', msg);
    await _tts.init();
    await _notif.init();
    // 从本地存储恢复自选股（必须等待完成，防止竞态）
    // 同步等待第一次价格获取完成，确保内存中已有实时价格
    await _loadStocks();
    notifyListeners();
  }

  static const _kKey = 'watchlist_v2';

  Future<void> _loadStocks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List;
      for (final item in list) {
        final code = item['code'] as String;
        final name = item['name'] as String;
        _stocks[code] = Stock(code: code, name: name, tradeDate: DateTime.now());
      }
      if (_stocks.isNotEmpty) {
        // 连接 WebSocket 实时行情，同时做一次 HTTP 预热（确保 UI 立即有数据）
        final codes = _stocks.keys.toList();
        _ensureWatchRunning();
        // HTTP 预热：立即获取一次价格填充内存，WebSocket 推送覆盖之
        await _pollPricesLive();
        // 连接 WebSocket，实现 <1秒延迟
        _connectRealtime(codes);
      }
    } catch (e) {
      _log('init', '_loadStocks error: $e');
    }
  }

  Future<void> _saveStocks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _stocks.values.map((s) => {'code': s.code, 'name': s.name}).toList();
      await prefs.setString(_kKey, jsonEncode(list));
    } catch (e) {
      _log('lifecycle', '_saveStocks error: $e');
    }
  }

  /// 连接东方财富 WebSocket 实时行情（<1秒延迟）
  Future<void> _connectRealtime(List<String> codes) async {
    if (codes.isEmpty) return;
    
    await _rtq.connect(codes);
    
    // 监听 WebSocket 数据推送，实时更新内存中的股票行情
    _rtqSub?.cancel();
    _rtqSub = _rtq.quoteStream.listen((quotes) {
      bool changed = false;
      for (final entry in quotes.entries) {
        if (_stocks.containsKey(entry.key)) {
          _stocks[entry.key] = Stock(
            code: entry.key,
            name: _stocks[entry.key]!.name,
            price: entry.value.price,
            prevClose: _stocks[entry.key]!.prevClose,
            change: entry.value.change,
            changePct: entry.value.changePct,
            openPrice: _stocks[entry.key]!.openPrice,
            lastUpdate: DateTime.now(),
            tradeDate: _stocks[entry.key]!.tradeDate,
          );
          changed = true;
        }
      }
      if (changed) notifyListeners();
    });
    
    _log('lifecycle', '_connectRealtime: connected, ${codes.length} stocks subscribed');
  }

  /// 开始监控：启动轮询（内部使用，无需外部调用）
  /// WebSocket 已连接时，轮询降为 5 秒间隔（数据来自 WebSocket，轮询仅做备用）
  /// WebSocket 未连接时，保持 1 秒轮询（降级保底）
  void _ensureWatchRunning() {
    if (_isPolling) {
      // 已经运行中，重启轮询以包含最新股票列表
      _pollTimer?.cancel();
      // WebSocket 连通时降频轮询（省电），WebSocket 断开时恢复 1s
      final interval = _rtq.isConnected ? 5 : 1;
      _pollTimer = Timer.periodic(Duration(seconds: interval), (_) => _pollPricesLive());
      _log('lifecycle', '_ensureWatchRunning: restarted polling interval=${interval}s (RTQ=${_rtq.isConnected})');
      return;
    }

    final codes = _stocks.keys.toList();
    if (codes.isEmpty) return;

    _isPolling = true;
    // WebSocket 连通时降频轮询，WebSocket 断开时保持 1s
    final interval = _rtq.isConnected ? 5 : 1;
    _pollTimer = Timer.periodic(Duration(seconds: interval), (_) => _pollPricesLive());

    // 立即获取一次价格
    _pollPricesLive();

    _log('lifecycle', '_ensureWatchRunning: started polling, stocks=${codes.length}, interval=${interval}s');
    notifyListeners();
  }

  void stopWatch() {
    _pollTimer?.cancel();
    _isPolling = false;
    _stocks.clear();
    _rtqSub?.cancel();
    _rtq.disconnect();
    _log('lifecycle', 'stopWatch: stopped polling, cleared stocks, disconnected RTQ');
    notifyListeners();
  }

  void addStock(String code, String name) {
    if (!_stocks.containsKey(code)) {
      _stocks[code] = Stock(code: code, name: name, tradeDate: DateTime.now());
      _saveStocks();
      if (_speaking) _updateBackgroundTimer(); // 同步更新熄屏播报列表
      
      // 如果是添加第一只股票，初始化 WebSocket 连接
      final isFirstStock = _stocks.length == 1;
      
      // 更新 WebSocket 订阅（新增股票）
      if (_rtq.isConnected) {
        _rtq.updateSubscriptions(_stocks.keys.toList());
      } else if (isFirstStock) {
        // 首次添加股票且尚未连接 WebSocket，建立连接
        _connectRealtime(_stocks.keys.toList());
      }
      
      _ensureWatchRunning();
      notifyListeners();
    }
  }

  void removeStock(String code) {
    _stocks.remove(code);
    if (_stocks.isEmpty) {
      stopWatch();
      _saveStocks();
    } else {
      // 更新 WebSocket 订阅（移除股票）
      if (_rtq.isConnected) {
        _rtq.updateSubscriptions(_stocks.keys.toList());
      }
      _ensureWatchRunning();
    }
    if (_speaking) _updateBackgroundTimer(); // 同步更新熄屏播报列表
    notifyListeners();
  }

  /// 开启循环播报（用户按播放按钮）
  /// 前台：Flutter Timer 驱动
  /// 熄屏后：Android AlarmManager → TtsBroadcastService（原生 TTS）驱动
  void startReport() {
    if (_speaking) {
      _log('report', 'startReport: already speaking, ignore');
      return;
    }
    _speaking = true;
    _reportTimer?.cancel();
    _log('report', 'startReport: _speaking=true, starting timer every ${_reportIntervalSec}s');

    // 首次开启播报时引导用户设置电池优化白名单（国产手机必须）
    _showBatteryGuideIfNeeded();

    // 立即激活 AlarmManager（与 _speaking 解耦，只要用户开启播报就设置）
    _activateBackgroundTimer();

    // 立即播一次，然后按间隔循环
    _reportAll(); // 异步，不阻塞
    _reportTimer = Timer.periodic(
      Duration(seconds: _reportIntervalSec),
      (_) => _reportAll(),
    );
    notifyListeners();
  }

  /// 首次开启播报时提示电池优化引导（只提示一次）
  bool _batteryGuideShown = false;
  void _showBatteryGuideIfNeeded() {
    if (_batteryGuideShown) return;
    _batteryGuideShown = true;
    // 异步弹出对话框，不阻塞播报启动
    Future.microtask(() => _tts.showBatteryOptimizationDialog());
  }

  void setReportInterval(int seconds) {
    _reportIntervalSec = seconds;
    _log('report', 'setReportInterval: changed to $seconds');
    // 如果正在播报，重新启动定时器（用新间隔）
    if (_speaking) {
      _reportTimer?.cancel();
      _reportTimer = Timer.periodic(
        Duration(seconds: seconds),
        (_) => _reportAll(),
      );
      // 同时更新熄屏定时器间隔
      _updateBackgroundTimer();
    }
    notifyListeners();
  }

  /// 每秒轮询：获取最新价格（腾讯 HTTP API，返回 UTF-8）
  /// v_{code}="1~名称~代码~现价~昨收~今开~成交量~外盘~内盘~买一价~买一量~
  ///        买一价~买一量~... ~时间(YYYYMMDDHHMMSS)~涨跌~涨跌幅%~最高~最低~..."
  Future<void> _pollPricesLive() async {
    if (_stocks.isEmpty) return;
    final codes = _stocks.keys.toList();
    final url = 'https://qt.gtimg.cn/q=${codes.join(",")}';
    try {
      final r = await http.get(
        Uri.parse(url),
        headers: {
          'Referer': 'https://gu.qq.com',
          'Accept': '*/*',
        },
      ).timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        // 腾讯 API 返回 GBK 编码，需要正确解码
        final body = await CharsetConverter.decode('gbk', r.bodyBytes);
        _parseTencentResponse(body);
      }
    } catch (e) {
      _log('poll', 'Poll error: $e');
    }
  }

  /// 解析腾讯 v_{code}="1~名称~代码~现价~昨收~今开~...~时间~涨跌~涨跌幅%~最高~最低~..." 格式
  /// 字段（~分隔，从0计）：
  /// f[0]=固定1  f[1]=名称  f[2]=代码  f[3]=现价  f[4]=昨收  f[5]=今开
  /// f[6]=成交量  f[7]=外盘  f[8]=内盘  f[30]=时间戳(YYYYMMDDHHMMSS)
  /// f[31]=涨跌额  f[32]=涨跌幅%  f[33]=最高  f[34]=最低
  void _parseTencentResponse(String raw) {
    final re = RegExp(r'v_(\w+)="([^"]+)"');
    bool changed = false;
    int matched = 0;
    for (final m in re.allMatches(raw)) {
      final code = m[1]!;
      final f = m[2]!.split('~');
      if (f.length < 36) {
        _log('poll', 'Tencent skip $code: fields=${f.length}');
        continue;
      }
      final price     = double.tryParse(f[3])  ?? 0; // 现价
      final prevClose = double.tryParse(f[4])  ?? 0; // 昨收
      final openPrice = double.tryParse(f[5])  ?? 0; // 今开
      final change     = double.tryParse(f[31]) ?? 0; // 涨跌额
      final changePct  = double.tryParse(f[32]) ?? 0; // 涨跌幅%

      // 解析时间戳 f[30]：格式 YYYYMMDDHHMMSS
      DateTime? serverTime;
      DateTime? tradeDate;
      if (f[30].length >= 14) {
        try {
          final y = int.parse(f[30].substring(0, 4));
          final mon = int.parse(f[30].substring(4, 6));
          final d = int.parse(f[30].substring(6, 8));
          final h = int.parse(f[30].substring(8, 10));
          final mi = int.parse(f[30].substring(10, 12));
          final s = int.parse(f[30].substring(12, 14));
          serverTime = DateTime(y, mon, d, h, mi, s);
          tradeDate = DateTime(y, mon, d);
        } catch (_) {
          serverTime = DateTime.now();
          tradeDate = DateTime.now();
        }
      } else {
        serverTime = DateTime.now();
        tradeDate = DateTime.now();
      }

      if (_stocks.containsKey(code)) {
        _stocks[code] = Stock(
          code: code,
          name: _stocks[code]!.name,
          price: price,
          prevClose: prevClose,
          change: change,
          changePct: changePct,
          openPrice: openPrice,
          lastUpdate: serverTime ?? DateTime.now(),
          tradeDate: tradeDate ?? DateTime.now(),
        );
        changed = true;
        matched++;
      }
    }
    _log('poll', 'Tencent matched=$matched/${_stocks.length}');
    if (changed) notifyListeners();
  }

  /// 定时播报：按间隔循环播报所有股票，直到用户关闭
  /// 由 _reportTimer 定时器调用
  Future<void> _reportAll() async {
    _log('report', '_reportAll triggered: _speaking=$_speaking, _isReporting=$_isReporting, stocks=${_stocks.length}');
    if (_stocks.isEmpty) {
      _log('report', '_reportAll: no stocks, skip');
      return;
    }
    if (_isReporting) {
      _log('report', '_reportAll: already reporting, skip');
      return;
    }
    _isReporting = true;
    try {
      bool anySkipped = false;
      for (final s in _stocks.values) {
        // 用户关闭播报时立即退出
        if (!_speaking) {
          _log('report', '_reportAll: user stopped, exit loop');
          return;
        }
        if (s.price <= 0) {
          _log('report', 'TTS skip ${s.name}: price=${s.price} (数据未就绪)');
          anySkipped = true;
          continue;
        }
        final dir = s.changePct >= 0 ? '涨' : '跌';
        final text = '${s.name}，报${s.price.toStringAsFixed(2)}元，$dir${s.changePct.abs().toStringAsFixed(2)}%';
        _log('report', '_reportAll: about to speak "$text"');
        await _speakAndNotify(text, AlertType.selfQuote);
        if (!_speaking) {
          _log('report', '_reportAll: stopped mid-loop after speak');
          return;
        }
        // 播报间隔（等待上一句播完 + 短暂停顿）
        await Future.delayed(const Duration(milliseconds: 800));
        if (!_speaking) {
          _log('report', '_reportAll: stopped mid-loop after delay');
          return;
        }
      }
      if (anySkipped && _stocks.values.every((s) => s.price <= 0)) {
        _lastError = ReportError('行情数据未就绪，请检查网络后重试');
        notifyListeners();
      }
      _log('report', '_reportAll: completed one round');
    } catch (e) {
      _log('report', 'TTS _reportAll error: $e');
    } finally {
      _isReporting = false;
    }
  }

  /// 停止播报（用户点击停止按钮）
  Future<void> stopSpeaking() async {
    _log('report', 'stopSpeaking: _speaking=false, cancelling timer');
    _speaking = false;
    _reportTimer?.cancel();
    _reportTimer = null;
    await _tts.stop();
    // 取消熄屏定时器
    await _deactivateBackgroundTimer();
    notifyListeners();
  }

  // ═══════════════════════════════════════════
  // 熄屏后定时播报（Android 原生 AlarmManager）
  // 原理：Flutter Timer 在熄屏时被暂停，但 AlarmManager 由系统唤醒
  // ═══════════════════════════════════════════

  /// 激活熄屏定时器（写入股票配置到 SharedPreferences，Android 原生层读取）
  /// 与 _speaking 解耦：只要用户开启播报就激活 AlarmManager
  Future<void> _activateBackgroundTimer() async {
    try {
      // 构建股票名称映射
      final namesJson = <String, String>{};
      final codesJson = <String>[];
      for (final s in _stocks.values) {
        namesJson[s.code] = s.name;
        codesJson.add(s.code);
      }
      _log('lifecycle', '_activateBackgroundTimer: BEFORE native call, interval=${_reportIntervalSec}s, stocks=${_stocks.length}');
      await _tts.startBackgroundReporting(
        intervalSec: _reportIntervalSec,
        stocks: namesJson.entries.map((e) => MapEntry(e.key, e.value)).toList(),
      );
      _backgroundTimerActive = true;
      _log('lifecycle', '_activateBackgroundTimer: AFTER native call success');
    } catch (e, st) {
      _log('lifecycle', '_activateBackgroundTimer FAILED: $e\n$st');
    }
  }

  /// 更新熄屏定时器（间隔变化或股票列表变化时调用）
  Future<void> _updateBackgroundTimer() async {
    try {
      final namesJson = <String, String>{};
      final codesJson = <String>[];
      for (final s in _stocks.values) {
        namesJson[s.code] = s.name;
        codesJson.add(s.code);
      }
      await _tts.updateBackgroundReporting(
        intervalSec: _reportIntervalSec,
        stocks: namesJson.entries.map((e) => MapEntry(e.key, e.value)).toList(),
      );
      _log('lifecycle', '_updateBackgroundTimer: done');
    } catch (e) {
      _log('lifecycle', '_updateBackgroundTimer failed: $e');
    }
  }

  /// 取消熄屏定时器
  Future<void> _deactivateBackgroundTimer() async {
    try {
      await _tts.stopBackgroundReporting();
      _backgroundTimerActive = false;
      _log('lifecycle', '_deactivateBackgroundTimer: done');
    } catch (e) {
      _log('lifecycle', '_deactivateBackgroundTimer failed: $e');
    }
  }

  Future<void> _speakAndNotify(String text, AlertType type) async {
    // 添加到播报记录
    final item = AlertItem(type: type, text: text);
    _recentAlerts.insert(0, item);
    if (_recentAlerts.length > 30) _recentAlerts.removeLast();
    notifyListeners();

    // TTS 语音播报（speak 内部已处理所有异常，抛出的都是需要用户感知的）
    try {
      _log('report', '_speakAndNotify: calling _tts.speak("$text")');
      await _tts.speak(text);
      _lastError = null;
      _log('report', '_speakAndNotify: _tts.speak completed normally');
    } on TtsException catch (e) {
      _log('report', 'TTS speak failed: $e');
      _lastError = ReportError(e.message);
      notifyListeners();
      return; // 跳过本次播报，继续下一只
    }
    // 不再发送本地通知（用户只需要听语音即可）
  }

  /// 手动播报（首页按钮触发）
  /// 播放/暂停只控制声音，不影响界面状态
  Future<ReportError?> reportAllStocks() async {
    if (_stocks.isEmpty) {
      _lastError = ReportError('请先添加自选股');
      notifyListeners();
      return _lastError;
    }
    await _reportAll();
    return _lastError;
  }

  // ═══════════════════════════════════════════
  // ═══════════════════════════════════════════
  // App 生命周期监听（WidgetBindingObserver）
  // 关键：检测熄屏/切后台是否导致定时器被暂停
  // ═══════════════════════════════════════════
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycle = state;

    if (state == AppLifecycleState.inactive) {
      // 记录切后台时是否在播
      _wasPlayingWhenBackgrounded = _tts.isPlaying || _speaking;
      _log('lifecycle', 'App INACTIVE: wasPlaying=$_wasPlayingWhenBackgrounded, speaking=$_speaking, tts.isPlaying=${_tts.isPlaying}');
      // 确保 AlarmManager 已激活（熄屏后独立触发播报）
      if (_speaking) _activateBackgroundTimer();
    } else if (state == AppLifecycleState.paused) {
      _log('lifecycle', 'App PAUSED: speaking=$_speaking, timer=${_reportTimer != null}');
      // 熄屏瞬间再确保一次 AlarmManager
      if (_speaking) _activateBackgroundTimer();
    } else if (state == AppLifecycleState.resumed) {
      _log('lifecycle', 'App RESUMED: wasPlaying=$_wasPlayingWhenBackgrounded, speaking=$_speaking, tts.isPlaying=${_tts.isPlaying}');

      // 自动恢复：如果之前在播但 TTS 被中断，立即重启
      if (_wasPlayingWhenBackgrounded && !_tts.isPlaying) {
        _log('lifecycle', 'App resumed: TTS was interrupted, restarting');
        if (_reportTimer != null) {
          _reportTimer!.cancel();
          _reportTimer = Timer.periodic(
            Duration(seconds: _reportIntervalSec),
            (_) => _reportAll(),
          );
        }
        _reportAll();
      } else if (_reportTimer == null && _speaking) {
        _log('lifecycle', 'App resumed: timer missing! Restarting.');
        _reportTimer = Timer.periodic(
          Duration(seconds: _reportIntervalSec),
          (_) => _reportAll(),
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _reportTimer?.cancel();
    _rtqSub?.cancel();
    _rtq.dispose();
    // 关闭熄屏定时器
    _deactivateBackgroundTimer();
    _tts.dispose();
    super.dispose();
  }
}
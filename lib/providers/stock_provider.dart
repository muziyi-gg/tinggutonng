import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:charset_converter/charset_converter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/stock.dart';
import '../models/alert_type.dart';
import '../services/tts_service.dart';
import '../services/notification_service.dart';

/// 播报错误信息，用于 UI 层展示
class ReportError {
  final String message;
  ReportError(this.message);
}

/// 听股通 Phase 1 MVP — 核心播报引擎
/// 数据流：API轮询 → 播报间隔判断 → TTS语音 + 本地通知
class StockProvider extends ChangeNotifier {
  final TtsService _tts = TtsService();
  final NotificationService _notif = NotificationService();

  Timer? _reportTimer;
  Timer? _pollTimer;
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

  /// 当前错误（UI 层负责展示和清除）
  ReportError? _lastError;

  Map<String, Stock> get stocks => _stocks;
  List<Stock> get stockList => _stocks.values.toList();
  List<AlertItem> get recentAlerts => _recentAlerts;
  bool get isPolling => _isPolling;
  int get reportIntervalSec => _reportIntervalSec;
  ReportError? get lastError => _lastError;
  bool get isSpeaking => _speaking;

  void clearError() {
    _lastError = null;
    notifyListeners();
  }

  Future<void> init() async {
    await _tts.init();
    await _notif.init();
    // 从本地存储恢复自选股（必须等待完成，防止竞态）
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
        _ensureWatchRunning();
        // 立即获取一次价格
        _pollPricesLive();
      }
    } catch (e) {
      debugPrint('_loadStocks error: $e');
    }
  }

  Future<void> _saveStocks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _stocks.values.map((s) => {'code': s.code, 'name': s.name}).toList();
      await prefs.setString(_kKey, jsonEncode(list));
    } catch (e) {
      debugPrint('_saveStocks error: $e');
    }
  }

  /// 开始监控：启动轮询（内部使用，无需外部调用）
  void _ensureWatchRunning() {
    if (_isPolling) {
      // 已经运行中，重启轮询以包含最新股票列表
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollPricesLive());
      return;
    }

    final codes = _stocks.keys.toList();
    if (codes.isEmpty) return;

    _isPolling = true;
    // 每秒轮询价格（使用 _pollPricesLive 读取实时股票列表）
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollPricesLive());

    // 立即获取一次价格
    _pollPricesLive();

    notifyListeners();
  }

  void stopWatch() {
    _pollTimer?.cancel();
    _isPolling = false;
    _stocks.clear();
    notifyListeners();
  }

  void addStock(String code, String name) {
    if (!_stocks.containsKey(code)) {
      _stocks[code] = Stock(code: code, name: name, tradeDate: DateTime.now());
      _ensureWatchRunning();
      _saveStocks();
      notifyListeners();
    }
  }

  void removeStock(String code) {
    _stocks.remove(code);
    if (_stocks.isEmpty) {
      stopWatch();
      _saveStocks();
    } else {
      _ensureWatchRunning();
    }
    notifyListeners();
  }

  /// 开启循环播报（用户按播放按钮）
  /// 定时器按 _reportIntervalSec 间隔触发，播完一轮后等下一轮
  void startReport() {
    if (_speaking) return; // 已在播报中
    _speaking = true;
    _reportTimer?.cancel();
    // 立即播一次，然后按间隔循环
    _reportAll(); // 异步，不阻塞
    _reportTimer = Timer.periodic(
      Duration(seconds: _reportIntervalSec),
      (_) => _reportAll(),
    );
    notifyListeners();
  }

  void setReportInterval(int seconds) {
    _reportIntervalSec = seconds;
    // 如果正在播报，重新启动定时器（用新间隔）
    if (_speaking) {
      _reportTimer?.cancel();
      _reportTimer = Timer.periodic(
        Duration(seconds: seconds),
        (_) => _reportAll(),
      );
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
      debugPrint('Poll error: $e');
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
        debugPrint('Tencent skip $code: fields=${f.length}');
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
    debugPrint('Tencent matched=$matched/${_stocks.length}');
    if (changed) notifyListeners();
  }

  /// 定时播报：按间隔循环播报所有股票，直到用户关闭
  /// 由 _reportTimer 定时器调用
  Future<void> _reportAll() async {
    if (_stocks.isEmpty || _isReporting) return;
    _isReporting = true;
    try {
      bool anySkipped = false;
      for (final s in _stocks.values) {
        // 用户关闭播报时立即退出
        if (!_speaking) {
          debugPrint('TTS stopped by user');
          return;
        }
        if (s.price <= 0) {
          debugPrint('TTS skip ${s.name}: price=${s.price} (数据未就绪)');
          anySkipped = true;
          continue;
        }
        final dir = s.changePct >= 0 ? '涨' : '跌';
        final text = '${s.name}，报${s.price.toStringAsFixed(2)}元，$dir${s.changePct.abs().toStringAsFixed(2)}%';
        await _speakAndNotify(text, AlertType.selfQuote);
        if (!_speaking) return;
        // 播报间隔（等待上一句播完 + 短暂停顿）
        await Future.delayed(const Duration(milliseconds: 800));
        if (!_speaking) return;
      }
      if (anySkipped && _stocks.values.every((s) => s.price <= 0)) {
        _lastError = ReportError('行情数据未就绪，请检查网络后重试');
        notifyListeners();
      }
    } catch (e) {
      debugPrint('TTS _reportAll error: $e');
    } finally {
      _isReporting = false;
    }
  }

  /// 停止播报（用户点击停止按钮）
  Future<void> stopSpeaking() async {
    _speaking = false;
    _reportTimer?.cancel();
    _reportTimer = null;
    await _tts.stop();
    notifyListeners();
  }

  Future<void> _speakAndNotify(String text, AlertType type) async {
    // 添加到播报记录
    final item = AlertItem(type: type, text: text);
    _recentAlerts.insert(0, item);
    if (_recentAlerts.length > 30) _recentAlerts.removeLast();
    notifyListeners();

    // TTS 语音播报（speak 内部已处理所有异常，抛出的都是需要用户感知的）
    try {
      await _tts.speak(text);
      _lastError = null;
    } on TtsException catch (e) {
      debugPrint('TTS speak failed: $e');
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

  @override
  void dispose() {
    _pollTimer?.cancel();
    _reportTimer?.cancel();
    _tts.dispose();
    super.dispose();
  }
}

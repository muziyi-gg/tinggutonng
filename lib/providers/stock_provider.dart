import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
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

  // 暂停播报标志（防止播报重叠）
  bool _speaking = false;

  // 当前错误（UI 层负责展示和清除）
  ReportError? _lastError;

  Map<String, Stock> get stocks => _stocks;
  List<Stock> get stockList => _stocks.values.toList();
  List<AlertItem> get recentAlerts => _recentAlerts;
  bool get isPolling => _isPolling;
  int get reportIntervalSec => _reportIntervalSec;
  ReportError? get lastError => _lastError;

  void clearError() {
    _lastError = null;
    notifyListeners();
  }

  Future<void> init() async {
    await _tts.init();
    await _notif.init();
    notifyListeners();
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

    // 定时播报
    _reportTimer?.cancel();
    _reportTimer = Timer.periodic(
      Duration(seconds: _reportIntervalSec),
      (_) => _reportAll(),
    );

    // 立即获取一次价格
    _pollPricesLive();

    notifyListeners();
  }

  void stopWatch() {
    _pollTimer?.cancel();
    _reportTimer?.cancel();
    _isPolling = false;
    _stocks.clear();
    notifyListeners();
  }

  void addStock(String code, String name) {
    if (!_stocks.containsKey(code)) {
      _stocks[code] = Stock(code: code, name: name);
      _ensureWatchRunning();
      notifyListeners();
    }
  }

  void removeStock(String code) {
    _stocks.remove(code);
    if (_stocks.isEmpty) {
      stopWatch();
    } else {
      _ensureWatchRunning();
    }
    notifyListeners();
  }

  void setReportInterval(int seconds) {
    _reportIntervalSec = seconds;
    // 重新启动定时器
    _reportTimer?.cancel();
    if (_isPolling) {
      _reportTimer = Timer.periodic(
        Duration(seconds: seconds),
        (_) => _reportAll(),
      );
    }
    notifyListeners();
  }

  /// 每秒轮询：获取最新价格（从实时股票列表）
  Future<void> _pollPricesLive() async {
    if (_stocks.isEmpty) return;
    try {
      final codes = _stocks.keys.toList();
      final uri = Uri.parse('https://qt.gtimg.cn/q=${codes.join(",")}');
      final resp = await http.get(
        uri,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
          'Referer': 'https://gu.qq.com/',
        },
      ).timeout(const Duration(seconds: 3));

      if (resp.statusCode != 200) return;
      final raw = utf8.decode(resp.bodyBytes);
      _parseQtResponse(raw);
    } catch (e) {
      debugPrint('poll error: $e');
    }
  }

  void _parseQtResponse(String raw) {
    final re = RegExp(r'v_(\w+)="([^"]+)"');
    bool changed = false;
    for (final m in re.allMatches(raw)) {
      final code = m[1]!;
      final f = m[2]!.split('~');
      if (f.length < 33) continue;
      final price = double.tryParse(f[3]) ?? 0;
      final prevClose = double.tryParse(f[4]) ?? 0;
      final change = double.tryParse(f[31]) ?? 0;
      final changePct = double.tryParse(f[32]) ?? 0;

      if (_stocks.containsKey(code)) {
        _stocks[code] = Stock(
          code: code,
          name: _stocks[code]!.name,
          price: price,
          prevClose: prevClose,
          change: change,
          changePct: changePct,
          lastUpdate: DateTime.now(),
        );
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// 定时播报：按间隔播报所有股票
  Future<void> _reportAll() async {
    if (_speaking || _stocks.isEmpty) return;
    _speaking = true;
    try {
      for (final s in _stocks.values) {
        if (s.price <= 0) continue;
        final dir = s.changePct >= 0 ? '涨' : '跌';
        final text = '${s.name}，报${s.price.toStringAsFixed(2)}元，$dir${s.changePct.abs().toStringAsFixed(2)}%';
        await _speakAndNotify(text, AlertType.selfQuote);
        await Future.delayed(const Duration(milliseconds: 800));
      }
    } finally {
      _speaking = false;
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
      await _tts.speak(text);
      _lastError = null;
    } on TtsException catch (e) {
      debugPrint('TTS speak failed: $e');
      _lastError = ReportError(e.message);
      notifyListeners();
      return; // 跳过本次播报，继续下一只
    }
    // 本地通知
    await _notif.show(title: '听股通播报', body: text);
  }

  /// 手动播报（首页按钮触发）
  /// 返回错误信息供 UI 弹窗使用
  Future<ReportError?> reportAllStocks() async {
    if (_speaking) {
      _lastError = ReportError('正在播报中，请稍候...');
      notifyListeners();
      return _lastError;
    }
    if (_stocks.isEmpty) {
      _lastError = ReportError('请先添加自选股');
      notifyListeners();
      return _lastError;
    }
    await _reportAll();
    // 如果 _reportAll 中 TTS 失败，_lastError 会被设置
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

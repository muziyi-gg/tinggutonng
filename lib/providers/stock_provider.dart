import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/stock.dart';
import '../models/alert_type.dart';
import '../services/stock_api_service.dart';
import '../services/tts_service.dart';
import '../services/notification_service.dart';

/// 播报调度器
/// 负责：API轮询 → 警报判断 → TTS播报 + 通知
/// 核心原则：直接调用API，本地完成所有计算，无中间层
class StockProvider extends ChangeNotifier {
  final StockApiService _api = StockApiService();
  final TtsService _tts = TtsService();
  final NotificationService _notif = NotificationService();

  Timer? _pollTimer;
  Map<String, Stock> _stocks = {};
  List<AlertItem> _recentAlerts = [];
  bool _isPolling = false;

  // 5分钟价格快照 {code: price}
  final Map<String, double> _fiveMinSnapshot = {};
  DateTime? _last5MinReset;

  // 去重记录 {code: last_trigger_time}
  final Map<String, DateTime> _alertLastTime = {};
  final Set<String> _limitUpFired = {}; // 今日已触发涨停
  final Set<String> _limitDownFired = {};
  final Set<String> _limitBrokenFired = {}; // 今日已触发炸板
  final Set<String> _sectorFired = {}; // 今日已触发板块

  // 自选股代码列表
  List<String> _watchList = [];

  // 阈值配置
  int riseThreshold = 3;
  int fallThreshold = 3;
  int indexThreshold = 1;
  int sectorThreshold = 2;
  int volumeMultiple = 3;
  int auctionThreshold = 5;

  // 各播报类型开关
  final Map<AlertType, bool> _alertEnabled = {
    AlertType.selfQuote: true,
    AlertType.rapidRise: true,
    AlertType.rapidFall: true,
    AlertType.limitUp: true,
    AlertType.limitDown: true,
    AlertType.limitBroken: true,
    AlertType.sectorMove: true,
    AlertType.indexMove: true,
    AlertType.volumeAbnormal: true,
    AlertType.auctionMove: true,
  };

  Map<String, Stock> get stocks => _stocks;
  List<Stock> get stockList => _stocks.values.toList();
  List<AlertItem> get recentAlerts => _recentAlerts;
  bool get isPolling => _isPolling;

  bool isAlertEnabled(AlertType t) => _alertEnabled[t] ?? true;

  Future<void> init() async {
    await _tts.init();
    await _notif.init();
    notifyListeners();
  }

  /// 设置自选股列表并开始轮询
  void startWatch(List<String> codes) {
    _watchList = codes;
    _fiveMinReset();
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
    _isPolling = true;
    notifyListeners();
  }

  void stopWatch() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _isPolling = false;
    notifyListeners();
  }

  void addStock(String code, String name) {
    if (!_watchList.contains(code)) {
      _watchList.add(code);
      _stocks[code] = Stock(code: code, name: name);
    }
    notifyListeners();
  }

  void removeStock(String code) {
    _watchList.remove(code);
    _stocks.remove(code);
    notifyListeners();
  }

  void setAlertEnabled(AlertType t, bool v) {
    _alertEnabled[t] = v;
    notifyListeners();
  }

  void updateThreshold({
    int? rise,
    int? fall,
    int? idx,
    int? sector,
    int? vol,
    int? auction,
  }) {
    if (rise != null) riseThreshold = rise;
    if (fall != null) fallThreshold = fall;
    if (idx != null) indexThreshold = idx;
    if (sector != null) sectorThreshold = sector;
    if (volumeMultiple != null) volumeMultiple = vol ?? volumeMultiple;
    if (auction != null) auctionThreshold = auction;
    notifyListeners();
  }

  /// 每秒轮询
  Future<void> _poll() async {
    if (_watchList.isEmpty) return;
    try {
      final raw = await _api.fetchQuotes(_watchList);
      if (raw.isEmpty) return;

      // 检查集合竞价时间
      final now = DateTime.now();
      final cstHour = int.parse(now.toUtc().add(const Duration(hours: 8)).toString().substring(11, 13));
      final cstMin = int.parse(now.toUtc().add(const Duration(hours: 8)).toString().substring(14, 16));
      final totalMin = cstHour * 60 + cstMin;
      final isAuctionTime = (totalMin >= 9 * 60 + 15 && totalMin < 9 * 60 + 25);

      // 检查是否需要重置5分钟快照（每分钟）
      _check5MinReset();

      for (final entry in raw.entries) {
        final code = entry.key;
        final r = entry.value;
        final prevStock = _stocks[code];

        // 构建 Stock 对象
        _stocks[code] = Stock(
          code: code,
          name: r.name,
          price: r.price,
          prevClose: r.prevClose,
          change: r.change,
          changePct: r.changePct,
          lastUpdate: DateTime.now(),
        );

        // === 警报检测（本地计算，直接来自API） ===
        // A4: 涨停预警
        if (_alertEnabled[AlertType.limitUp]! && r.isLimitUp) {
          if (!_limitUpFired.contains(code)) {
            _limitUpFired.add(code);
            _fire(AlertType.limitUp, '${r.name}，涨停！报${r.price}元，涨停！', code);
          }
        }
        // A5: 跌停预警
        if (_alertEnabled[AlertType.limitDown]! && r.isLimitDown) {
          if (!_limitDownFired.contains(code)) {
            _limitDownFired.add(code);
            _fire(AlertType.limitDown, '${r.name}，跌停！报${r.price}元，已跌停！', code);
          }
        }
        // A6: 炸板预警（昨日涨停股今日开板）
        if (_alertEnabled[AlertType.limitBroken]! && prevStock != null) {
          // 若之前已涨停但现在跌回
          final wasLimitUp = prevStock.isLimitUp;
          if (wasLimitUp && !r.isLimitUp && r.price < r.limitUpPrice * 0.998) {
            if (!_limitBrokenFired.contains(code)) {
              _limitBrokenFired.add(code);
              _fire(AlertType.limitBroken, '${r.name}，炸板！打开涨停，当前报${r.price}元', code);
            }
          }
        }
        // A2: 快速拉升（5分钟涨幅）
        if (_alertEnabled[AlertType.rapidRise]!) {
          final fiveMinAgo = _fiveMinSnapshot[code];
          if (fiveMinAgo != null && fiveMinAgo > 0) {
            final fiveMinChg = ((r.price - fiveMinAgo) / fiveMinAgo) * 100;
            if (fiveMinChg >= riseThreshold) {
              final last = _alertLastTime['${code}_rise'] ?? DateTime(2000);
              if (DateTime.now().difference(last).inMinutes >= 5) {
                _alertLastTime['${code}_rise'] = DateTime.now();
                _fire(AlertType.rapidRise, '⚠️ 拉升！${r.name}，5分钟涨了${fiveMinChg.abs().toStringAsFixed(2)}%，当前报${r.price}元', code);
              }
            }
          }
        }
        // A3: 快速下跌
        if (_alertEnabled[AlertType.rapidFall]!) {
          final fiveMinAgo = _fiveMinSnapshot[code];
          if (fiveMinAgo != null && fiveMinAgo > 0) {
            final fiveMinChg = ((r.price - fiveMinAgo) / fiveMinAgo) * 100;
            if (fiveMinChg <= -fallThreshold) {
              final last = _alertLastTime['${code}_fall'] ?? DateTime(2000);
              if (DateTime.now().difference(last).inMinutes >= 5) {
                _alertLastTime['${code}_fall'] = DateTime.now();
                _fire(AlertType.rapidFall, '⚠️ 下跌！${r.name}，5分钟跌了${fiveMinChg.abs().toStringAsFixed(2)}%，当前报${r.price}元', code);
              }
            }
          }
        }
        // A10: 集合竞价异动
        if (_alertEnabled[AlertType.auctionMove!] && isAuctionTime) {
          if (r.changePct.abs() >= auctionThreshold) {
            final last = _alertLastTime['${code}_auction'] ?? DateTime(2000);
            if (DateTime.now().difference(last).inMinutes >= 10) {
              _alertLastTime['${code}_auction'] = DateTime.now();
              final dir = r.changePct > 0 ? '高开' : '低开';
              _fire(AlertType.auctionMove, '竞价预警：${r.name}$dir${r.changePct.abs().toStringAsFixed(2)}%', code);
            }
          }
        }
      }

      notifyListeners();
    } catch (e) {
      debugPrint('poll error: $e');
    }
  }

  /// 重置5分钟快照（每分钟）
  void _check5MinReset() {
    final now = DateTime.now();
    if (_last5MinReset == null || now.difference(_last5MinReset!).inMinutes >= 1) {
      _fiveMinReset();
    }
  }

  void _fiveMinReset() {
    for (final s in _stocks.values) {
      if (s.price > 0) _fiveMinSnapshot[s.code] = s.price;
    }
    _last5MinReset = DateTime.now();
  }

  /// 触发播报
  Future<void> _fire(AlertType type, String text, String code) async {
    final item = AlertItem(type: type, text: text, stockCode: code);
    _recentAlerts.insert(0, item);
    if (_recentAlerts.length > 50) _recentAlerts.removeLast();
    notifyListeners();
    await _tts.speak(text);
    await _notif.show(title: '听股通预警', body: text, payload: code);
  }

  /// 手动播报所有自选股
  Future<void> reportAllStocks() async {
    for (final s in _stocks.values) {
      final dir = s.changePct >= 0 ? '涨' : '跌';
      final text = '${s.name}，报${s.price}元，$dir${s.changePct.abs().toStringAsFixed(2)}%';
      await _tts.speak(text);
      await Future.delayed(const Duration(milliseconds: 800));
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tts.dispose();
    super.dispose();
  }
}

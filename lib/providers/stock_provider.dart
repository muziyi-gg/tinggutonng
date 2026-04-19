import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
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

  // 暂停播报标志（防止播报重叠）
  bool _speaking = false;
  // 停止请求标志（用户主动停止）
  bool _stopRequested = false;

  // 当前错误（UI 层负责展示和清除）
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
        _stocks[code] = Stock(code: code, name: name);
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

  /// 每秒轮询：获取最新价格（新浪 HTTPS API，返回 GBK 编码）
  Future<void> _pollPricesLive() async {
    if (_stocks.isEmpty) return;
    try {
      final codes = _stocks.keys.toList();
      // 新浪 HTTPS API（sh/sz 前缀与代码格式一致）
      final uri = Uri.parse('https://hq.sinajs.cn/list=${codes.join(",")}');
      final resp = await http.get(
        uri,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
          'Referer': 'https://finance.sina.com.cn/',
        },
      ).timeout(const Duration(seconds: 3));

      if (resp.statusCode != 200) {
        debugPrint('Sina HTTP ${resp.statusCode}');
        return;
      }
      // 新浪接口返回 GBK/GB18030 编码
      // 注意：dart http 默认按 Content-Type charset 解码，
      // 但对 GBK 支持不完整，直接用 bodyBytes + latin1.decode 更可靠
      final raw = _decodeGbk(resp.bodyBytes);
      debugPrint('Sina raw(${raw.length}): ${raw.substring(0, raw.length > 120 ? 120 : raw.length)}');
      _parseSinaResponse(raw);
    } catch (e) {
      debugPrint('Sina poll error: $e');
    }
  }

  /// 解析新浪 hq_str_{code}="name,price,prevClose,open,vol,... 日期,时间" 格式
  void _parseSinaResponse(String raw) {
    // 匹配 var hq_str_sz300059="东方财富,19.95,20.03,19.90,... 日期,时间,...";
    final re = RegExp(r'hq_str_(\w+)="([^"]+)"');
    bool changed = false;
    int matched = 0;
    for (final m in re.allMatches(raw)) {
      final code = m[1]!;
      final f = m[2]!.split(',');
      if (f.length < 32) {
        debugPrint('Sina skip $code: fields=${f.length}');
        continue;
      }
      final price = double.tryParse(f[1]) ?? 0;
      final prevClose = double.tryParse(f[2]) ?? 0;
      final change = prevClose > 0 ? price - prevClose : 0.0;
      final changePct = prevClose > 0 ? (change / prevClose) * 100 : 0.0;

      // 解析服务器时间：f[30]=日期(YYYY-MM-DD), f[31]=时间(HH:MM:SS)
      DateTime? serverTime;
      if (f[30].isNotEmpty && f[31].isNotEmpty) {
        try {
          final dateStr = '${f[30]} ${f[31]}';
          serverTime = DateTime.parse(dateStr.replaceFirst(' ', 'T'));
        } catch (_) {
          serverTime = DateTime.now();
        }
      }

      if (_stocks.containsKey(code)) {
        _stocks[code] = Stock(
          code: code,
          name: _stocks[code]!.name,
          price: price,
          prevClose: prevClose,
          change: change,
          changePct: changePct,
          lastUpdate: serverTime ?? DateTime.now(),
        );
        changed = true;
        matched++;
      }
    }
    debugPrint('Sina matched=$matched/${_stocks.length}');
    if (changed) notifyListeners();
  }

  /// GBK/GB18030 解码（Dart 内置 latin1 覆盖 ASCII + Latin-1，足够解码中文常用区）
  String _decodeGbk(List<int> bytes) {
    try {
      return latin1.decode(bytes);
    } catch (_) {
      // latin1 之外的字节替换为 ?（不影响数字解析）
      final safe = bytes.map((b) => b < 256 ? b : 63).toList();
      return latin1.decode(safe);
    }
  }

  /// 定时播报：按间隔播报所有股票
  Future<void> _reportAll() async {
    if (_stocks.isEmpty) return;
    _speaking = true;
    _stopRequested = false;
    try {
      bool anySkipped = false;
      for (final s in _stocks.values) {
        // 检查用户是否请求停止
        if (_stopRequested) {
          debugPrint('TTS stop requested, aborting');
          break;
        }
        if (s.price <= 0) {
          debugPrint('TTS skip ${s.name}: price=${s.price} (数据未就绪)');
          anySkipped = true;
          continue;
        }
        final dir = s.changePct >= 0 ? '涨' : '跌';
        final text = '${s.name}，报${s.price.toStringAsFixed(2)}元，$dir${s.changePct.abs().toStringAsFixed(2)}%';
        await _speakAndNotify(text, AlertType.selfQuote);
        // 播报间隔（等待上一句播完 + 短暂停顿）
        await Future.delayed(const Duration(milliseconds: 800));
        // 停止请求检查（延迟后再次检查）
        if (_stopRequested) break;
      }
      // 所有股票价格都是0，说明行情未拉到
      if (anySkipped && _stocks.values.every((s) => s.price <= 0)) {
        _lastError = ReportError('行情数据未就绪，请检查网络后重试');
        notifyListeners();
      }
    } catch (e) {
      debugPrint('TTS _reportAll error: $e');
    } finally {
      _speaking = false;
      _stopRequested = false;
      notifyListeners(); // 确保 UI 始终收到状态更新
    }
  }

  /// 停止当前播报（用户点击停止按钮）
  Future<void> stopSpeaking() async {
    _stopRequested = true;
    await _tts.stop();
    _speaking = false;
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

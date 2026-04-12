import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/stock.dart';
import '../models/alert_type.dart';

/// 连接 OpenClaw 后台 Daemon（Node.js）
/// Daemon 地址: /workspace/stock_monitor/daemon.js（服务器本地）
/// 通讯方式: 共享 state.json 文件轮询（服务器本地，无网络延迟）
class DaemonService {
  static const String _stateFile = '/workspace/stock_monitor/state.json';
  static const String _triggerFile = '/workspace/stock_monitor/trigger.json';

  Timer? _pollTimer;
  final _stockController = StreamController<Map<String,Stock>>.broadcast();
  final _alertController = StreamController<AlertItem>.broadcast();

  Map<String,Stock> _lastState = {};

  Stream<Map<String,Stock>> get stockStream => _stockController.stream;
  Stream<AlertItem> get alertStream => _alertController.stream;

  bool get isConnected => _pollTimer != null;

  void start({int intervalMs = 1500}) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) => _poll());
    _poll(); // 立即执行一次
  }

  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _poll() async {
    try {
      // 读取 state.json（服务器本地，延迟<10ms）
      final stateFile = File(_stateFile);
      if (!await stateFile.exists()) return;
      final raw = await stateFile.readAsString();
      final Map<String,dynamic> json = jsonDecode(raw);

      final Map<String,Stock> now = {};
      json.forEach((code, v) {
        final m = Map<String,dynamic>.from(v);
        final s = Stock(
          code: code,
          name: m['name']??code,
          price: (m['price']??0).toDouble(),
          prevClose: (m['prevClose']??0).toDouble(),
          change: (m['change']??0).toDouble(),
          changePct: (m['changePct']??0).toDouble(),
          lastUpdate: DateTime.tryParse(m['time']??'') ?? DateTime.now(),
        );
        now[code] = s;
      });

      _stockController.add(now);
      _lastState = now;

      // 检查 trigger.json（警报触发）
      final triggerFile = File(_triggerFile);
      if (await triggerFile.exists()) {
        final tRaw = await triggerFile.readAsString();
        final t = jsonDecode(tRaw);
        final alert = AlertItem(
          type: _detectAlertType(t),
          text: t['text']??'',
          stockCode: t['code'],
        );
        _alertController.add(alert);
        await triggerFile.delete(); // 消费后删除
      }
    } catch(e) {
      debugPrint('DaemonService poll error: $e');
    }
  }

  AlertType _detectAlertType(Map<String,dynamic> t) {
    final text = (t['text']??'') as String;
    if (text.contains('涨停')) return AlertType.limitUp;
    if (text.contains('跌停')) return AlertType.limitDown;
    if (text.contains('炸板')) return AlertType.limitBroken;
    if (text.contains('拉升')||text.contains('上涨')) return AlertType.rapidRise;
    if (text.contains('下跌')) return AlertType.rapidFall;
    if (text.contains('板块')) return AlertType.sectorMove;
    if (text.contains('大盘')||text.contains('指数')) return AlertType.indexMove;
    if (text.contains('竞价')) return AlertType.auctionMove;
    if (text.contains('成交')) return AlertType.volumeAbnormal;
    return AlertType.selfQuote;
  }

  void dispose() {
    stop();
    _stockController.close();
    _alertController.close();
  }
}

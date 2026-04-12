import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/stock.dart';
import '../models/alert_type.dart';

/// 腾讯行情 API 服务
/// 直接调用 qt.gtimg.cn，全量字段解析，不做本地运算
class StockApiService {
  static const String _baseUrl = 'https://qt.gtimg.cn';

  /// 批量获取股票行情（最多50只）
  Future<Map<String, StockRaw>> fetchQuotes(List<String> codes) async {
    if (codes.isEmpty) return {};
    final uri = Uri.parse('$_baseUrl/q=${codes.join(",")}');
    final resp = await http.get(
      uri,
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
        'Referer': 'https://gu.qq.com/',
      },
    ).timeout(const Duration(seconds: 3));

    if (resp.statusCode != 200) return {};
    return _parseQtResponse(utf8.decode(resp.bodyBytes));
  }

  /// 解析腾讯行情 v_pakt 格式
  Map<String, StockRaw> _parseQtResponse(String raw) {
    final Map<String, StockRaw> result = {};
    final re = RegExp(r'v_(\w+)="([^"]+)"');
    for (final m in re.allMatches(raw)) {
      final code = m[1]!;
      final f = m[2]!.split('~');
      if (f.length < 40) continue;
      result[code] = StockRaw(
        code: code,
        name: f[1] ?? code,
        price: double.tryParse(f[3]) ?? 0,
        prevClose: double.tryParse(f[4]) ?? 0,
        open: double.tryParse(f[5]) ?? 0,
        volume: double.tryParse(f[6]) ?? 0,       // 成交量（手）
        bid1: double.tryParse(f[9]) ?? 0,          // 买一价
        ask1: double.tryParse(f[19]) ?? 0,         // 卖一价
        change: double.tryParse(f[31]) ?? 0,       // 涨跌额
        changePct: double.tryParse(f[32]) ?? 0,   // 涨跌幅%
        high: double.tryParse(f[33]) ?? 0,        // 最高
        low: double.tryParse(f[34]) ?? 0,         // 最低
        // f[36] = 今开, f[38] = 昨量
        timestamp: f[30].isNotEmpty ? f[30] : DateTime.now().toIso8601String(),
      );
    }
    return result;
  }
}

/// 原始行情数据（直接来自API，未计算）
class StockRaw {
  final String code;
  final String name;
  final double price;
  final double prevClose;
  final double open;
  final double volume;
  final double bid1;
  final double ask1;
  final double change;
  final double changePct;
  final double high;
  final double low;
  final String timestamp;

  StockRaw({
    required this.code,
    required this.name,
    required this.price,
    required this.prevClose,
    required this.open,
    required this.volume,
    required this.bid1,
    required this.ask1,
    required this.change,
    required this.changePct,
    required this.high,
    required this.low,
    required this.timestamp,
  });

  /// 涨停价（主板±10%，科创/创业±20%）
  double get limitUpPrice {
    bool isKCB = code.startsWith('sh688') || code.startsWith('sz301');
    bool isChiNext = code.startsWith('sz300');
    double pct = (isKCB || isChiNext) ? 0.20 : 0.10;
    return _toPrice(prevClose * (1 + pct));
  }

  /// 跌停价
  double get limitDownPrice {
    bool isKCB = code.startsWith('sh688') || code.startsWith('sz301');
    bool isChiNext = code.startsWith('sz300');
    double pct = (isKCB || isChiNext) ? 0.20 : 0.10;
    return _toPrice(prevClose * (1 - pct));
  }

  bool get isLimitUp => price >= limitUpPrice && price > 0 && prevClose > 0;
  bool get isLimitDown => price <= limitDownPrice && price > 0 && prevClose > 0;

  String get changePctDisplay =>
      '${changePct >= 0 ? '+' : ''}${changePct.toStringAsFixed(2)}%';

  double _toPrice(double v) => (v * 100).round() / 100;

  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    'price': price,
    'prevClose': prevClose,
    'open': open,
    'volume': volume,
    'change': change,
    'changePct': changePct,
    'high': high,
    'low': low,
    'limitUpPrice': limitUpPrice,
    'limitDownPrice': limitDownPrice,
    'isLimitUp': isLimitUp,
    'isLimitDown': isLimitDown,
    'timestamp': timestamp,
  };
}

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/stock.dart';
import '../models/alert_type.dart';

/// 新浪行情 API 服务（HTTPS）
/// 直接调用 hq.sinajs.cn，返回 GBK/GB18030 编码
class StockApiService {
  static const String _baseUrl = 'https://hq.sinajs.cn';

  /// 批量获取股票行情（最多50只）
  Future<Map<String, StockRaw>> fetchQuotes(List<String> codes) async {
    if (codes.isEmpty) return {};
    final uri = Uri.parse('$_baseUrl/list=${codes.join(",")}');
    final resp = await http.get(
      uri,
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
        'Referer': 'https://finance.sina.com.cn/',
      },
    ).timeout(const Duration(seconds: 3));

    if (resp.statusCode != 200) return {};
    // 新浪返回 GBK/GB18030 编码
    return _parseSinaResponse(_decodeGbk(resp.bodyBytes));
  }

  /// 解析新浪 hq_str_{code}="name,price,prevClose,open,vol,... 日期,时间" 格式
  Map<String, StockRaw> _parseSinaResponse(String raw) {
    final Map<String, StockRaw> result = {};
    final re = RegExp(r'hq_str_(\w+)="([^"]+)"');
    for (final m in re.allMatches(raw)) {
      final code = m[1]!;
      final f = m[2]!.split(',');
      if (f.length < 32) continue;
      final price = double.tryParse(f[1]) ?? 0;
      final prevClose = double.tryParse(f[2]) ?? 0;
      final change = prevClose > 0 ? price - prevClose : 0.0;
      final changePct = prevClose > 0 ? (change / prevClose) * 100 : 0.0;
      final open = double.tryParse(f[3]) ?? 0;
      final vol = double.tryParse(f[4]) ?? 0;
      final high = double.tryParse(f[5]) ?? 0;
      final low = double.tryParse(f[6]) ?? 0;
      // f[30] = 日期(YYYY-MM-DD), f[31] = 时间(HH:MM:SS)
      final ts = (f[30].isNotEmpty && f[31].isNotEmpty)
          ? '${f[30]}T${f[31]}'
          : DateTime.now().toIso8601String();
      result[code] = StockRaw(
        code: code,
        name: f[0] ?? code,
        price: price,
        prevClose: prevClose,
        open: open,
        volume: vol,
        bid1: 0,
        ask1: 0,
        change: change,
        changePct: changePct,
        high: high,
        low: low,
        timestamp: ts,
      );
    }
    return result;
  }

  /// GBK/GB18030 解码
  String _decodeGbk(List<int> bytes) {
    try {
      return latin1.decode(bytes);
    } catch (_) {
      final safe = bytes.map((b) => b < 256 ? b : 63).toList();
      return latin1.decode(safe);
    }
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

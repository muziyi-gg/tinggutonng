import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/stock.dart';

/// 腾讯行情 API 服务（UTF-8 编码，数据实时准确）
/// 调用 qt.gtimg.cn，返回 GBK 编码，字段含义：
///   [0]  未知标识
///   [1]  股票名称（去空格）
///   [2]  股票代码
///   [3]  当前价格（实时成交价）
///   [4]  昨收价
///   [5]  今日开盘价
///   [6]  成交量（手）
///   [30] 日期时间戳 YYYYMMDDHHMMSS
///   [31] 涨跌额（带符号，正负）
///   [32] 涨跌幅%（带符号，正负，直接可用）
///   [33] 最高价
///   [34] 最低价
class StockApiService {
  /// 批量获取股票行情（最多50只）
  Future<Map<String, StockRaw>> fetchQuotes(List<String> codes) async {
    if (codes.isEmpty) return {};
    final uri = Uri.parse('https://qt.gtimg.cn/q=${codes.join(",")}');
    final resp = await http.get(
      uri,
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
        'Referer': 'https://finance.qq.com/',
      },
    ).timeout(const Duration(seconds: 4));

    if (resp.statusCode != 200) return {};
    return _parseTencentResponse(_decodeGbk(resp.bodyBytes));
  }

  Map<String, StockRaw> _parseTencentResponse(String raw) {
    final Map<String, StockRaw> result = {};
    final re = RegExp(r'v_(\w+)="([^"]+)"');
    for (final m in re.allMatches(raw)) {
      final code = m[1]!;
      final f = m[2]!.split('~');
      if (f.length < 35) continue;

      final name   = f[1].trim();
      final price  = double.tryParse(f[3]) ?? 0.0;
      final prev   = double.tryParse(f[4]) ?? 0.0;
      final open   = double.tryParse(f[5]) ?? 0.0;
      final vol    = double.tryParse(f[6]) ?? 0.0;
      final high   = double.tryParse(f[41]) ?? 0.0; // 最高（真实 f[41]）
      final low    = double.tryParse(f[34]) ?? 0.0;  // 最低
      // 涨跌额和涨跌幅直接来自 API，无需自行计算
      final change    = double.tryParse(f[31]) ?? 0.0; // 涨跌额
      final changePct = double.tryParse(f[32]) ?? 0.0; // 涨跌幅%
      final ts       = f[30].isNotEmpty ? f[30] : '';

      result[code] = StockRaw(
        code: code,
        name: name,
        price: price,
        prevClose: prev,
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

/// 原始行情数据
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

  double get limitUpPrice {
    bool isKCB = code.startsWith('sh688') || code.startsWith('sz301');
    bool isChiNext = code.startsWith('sz300');
    double pct = (isKCB || isChiNext) ? 0.20 : 0.10;
    return _toPrice(prevClose * (1 + pct));
  }

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

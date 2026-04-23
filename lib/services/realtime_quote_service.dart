import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 东方财富 WebSocket 实时行情服务
/// 连接 push2his.eastmoney.com:443，实现 <1秒延迟的行情推送
/// 
/// 协议说明：
/// - 连接：wss://push2his.eastmoney.com/
/// - 订阅格式（JSON）：{"action":"subscribe","params":["s_sh600519","s_sz000001"]}
/// - 取消订阅格式：{"action":"unsubscribe","params":["s_sh600519"]}
/// - 数据推送格式：JSON 数组，每条是 [股票代码, 现价, 涨跌额, 涨跌幅%, ...]
/// - 心跳：服务端定期 ping，客户端需在 30s 内响应 pong
class RealtimeQuoteService {
  static const String _wsHost = 'wss://push2his.eastmoney.com/';
  
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  
  /// 是否已连接
  bool _isConnected = false;
  bool get isConnected => _isConnected;
  
  /// 当前订阅的股票代码列表
  final Set<String> _subscribed = {};
  
  /// 行情数据流（每次推送股票代码 → 最新行情）
  final StreamController<Map<String, StockQuote>> _quoteController =
      StreamController<Map<String, StockQuote>>.broadcast();
  
  /// 外部访问行情数据的唯一出口
  Stream<Map<String, StockQuote>> get quoteStream => _quoteController.stream;
  
  /// 连接状态变更通知
  final StreamController<bool> _statusController =
      StreamController<bool>.broadcast();
  Stream<bool> get statusStream => _statusController.stream;
  
  /// 最后一次推送的数据（用于查询当前价格）
  final Map<String, StockQuote> _latestQuotes = {};

  /// 诊断日志回调
  void Function(String)? onLog;

  void _log(String msg) {
    debugPrint('[RTQ] $msg');
    onLog?.call(msg);
  }

  /// 连接 WebSocket 并订阅股票列表
  Future<void> connect(List<String> codes) async {
    if (_isConnected) {
      await disconnect();
    }

    _log('Connecting to $_wsHost with ${codes.length} stocks...');
    
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_wsHost));
      
      await _channel!.ready;
      _isConnected = true;
      _statusController.add(true);
      _log('WebSocket connected');
      
      // 订阅股票
      if (codes.isNotEmpty) {
        await _subscribe(codes);
      }
      
      // 监听消息
      _sub = _channel!.stream.listen(
        _onMessage,
        onError: (e) {
          _log('WebSocket error: $e');
          _isConnected = false;
          _statusController.add(false);
          _scheduleReconnect(codes);
        },
        onDone: () {
          _log('WebSocket connection closed');
          _isConnected = false;
          _statusController.add(false);
          _scheduleReconnect(codes);
        },
      );
    } catch (e) {
      _log('Failed to connect: $e');
      _isConnected = false;
      _statusController.add(false);
    }
  }

  /// 订阅一批股票
  Future<void> _subscribe(List<String> codes) async {
    if (_channel == null || !_isConnected) return;
    
    // 东方财富格式：添加 "s_" 前缀
    final subs = codes.map((c) => 's_$c').toList();
    
    final msg = jsonEncode({
      'action': 'subscribe',
      'params': subs,
    });
    
    _channel!.sink.add(msg);
    _subscribed.addAll(codes);
    _log('Subscribed to ${codes.length} stocks: ${subs.take(5).join(", ")}${subs.length > 5 ? '...' : ''}');
  }

  /// 处理收到的消息
  void _onMessage(dynamic msg) {
    try {
      final data = jsonDecode(msg as String);
      
      // 处理心跳响应
      if (data is Map && data['type'] == 'ping') {
        _channel?.sink.add(jsonEncode({'type': 'pong'}));
        return;
      }
      
      // 处理行情推送（数组格式）
      if (data is List && data.isNotEmpty) {
        _processQuoteData(data);
      }
    } catch (e) {
      // 非 JSON 消息（如纯文本心跳），忽略
    }
  }

  /// 解析行情推送数据
  void _processQuoteData(List<dynamic> data) {
    final Map<String, StockQuote> updates = {};
    
    for (final item in data) {
      if (item is! List || item.length < 5) continue;
      
      final code = (item[0] as String?)?.toString();
      if (code == null) continue;
      
      // 去除东方财富的前缀
      final cleanCode = code.replaceFirst(RegExp(r'^(s_|sz_|sh_)'), '');
      
      try {
        final price  = double.tryParse('${item[1]}') ?? 0.0;
        final change = double.tryParse('${item[2]}') ?? 0.0;
        final pct    = double.tryParse('${item[3]}') ?? 0.0;
        final high   = double.tryParse('${item[4]}') ?? 0.0;
        final low    = double.tryParse('${item[5]}') ?? 0.0;
        final vol    = double.tryParse('${item[6]}') ?? 0.0;
        final ts     = (item[7] as String?) ?? '';
        
        final quote = StockQuote(
          code: cleanCode,
          price: price,
          change: change,
          changePct: pct,
          high: high,
          low: low,
          volume: vol,
          timestamp: ts,
        );
        
        _latestQuotes[cleanCode] = quote;
        updates[cleanCode] = quote;
      } catch (e) {
        _log('Parse quote error: $e, data=$item');
      }
    }
    
    if (updates.isNotEmpty) {
      _quoteController.add(Map.from(_latestQuotes));
    }
  }

  /// 获取某个股票的当前价格（如果已订阅）
  StockQuote? getQuote(String code) => _latestQuotes[code];

  /// 获取所有当前行情
  Map<String, StockQuote> getAllQuotes() => Map.from(_latestQuotes);

  /// 更新订阅列表（增删股票时调用）
  Future<void> updateSubscriptions(List<String> codes) async {
    if (!_isConnected) return;
    
    // 找出新增和已删除的
    final newCodes = codes.toSet();
    final added   = newCodes.difference(_subscribed);
    final removed = _subscribed.difference(newCodes);
    
    if (added.isNotEmpty) {
      await _subscribe(added.toList());
    }
    
    if (removed.isNotEmpty) {
      await _unsubscribe(removed.toList());
    }
  }

  Future<void> _unsubscribe(List<String> codes) async {
    if (_channel == null || !_isConnected) return;
    
    final subs = codes.map((c) => 's_$c').toList();
    final msg = jsonEncode({
      'action': 'unsubscribe',
      'params': subs,
    });
    
    _channel!.sink.add(msg);
    _subscribed.removeAll(codes);
    _log('Unsubscribed from ${codes.length} stocks');
  }

  Timer? _reconnectTimer;
  
  void _scheduleReconnect(List<String> codes) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!_isConnected) {
        connect(codes);
      }
    });
  }

  /// 主动断开连接
  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _isConnected = false;
    _statusController.add(false);
    _log('Disconnected');
  }

  void dispose() {
    disconnect();
    _quoteController.close();
    _statusController.close();
  }
}

/// 单只股票实时行情
class StockQuote {
  final String code;
  final double price;
  final double change;
  final double changePct;
  final double high;
  final double low;
  final double volume;
  final String timestamp;

  StockQuote({
    required this.code,
    required this.price,
    required this.change,
    required this.changePct,
    required this.high,
    required this.low,
    required this.volume,
    required this.timestamp,
  });

  String get changePctDisplay =>
      '${changePct >= 0 ? '+' : ''}${changePct.toStringAsFixed(2)}%';

  bool get isUp => changePct >= 0;

  Map<String, dynamic> toJson() => {
    'code': code,
    'price': price,
    'change': change,
    'changePct': changePct,
    'high': high,
    'low': low,
    'volume': volume,
    'timestamp': timestamp,
  };
}
/// 股票行情数据模型（纯内存版，无需持久化）
class Stock {
  final String code; // 腾讯格式: sh600519
  final String name;
  double price; // 当前价
  double prevClose; // 昨收
  double change; // 涨跌额
  double changePct; // 涨跌幅%
  DateTime lastUpdate;
  int reportIntervalSec; // 播报间隔(秒): 30/60/300
  bool enabled; // 是否启用播报

  Stock({
    required this.code,
    required this.name,
    this.price = 0,
    this.prevClose = 0,
    this.change = 0,
    this.changePct = 0,
    DateTime? lastUpdate,
    this.reportIntervalSec = 60,
    this.enabled = true,
  }) : lastUpdate = lastUpdate ?? DateTime.now();

  /// 涨停价（主板±10%，科创/创业±20%）
  double get limitUpPrice {
    bool isKCB = code.startsWith('sh688') || code.startsWith('sz301');
    bool isChiNext = code.startsWith('sz300');
    double pct = (isKCB || isChiNext) ? 0.20 : 0.10;
    return prevClose * (1 + pct);
  }

  /// 跌停价
  double get limitDownPrice {
    bool isKCB = code.startsWith('sh688') || code.startsWith('sz301');
    bool isChiNext = code.startsWith('sz300');
    double pct = (isKCB || isChiNext) ? 0.20 : 0.10;
    return prevClose * (1 - pct);
  }

  /// 5分钟前价格快照
  double? fiveMinAgoPrice;
  DateTime? fiveMinAgoTime;

  /// 更新5分钟前的快照
  void updateFiveMinSnapshot() {
    fiveMinAgoPrice = price;
    fiveMinAgoTime = DateTime.now();
  }

  /// 5分钟涨跌幅
  double get fiveMinChangePct {
    if (fiveMinAgoPrice == null || fiveMinAgoPrice == 0) return 0;
    return ((price - fiveMinAgoPrice!) / fiveMinAgoPrice!) * 100;
  }

  /// 是否涨停
  bool get isLimitUp => price >= limitUpPrice && price > 0;

  /// 是否跌停
  bool get isLimitDown => price <= limitDownPrice && price > 0;

  /// 格式化涨跌幅显示
  String get changePctDisplay =>
      '${changePct >= 0 ? '+' : ''}${changePct.toStringAsFixed(2)}%';

  String get changeDisplay =>
      '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}';

  Stock copyWith({
    String? code,
    String? name,
    double? price,
    double? prevClose,
    double? change,
    double? changePct,
    DateTime? lastUpdate,
    int? reportIntervalSec,
    bool? enabled,
  }) {
    return Stock(
      code: code ?? this.code,
      name: name ?? this.name,
      price: price ?? this.price,
      prevClose: prevClose ?? this.prevClose,
      change: change ?? this.change,
      changePct: changePct ?? this.changePct,
      lastUpdate: lastUpdate ?? this.lastUpdate,
      reportIntervalSec: reportIntervalSec ?? this.reportIntervalSec,
      enabled: enabled ?? this.enabled,
    );
  }
}

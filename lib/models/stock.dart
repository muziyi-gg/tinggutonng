import 'package:hive/hive.dart';

part 'stock.g.dart';

/// 股票行情数据模型
@HiveType(typeId: 0)
class Stock extends HiveObject {
  @HiveField(0)
  final String code; // 腾讯格式: sh600519

  @HiveField(1)
  final String name;

  @HiveField(2)
  double price; // 当前价

  @HiveField(3)
  double prevClose; // 昨收

  @HiveField(4)
  double change; // 涨跌额

  @HiveField(5)
  double changePct; // 涨跌幅%

  @HiveField(6)
  DateTime lastUpdate;

  @HiveField(7)
  int reportIntervalSec; // 播报间隔(秒): 30/60/300

  @HiveField(8)
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

  /// 5分钟前价格快照（用于计算5分钟涨跌幅）
  double? fiveMinAgoPrice;
  DateTime? fiveMinAgoTime;

  /// 更新5分钟前的快照（每分钟调用一次）
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

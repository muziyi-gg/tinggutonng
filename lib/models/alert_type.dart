/// 播报类型
enum AlertType {
  selfQuote, rapidRise, rapidFall,
  limitUp, limitDown, limitBroken,
  sectorMove, indexMove, volumeAbnormal, auctionMove,
}

enum AlertPriority { p0, p1, p2, p3, p4 }

extension AlertTypeExt on AlertType {
  String get id {
    return ['A1','A2','A3','A4','A5','A6','A7','A8','A9','A10'][index];
  }
  String get name {
    return ['自选股行情','快速拉升预警','快速下跌预警','涨停预警','跌停预警',
            '炸板预警','板块异动','大盘异动','成交量异常','集合竞价异动'][index];
  }
  String get icon {
    return ['📊','🚀','🔻','🔴','⚠️','💥','📡','📈','📊','⏰'][index];
  }
  String get desc {
    return ['定时播报自选股最新价格和涨跌幅','5分钟内涨幅超过阈值时提醒',
            '5分钟内跌幅超过阈值时提醒','个股首次触及涨停价时提醒',
            '个股首次触及跌停价时提醒','涨停股打开涨停板时提醒',
            '行业板块涨幅超阈值时提醒','大盘指数涨跌幅超阈值时提醒',
            '个股成交量异常放大时提醒','集合竞价阶段涨跌幅超阈值时提醒'][index];
  }
  AlertPriority get priority {
    return [AlertPriority.p4,AlertPriority.p1,AlertPriority.p1,
            AlertPriority.p0,AlertPriority.p0,AlertPriority.p0,
            AlertPriority.p2,AlertPriority.p3,AlertPriority.p4,AlertPriority.p2][index];
  }
  int get defaultThreshold {
    return [60,3,3,0,0,0,2,1,3,5][index]; // 秒或%
  }
}

class AlertItem {
  final AlertType type;
  final String text;
  final String? stockCode;
  final DateTime ts;
  bool isPlayed;
  AlertItem({required this.type, required this.text, this.stockCode, DateTime? ts, this.isPlayed=false})
      : ts = ts ?? DateTime.now();
  AlertPriority get priority => type.priority;
}

import 'package:hive/hive.dart';
import 'alert_type.dart';

part 'app_config.g.dart';

@HiveType(typeId: 1)
class AlertConfig extends HiveObject {
  @HiveField(0)
  bool enabled;
  @HiveField(1)
  int threshold; // 拉升/下跌/大盘阈值(%)，或成交量倍数
  @HiveField(2)
  int intervalSec; // 自选股播报间隔(秒)
  AlertConfig({this.enabled=true, this.threshold=3, this.intervalSec=60});
}

@HiveType(typeId: 2)
class AppConfig extends HiveObject {
  @HiveField(0)
  String? lastStockSearch;
  @HiveField(1)
  bool darkMode;
  @HiveField(2)
  String ttsVoice;
  AppConfig({this.darkMode=false, this.ttsVoice='system'});
}

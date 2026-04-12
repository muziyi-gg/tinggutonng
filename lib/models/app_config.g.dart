// GENERATED - DO NOT MODIFY
part of 'app_config.dart';

class AlertConfigAdapter extends HiveObjectAdapter<AlertConfig> {
  @override
  final int typeId = 1;
  @override
  AlertConfig read(rd.HiveObjectReader r, int _) {
    return AlertConfig(enabled:r.readBool(0), threshold:r.readInt(1), intervalSec:r.readInt(2));
  }
  @override
  void write(wt.HiveObjectWriter w, AlertConfig o) {
    w.writeBool(o.enabled, 0); w.writeInt(o.threshold, 1); w.writeInt(o.intervalSec, 2);
  }
}

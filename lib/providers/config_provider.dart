import 'package:flutter/foundation.dart';
import '../models/alert_type.dart';

/// 监控设置 Provider
class ConfigProvider extends ChangeNotifier {
  final Map<AlertType, bool> _enabled = {};
  final Map<AlertType, int> _thresholds = {};

  ConfigProvider() {
    for (final t in AlertType.values) {
      _enabled[t] = true; // 默认全部开启
      _thresholds[t] = t.defaultThreshold;
    }
  }

  bool isEnabled(AlertType t) => _enabled[t] ?? true;
  int threshold(AlertType t) => _thresholds[t] ?? t.defaultThreshold;

  void setEnabled(AlertType t, bool v) { _enabled[t] = v; notifyListeners(); }
  void setThreshold(AlertType t, int v) { _thresholds[t] = v; notifyListeners(); }

  List<AlertType> get enabledTypes => AlertType.values.where((t) => _enabled[t]!).toList();
}

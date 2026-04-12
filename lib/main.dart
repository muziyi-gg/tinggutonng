import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'models/stock.dart';
import 'models/app_config.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化 Hive
  await Hive.initFlutter();
  Hive.registerAdapter(StockAdapter());
  Hive.registerAdapter(AlertConfigAdapter());
  await Hive.openBox<Stock>('stocks');
  await Hive.openBox('config');

  // 竖屏锁定
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  runApp(const TingutongApp());
}

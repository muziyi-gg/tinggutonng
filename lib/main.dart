import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 竖屏锁定
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  runApp(const TingutongApp());
}

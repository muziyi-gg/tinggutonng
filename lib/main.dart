import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 竖屏锁定
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // Android 13+ 必须运行时请求通知权限，否则通知不生效
  if (await Permission.notification.isDenied) {
    await Permission.notification.request();
  }

  // 听股通 v1.4.10-dev
  runApp(const TingutongApp());
}

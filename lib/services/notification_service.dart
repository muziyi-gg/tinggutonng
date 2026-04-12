import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  final FlutterLocalNotificationsPlugin _f = FlutterLocalNotificationsPlugin();
  bool _initOk = false;

  Future<void> init() async {
    if (Platform.isAndroid) {
      await Permission.notification.request();
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const init = InitializationSettings(android: android);
      await _f.initialize(init, onDidReceiveNotificationResponse: _onTap);
      _initOk = true;
    }
  }

  void _onTap(NotificationResponse r) {
    debugPrint('Notification tapped: ${r.payload}');
  }

  Future<void> show({required String title, required String body, String? payload}) async {
    if (!_initOk) return;
    const androidDetail = AndroidNotificationDetails(
      'tingutong_alerts',
      '听股通预警',
      channelDescription: '听股通行情预警通知',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      category: AndroidNotificationCategory.alarm,
    );
    const detail = NotificationDetails(android: androidDetail);
    await _f.show(DateTime.now().millisecondsSinceEpoch % 100000,
        title, body, detail, payload: payload);
  }

  Future<void> cancelAll() async {
    await _f.cancelAll();
  }
}

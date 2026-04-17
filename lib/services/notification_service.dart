import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  final FlutterLocalNotificationsPlugin _f = FlutterLocalNotificationsPlugin();
  bool _initOk = false;

  Future<void> init() async {
    if (!Platform.isAndroid) return;

    // 不再这里请求权限，改为播报时按需请求
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: android);

    await _f.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onTap,
      onDidReceiveBackgroundNotificationResponse: _onBackgroundTap,
    );

    // Android 8+ 必须创建通知渠道
    const channel = AndroidNotificationChannel(
      'tingutong_alerts',
      '听股通行情播报',
      description: '听股通实时行情语音播报通知',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );

    await _f
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    _initOk = true;
  }

  void _onTap(NotificationResponse r) {
    debugPrint('Notification tapped: ${r.payload}');
  }

  static void _onBackgroundTap(NotificationResponse r) {
    debugPrint('Background notification: ${r.payload}');
  }

  Future<void> show({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_initOk) {
      // 初始化失败，先尝试再次初始化
      await init();
      if (!_initOk) return;
    }

    // 播报时检查并请求通知权限
    final status = await Permission.notification.status;
    if (status.isDenied) {
      await Permission.notification.request();
    }

    const androidDetail = AndroidNotificationDetails(
      'tingutong_alerts',
      '听股通行情播报',
      channelDescription: '听股通实时行情语音播报通知',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      category: AndroidNotificationCategory.alarm,
      styleInformation: BigTextStyleInformation(''),
    );

    const detail = NotificationDetails(android: androidDetail);

    await _f.show(
      DateTime.now().millisecondsSinceEpoch % 100000,
      title,
      body,
      detail,
      payload: payload,
    );
  }

  Future<void> cancelAll() async {
    await _f.cancelAll();
  }
}

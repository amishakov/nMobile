import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:nmobile/common/locator.dart';
import 'package:nmobile/helpers/error.dart';
import 'package:nmobile/utils/logger.dart';

Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print('FireBaseMessaging - _firebaseMessagingBackgroundHandler - messageId:${message.messageId} - from:${message.from}');
  await Firebase.initializeApp();
}

class FireBaseMessaging with Tag {
  static const String channel_id = "nmobile_d_chat";
  static const String channel_name = "D-Chat";
  static const String channel_desc = "D-Chat notification";

  late AndroidNotificationChannel channel;
  late FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin;

  String? _token;

  init() async {
    await Firebase.initializeApp();

    // background
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // android channel
    channel = AndroidNotificationChannel(
      channel_id,
      channel_name,
      channel_desc,
      importance: Importance.high,
      showBadge: true,
      playSound: true,
      enableLights: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 30, 100, 30]),
    );

    // local notification
    flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

    /// Create an Android Notification Channel.
    /// We use this channel in the `AndroidManifest.xml` file to override the default FCM channel to enable heads up notifications.
    await flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);

    /// Update the iOS foreground notification presentation options to allow heads up notifications.
    await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: false,
    );
  }

  startListen() {
    // token refresh
    FirebaseMessaging.instance.onTokenRefresh.listen((String event) {
      logger.i("$TAG - onTokenRefresh - old:$_token - new:$event");
      // TODO:GG firebase should notify all contact who notificationOpen?
      _token = event;
    });

    // background click
    FirebaseMessaging.instance.getInitialMessage().then((RemoteMessage? message) {
      if (message == null) return;
      logger.i("$TAG - getInitialMessage - messageId:${message.messageId} - from:${message.from}");
    });

    // foreground pop
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      logger.d("$TAG - onMessage - messageId:${message.messageId} - from:${message.from}");
      String? targetId = message.from; // TODO:GG no same with clientAddress? use senderId?
      RemoteNotification? notification = message.notification;
      if (notification == null) return;
      if (targetId != null && application.appLifecycleState == AppLifecycleState.resumed) {
        if (chatCommon.currentTalkId == targetId) return;
      }
      // AndroidNotification? android = message.notification?.android;
      // AppleNotification? apple = message.notification?.apple;
      flutterLocalNotificationsPlugin.show(
        notification.hashCode,
        notification.title,
        notification.body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            channel_id,
            channel_name,
            channel_desc,
            groupKey: targetId,
            importance: Importance.max,
            priority: Priority.high,
            autoCancel: true,
            enableLights: true,
            enableVibration: true,
            vibrationPattern: Int64List.fromList([0, 30, 100, 30]),
            // icon: , // set in manifest
          ),
          iOS: IOSNotificationDetails(
            threadIdentifier: targetId,
            // badgeNumber: apple?.badge, // TODO:GG firebase badgeNumber
            presentBadge: true,
            presentSound: true,
            presentAlert: true,
          ),
        ),
      );
    });

    // foreground click
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      logger.d("$TAG - onMessageOpenedApp - messageId:${message.messageId} - from:${message.from}");
    });
  }

  Future<String?> getToken() async {
    if (_token == null) {
      if (Platform.isAndroid) {
        _token = await FirebaseMessaging.instance.getToken();
      } else {
        _token = await FirebaseMessaging.instance.getAPNSToken();
      }
    }
    return _token;
  }

  Future deleteToken() async {
    await FirebaseMessaging.instance.deleteToken();
    _token = null;
  }

  sendPushMessage(
    String token,
    String uuid,
    String title,
    String content, {
    String? targetId,
    int? badgeNumber, // TODO:GG firebase badgeNumber
    String? payload,
  }) async {
    try {
      String body = constructFCMPayload(token, title, content, targetId, 100000);
      http.Response response = await http.post(
        Uri.parse('https://api.rnfirebase.io/messaging/send'),
        headers: <String, String>{'Content-Type': 'application/json; charset=UTF-8'},
        body: body,
      );
      if (response.statusCode == 200) {
        logger.d("$TAG - sendPushMessage - success - body:$body");
      } else {
        logger.w("$TAG - sendPushMessage - fail - code:${response.statusCode} - body:$body");
      }
    } catch (e) {
      handleError(e);
    }
  }

  String constructFCMPayload(
    String token,
    String title,
    String content,
    String? targetId,
    int expireS,
  ) {
    return jsonEncode({
      'token': token,
      // 'data': {
      //   'via': 'FlutterFire Cloud Messaging!!!',
      //   'count': "_messageCount.toString()",
      // },
      'notification': {
        'title': title,
        'body': content,
      },
      "android": {
        "collapseKey": targetId,
        "priority": "normal",
        "ttl": "${expireS}s",
      },
      "apns": {
        "apns-collapse-id": targetId,
        "headers": {
          "apns-priority": "5",
          "apns-expiration": "${DateTime.now().add(Duration(seconds: expireS)).millisecondsSinceEpoch / 1000}",
        },
      },
      "webpush": {
        "Topic": targetId,
        "headers": {
          "Urgency": "high",
          "TTL": "$expireS",
        }
      },
    });
  }
}

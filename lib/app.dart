import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nmobile/common/locator.dart';
import 'package:nmobile/common/settings.dart';
import 'package:nmobile/components/layout/nav.dart';
import 'package:nmobile/native/common.dart';
import 'package:nmobile/screens/chat/home.dart';
import 'package:nmobile/screens/settings/home.dart';
import 'package:nmobile/screens/wallet/home.dart';
import 'package:nmobile/services/task.dart';
import 'package:nmobile/storages/settings.dart';
import 'package:nmobile/utils/logger.dart';

class AppScreen extends StatefulWidget {
  static const String routeName = '/';
  static final String argIndex = "index";

  static go(BuildContext? context) {
    if (context == null) return;
    // return Navigator.pushNamed(context, routeName, arguments: {
    //   argIndex: index,
    // });
    Navigator.popUntil(context, ModalRoute.withName(routeName));
  }

  final Map<String, dynamic>? arguments;

  const AppScreen({Key? key, this.arguments}) : super(key: key);

  @override
  _AppScreenState createState() => _AppScreenState();
}

class _AppScreenState extends State<AppScreen> with WidgetsBindingObserver {
  List<Widget> screens = <Widget>[
    ChatHomeScreen(),
    WalletHomeScreen(),
    SettingsHomeScreen(),
  ];

  int _currentIndex = 0;
  late PageController _pageController;

  StreamSubscription? _clientStatusChangeSubscription;
  StreamSubscription? _appLifeChangeSubscription;

  bool firstConnect = true;
  int lastTopicsCheckAt = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

    // init
    Settings.appContext = context; // before at mounted
    application.mounted(); // await

    // page_controller
    this._currentIndex = widget.arguments != null ? (widget.arguments?[AppScreen.argIndex] ?? 0) : 0;
    _pageController = PageController(initialPage: this._currentIndex);

    // settings
    SettingsStorage.getSettings(SettingsStorage.LAST_CHECK_TOPICS_AT).then((value) {
      lastTopicsCheckAt = int.tryParse(value?.toString() ?? "0") ?? 0;
    });

    // clientStatus
    _clientStatusChangeSubscription = clientCommon.statusStream.listen((int status) {
      if (clientCommon.isClientOK) {
        if (firstConnect) {
          firstConnect = false;
          taskService.addTask10(TaskService.KEY_CLIENT_CONNECT, (key) => clientCommon.connectCheck(), delayMs: 5 * 1000);
          taskService.addTask30(TaskService.KEY_SUBSCRIBE_CHECK, (key) => topicCommon.checkAndTryAllSubscribe(), delayMs: 1500);
          taskService.addTask30(TaskService.KEY_PERMISSION_CHECK, (key) => topicCommon.checkAndTryAllPermission(), delayMs: 2000);
        }
      } else if (clientCommon.isClientStop) {
        taskService.removeTask10(TaskService.KEY_CLIENT_CONNECT);
        taskService.removeTask30(TaskService.KEY_SUBSCRIBE_CHECK);
        taskService.removeTask30(TaskService.KEY_PERMISSION_CHECK);
        firstConnect = true;
      }
    });

    // appLife
    _appLifeChangeSubscription = application.appLifeStream.listen((List<AppLifecycleState> states) async {
      if (application.isFromBackground(states)) {
        // topics check (24h)
        if (clientCommon.isClientOK) {
          int lastCheckTopicGap = DateTime.now().millisecondsSinceEpoch - lastTopicsCheckAt;
          logger.i("App - checkAllTopics - check:${lastCheckTopicGap > Settings.gapTopicSubscribeCheckMs} - gap:$lastCheckTopicGap");
          if (lastCheckTopicGap > Settings.gapTopicSubscribeCheckMs) {
            Future.delayed(Duration(milliseconds: 1000)).then((value) {
              topicCommon.checkAllTopics(refreshSubscribers: false); // await
              lastTopicsCheckAt = DateTime.now().millisecondsSinceEpoch;
              SettingsStorage.setSettings(SettingsStorage.LAST_CHECK_TOPICS_AT, lastTopicsCheckAt);
            });
          }
        }
      } else if (application.isGoBackground(states)) {
        // nothing
      }
    });

    // wallet
    taskService.addTask60(TaskService.KEY_WALLET_BALANCE, (key) => walletCommon.queryAllBalance(), delayMs: 1000);
  }

  @override
  void dispose() {
    _clientStatusChangeSubscription?.cancel();
    _appLifeChangeSubscription?.cancel();
    _pageController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    logger.i("AppScreen - didChangeAppLifecycleState - $state");
    AppLifecycleState old = application.appLifecycleState;
    application.appLifecycleState = state;
    super.didChangeAppLifecycleState(state);
    application.appLifeSink.add([old, state]);
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (Platform.isAndroid) {
          await Common.backDesktop();
        }
        return false;
      },
      child: Scaffold(
        backgroundColor: application.theme.backgroundColor,
        body: Stack(
          children: [
            PageView(
              controller: _pageController,
              onPageChanged: (n) {
                setState(() {
                  _currentIndex = n;
                });
              },
              children: screens,
            ),
            // footer nav
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: PhysicalModel(
                color: application.theme.backgroundColor,
                clipBehavior: Clip.antiAlias,
                elevation: 2,
                borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                child: Nav(
                  currentIndex: _currentIndex,
                  screens: screens,
                  controller: _pageController,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

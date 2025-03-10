import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:nmobile/app.dart';
import 'package:nmobile/common/locator.dart';
import 'package:nmobile/common/settings.dart';
import 'package:nmobile/components/base/stateful.dart';
import 'package:nmobile/components/button/button.dart';
import 'package:nmobile/components/contact/avatar_editable.dart';
import 'package:nmobile/components/dialog/bottom.dart';
import 'package:nmobile/components/dialog/loading.dart';
import 'package:nmobile/components/dialog/modal.dart';
import 'package:nmobile/components/layout/expansion_layout.dart';
import 'package:nmobile/components/layout/header.dart';
import 'package:nmobile/components/layout/layout.dart';
import 'package:nmobile/components/text/label.dart';
import 'package:nmobile/components/tip/toast.dart';
import 'package:nmobile/helpers/error.dart';
import 'package:nmobile/helpers/file.dart';
import 'package:nmobile/helpers/media_picker.dart';
import 'package:nmobile/schema/contact.dart';
import 'package:nmobile/schema/device_info.dart';
import 'package:nmobile/schema/wallet.dart';
import 'package:nmobile/screens/chat/messages.dart';
import 'package:nmobile/screens/contact/chat_profile.dart';
import 'package:nmobile/utils/asset.dart';
import 'package:nmobile/utils/logger.dart';
import 'package:nmobile/utils/path.dart';
import 'package:nmobile/utils/util.dart';

class ContactProfileScreen extends BaseStateFulWidget {
  static const String routeName = '/contact/profile';
  static final String argContactSchema = "contact_schema";
  static final String argContactAddress = "contact_address";

  static Future go(BuildContext? context, {ContactSchema? schema, String? address}) {
    if (context == null) return Future.value(null);
    if (schema == null && (address == null || address.isEmpty)) return Future.value(null);
    return Navigator.pushNamed(context, routeName, arguments: {
      argContactSchema: schema,
      argContactAddress: address,
    });
  }

  final Map<String, dynamic>? arguments;

  ContactProfileScreen({Key? key, this.arguments}) : super(key: key);

  @override
  _ContactProfileScreenState createState() => _ContactProfileScreenState();
}

class _ContactProfileScreenState extends BaseStateFulWidgetState<ContactProfileScreen> with Tag {
  static List<Duration> burnValueArray = [
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 30),
    Duration(hours: 1),
    Duration(hours: 6),
    Duration(hours: 12),
    Duration(days: 1),
    Duration(days: 7),
  ];

  static List<String> burnTextArray() {
    return [
      Settings.locale((s) => s.burn_5_seconds),
      Settings.locale((s) => s.burn_10_seconds),
      Settings.locale((s) => s.burn_30_seconds),
      Settings.locale((s) => s.burn_1_minute),
      Settings.locale((s) => s.burn_5_minutes),
      Settings.locale((s) => s.burn_10_minutes),
      Settings.locale((s) => s.burn_30_minutes),
      Settings.locale((s) => s.burn_1_hour),
      Settings.locale((s) => s.burn_6_hour),
      Settings.locale((s) => s.burn_12_hour),
      Settings.locale((s) => s.burn_1_day),
      Settings.locale((s) => s.burn_1_week),
    ];
  }

  static String getStringFromSeconds(int seconds) {
    int currentIndex = -1;
    for (int index = 0; index < burnValueArray.length; index++) {
      Duration duration = burnValueArray[index];
      if (seconds == duration.inSeconds) {
        currentIndex = index;
        break;
      }
    }
    if (currentIndex == -1) {
      return '';
    } else {
      return burnTextArray()[currentIndex];
    }
  }

  StreamSubscription? _updateContactSubscription;

  ContactSchema? _contact;
  WalletSchema? _wallet;

  bool _initBurnOpen = false;
  int _initBurnProgress = -1;
  bool _burnOpen = false;
  int _burnProgress = -1;

  bool _notificationOpen = false;

  bool _profileFetched = false;

  @override
  void onRefreshArguments() {
    _refreshContactSchema();
  }

  @override
  initState() {
    super.initState();
    // listen
    _updateContactSubscription = contactCommon.updateStream.where((event) => event.address == _contact?.address).listen((ContactSchema event) {
      _initBurning(event);
      _initNotification(event);
      setState(() {
        _contact = event;
      });
    });

    // init
    _refreshDefaultWallet();
  }

  @override
  void dispose() {
    _updateBurnIfNeed();
    _updateContactSubscription?.cancel();
    super.dispose();
  }

  _refreshContactSchema({ContactSchema? schema}) async {
    ContactSchema? contactSchema = widget.arguments?[ContactProfileScreen.argContactSchema];
    String? contactAddress = widget.arguments?[ContactProfileScreen.argContactAddress];
    if (schema != null) {
      this._contact = schema;
    } else if (contactSchema != null) {
      this._contact = contactSchema;
    } else if (contactAddress?.isNotEmpty == true) {
      this._contact = await contactCommon.query(contactAddress);
    }

    if (this._contact == null || (this._contact?.address.isEmpty == true)) return;

    // exist
    contactCommon.query(this._contact?.address).then((ContactSchema? exist) async {
      if (exist != null) return;
      ContactSchema? added = await contactCommon.add(this._contact, notify: true);
      if (added == null) return;
      setState(() {
        this._contact = added;
      });
    });

    _initBurning(this._contact);
    _initNotification(this._contact);

    setState(() {});

    // fetch
    if (!_profileFetched && (_contact?.isMe == false)) {
      _profileFetched = true;
      chatOutCommon.sendContactProfileRequest(_contact?.address, ContactRequestType.header, _contact?.profileVersion); // await
      chatOutCommon.sendDeviceRequest(_contact?.address).then((value) {
        if (value) contactCommon.setDeviceInfoRequestAt(_contact?.address);
      }); // await
    }
  }

  _initBurning(ContactSchema? schema) {
    int? burnAfterSeconds = schema?.options.deleteAfterSeconds;
    _burnOpen = burnAfterSeconds != null && burnAfterSeconds != 0;
    if (_burnOpen) {
      _burnProgress = burnValueArray.indexWhere((x) => x.inSeconds == burnAfterSeconds);
      if (burnAfterSeconds != null && burnAfterSeconds > burnValueArray.last.inSeconds) {
        _burnProgress = burnValueArray.length - 1;
      }
    }
    if (_burnProgress < 0) _burnProgress = 0;
    _initBurnOpen = _burnOpen;
    _initBurnProgress = _burnProgress;
  }

  _initNotification(ContactSchema? schema) {
    if (schema?.isMe == false) {
      if (schema?.options.notificationOpen != null) {
        _notificationOpen = schema?.options.notificationOpen ?? false;
      } else {
        _notificationOpen = false;
      }
    }
  }

  Future<bool> _refreshDefaultWallet({WalletSchema? wallet}) async {
    wallet = wallet ?? await walletCommon.getDefault();
    if (wallet == null) {
      AppScreen.go(this.context);
      return false;
    }
    setState(() {
      _wallet = wallet;
    });
    return true;
  }

  _selectDefaultWallet() async {
    WalletSchema? selected = await BottomDialog.of(Settings.appContext).showWalletSelect(title: Settings.locale((s) => s.select_another_wallet), onlyNKN: true);
    if (selected == null || selected.address.isEmpty || selected.address == (_contact?.walletAddress)) return;

    Loading.show();
    try {
      // client signOut
      await clientCommon.signOut(clearWallet: true, closeDB: true);
      await Future.delayed(Duration(milliseconds: 250)); // wait client close
      Loading.dismiss();
      // client signIn
      bool success = await clientCommon.signIn(selected, toast: true, loading: (visible, input, dbOpen) {
        if (visible && !input && !dbOpen) {
          Loading.show();
        } else if (visible && input) {
          Loading.dismiss();
        } else if (!visible) {
          Loading.dismiss();
        }
      });
      await Future.delayed(Duration(milliseconds: 250)); // wait client create

      if (success) {
        Toast.show(Settings.locale((s) => s.tip_switch_success, ctx: context)); // must global context
        // contact
        ContactSchema? _me = await contactCommon.getMe(canAdd: true, fetchWalletAddress: true);
        await _refreshContactSchema(schema: _me);
        contactCommon.meUpdateSink.add(_me);
      }
      if (mounted) {
        AppScreen.go(this.context);
      } else {
        Future.delayed(Duration(milliseconds: 250), () => _refreshDefaultWallet()); // await ui refresh
      }
    } catch (e, st) {
      handleError(e, st);
    } finally {
      Loading.dismiss();
    }
  }

  _onDropRemarkAvatar() async {
    if (_contact?.type == ContactType.me) return;
    contactCommon.setOtherRemarkAvatar(_contact?.address, null, notify: true); // await
  }

  _selectAvatarPicture() async {
    String remarkAvatarPath = await Path.getRandomFile(clientCommon.getPublicKey(), DirType.profile, subPath: _contact?.address, fileExt: FileHelper.DEFAULT_IMAGE_EXT);
    String? remarkAvatarLocalPath = Path.convert2Local(remarkAvatarPath);
    if (remarkAvatarPath.isEmpty || remarkAvatarLocalPath == null || remarkAvatarLocalPath.isEmpty) return;
    application.inSystemSelecting = true;
    File? picked = await MediaPicker.pickImage(
      cropStyle: CropStyle.rectangle,
      cropRatio: CropAspectRatio(ratioX: 1, ratioY: 1),
      maxSize: Settings.sizeAvatarMax,
      bestSize: Settings.sizeAvatarBest,
      savePath: remarkAvatarPath,
    );
    application.inSystemSelecting = false;
    if (picked == null) {
      // Toast.show("Open camera or MediaLibrary for nMobile to update your profile");
      return;
    } else {
      remarkAvatarPath = picked.path;
      remarkAvatarLocalPath = Path.convert2Local(remarkAvatarPath);
    }
    if (remarkAvatarPath.isEmpty || remarkAvatarLocalPath == null || remarkAvatarLocalPath.isEmpty) return;

    if (_contact?.type == ContactType.me) {
      contactCommon.setSelfAvatar(_contact?.address, remarkAvatarLocalPath, notify: true); // await
    } else {
      contactCommon.setOtherRemarkAvatar(_contact?.address, remarkAvatarLocalPath, notify: true); // await
    }
  }

  _modifyNickname() async {
    String? newName = await BottomDialog.of(Settings.appContext).showInput(
      title: Settings.locale((s) => s.edit_nickname, ctx: context),
      inputTip: Settings.locale((s) => s.edit_nickname, ctx: context),
      inputHint: Settings.locale((s) => s.input_nickname, ctx: context),
      value: _contact?.displayName,
      actionText: Settings.locale((s) => s.save, ctx: context),
      maxLength: 20,
      canTapClose: false,
    );
    if (_contact?.type == ContactType.me) {
      contactCommon.setSelfFullName(_contact?.address, newName?.trim(), null, notify: true); // await
    } else {
      contactCommon.setOtherRemarkName(_contact?.address, newName?.trim(), notify: true); // await
    }
  }

  _updateBurnIfNeed() {
    if ((_burnOpen == _initBurnOpen) && (_burnProgress == _initBurnProgress)) return;
    int _burnValue;
    if (!_burnOpen || _burnProgress < 0) {
      _burnValue = 0;
    } else {
      _burnValue = burnValueArray[_burnProgress].inSeconds;
    }
    int timeNow = DateTime.now().millisecondsSinceEpoch;
    _contact?.options.deleteAfterSeconds = _burnValue;
    _contact?.options.updateBurnAfterAt = timeNow;
    // inside update
    contactCommon.setOptionsBurn(_contact?.address, _burnValue, timeNow, notify: true).then((options) {
      // outside update
      if (options != null) chatOutCommon.sendContactOptionsBurn(_contact?.address, _burnValue, timeNow); // await
    });
  }

  _updateNotificationAndDeviceToken(bool notificationOpen) async {
    DeviceInfoSchema? deviceInfo = await deviceInfoCommon.getMe(fetchDeviceToken: notificationOpen);
    String? deviceToken = notificationOpen ? deviceInfo?.deviceToken : null;
    bool tokenEmpty = (deviceToken == null) || deviceToken.isEmpty;
    if (notificationOpen && tokenEmpty) {
      setState(() {
        _notificationOpen = false;
      });
      Toast.show(Settings.locale((s) => s.unavailable_device, ctx: context));
      return;
    }
    _contact?.options.notificationOpen = notificationOpen;
    // update
    var data = await contactCommon.setNotificationOpen(_contact?.address, notificationOpen, notify: true);
    if (data == null) return;
    chatOutCommon.sendContactOptionsToken(_contact?.address, deviceToken).then((success) {
      if (!success) contactCommon.setNotificationOpen(_contact?.address, !notificationOpen, notify: true); // await
    }); // await
  }

  _addFriend() async {
    bool success = await contactCommon.setType(_contact?.address, ContactType.friend, notify: true);
    if (success) Toast.show(Settings.locale((s) => s.success, ctx: context));
  }

  _deleteAction() {
    ModalDialog.of(Settings.appContext).confirm(
      title: Settings.locale((s) => s.tip, ctx: context),
      content: Settings.locale((s) => s.delete_friend_confirm_title, ctx: context),
      agree: Button(
        width: double.infinity,
        text: Settings.locale((s) => s.delete_contact, ctx: context),
        backgroundColor: application.theme.strongColor,
        onPressed: () async {
          if (Navigator.of(this.context).canPop()) Navigator.pop(this.context);
          bool success = await contactCommon.setType(_contact?.address, ContactType.none, notify: true);
          if (!success) return;
          if (Navigator.of(this.context).canPop()) Navigator.pop(this.context);
        },
      ),
      reject: Button(
        width: double.infinity,
        text: Settings.locale((s) => s.cancel, ctx: context),
        fontColor: application.theme.fontColor2,
        backgroundColor: application.theme.backgroundLightColor,
        onPressed: () {
          if (Navigator.of(this.context).canPop()) Navigator.pop(this.context);
        },
      ),
    );
  }

  String _getClientAddressShow() {
    String? address = _contact?.address;
    if (address != null) {
      if (address.length > 10) {
        return address.substring(0, 10) + '...';
      }
      return address;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Layout(
      headerColor: application.theme.backgroundColor4,
      clipAlias: false,
      header: Header(
        backgroundColor: application.theme.backgroundColor4,
        title: Settings.locale((s) => s.settings, ctx: context),
      ),
      body: _contact?.isMe == true
          ? _getSelfView()
          : _contact?.isMe == false
              ? _getPersonView()
              : SizedBox.shrink(),
    );
  }

  _buttonStyle({bool topRadius = true, bool botRadius = true, double topPad = 12, double botPad = 12}) {
    return ButtonStyle(
      backgroundColor: MaterialStateProperty.resolveWith((state) => application.theme.backgroundLightColor),
      padding: MaterialStateProperty.resolveWith((states) => EdgeInsets.only(left: 16, right: 16, top: topPad, bottom: botPad)),
      shape: MaterialStateProperty.resolveWith(
        (states) => RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: topRadius ? Radius.circular(12) : Radius.zero,
            bottom: botRadius ? Radius.circular(12) : Radius.zero,
          ),
        ),
      ),
    );
  }

  _getSelfView() {
    List<String> mappeds = _contact?.mappedAddress ?? [];
    List<Widget> mappedWidget = [];
    for (int i = 0; i < mappeds.length; i++) {
      mappedWidget.add(Slidable(
        key: ObjectKey(mappeds[i]),
        direction: Axis.horizontal,

        child: TextButton(
          style: _buttonStyle(topRadius: false, botRadius: false, topPad: 15, botPad: 10),
          onPressed: () {
            Util.copyText(mappeds[i]);
          },
          child: Row(
            children: <Widget>[
              Expanded(
                child: SizedBox(
                  height: 24,
                  child: Label(
                    mappeds[i],
                    overflow: TextOverflow.ellipsis,
                    type: LabelType.bodyRegular,
                    color: application.theme.fontColor2,
                  ),
                ),
              ),
            ],
          ),
        ),
        endActionPane: ActionPane(
          motion: ScrollMotion(),
          extentRatio: 0.25,
          children: [
            CustomSlidableAction(
              onPressed: (BuildContext context) {
                ModalDialog.of(Settings.appContext).confirm(
                  title: Settings.locale((s) => s.delete_mapping_address_confirm_title, ctx: context),
                  agree: Button(
                    width: double.infinity,
                    text: Settings.locale((s) => s.delete, ctx: context),
                    backgroundColor: application.theme.strongColor,
                    onPressed: () async {
                      List<String> modified = mappeds..remove(mappeds[i]);
                      await contactCommon.setMappedAddress(_contact?.address, modified.toSet().toList(), notify: true);
                      Navigator.pop(this.context);
                    },
                  ),
                  reject: Button(
                    width: double.infinity,
                    text: Settings.locale((s) => s.cancel, ctx: context),
                    fontColor: application.theme.fontColor2,
                    backgroundColor: application.theme.backgroundLightColor,
                    onPressed: () {
                      if (Navigator.of(this.context).canPop()) Navigator.pop(this.context);
                    },
                  ),
                );
              },
              backgroundColor: Colors.red,
              foregroundColor: application.theme.fontLightColor,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(Icons.delete, color: application.theme.fontLightColor, size: 24,),
                  Label(
                    Settings.locale((s) => s.delete, ctx: context),
                    color: application.theme.fontLightColor,
                    type: LabelType.bodyRegular,
                  ),
                ],
              ),
            ),
          ],
        ),
      ));
    }
    return SingleChildScrollView(
      child: Column(
        children: <Widget>[
          Container(
            padding: EdgeInsets.only(left: 16, right: 16, bottom: 32),
            decoration: BoxDecoration(
              color: application.theme.backgroundColor4,
            ),
            child: Center(
              /// avatar
              child: _contact != null
                  ? ContactAvatarEditable(
                      radius: 48,
                      contact: _contact!,
                      placeHolder: false,
                      onSelect: _selectAvatarPicture,
                    )
                  : SizedBox.shrink(),
            ),
          ),
          Stack(
            children: [
              Container(
                height: 32,
                decoration: BoxDecoration(color: application.theme.backgroundColor4),
              ),
              Container(
                decoration: BoxDecoration(
                  color: application.theme.backgroundColor,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                ),
                padding: EdgeInsets.only(left: 16, right: 16, top: 26, bottom: 26),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Label(
                      Settings.locale((s) => s.my_profile, ctx: context),
                      type: LabelType.h3,
                    ),
                    SizedBox(height: 24),

                    /// name
                    TextButton(
                      style: _buttonStyle(topRadius: true, botRadius: false, topPad: 15, botPad: 10),
                      onPressed: () {
                        _modifyNickname();
                      },
                      child: Row(
                        children: <Widget>[
                          Asset.iconSvg('user', color: application.theme.primaryColor, width: 24),
                          SizedBox(width: 10),
                          Label(
                            Settings.locale((s) => s.nickname, ctx: context),
                            type: LabelType.bodyRegular,
                            color: application.theme.fontColor1,
                          ),
                          SizedBox(width: 20),
                          Expanded(
                            child: Label(
                              _contact?.displayName ?? "",
                              type: LabelType.bodyRegular,
                              color: application.theme.fontColor2,
                              overflow: TextOverflow.fade,
                              textAlign: TextAlign.right,
                            ),
                          ),
                          Asset.iconSvg(
                            'right',
                            width: 24,
                            color: application.theme.fontColor2,
                          ),
                        ],
                      ),
                    ),

                    /// address
                    TextButton(
                      style: _buttonStyle(topRadius: false, botRadius: false, topPad: 12, botPad: 12),
                      onPressed: () {
                        if (this._contact == null) return;
                        ContactChatProfileScreen.go(this.context, this._contact!);
                      },
                      child: Row(
                        children: <Widget>[
                          Asset.image('chat/chat-id.png', color: application.theme.primaryColor, width: 24),
                          SizedBox(width: 10),
                          Label(
                            Settings.locale((s) => s.d_chat_address, ctx: context),
                            type: LabelType.bodyRegular,
                            color: application.theme.fontColor1,
                          ),
                          SizedBox(width: 20),
                          Expanded(
                            child: Label(
                              _getClientAddressShow(),
                              type: LabelType.bodyRegular,
                              color: application.theme.fontColor2,
                              overflow: TextOverflow.fade,
                              textAlign: TextAlign.right,
                            ),
                          ),
                          Asset.iconSvg(
                            'right',
                            width: 24,
                            color: application.theme.fontColor2,
                          ),
                        ],
                      ),
                    ),

                    /// wallet
                    TextButton(
                      style: _buttonStyle(topRadius: false, botRadius: true, topPad: 10, botPad: 15),
                      onPressed: () {
                        _selectDefaultWallet();
                      },
                      child: Row(
                        children: <Widget>[
                          Asset.iconSvg('wallet', color: application.theme.primaryColor, width: 24),
                          SizedBox(width: 10),
                          Expanded(
                            child: Label(
                              _wallet?.name ?? "--",
                              type: LabelType.bodyRegular,
                              color: application.theme.fontColor1,
                            ),
                          ),
                          SizedBox(width: 20),
                          Label(
                            Settings.locale((s) => s.change_default_chat_wallet, ctx: context),
                            type: LabelType.bodyRegular,
                            color: application.theme.primaryColor,
                            overflow: TextOverflow.fade,
                            textAlign: TextAlign.right,
                            fontWeight: FontWeight.w600,
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  _getPersonView() {
    bool remarkNameExists = _contact?.remarkName.isNotEmpty == true;
    bool originalNameExists = _contact?.fullName.isNotEmpty == true;
    // String clientAddress = _contactSchema?.clientAddress ?? "";
    // bool isDefaultName = originalNameExists && clientAddress.startsWith(_contactSchema?.fullName ?? "");
    bool showOriginalName = remarkNameExists && originalNameExists; // && !isDefaultName

    List<String> mappeds = _contact?.mappedAddress ?? [];
    List<Widget> mappedWidget = [];
    for (int i = 0; i < mappeds.length; i++) {
      mappedWidget.add(Slidable(
        key: ObjectKey(mappeds[i]),
        direction: Axis.horizontal,
        child: TextButton(
          style: _buttonStyle(topRadius: false, botRadius: false, topPad: 15, botPad: 10),
          onPressed: () {
            Util.copyText(mappeds[i]);
          },
          child: Row(
            children: <Widget>[
              Expanded(
                child: SizedBox(
                  height: 24,
                  child: Label(
                    mappeds[i],
                    overflow: TextOverflow.ellipsis,
                    type: LabelType.bodyRegular,
                    color: application.theme.fontColor2,
                  ),
                ),
              ),
            ],
          ),
        ),
        endActionPane: ActionPane(
          motion: ScrollMotion(),
          extentRatio: 0.25,
          children: [
            CustomSlidableAction(
              onPressed: (BuildContext context) {
                ModalDialog.of(Settings.appContext).confirm(
                  title: Settings.locale((s) => s.delete_mapping_address_confirm_title, ctx: context),
                  agree: Button(
                    width: double.infinity,
                    text: Settings.locale((s) => s.delete, ctx: context),
                    backgroundColor: application.theme.strongColor,
                    onPressed: () async {
                      List<String> modified = mappeds..remove(mappeds[i]);
                      await contactCommon.setMappedAddress(_contact?.address, modified.toSet().toList(), notify: true);
                      Navigator.pop(this.context);
                    },
                  ),
                  reject: Button(
                    width: double.infinity,
                    text: Settings.locale((s) => s.cancel, ctx: context),
                    fontColor: application.theme.fontColor2,
                    backgroundColor: application.theme.backgroundLightColor,
                    onPressed: () {
                      if (Navigator.of(this.context).canPop()) Navigator.pop(this.context);
                    },
                  ),
                );
              },
              backgroundColor: Colors.red,
              foregroundColor: application.theme.fontLightColor,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(Icons.delete, color: application.theme.fontLightColor, size: 24,),
                  Label(
                    Settings.locale((s) => s.delete, ctx: context),
                    color: application.theme.fontLightColor,
                    type: LabelType.bodyRegular,
                  ),
                ],
              ),
            ),
          ],
        ),
      ));
    }
    return SingleChildScrollView(
      padding: EdgeInsets.only(top: 20, bottom: 30, left: 16, right: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          /// avatar
          Center(
            child: _contact != null
                ? ContactAvatarEditable(
                    radius: 48,
                    contact: _contact!,
                    placeHolder: false,
                    onSelect: _selectAvatarPicture,
                    onDrop: _onDropRemarkAvatar,
                  )
                : SizedBox.shrink(),
          ),
          SizedBox(height: 6),

          /// name(original)
          showOriginalName
              ? Center(
                  child: Label(
                    _contact?.fullName ?? "",
                    type: LabelType.h3,
                    color: application.theme.fontColor2,
                    overflow: TextOverflow.fade,
                    textAlign: TextAlign.right,
                  ),
                )
              : SizedBox.shrink(),
          SizedBox(height: showOriginalName ? 24 : 30),

          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              /// name
              TextButton(
                style: _buttonStyle(topRadius: true, botRadius: false, topPad: 15, botPad: 10),
                onPressed: () {
                  _modifyNickname();
                },
                child: Row(
                  children: <Widget>[
                    Asset.iconSvg('user', color: application.theme.primaryColor, width: 24),
                    SizedBox(width: 10),
                    Label(
                      Settings.locale((s) => s.nickname, ctx: context),
                      type: LabelType.bodyRegular,
                      color: application.theme.fontColor1,
                    ),
                    SizedBox(width: 20),
                    Expanded(
                      child: Label(
                        _contact?.displayName ?? "",
                        type: LabelType.bodyRegular,
                        color: application.theme.fontColor2,
                        overflow: TextOverflow.fade,
                        textAlign: TextAlign.right,
                      ),
                    ),
                    Asset.iconSvg(
                      'right',
                      width: 24,
                      color: application.theme.fontColor2,
                    ),
                  ],
                ),
              ),

              /// address
              TextButton(
                style: _buttonStyle(topRadius: false, botRadius: true, topPad: 10, botPad: 15),
                onPressed: () {
                  if (this._contact == null) return;
                  ContactChatProfileScreen.go(this.context, this._contact!);
                },
                child: Row(
                  children: <Widget>[
                    Asset.image('chat/chat-id.png', color: application.theme.primaryColor, width: 24),
                    SizedBox(width: 10),
                    Label(
                      Settings.locale((s) => s.d_chat_address, ctx: context),
                      type: LabelType.bodyRegular,
                      color: application.theme.fontColor1,
                    ),
                    SizedBox(width: 20),
                    Expanded(
                      child: Label(
                        _getClientAddressShow(),
                        type: LabelType.bodyRegular,
                        color: application.theme.fontColor2,
                        overflow: TextOverflow.fade,
                        textAlign: TextAlign.right,
                      ),
                    ),
                    Asset.iconSvg(
                      'right',
                      width: 24,
                      color: application.theme.fontColor2,
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 28),

          /// burn
          TextButton(
            style: _buttonStyle(topRadius: true, botRadius: true, topPad: 8, botPad: 8),
            onPressed: () {
              setState(() {
                _burnOpen = !_burnOpen;
              });
            },
            child: Column(
              children: [
                Row(
                  mainAxisSize: MainAxisSize.max,
                  children: <Widget>[
                    Asset.image('contact/xiaohui.png', color: application.theme.primaryColor, width: 24),
                    SizedBox(width: 10),
                    Label(
                      Settings.locale((s) => s.burn_after_reading, ctx: context),
                      type: LabelType.bodyRegular,
                      color: application.theme.fontColor1,
                    ),
                    Spacer(),
                    CupertinoSwitch(
                      value: _burnOpen,
                      activeColor: application.theme.primaryColor,
                      onChanged: (value) {
                        setState(() {
                          _burnOpen = value;
                        });
                      },
                    ),
                  ],
                ),
                ExpansionLayout(
                  isExpanded: _burnOpen,
                  child: Container(
                    padding: EdgeInsets.only(top: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.max,
                      children: [
                        Icon(Icons.alarm_on, size: 24, color: application.theme.primaryColor),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(left: 16),
                                child: Label(
                                  (!_burnOpen || _burnProgress < 0) ? Settings.locale((s) => s.off, ctx: context) : getStringFromSeconds(burnValueArray[_burnProgress].inSeconds),
                                  type: LabelType.bodyRegular,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Slider(
                                value: _burnProgress >= 0 ? _burnProgress.roundToDouble() : 0,
                                min: 0,
                                max: (burnValueArray.length - 1).roundToDouble(),
                                activeColor: application.theme.primaryColor,
                                inactiveColor: application.theme.fontColor2,
                                divisions: burnValueArray.length - 1,
                                label: _burnProgress >= 0 ? burnTextArray()[_burnProgress] : "",
                                onChanged: (value) {
                                  setState(() {
                                    _burnProgress = value.round();
                                    if (_burnProgress > burnValueArray.length - 1) {
                                      _burnProgress = burnValueArray.length - 1;
                                    }
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 20, top: 6),
            child: Label(
              (!_burnOpen || _burnProgress < 0)
                  ? Settings.locale((s) => s.burn_after_reading_desc, ctx: context)
                  : Settings.locale(
                      (s) => s.burn_after_reading_desc_disappear(
                            burnTextArray()[_burnProgress],
                          ),
                      ctx: context),
              type: LabelType.bodySmall,
              fontWeight: FontWeight.w600,
              softWrap: true,
            ),
          ),
          SizedBox(height: 28),

          /// notification
          TextButton(
            style: _buttonStyle(topRadius: true, botRadius: true, topPad: 8, botPad: 8),
            onPressed: () {
              // setState(() {
              //   _notificationOpen = !_notificationOpen;
              //   _updateNotificationAndDeviceToken();
              // });
            },
            child: Row(
              children: <Widget>[
                Asset.iconSvg('notification-bell', color: application.theme.primaryColor, width: 24),
                SizedBox(width: 10),
                Label(
                  Settings.locale((s) => s.remote_notification, ctx: context),
                  type: LabelType.bodyRegular,
                  color: application.theme.fontColor1,
                ),
                Spacer(),
                CupertinoSwitch(
                  value: _notificationOpen,
                  activeColor: application.theme.primaryColor,
                  onChanged: (value) {
                    setState(() {
                      _notificationOpen = value;
                    });
                    _updateNotificationAndDeviceToken(value);
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 20, right: 20),
            child: Label(
              Settings.locale((s) => s.accept_notification, ctx: context),
              type: LabelType.bodySmall,
              fontWeight: FontWeight.w600,
              softWrap: true,
            ),
          ),
          SizedBox(height: 28),

          /// sendMsg
          TextButton(
            style: _buttonStyle(topRadius: true, botRadius: true, topPad: 12, botPad: 12),
            onPressed: () {
              _updateBurnIfNeed();
              ChatMessagesScreen.go(this.context, _contact);
            },
            child: Row(
              children: <Widget>[
                Asset.iconSvg('chat', color: application.theme.primaryColor, width: 24),
                SizedBox(width: 10),
                Label(
                  Settings.locale((s) => s.send_message, ctx: context),
                  type: LabelType.bodyRegular,
                  color: application.theme.fontColor1,
                ),
                Spacer(),
                Asset.iconSvg(
                  'right',
                  width: 24,
                  color: application.theme.fontColor2,
                ),
              ],
            ),
          ),
          // SizedBox(height: 28),

          /// AddContact
          _contact?.type != ContactType.friend
              ? Column(
                  children: [
                    SizedBox(height: 10),
                    TextButton(
                      style: _buttonStyle(topRadius: true, botRadius: true, topPad: 12, botPad: 12),
                      onPressed: () {
                        _addFriend();
                      },
                      child: Row(
                        children: <Widget>[
                          Icon(Icons.person_add, color: application.theme.primaryColor),
                          SizedBox(width: 10),
                          Label(
                            Settings.locale((s) => s.add_contact, ctx: context),
                            type: LabelType.bodyRegular,
                            color: application.theme.primaryColor,
                          ),
                          Spacer(),
                        ],
                      ),
                    ),
                  ],
                )
              : SizedBox.shrink(),

          /// delete
          (_contact?.type == ContactType.friend) || (_contact?.type == ContactType.stranger)
              ? Column(
                  children: [
                    SizedBox(height: 28),
                    TextButton(
                      style: _buttonStyle(topRadius: true, botRadius: true, topPad: 12, botPad: 12),
                      onPressed: () {
                        _deleteAction();
                      },
                      child: Row(
                        children: <Widget>[
                          Spacer(),
                          Icon(Icons.delete, color: Colors.red),
                          SizedBox(width: 10),
                          Label(Settings.locale((s) => s.delete, ctx: context), type: LabelType.bodyRegular, color: Colors.red),
                          Spacer(),
                        ],
                      ),
                    ),
                  ],
                )
              : SizedBox.shrink(),
        ],
      ),
    );
  }
}

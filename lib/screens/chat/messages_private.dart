import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nmobile/common/locator.dart';
import 'package:nmobile/components/chat/bottom_menu.dart';
import 'package:nmobile/components/chat/message_item.dart';
import 'package:nmobile/components/chat/send_bar.dart';
import 'package:nmobile/components/contact/header.dart';
import 'package:nmobile/components/layout/header.dart';
import 'package:nmobile/components/layout/layout.dart';
import 'package:nmobile/components/text/label.dart';
import 'package:nmobile/generated/l10n.dart';
import 'package:nmobile/schema/contact.dart';
import 'package:nmobile/schema/message.dart';
import 'package:nmobile/screens/contact/detail.dart';
import 'package:nmobile/storages/message.dart';
import 'package:nmobile/theme/theme.dart';
import 'package:nmobile/utils/asset.dart';

class ChatMessagesPrivateLayout extends StatefulWidget {
  final ContactSchema contact;

  ChatMessagesPrivateLayout({this.contact});

  @override
  _ChatMessagesPrivateLayoutState createState() => _ChatMessagesPrivateLayoutState();
}

class _ChatMessagesPrivateLayoutState extends State<ChatMessagesPrivateLayout> {
  final int _messagesLimit = 20;
  ScrollController _scrollController = ScrollController();
  bool _moreLoading = false;

  ContactSchema _contact;

  StreamSubscription _onMessageStreamSubscription;
  MessageStorage _messageStorage = MessageStorage();

  List<MessageSchema> _messages = <MessageSchema>[];

  bool _showBottomMenu = false;

  @override
  void initState() {
    super.initState();
    this._contact = widget.contact;

    // onReceive + OnSaveSqlite
    _onMessageStreamSubscription = chat.onMessageSavedStream?.where((event) => event.from == _contact.clientAddress)?.listen((MessageSchema event) {
      if (event == null) return;
      _messageStorage.markMessageRead(event?.msgId);
      setState(() {
        _messages?.insert(0, event);
      });
    });
    chat.onMessageSavedStreamSubscriptions.add(_onMessageStreamSubscription);

    // loadMore
    _scrollController.addListener(() {
      double offsetFromBottom = _scrollController.position.maxScrollExtent - _scrollController.position.pixels;
      if (offsetFromBottom < 50 && !_moreLoading) {
        _moreLoading = true;
        _loadMore().then((v) {
          _moreLoading = false;
        });
      }
    });

    // init
    initDataAsync();
  }

  @override
  void dispose() {
    super.dispose();
    _onMessageStreamSubscription?.cancel();
  }

  initDataAsync() async {
    await _loadMore();
  }

  _loadMore() async {
    int _skip = _messages.length;
    var messages = await _messageStorage.getAndReadTargetMessages(_contact.clientAddress, skip: _skip, limit: _messagesLimit);
    if (messages != null) {
      setState(() {
        _messages = _messages + messages;
      });
    }
  }

  _toggleBottomMenu() async {
    setState(() {
      _showBottomMenu = !_showBottomMenu;
    });
  }

  _hideAll() {
    FocusScope.of(context).requestFocus(FocusNode());
    setState(() {
      _showBottomMenu = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    S _localizations = S.of(context);
    SkinTheme _theme = application.theme;

    return Layout(
      headerColor: _theme.headBarColor2,
      header: Header(
        backgroundColor: _theme.headBarColor2,
        titleChild: Container(
          child: ContactHeader(
            contact: _contact,
            onTap: () {
              ContactDetailScreen.go(context, contactId: _contact?.id);
            },
            body: Label(
              _localizations.click_to_settings,
              type: LabelType.h4,
              color: _theme.fontColor2,
            ),
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              icon: Asset.iconSvg('notification-bell', color: Colors.white, width: 24),
              onPressed: () {
                // TODO:GG notification
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              icon: Asset.iconSvg('more', color: Colors.white, width: 24),
              onPressed: () {
                ContactDetailScreen.go(context, contactId: _contact?.id);
              },
            ),
          ),
        ],
      ),
      body: GestureDetector(
        onTap: () {
          _hideAll();
        },
        child: SafeArea(
          child: Flex(
            direction: Axis.vertical,
            children: [
              Expanded(
                flex: 1,
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 16),
                  child: ListView.builder(
                    controller: _scrollController,
                    itemCount: _messages?.length ?? 0,
                    reverse: true,
                    padding: const EdgeInsets.only(bottom: 8, top: 16),
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemBuilder: (BuildContext context, int index) {
                      MessageSchema message = _messages[index];
                      ContactSchema contact = _contact;

                      // Fixme: show time
                      bool showTime = false;
                      if (index >= _messages.length - 1) {
                        showTime = true;
                      } else {
                        if (index + 1 < _messages.length) {
                          var targetMessage = _messages[index + 1];
                          if (message.timestamp.isAfter(targetMessage.timestamp.add(Duration(minutes: 3)))) {
                            showTime = true;
                          }
                        }
                      }

                      return ChatMessageItem(
                        message: message,
                        contact: contact,
                        showTime: showTime,
                      );
                    },
                  ),
                ),
              ),
              Divider(
                height: 1,
                color: _theme.backgroundColor2,
              ),
              ChatSendBar(
                onMenuPressed: () {
                  _toggleBottomMenu();
                },
              ),
              ChatBottomMenu(show: _showBottomMenu),
            ],
          ),
        ),
      ),
    );
  }
}

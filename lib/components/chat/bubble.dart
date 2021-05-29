import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nmobile/common/locator.dart';
import 'package:nmobile/components/contact/avatar.dart';
import 'package:nmobile/components/text/label.dart';
import 'package:nmobile/components/text/markdown.dart';
import 'package:nmobile/schema/contact.dart';
import 'package:nmobile/schema/message.dart';
import 'package:nmobile/theme/theme.dart';
import 'package:nmobile/utils/format.dart';

enum BubbleStyle { SendSuccess, SendFailed, Received }

class ChatBubble extends StatefulWidget {
  MessageSchema message;
  ContactSchema contact;
  BubbleStyle? style;
  ValueChanged<String>? onChanged;
  ValueChanged<String>? resendMessage;

  ChatBubble({
    required this.message,
    required this.contact,
    this.style,
    this.onChanged,
    this.resendMessage,
  }) {
    if (MessageStatus.get(message) == MessageStatus.SendFail) {
      style = BubbleStyle.SendFailed;
    } else if (message.isOutbound) {
      style = BubbleStyle.SendSuccess;
    } else {
      style = BubbleStyle.Received;
    }
  }

  @override
  _ChatBubbleState createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<ChatBubble> {
  GlobalKey popupMenuKey = GlobalKey();
  late MessageSchema _message;
  late ContactSchema _contact;

  // TODO
  // _textPopupMenuShow() {
  //   PopupMenu popupMenu = PopupMenu(
  //     context: context,
  //     maxColumn: 4,
  //     items: [
  //       MenuItem(
  //         userInfo: 0,
  //         title: S.of(context).copy,
  //         textStyle: TextStyle(color: application.theme.fontLightColor, fontSize: 12),
  //       ),
  //     ],
  //     onClickMenu: (MenuItemProvider item) {
  //       var index = (item as MenuItem).userInfo;
  //       switch (index) {
  //         case 0:
  //           copyText(_message.content, context: context);
  //           break;
  //       }
  //     },
  //   );
  //   popupMenu.show(widgetKey: popupMenuKey);
  // }

  @override
  Widget build(BuildContext context) {
    SkinTheme _theme = application.theme;

    _message = widget.message;
    _contact = widget.contact;

    BoxDecoration decoration;
    Widget timeWidget;
    Widget burnWidget = Container();
    String timeFormat = formatChatTime(_message.sendTime);
    List<Widget> contentsWidget = <Widget>[];
    bool dark = false;
    if (widget.style == BubbleStyle.SendSuccess) {
      decoration = BoxDecoration(
        color: _theme.primaryColor,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(12),
          topRight: const Radius.circular(12),
          bottomLeft: const Radius.circular(12),
          bottomRight: const Radius.circular(2),
        ),
      );
      dark = true;
    } else if (widget.style == BubbleStyle.SendFailed) {
      decoration = BoxDecoration(
        color: _theme.fallColor.withAlpha(178),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(12),
          topRight: const Radius.circular(12),
          bottomLeft: const Radius.circular(12),
          bottomRight: const Radius.circular(2),
        ),
      );
      dark = true;
    } else {
      decoration = BoxDecoration(
        color: _theme.backgroundColor2,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(2),
          topRight: const Radius.circular(12),
          bottomLeft: const Radius.circular(12),
          bottomRight: const Radius.circular(12),
        ),
      );
    }
    switch (_message.contentType) {
      case ContentType.text:
      case ContentType.textExtension:
        contentsWidget.add(
          Markdown(
            data: _message.content,
            dark: dark,
          ),
        );
        break;
      case ContentType.media:
        contentsWidget.add(
          Image.file(_message.content as File),
        );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 12),
      child: Flex(
        direction: Axis.horizontal,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 0,
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              child: ContactAvatar(
                contact: _contact,
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: Label(
                    _contact.getDisplayName,
                    type: LabelType.h3,
                    color: application.theme.primaryColor,
                  ),
                ),
                Container(
                  padding: EdgeInsets.all(10),
                  decoration: decoration,
                  child: Container(
                    constraints: BoxConstraints(maxWidth: 272),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: contentsWidget,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

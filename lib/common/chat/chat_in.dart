import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:nmobile/common/chat/chat_out.dart';
import 'package:nmobile/common/push/badge.dart';
import 'package:nmobile/helpers/file.dart';
import 'package:nmobile/native/common.dart';
import 'package:nmobile/schema/contact.dart';
import 'package:nmobile/schema/device_info.dart';
import 'package:nmobile/schema/message.dart';
import 'package:nmobile/schema/subscriber.dart';
import 'package:nmobile/schema/topic.dart';
import 'package:nmobile/storages/message.dart';
import 'package:nmobile/utils/format.dart';
import 'package:nmobile/utils/logger.dart';
import 'package:nmobile/utils/path.dart';

import '../locator.dart';

class ChatInCommon with Tag {
  // ignore: close_sinks
  StreamController<MessageSchema> _onReceiveController = StreamController<MessageSchema>(); //.broadcast();
  StreamSink<MessageSchema> get _onReceiveSink => _onReceiveController.sink;
  Stream<MessageSchema> get _onReceiveStream => _onReceiveController.stream.distinct((prev, next) => prev.pid == next.pid);

  // ignore: close_sinks
  StreamController<MessageSchema> _onSavedController = StreamController<MessageSchema>.broadcast();
  StreamSink<MessageSchema> get _onSavedSink => _onSavedController.sink;
  Stream<MessageSchema> get onSavedStream => _onSavedController.stream.distinct((prev, next) => prev.pid == next.pid);

  MessageStorage _messageStorage = MessageStorage();

  ChatInCommon() {
    start();
  }

  Future onClientMessage(MessageSchema? message, {bool needWait = false}) async {
    if (message == null) return;
    // topic msg published callback can be used receipt
    if (message.isTopic && !message.isOutbound && (message.from == message.to || message.from == clientCommon.address)) {
      message.contentType = MessageContentType.receipt;
      message.content = message.msgId;
    }
    // message
    if (needWait) {
      await _messageHandle(message);
    } else {
      _onReceiveSink.add(message);
    }
  }

  Future start() async {
    await for (MessageSchema received in _onReceiveStream) {
      await _messageHandle(received);
    }
  }

  Future _messageHandle(MessageSchema received) async {
    // contact
    ContactSchema? contact = await chatCommon.contactHandle(received);
    DeviceInfoSchema? deviceInfo = await chatCommon.deviceInfoHandle(received, contact);
    // topic
    TopicSchema? topic = await chatCommon.topicHandle(received);
    SubscriberSchema? subscriber = await chatCommon.subscriberHandle(received, topic, deviceInfo: deviceInfo);
    if (topic != null && subscriber != null) {
      if (topic.joined != true) {
        logger.w("$TAG - _messageHandle - deny message - topic unsubscribe - subscriber:$subscriber - topic:$topic}");
        return;
      } else if (subscriber.status == SubscriberStatus.Subscribed) {
        logger.v("$TAG - _messageHandle - receive message - subscriber ok permission - subscriber:$subscriber - topic:$topic}");
      } else {
        // SUPPORT:START
        if (!deviceInfoCommon.isTopicPermissionEnable(deviceInfo?.platform, deviceInfo?.appVersion)) {
          if (subscriber.status == SubscriberStatus.None) {
            logger.i("$TAG - _messageHandle - accept message - subscriber ok permission (old version) - subscriber:$subscriber - topic:$topic}");
          } else {
            logger.w("$TAG - _messageHandle - deny message - subscriber no permission (old version) - subscriber:$subscriber - topic:$topic}");
            return;
          }
        } else {
          // SUPPORT:END
          logger.w("$TAG - _messageHandle - deny message - subscriber no permission - subscriber:$subscriber - topic:$topic}");
          return;
        }
      }
    }
    // session
    await chatCommon.sessionHandle(received); // must await
    // message
    bool receiveOk = false;
    switch (received.contentType) {
      case MessageContentType.receipt:
        _receiveReceipt(received); // await
        break;
      case MessageContentType.contact:
        _receiveContact(received, contact: contact); // await
        break;
      case MessageContentType.contactOptions:
        receiveOk = await _receiveContactOptions(received, contact: contact);
        break;
      case MessageContentType.deviceRequest:
        _receiveDeviceRequest(received, contact: contact); // await
        break;
      case MessageContentType.deviceInfo:
        _receiveDeviceInfo(received, contact: contact); // await
        break;
      case MessageContentType.text:
      case MessageContentType.textExtension:
        receiveOk = await _receiveText(received);
        break;
      case MessageContentType.media:
      case MessageContentType.image:
        receiveOk = await _receiveImage(received);
        break;
      case MessageContentType.audio:
        receiveOk = await _receiveAudio(received);
        break;
      case MessageContentType.piece:
        receiveOk = await _receivePiece(received);
        break;
      case MessageContentType.topicSubscribe:
        receiveOk = await _receiveTopicSubscribe(received);
        break;
      case MessageContentType.topicUnsubscribe:
        receiveOk = await _receiveTopicUnsubscribe(received);
        break;
      case MessageContentType.topicInvitation:
        receiveOk = await _receiveTopicInvitation(received);
        break;
      case MessageContentType.topicKickOut:
        receiveOk = await _receiveTopicKickOut(received);
        break;
    }
    if (received.needReceipt) {
      chatOutCommon.sendReceipt(received); // await
    }
    if (received.canDisplayAndRead) {
      // badge
      if (receiveOk && (chatCommon.currentChatTargetId != received.targetId)) {
        Badge.onCountUp(1); // await
      }
    } else {
      // not handle in messages screen
      chatCommon.updateMessageStatus(received, MessageStatus.ReceivedRead); // await
    }
  }

  // NO DB NO display NO topic (1 to 1)
  Future<bool> _receiveReceipt(MessageSchema received) async {
    // if (received.isTopic) return; (limit in out)
    List<MessageSchema> _schemaList = await _messageStorage.queryList(received.content);
    int effectCount = 0;
    _schemaList.forEach((MessageSchema element) {
      if (MessageStatus.get(received) == MessageStatus.SendWithReceipt) {
        logger.d("$TAG - receiveReceipt - duplicated:$element");
        return;
      }
      logger.d("$TAG - receiveReceipt - updated:$element");
      effectCount++;
      chatCommon.updateMessageStatus(element, MessageStatus.SendWithReceipt, notify: true);
    });
    // topicInvitation
    if (_schemaList.length == 1 && _schemaList[0].contentType == MessageContentType.topicInvitation) {
      subscriberCommon.onInvitedReceipt(_schemaList[0].content, received.from); // await
    }
    if (effectCount <= 0) return false;
    return true;
  }

  // NO DB NO display (1 to 1)
  Future<bool> _receiveContact(MessageSchema received, {ContactSchema? contact}) async {
    if (received.content == null) return false;
    Map<String, dynamic> data = received.content; // == data
    // duplicated
    ContactSchema? exist = contact ?? await received.getSender(emptyAdd: true);
    if (exist == null) {
      logger.w("$TAG - receiveContact - empty - data:$data");
      return false;
    }
    // D-Chat NO support piece
    // String? supportPiece = data['onePieceReady']?.toString();
    // if (supportPiece?.isNotEmpty == true) {
    //   contactCommon.setSupportPiece(received.from, value: supportPiece); // await
    // }
    // D-Chat NO RequestType.header
    String? requestType = data['requestType']?.toString();
    String? responseType = data['responseType']?.toString();
    String? version = data['version']?.toString();
    Map<String, dynamic>? content = data['content'];
    if ((requestType?.isNotEmpty == true) || (requestType == null && responseType == null && version == null)) {
      // need reply
      if (requestType == RequestType.header) {
        chatOutCommon.sendContactResponse(exist, RequestType.header); // await
      } else {
        chatOutCommon.sendContactResponse(exist, RequestType.full); // await
      }
    } else {
      // need request/save
      if (!contactCommon.isProfileVersionSame(exist.profileVersion, version)) {
        if (responseType != RequestType.full && content == null) {
          chatOutCommon.sendContactRequest(exist, RequestType.full); // await
        } else {
          if (content == null) {
            logger.w("$TAG - receiveContact - content is empty - data:$data");
            return false;
          }
          String? firstName = content['first_name'] ?? content['name'];
          String? lastName = content['last_name'];
          File? avatar;
          String? avatarType = content['avatar'] != null ? content['avatar']['type'] : null;
          if (avatarType?.isNotEmpty == true) {
            String? avatarData = content['avatar'] != null ? content['avatar']['data'] : null;
            if (avatarData?.isNotEmpty == true) {
              if (avatarData.toString().split(",").length != 1) {
                avatarData = avatarData.toString().split(",")[1];
              }
              avatar = await FileHelper.convertBase64toFile(avatarData, SubDirType.contact, extension: "jpg");
            }
          }
          // if (firstName.isEmpty || lastName.isEmpty || (avatar?.path ?? "").isEmpty) {
          //   logger.i("$TAG - receiveContact - setProfile - NULL");
          // } else {
          contactCommon.setOtherProfile(exist, firstName, lastName, Path.getLocalFile(avatar?.path), version, notify: true); // await
          logger.i("$TAG - receiveContact - setProfile - firstName:$firstName - avatar:${avatar?.path} - version:$version - data:$data");
          // }
        }
      } else {
        logger.d("$TAG - receiveContact - profile version same - contact:$exist - data:$data");
      }
    }
    return true;
  }

  // NO topic (1 to 1)
  Future<bool> _receiveContactOptions(MessageSchema received, {ContactSchema? contact}) async {
    if (received.content == null) return false; // received.isTopic (limit in out)
    Map<String, dynamic> data = received.content; // == data
    // duplicated
    ContactSchema? existContact = contact ?? await received.getSender(emptyAdd: true);
    if (existContact == null) {
      logger.w("$TAG - _receiveContactOptions - empty - received:$received");
      return false;
    }
    List<MessageSchema> existsMsg = await _messageStorage.queryList(received.msgId);
    if (existsMsg.isNotEmpty) {
      logger.d("$TAG - _receiveContactOptions - duplicated - message:$existsMsg");
      return false;
    }
    // options type
    String? optionsType = data['optionType']?.toString();
    Map<String, dynamic> content = data['content'] ?? Map();
    if (optionsType == null || optionsType.isEmpty) return false;
    if (optionsType == '0') {
      int burningSeconds = (content['deleteAfterSeconds'] as int?) ?? 0;
      int updateAt = ((content['updateBurnAfterAt'] ?? content['updateBurnAfterTime']) as int?) ?? DateTime.now().millisecondsSinceEpoch;
      logger.d("$TAG - _receiveContactOptions - setBurn - burningSeconds:$burningSeconds - updateAt:${DateTime.fromMillisecondsSinceEpoch(updateAt)} - data:$data");
      contactCommon.setOptionsBurn(existContact, burningSeconds, updateAt, notify: true); // await
    } else if (optionsType == '1') {
      String deviceToken = (content['deviceToken']?.toString()) ?? "";
      logger.d("$TAG - _receiveContactOptions - setDeviceToken - deviceToken:$deviceToken - data:$data");
      contactCommon.setDeviceToken(existContact.id, deviceToken, notify: true); // await
    } else {
      logger.w("$TAG - _receiveContactOptions - setNothing - data:$data");
      return false;
    }
    // DB
    MessageSchema? inserted = await _messageStorage.insert(received);
    if (inserted == null) return false;
    // display
    _onSavedSink.add(inserted);
    return true;
  }

  // NO DB NO display
  Future<bool> _receiveDeviceRequest(MessageSchema received, {ContactSchema? contact}) async {
    ContactSchema? exist = contact ?? await received.getSender(emptyAdd: true);
    if (exist == null) {
      logger.w("$TAG - _receiveDeviceRequest - contact - empty - data:${received.content}");
      return false;
    }
    chatOutCommon.sendDeviceInfo(exist.clientAddress); // await
    return true;
  }

  // NO DB NO display
  Future<bool> _receiveDeviceInfo(MessageSchema received, {ContactSchema? contact}) async {
    if (received.content == null) return false;
    Map<String, dynamic> data = received.content; // == data
    // duplicated
    ContactSchema? exist = contact ?? await received.getSender(emptyAdd: true);
    if (exist == null || exist.id == null) {
      logger.w("$TAG - _receiveDeviceInfo - contact - empty - received:$received");
      return false;
    }
    DeviceInfoSchema message = DeviceInfoSchema(
      contactAddress: exist.clientAddress,
      deviceId: data["deviceId"],
      data: {
        'appName': data["appName"],
        'appVersion': data["appVersion"],
        'platform': data["platform"],
        'platformVersion': data["platformVersion"],
      },
    );
    logger.d("$TAG - _receiveDeviceInfo - addOrUpdate - message:$message - data:$data");
    deviceInfoCommon.set(message); // await
    return true;
  }

  Future<bool> _receiveText(MessageSchema received) async {
    // deleted
    String key = clientCommon.address ?? "";
    if (chatCommon.deletedCache[key] != null && chatCommon.deletedCache[key]![received.msgId] != null) {
      logger.d("$TAG - receiveText - duplicated - deleted:${received.msgId}");
      return false;
    }
    // duplicated
    List<MessageSchema> exists = await _messageStorage.queryList(received.msgId);
    if (exists.isNotEmpty) {
      logger.d("$TAG - receiveText - duplicated - message:$exists");
      return false;
    }
    // DB
    MessageSchema? inserted = await _messageStorage.insert(received);
    if (inserted == null) return false;
    // display
    _onSavedSink.add(inserted);
    return true;
  }

  Future<bool> _receiveImage(MessageSchema received) async {
    // deleted
    String key = clientCommon.address ?? "";
    if (chatCommon.deletedCache[key] != null && chatCommon.deletedCache[key]![received.msgId] != null) {
      logger.d("$TAG - receiveImage - duplicated - deleted:${received.msgId}");
      return false;
    }
    bool isPieceCombine = received.options != null ? (received.options![MessageOptions.KEY_PARENT_PIECE] ?? false) : false;
    // duplicated
    List<MessageSchema> exists = [];
    if (isPieceCombine) {
      exists = await _messageStorage.queryListByType(received.msgId, received.contentType);
    } else {
      // SUPPORT:START
      exists = await _messageStorage.queryList(received.msgId); // old version will send type nknImage/media/image
      // SUPPORT:END
    }
    if (exists.isNotEmpty) {
      logger.d("$TAG - receiveImage - duplicated - message:$exists");
      return false;
    }
    // File
    received.content = await FileHelper.convertBase64toFile(received.content, SubDirType.chat, extension: isPieceCombine ? "jpg" : null, chatTarget: received.from);
    if (received.content == null) {
      logger.w("$TAG - receiveImage - content is null - message:$exists");
      return false;
    }
    // DB
    MessageSchema? inserted = await _messageStorage.insert(received);
    if (inserted == null) return false;
    // display
    _onSavedSink.add(inserted);
    return true;
  }

  Future<bool> _receiveAudio(MessageSchema received) async {
    // deleted
    String key = clientCommon.address ?? "";
    if (chatCommon.deletedCache[key] != null && chatCommon.deletedCache[key]![received.msgId] != null) {
      logger.d("$TAG - receiveAudio - duplicated - deleted:${received.msgId}");
      return false;
    }
    bool isPieceCombine = received.options != null ? (received.options![MessageOptions.KEY_PARENT_PIECE] ?? false) : false;
    // duplicated
    List<MessageSchema> exists = [];
    if (isPieceCombine) {
      exists = await _messageStorage.queryListByType(received.msgId, received.contentType);
    } else {
      // SUPPORT:START
      exists = await _messageStorage.queryList(received.msgId); // old version will send type 2 times
      // SUPPORT:END
    }
    if (exists.isNotEmpty) {
      logger.d("$TAG - receiveAudio - duplicated - message:$exists");
      return false;
    }
    // File
    received.content = await FileHelper.convertBase64toFile(received.content, SubDirType.chat, extension: isPieceCombine ? "aac" : null, chatTarget: received.from);
    if (received.content == null) {
      logger.w("$TAG - receiveAudio - content is null - message:$exists");
      return false;
    }
    // DB
    MessageSchema? inserted = await _messageStorage.insert(received);
    if (inserted == null) return false;
    // display
    _onSavedSink.add(inserted);
    return true;
  }

  // NO DB NO display
  Future<bool> _receivePiece(MessageSchema received) async {
    // duplicated
    List<MessageSchema> existsCombine = await _messageStorage.queryListByType(received.msgId, received.parentType);
    if (existsCombine.isNotEmpty) {
      logger.d("$TAG - receivePiece - duplicated - message:$existsCombine");
      return false;
    }
    // piece
    MessageSchema? piece = await _messageStorage.queryByPid(received.pid);
    if (piece == null) {
      received.content = await FileHelper.convertBase64toFile(received.content, SubDirType.cache, extension: received.parentType);
      piece = await _messageStorage.insert(received);
    }
    if (piece == null) {
      logger.w("$TAG - receivePiece - piece is null - message:$received");
      return false;
    }
    // pieces
    int total = piece.total ?? ChatOutCommon.maxPiecesTotal;
    int parity = piece.parity ?? (total ~/ ChatOutCommon.piecesParity);
    int bytesLength = piece.bytesLength ?? 0;
    int piecesCount = await _messageStorage.queryCountByType(piece.msgId, piece.contentType);
    logger.v("$TAG - receivePiece - progress:$piecesCount/${piece.total}/${total + parity}");
    if (piecesCount < total || bytesLength <= 0) return false;
    logger.d("$TAG - receivePiece - COMBINE:START - total:$total - parity:$parity - bytesLength:${formatFlowSize(bytesLength.toDouble(), unitArr: ['B', 'KB', 'MB', 'GB'])}");
    List<MessageSchema> pieces = await _messageStorage.queryListByType(piece.msgId, piece.contentType);
    pieces.sort((prev, next) => (prev.index ?? ChatOutCommon.maxPiecesTotal).compareTo((next.index ?? ChatOutCommon.maxPiecesTotal)));
    // recover
    List<Uint8List> recoverList = <Uint8List>[];
    for (int index = 0; index < total + parity; index++) {
      recoverList.add(Uint8List(0)); // fill
    }
    int recoverCount = 0;
    for (int index = 0; index < pieces.length; index++) {
      MessageSchema item = pieces[index];
      File? file = item.content as File?;
      if (file == null || !file.existsSync()) {
        logger.e("$TAG - receivePiece - COMBINE:ERROR - file no exists - item:$item - file:${file?.path}");
        continue;
      }
      Uint8List itemBytes = await file.readAsBytes();
      if (item.index != null && item.index! >= 0 && item.index! < recoverList.length) {
        recoverList[item.index!] = itemBytes;
        recoverCount++;
      }
    }
    if (recoverCount < total) {
      logger.w("$TAG - receivePiece - COMBINE:FAIL - recover_lost:${pieces.length - recoverCount}");
      return false;
    }
    // combine
    String? base64String = await Common.combinePieces(recoverList, total, parity, bytesLength);
    if (base64String == null || base64String.isEmpty) {
      logger.e("$TAG - receivePiece - COMBINE:FAIL - base64String is empty");
      return false;
    }
    MessageSchema combine = MessageSchema.fromPieces(pieces, base64String);
    // combine.content - handle later
    logger.i("$TAG - receivePiece - COMBINE:SUCCESS - combine:$combine");
    await onClientMessage(combine, needWait: true);
    // delete
    logger.d("$TAG - receivePiece - DELETE:START - pieces_count:${pieces.length}");
    bool deleted = await _messageStorage.deleteByType(piece.msgId, piece.contentType);
    if (deleted) {
      pieces.forEach((MessageSchema element) {
        if (element.content is File) {
          if ((element.content as File).existsSync()) {
            (element.content as File).delete(); // await
            // logger.v("$TAG - receivePiece - DELETE:PROGRESS - path:${(element.content as File).path}");
          } else {
            logger.e("$TAG - receivePiece - DELETE:ERROR - NoExists - path:${(element.content as File).path}");
          }
        } else {
          logger.e("$TAG - receivePiece - DELETE:ERROR - empty:${element.content?.toString()}");
        }
      });
      logger.i("$TAG - receivePiece - DELETE:SUCCESS - count:${pieces.length}");
    } else {
      logger.w("$TAG - receivePiece - DELETE:FAIL - empty - pieces:$pieces");
    }
    return true;
  }

  // NO single
  Future<bool> _receiveTopicSubscribe(MessageSchema received) async {
    // duplicated
    List<MessageSchema> exists = await _messageStorage.queryList(received.msgId);
    if (exists.isNotEmpty) {
      logger.d("$TAG - _receiveTopicSubscribe - duplicated - message:$exists");
      return false;
    }
    // subscriber
    SubscriberSchema? _subscriber = await subscriberCommon.queryByTopicChatId(received.topic, received.from);
    bool historySubscribed = _subscriber?.status == SubscriberStatus.Subscribed;
    await topicCommon.onSubscribe(received.topic, received.from); // await
    if (historySubscribed) return false;
    // DB
    MessageSchema? inserted = await _messageStorage.insert(received);
    if (inserted == null) return false;
    // display
    _onSavedSink.add(inserted);
    return true;
  }

  // NO single
  Future<bool> _receiveTopicUnsubscribe(MessageSchema received) async {
    SubscriberSchema? _subscriber = await topicCommon.onUnsubscribe(received.topic, received.from);
    return _subscriber != null;
  }

  // NO topic (1 to 1)
  Future<bool> _receiveTopicInvitation(MessageSchema received) async {
    // duplicated
    List<MessageSchema> exists = await _messageStorage.queryList(received.msgId);
    if (exists.isNotEmpty) {
      logger.d("$TAG - _receiveTopicInvitation - duplicated - message:$exists");
      return false;
    }
    // permission checked in message click
    // DB
    MessageSchema? inserted = await _messageStorage.insert(received);
    if (inserted == null) return false;
    // display
    _onSavedSink.add(inserted);
    return true;
  }

  // NO single
  Future<bool> _receiveTopicKickOut(MessageSchema received) async {
    SubscriberSchema? _subscriber = await topicCommon.onKickOut(received.topic, received.content);
    return _subscriber != null;
  }
}

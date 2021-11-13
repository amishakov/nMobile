import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nmobile/common/global.dart';
import 'package:nmobile/common/locator.dart';
import 'package:nmobile/components/tip/toast.dart';
import 'package:nmobile/generated/l10n.dart';
import 'package:nmobile/helpers/error.dart';
import 'package:nmobile/helpers/validate.dart';
import 'package:nmobile/schema/message.dart';
import 'package:nmobile/schema/subscriber.dart';
import 'package:nmobile/schema/topic.dart';
import 'package:nmobile/storages/topic.dart';
import 'package:nmobile/utils/logger.dart';
import 'package:nmobile/utils/utils.dart';
import 'package:synchronized/synchronized.dart';

class TopicCommon with Tag {
  TopicStorage _topicStorage = TopicStorage();

  // ignore: close_sinks
  StreamController<TopicSchema> _addController = StreamController<TopicSchema>.broadcast();
  StreamSink<TopicSchema> get _addSink => _addController.sink;
  Stream<TopicSchema> get addStream => _addController.stream;

  // ignore: close_sinks
  // StreamController<String> _deleteController = StreamController<String>.broadcast();
  // StreamSink<String> get _deleteSink => _deleteController.sink;
  // Stream<String> get deleteStream => _deleteController.stream;

  // ignore: close_sinks
  StreamController<TopicSchema> _updateController = StreamController<TopicSchema>.broadcast();
  StreamSink<TopicSchema> get _updateSink => _updateController.sink;
  Stream<TopicSchema> get updateStream => _updateController.stream;

  Lock _lock = Lock();

  TopicCommon();

  /// ***********************************************************************************************************
  /// ************************************************* check ***************************************************
  /// ***********************************************************************************************************

  Future checkAllTopics({bool refreshSubscribers = true, bool enablePublic = true, bool enablePrivate = true, int? delayMs}) async {
    if (!clientCommon.isClientCreated || clientCommon.clientClosing) return;
    if (application.inBackGroundLater && Platform.isIOS) return;
    if (delayMs != null) await await Future.delayed(Duration(milliseconds: delayMs));

    await _lock.synchronized(() async {
      int limit = 20;
      List<TopicSchema> topics = [];
      for (int offset = 0; true; offset += limit) {
        List<TopicSchema> result = await queryList(offset: offset, limit: limit);
        topics.addAll(result);
        if (result.length < limit) break;
      }
      if (refreshSubscribers) {
        for (var i = 0; i < topics.length; i++) {
          TopicSchema topic = topics[i];
          bool check = (!topic.isPrivate && enablePublic) || (topic.isPrivate && enablePrivate);
          if (check) await checkExpireAndSubscribe(topic.topic, refreshSubscribers: refreshSubscribers && topic.joined);
        }
      } else {
        List<Future> futures = [];
        topics.forEach((TopicSchema topic) {
          bool check = (!topic.isPrivate && enablePublic) || (topic.isPrivate && enablePrivate);
          if (check) futures.add(checkExpireAndSubscribe(topic.topic, refreshSubscribers: refreshSubscribers && topic.joined));
        });
        await Future.wait(futures);
      }
    });
  }

  Future checkAndTryAllSubscribe({int? delayMs, bool txPool = true}) async {
    if (!clientCommon.isClientCreated || clientCommon.clientClosing) return;
    if (application.inBackGroundLater && Platform.isIOS) return;
    if (delayMs != null) await await Future.delayed(Duration(milliseconds: delayMs));

    await _lock.synchronized(() async {
      int max = 10;
      int limit = 20;
      List<TopicSchema> topicsWithSubscribe = [];
      List<TopicSchema> topicsWithUnSubscribe = [];

      // query
      for (int offset = 0; true; offset += limit) {
        List<TopicSchema> result = await queryList(offset: offset, limit: limit);
        result.forEach((element) {
          if (element.isSubscribeProgress()) {
            logger.i("$TAG - checkAndTryAllSubscribe - topic is subscribe progress - topic:$element");
            topicsWithSubscribe.add(element);
          } else if (element.isUnSubscribeProgress()) {
            logger.i("$TAG - checkAndTryAllSubscribe - topic is unsubscribe progress - topic:$element");
            topicsWithUnSubscribe.add(element);
          } else {
            logger.v("$TAG - checkAndTryAllSubscribe - topic is over - topic:$element");
          }
        });
        if ((result.length < limit) || ((topicsWithSubscribe.length + topicsWithUnSubscribe.length) >= max)) break;
      }
      // check + try
      for (var i = 0; i < topicsWithSubscribe.length; i++) {
        TopicSchema topic = topicsWithSubscribe[i];
        await checkAndTrySubscribe(topic, true);
      }
      for (var i = 0; i < topicsWithUnSubscribe.length; i++) {
        TopicSchema topic = topicsWithUnSubscribe[i];
        await checkAndTrySubscribe(topic, false);
      }
    });
  }

  Future checkAndTrySubscribe(TopicSchema? topic, bool subscribed, {int? delayMs}) async {
    if (topic == null || !clientCommon.isClientCreated || clientCommon.clientClosing) return;
    if (application.inBackGroundLater && Platform.isIOS) return;
    if (delayMs != null) await await Future.delayed(Duration(milliseconds: delayMs));

    int expireHeight = await getExpireAtByNode(topic.topic, clientCommon.address);
    if (subscribed) {
      if (expireHeight <= 0) {
        logger.i("$TAG - checkAndTrySubscribe - topic try subscribe - trySubscribe:$subscribed - topic:$topic");
        final result = await checkExpireAndSubscribe(topic.topic, enableFirst: true, forceSubscribe: true, refreshSubscribers: false, toast: false);
        if (result != null) await subscriberCommon.onSubscribe(topic.topic, clientCommon.address, null);
      } else {
        logger.i("$TAG - checkAndTrySubscribe - topic subscribe OK - topic:$topic");
        Map<String, dynamic> newData = topic.getDataByAppendSubscribe(true, false);
        await setData(topic.id, newData, notify: true);
      }
    } else {
      if (expireHeight >= 0) {
        logger.i("$TAG - checkAndTrySubscribe - topic try unsubscribe - trySubscribe:$subscribed - topic:$topic");
        await unsubscribe(topic.topic);
      } else {
        logger.i("$TAG - checkAndTrySubscribe - topic unsubscribe OK - topic:$topic");
        Map<String, dynamic> newData = topic.getDataByAppendSubscribe(false, false);
        await setData(topic.id, newData, notify: true);
      }
    }
  }

  Future checkAndTryAllPermission({int? delayMs}) async {
    if (!clientCommon.isClientCreated || clientCommon.clientClosing) return;
    if (application.inBackGroundLater && Platform.isIOS) return;
    if (delayMs != null) await await Future.delayed(Duration(milliseconds: delayMs));

    await _lock.synchronized(() async {
      int topicMax = 10;
      int subscriberMax = 20;
      int limit = 20;
      List<TopicSchema> topics = [];
      List<SubscriberSchema> subscribers = [];

      // query
      for (int offset = 0; true; offset += limit) {
        List<TopicSchema> result = await queryList(topicType: TopicType.privateTopic, offset: offset, limit: limit);
        result.forEach((element) {
          if (element.isOwner(clientCommon.address)) {
            topics.add(element);
          }
        });
        if ((result.length < limit) || (topics.length >= topicMax)) break;
      }
      for (var i = 0; i < topics.length; i++) {
        TopicSchema topic = topics[i];
        for (int offset = 0; true; offset += limit) {
          List<SubscriberSchema> result = await subscriberCommon.queryListByTopic(topic.topic, offset: offset, limit: limit);
          result.forEach((element) {
            if (element.isPermissionProgress() != null) {
              logger.i("$TAG - checkAndTryAllPermission - topic permission progress - topic:$topic");
              subscribers.add(element);
            }
          });
          if ((result.length < limit) || (subscribers.length >= subscriberMax)) break;
        }
        if (subscribers.length >= subscriberMax) break;
      }
      // check + try
      for (var i = 0; i < subscribers.length; i++) {
        SubscriberSchema subscribe = subscribers[i];
        int? progressStatus = subscribe.isPermissionProgress();
        await checkAndTryPermission(subscribe, progressStatus);
      }
    });
  }

  Future checkAndTryPermission(SubscriberSchema? subscriber, int? status, {int? delayMs, bool txPool = true}) async {
    if (subscriber == null || status == null || !clientCommon.isClientCreated || clientCommon.clientClosing) return;
    if (application.inBackGroundLater && Platform.isIOS) return;
    if (delayMs != null) await await Future.delayed(Duration(milliseconds: delayMs));

    bool needAccept = (status == SubscriberStatus.InvitedSend) || (status == SubscriberStatus.InvitedReceipt) || (status == SubscriberStatus.Subscribed);
    bool needReject = status == SubscriberStatus.Unsubscribed;
    bool needNoPermission = status == SubscriberStatus.None;

    List<dynamic> permission = await subscriberCommon.findPermissionFromNode(subscriber.topic, true, subscriber.clientAddress, txPool: txPool);
    // int? permPage = permission[0];
    // bool? acceptAll = permission[1];
    bool? isAccept = permission[2];
    bool? isReject = permission[3];
    if (needAccept) {
      if (isAccept == true) {
        logger.i("$TAG - checkAndTryPermission - subscriber permission(accept) OK - subscribe:$subscribe");
        Map<String, dynamic> newData = subscriber.getDataByAppendStatus(status, false);
        await subscriberCommon.setData(subscriber.id, newData, notify: true);
      } else {
        logger.i("$TAG - checkAndTryPermission - subscriber try invitee - tryStatus:$status - subscribe:$subscribe");
        await invitee(subscriber.topic, true, true, subscriber.clientAddress);
      }
    } else if (needReject) {
      if (isReject == true) {
        logger.i("$TAG - checkAndTryPermission - subscriber permission(reject) OK - subscribe:$subscribe");
        Map<String, dynamic> newData = subscriber.getDataByAppendStatus(status, false);
        await subscriberCommon.setData(subscriber.id, newData, notify: true);
      } else {
        logger.i("$TAG - checkAndTryPermission - subscriber try kick - tryStatus:$status - subscribe:$subscribe");
        await kick(subscriber.topic, true, true, subscriber.clientAddress);
      }
    } else if (needNoPermission) {
      if (isAccept != true && isReject != true) {
        logger.i("$TAG - checkAndTryPermission - subscriber permission(none) OK - subscribe:$subscribe");
        Map<String, dynamic> newData = subscriber.getDataByAppendStatus(status, false);
        await subscriberCommon.setData(subscriber.id, newData, notify: true);
      } else {
        logger.i("$TAG - checkAndTryPermission - subscriber try kick - tryStatus:$status - subscribe:$subscribe");
        await onUnsubscribe(subscriber.topic, subscriber.clientAddress);
      }
    } else {
      logger.w("$TAG - checkAndTryPermission - subscriber permission none - tryStatus:$status - subscribe:$subscribe");
      Map<String, dynamic> newData = subscriber.getDataByAppendStatus(status, false);
      await subscriberCommon.setData(subscriber.id, newData, notify: true);
    }
  }

  /// ***********************************************************************************************************
  /// *********************************************** subscribe *************************************************
  /// ***********************************************************************************************************

  // caller = self(owner/normal)
  Future<TopicSchema?> subscribe(String? topic, {bool fetchSubscribers = false, bool justNow = false, double fee = 0}) async {
    if (topic == null || topic.isEmpty || !clientCommon.isClientCreated || clientCommon.clientClosing) return null;

    // topic exist
    TopicSchema? exists = await queryByTopic(topic);
    if (exists == null) {
      int expireHeight = await getExpireAtByNode(topic, clientCommon.address);
      exists = await add(TopicSchema.create(topic, expireHeight: expireHeight), notify: true, checkDuplicated: false);
      logger.d("$TAG - subscribe - new - expireHeight:$expireHeight - schema:$exists");
      // refreshSubscribers later
    }
    if (exists == null) {
      logger.w("$TAG - subscribe - null - topic:$topic");
      return null;
    }

    // permission(private + normal)
    int? permPage;
    if (exists.isPrivate && !exists.isOwner(clientCommon.address)) {
      List<dynamic> permission = await subscriberCommon.findPermissionFromNode(topic, exists.isPrivate, clientCommon.address);
      permPage = permission[0];
      bool? acceptAll = permission[1];
      bool? isAccept = permission[2];
      bool? isReject = permission[3];
      if ((acceptAll != true)) {
        if (isReject == true) {
          if (justNow) {
            Toast.show(S.of(Global.appContext).no_permission_join_group);
          } else {
            Toast.show(S.of(Global.appContext).removed_group_tip);
          }
          return null;
        } else if (isAccept != true) {
          if (justNow) {
            Toast.show(S.of(Global.appContext).no_permission_join_group);
          } else {
            Toast.show(S.of(Global.appContext).contact_invite_group_tip);
          }
          return null;
        } else {
          logger.d("$TAG - subscribe - is_accept ok - schema:$exists");
        }
      } else {
        logger.d("$TAG - subscribe - accept all - schema:$exists");
      }
    }

    // check expire + pull subscribers
    exists = await checkExpireAndSubscribe(topic, enableFirst: true, forceSubscribe: true, refreshSubscribers: fetchSubscribers, fee: fee, toast: true);
    if (exists == null) return null;
    await Future.delayed(Duration(milliseconds: 250));

    // SUPPORT:START
    // status + permission
    if (exists.isPrivate && exists.isOwner(clientCommon.address)) {
      SubscriberSchema? _subscriberMe = await subscriberCommon.onSubscribe(topic, clientCommon.address, 0);
      Map<String, dynamic> meta = await _getMetaByNodePage(topic, 0);
      meta = await _buildMetaByAppend(topic, meta, _subscriberMe);
      await _clientSubscribe(topic, fee: fee, permissionPage: 0, meta: meta, clientAddress: clientCommon.address, status: SubscriberStatus.Subscribed);
    } else {
      await subscriberCommon.onSubscribe(topic, clientCommon.address, permPage);
    }
    // SUPPORT:END
    // FUTURE:START
    // await subscriberCommon.onSubscribe(topic, clientCommon.address, permPage);
    // FUTURE:END
    await Future.delayed(Duration(milliseconds: 250));

    // send messages
    await chatOutCommon.sendTopicSubscribe(topic);
    await setCount(exists.id, (exists.count ?? 0) + 1, notify: true);
    // subscribersInfo
    subscriberCommon.fetchSubscribersInfo(topic); // await
    return exists;
  }

  // caller = self(owner/normal)
  Future<TopicSchema?> checkExpireAndSubscribe(
    String? topic, {
    bool refreshSubscribers = false,
    bool forceSubscribe = false,
    bool enableFirst = false,
    double fee = 0,
    int tryCount = 1,
    bool toast = false,
  }) async {
    if (topic == null || topic.isEmpty || !clientCommon.isClientCreated || clientCommon.clientClosing) return null;

    // topic exist
    TopicSchema? exists = await queryByTopic(topic);
    if (exists == null) {
      logger.w("$TAG - checkExpireAndSubscribe - null - topic:$topic");
      return null;
    }

    // check expire
    bool noSubscribed;
    int expireHeight = await getExpireAtByNode(exists.topic, clientCommon.address);
    if (!exists.joined || exists.subscribeAt == null || exists.subscribeAt! <= 0 || exists.expireBlockHeight == null || exists.expireBlockHeight! <= 0) {
      if (expireHeight > 0) {
        // DB no joined + node is joined
        noSubscribed = false;
        int createAt = exists.createAt ?? DateTime.now().millisecondsSinceEpoch;
        if ((DateTime.now().millisecondsSinceEpoch - createAt) > Global.txPoolDelayMs) {
          logger.d("$TAG - checkExpireAndSubscribe - DB expire but node not expire - topic:$exists");
          int subscribeAt = exists.subscribeAt ?? DateTime.now().millisecondsSinceEpoch;
          bool success = await setJoined(exists.id, true, subscribeAt: subscribeAt, expireBlockHeight: expireHeight, notify: true);
          if (success) {
            exists.joined = true;
            exists.subscribeAt = subscribeAt;
            exists.expireBlockHeight = expireHeight;
          }
        } else {
          var betweenS = (DateTime.now().millisecondsSinceEpoch - createAt) / 1000;
          logger.i("$TAG - checkExpireAndSubscribe - DB expire but node not expire, maybe in txPool, just return - between:${betweenS}s - topic:$exists");
        }
      } else {
        // DB no joined + node no joined
        noSubscribed = true;
        logger.i("$TAG - checkExpireAndSubscribe - no subscribe history - topic:$exists");
      }
    } else {
      if (expireHeight <= 0) {
        // DB is joined + node no joined
        noSubscribed = true;
        int createAt = exists.createAt ?? DateTime.now().millisecondsSinceEpoch;
        if (exists.joined && (DateTime.now().millisecondsSinceEpoch - createAt) > Global.txPoolDelayMs) {
          logger.i("$TAG - checkExpireAndSubscribe - DB no expire but node expire - topic:$exists");
          bool success = await setJoined(exists.id, false, notify: true);
          if (success) {
            exists.joined = false;
            exists.subscribeAt = 0;
            exists.expireBlockHeight = 0;
          }
        } else {
          var betweenS = (DateTime.now().millisecondsSinceEpoch - createAt) / 1000;
          logger.i("$TAG - checkExpireAndSubscribe - DB not expire but node expire, maybe in txPool, just run - between:${betweenS}s - topic:$exists");
        }
      } else {
        // DB is joined + node is joined
        logger.d("$TAG - checkExpireAndSubscribe - OK OK OK OK OK - topic:$exists");
        noSubscribed = false;
      }
    }

    // subscribe
    int? globalHeight;
    try {
      if (clientCommon.isClientCreated && !clientCommon.clientClosing) {
        globalHeight = await clientCommon.client?.getHeight();
      }
    } catch (e) {
      handleError(e);
    }
    bool shouldResubscribe = await exists.shouldResubscribe(globalHeight: globalHeight);
    if (forceSubscribe || (noSubscribed && enableFirst) || (exists.joined && shouldResubscribe)) {
      // client subscribe
      bool subscribeSuccess = await _clientSubscribe(topic, fee: fee, toast: toast, clientAddress: clientCommon.address, status: SubscriberStatus.Subscribed);
      if (!subscribeSuccess) {
        if ((tryCount >= 5) || toast) {
          logger.e("$TAG - checkExpireAndSubscribe - _clientSubscribe fail - topic:$exists");
          return null;
        }
        logger.w("$TAG - checkExpireAndSubscribe - _clientSubscribe fail - tryCount:$tryCount - topic:$exists");
        await Future.delayed(Duration(seconds: 2));
        return checkExpireAndSubscribe(topic, refreshSubscribers: refreshSubscribers, forceSubscribe: forceSubscribe, enableFirst: enableFirst, fee: fee, tryCount: ++tryCount, toast: toast);
      }

      // db update
      var subscribeAt = exists.subscribeAt ?? DateTime.now().millisecondsSinceEpoch;
      var expireHeight = (globalHeight ?? exists.expireBlockHeight ?? 0) + Global.topicDefaultSubscribeHeight;
      bool setSuccess = await setJoined(exists.id, true, subscribeAt: subscribeAt, expireBlockHeight: expireHeight, notify: true);
      if (setSuccess) {
        exists.joined = true;
        exists.subscribeAt = subscribeAt;
        exists.expireBlockHeight = expireHeight;
      }
      logger.i("$TAG - checkExpireAndSubscribe - _clientSubscribe success - topic:$exists");
    } else {
      logger.d("$TAG - checkExpireAndSubscribe - _clientSubscribe no need subscribe - topic:$exists");
    }
    // subscribers
    if (refreshSubscribers) {
      await subscriberCommon.refreshSubscribers(topic, ownerPubKey: exists.ownerPubKey, meta: exists.isPrivate);
    }
    return exists;
  }

  // publish(meta = null) / private(meta != null)(owner_create / invitee / kick)
  Future<bool> _clientSubscribe(
    String? topic, {
    double fee = 0,
    int? permissionPage,
    Map<String, dynamic>? meta,
    int? nonce,
    int tryCount = 1,
    bool toast = false,
    String? clientAddress,
    int? status,
  }) async {
    if (topic == null || topic.isEmpty) return false;
    String identifier = permissionPage != null ? '__${permissionPage}__.__permission__' : "";
    String metaString = (meta?.isNotEmpty == true) ? jsonEncode(meta) : "";
    nonce = nonce ?? await Global.getNonce();

    bool success;
    try {
      if (clientCommon.isClientCreated && !clientCommon.clientClosing) {
        String? topicHash = await clientCommon.client?.subscribe(
          topic: genTopicHash(topic),
          duration: Global.topicDefaultSubscribeHeight,
          fee: fee.toString(),
          identifier: identifier,
          meta: metaString,
          nonce: nonce,
        );
        if (topicHash != null && topicHash.isNotEmpty) {
          logger.d("$TAG - _clientSubscribe - success - topic:$topic - nonce:$nonce - topicHash:$topicHash - identifier:$identifier - metaString:$metaString");
        } else {
          logger.e("$TAG - _clientSubscribe - fail - topic:$topic - nonce:$nonce - identifier:$identifier - metaString:$metaString");
        }
        success = (topicHash != null) && (topicHash.isNotEmpty);
      } else {
        success = false;
      }
    } catch (e) {
      if (e.toString().contains("nonce is not continuous")) {
        // can not append tx to txpool: nonce is not continuous
        if (tryCount >= 3) {
          logger.w("$TAG - _clientSubscribe - try over by nonce is not continuous - topic:$topic - nonce:$nonce - identifier:$identifier - metaString:$metaString");
          if (toast && identifier.isEmpty) Toast.show(S.of(Global.appContext).something_went_wrong);
          success = identifier.isNotEmpty;
        } else {
          int? nonce = await Global.getNonce(forceFetch: true);
          return _clientSubscribe(topic, fee: fee, permissionPage: permissionPage, meta: meta, nonce: nonce, tryCount: ++tryCount, toast: toast, clientAddress: clientAddress, status: status);
        }
      } else {
        await Global.refreshNonce();
        if (e.toString().contains('duplicate subscription exist in block')) {
          // can not append tx to txpool: duplicate subscription exist in block
          logger.i("$TAG - _clientSubscribe - duplicated - topic:$topic - nonce:$nonce - identifier:$identifier - metaString:$metaString");
          if (toast && identifier.isEmpty) Toast.show(S.of(Global.appContext).request_processed);
        } else {
          handleError(e);
        }
        success = identifier.isNotEmpty; // permission action can add to try timer
      }
    }
    // data
    if (success) {
      if (identifier.isNotEmpty) {
        subscriberCommon.queryByTopicChatId(topic, clientAddress).then((value) async {
          if (value != null && status != null) {
            Map<String, dynamic> newData = value.getDataByAppendStatus(status, true);
            logger.i("$TAG - _clientSubscribe - add permission try - topic:$topic - clientAddress:$clientAddress - newData:$newData - nonce:$nonce - identifier:$identifier - metaString:$metaString");
            subscriberCommon.setData(value.id, newData); // await
          } else {
            logger.w("$TAG - _clientSubscribe - add permission try at null - topic:$topic - clientAddress:$clientAddress - nonce:$nonce - identifier:$identifier - metaString:$metaString");
          }
        });
      } else {
        queryByTopic(topic).then((value) {
          Map<String, dynamic> newData = value?.getDataByAppendSubscribe(true, true) ?? Map();
          logger.i("$TAG - _clientSubscribe - add subscribe try - topic:$topic - clientAddress:$clientAddress - newData:$newData - nonce:$nonce - identifier:$identifier - metaString:$metaString");
          setData(value?.id, newData); // await
        });
      }
    }
    return success;
  }

  /// ***********************************************************************************************************
  /// ********************************************** unsubscribe ************************************************
  /// ***********************************************************************************************************

  // caller = self
  Future<TopicSchema?> unsubscribe(String? topic, {double fee = 0, bool toast = false}) async {
    if (topic == null || topic.isEmpty || !clientCommon.isClientCreated || clientCommon.clientClosing) return null;
    // permission modify in owners message received by owner

    // client unsubscribe
    bool exitSuccess = await _clientUnsubscribe(topic, fee: fee, toast: toast);
    if (!exitSuccess) return null;
    await Future.delayed(Duration(milliseconds: 250));

    // topic update
    TopicSchema? exists = await queryByTopic(topic);
    bool setSuccess = await setJoined(exists?.id, false, notify: true);
    if (setSuccess) {
      exists?.joined = false;
      exists?.subscribeAt = 0;
      exists?.expireBlockHeight = 0;
    }
    // setSuccess = await setCount(exists?.id, (exists?.count ?? 1) - 1, notify: true);
    // if (setSuccess) exists?.count = (exists.count ?? 1) - 1;

    // DB(topic+subscriber) delete
    await subscriberCommon.onUnsubscribe(topic, clientCommon.address);
    // await subscriberCommon.deleteByTopic(topic); // stay is useful
    // await delete(exists?.id, notify: true); // replace by setJoined

    // send message
    await chatOutCommon.sendTopicUnSubscribe(topic);
    await Future.delayed(Duration(milliseconds: 250));
    return exists;
  }

  Future<bool> _clientUnsubscribe(String? topic, {double fee = 0, int? nonce, int tryCount = 1, bool toast = false}) async {
    if (topic == null || topic.isEmpty) return false;
    // String identifier = permissionPage != null ? '__${permissionPage}__.__permission__' : "";
    nonce = nonce ?? await Global.getNonce();

    bool success;
    try {
      if (clientCommon.isClientCreated && !clientCommon.clientClosing) {
        String? topicHash = await clientCommon.client?.unsubscribe(
          topic: genTopicHash(topic),
          identifier: "", // no used (maybe will be used by owner later)
          fee: fee.toString(),
          nonce: nonce,
        );
        if (topicHash != null && topicHash.isNotEmpty) {
          logger.d("$TAG - _clientUnsubscribe - success - topic:$topic - nonce:$nonce - topicHash:$topicHash");
        } else {
          logger.e("$TAG - _clientUnsubscribe - fail - topic:$topic - nonce:$nonce - topicHash:$topicHash");
        }
        success = (topicHash != null) && (topicHash.isNotEmpty);
      } else {
        success = false;
      }
    } catch (e) {
      if (e.toString().contains("nonce is not continuous")) {
        // can not append tx to txpool: nonce is not continuous
        if (tryCount >= 3) {
          logger.w("$TAG - _clientUnsubscribe - try over by nonce is not continuous - topic:$topic - nonce:$nonce");
          if (toast) Toast.show(S.of(Global.appContext).something_went_wrong);
          success = false;
        } else {
          int? nonce = await Global.getNonce(forceFetch: true);
          return _clientUnsubscribe(topic, fee: fee, nonce: nonce, tryCount: ++tryCount, toast: toast);
        }
      } else {
        await Global.refreshNonce();
        if (e.toString().contains('duplicate subscription exist in block')) {
          // can not append tx to txpool: duplicate subscription exist in block
          logger.w("$TAG - _clientUnsubscribe - duplicated - topic:$topic - nonce:$nonce");
          if (toast) Toast.show(S.of(Global.appContext).request_processed);
        } else {
          handleError(e);
        }
        success = false;
      }
    }
    // data
    if (success) {
      queryByTopic(topic).then((value) {
        Map<String, dynamic> newData = value?.getDataByAppendSubscribe(false, true) ?? Map();
        logger.i("$TAG - _clientUnsubscribe - add unsubscribe try - topic:$topic - newData:$newData - nonce:$nonce");
        setData(value?.id, newData); // await
      });
    }
    return success;
  }

  /// ***********************************************************************************************************
  /// ********************************************** subscription ***********************************************
  /// ***********************************************************************************************************

  // caller = everyone
  Future<bool> isSubscribed(String? topic, String? clientAddress, {int? globalHeight}) async {
    if (topic == null || topic.isEmpty) return false;
    TopicSchema? exists = await queryByTopic(topic);
    int createAt = exists?.createAt ?? DateTime.now().millisecondsSinceEpoch;
    if (exists != null && (DateTime.now().millisecondsSinceEpoch - createAt) < Global.txPoolDelayMs) {
      logger.i("$TAG - isJoined - createAt just now, maybe in txPool - topic:$topic - clientAddress:$clientAddress");
      return exists.joined; // maybe in txPool
    }
    int expireHeight = await getExpireAtByNode(exists?.topic, clientAddress);
    if (expireHeight <= 0) {
      logger.i("$TAG - isJoined - expireHeight <= 0 - topic:$topic - clientAddress:$clientAddress");
      return false;
    }
    try {
      if (clientCommon.isClientCreated && !clientCommon.clientClosing) {
        globalHeight = globalHeight ?? await clientCommon.client?.getHeight();
      }
    } catch (e) {
      handleError(e);
    }
    if (globalHeight == null || globalHeight <= 0) {
      logger.w("$TAG - isJoined - globalHeight <= 0 - topic:$topic");
      return false;
    }
    return expireHeight >= globalHeight;
  }

  Future<int> getExpireAtByNode(String? topic, String? clientAddress) async {
    if (topic == null || topic.isEmpty || clientAddress == null || clientAddress.isEmpty) return 0;
    String? pubKey = getPubKeyFromTopicOrChatId(clientAddress);
    Map<String, dynamic> result = await _clientGetSubscription(topic, pubKey);
    String? expiresAt = result['expiresAt']?.toString() ?? "0";
    return int.tryParse(expiresAt) ?? 0;
  }

  Future<Map<String, dynamic>> _getMetaByNodePage(String? topic, int permPage) async {
    if (topic == null || topic.isEmpty) return Map();
    String? ownerPubKey = getPubKeyFromTopicOrChatId(topic);
    String indexWithPubKey = '__${permPage}__.__permission__.$ownerPubKey';
    Map<String, dynamic> result = await _clientGetSubscription(topic, indexWithPubKey);
    if (result['meta']?.toString().isNotEmpty == true) {
      Map<String, dynamic> meta = jsonFormat(result['meta']) ?? Map();
      logger.d("$TAG - _getMetaByNodePage - meta:$meta");
      return meta;
    }
    logger.d("$TAG - _getMetaByNodePage - meta is null");
    return Map();
  }

  Future<Map<String, dynamic>> _clientGetSubscription(String? topic, String? subscriber, {int tryCount = 0}) async {
    if (topic == null || topic.isEmpty || subscriber == null || subscriber.isEmpty) return Map();
    try {
      if (clientCommon.isClientCreated && !clientCommon.clientClosing) {
        Map<String, dynamic>? result = await clientCommon.client?.getSubscription(
          topic: genTopicHash(topic),
          subscriber: subscriber,
        );
        if (result?.isNotEmpty == true) {
          logger.d("$TAG - _clientGetSubscription - success - topic:$topic - subscriber:$subscriber - result:$result");
        } else {
          logger.w("$TAG - _clientGetSubscription - fail - topic:$topic - subscriber:$subscriber");
        }
        return result ?? Map();
      } else {
        logger.w("$TAG - _clientGetSubscription - retry - tryCount:$tryCount - topic:$topic - subscriber:$subscriber");
        if (tryCount >= 5) Map();
        await Future.delayed(Duration(seconds: 2));
        return _clientGetSubscription(topic, subscriber, tryCount: ++tryCount);
      }
    } catch (e) {
      handleError(e);
      return Map();
    }
  }

  /// ***********************************************************************************************************
  /// ************************************************ action ***************************************************
  /// ***********************************************************************************************************

  // caller = everyone
  Future<SubscriberSchema?> invitee(String? topic, bool isPrivate, bool isOwner, String? clientAddress, {bool toast = false, bool sendMsg = false}) async {
    if (topic == null || topic.isEmpty || clientAddress == null || clientAddress.isEmpty || !clientCommon.isClientCreated || clientCommon.clientClosing) return null;
    if (clientAddress == clientCommon.address) {
      if (toast) Toast.show(S.of(Global.appContext).invite_yourself_error);
      return null;
    }
    if (isPrivate && !isOwner) {
      if (toast) Toast.show(S.of(Global.appContext).member_no_auth_invite);
      return null;
    }

    // check status
    SubscriberSchema? _subscriber = await subscriberCommon.queryByTopicChatId(topic, clientAddress);
    if (_subscriber != null && _subscriber.status == SubscriberStatus.Subscribed) {
      if (toast) Toast.show(S.of(Global.appContext).group_member_already);
      return null;
    }
    bool isOldStatusInvitedReceived = _subscriber?.status == SubscriberStatus.InvitedReceipt;

    // if (isPrivate && toast) Toast.show(S.of(Global.appContext).inviting);

    // check permission
    int? appendPermPage;
    if (isPrivate) {
      List<dynamic> permission = await subscriberCommon.findPermissionFromNode(topic, isPrivate, clientAddress);
      appendPermPage = permission[0] ?? (await subscriberCommon.queryMaxPermPageByTopic(topic));
      bool? acceptAll = permission[1];
      bool? isReject = permission[3];

      // just owner can invitee reject item
      if (!isOwner && (acceptAll != true) && (isReject == true)) {
        if (toast) Toast.show(S.of(Global.appContext).blocked_user_disallow_invite);
        return null;
      }

      // update DB
      _subscriber = await subscriberCommon.onInvitedSend(topic, clientAddress, appendPermPage);

      // update meta (private + owner + no_accept_all)
      if (isOwner && (acceptAll != true) && (appendPermPage != null)) {
        Map<String, dynamic> meta = await _getMetaByNodePage(topic, appendPermPage);
        meta = await _buildMetaByAppend(topic, meta, _subscriber);
        bool subscribeSuccess = await _clientSubscribe(topic, fee: 0, permissionPage: appendPermPage, meta: meta, toast: toast, clientAddress: clientAddress, status: SubscriberStatus.InvitedSend);
        if (!subscribeSuccess) {
          logger.w("$TAG - invitee - clientSubscribe error - permPage:$appendPermPage - meta:$meta");
          return null;
        }
      }
    } else {
      // update DB
      _subscriber = await subscriberCommon.onInvitedSend(topic, clientAddress, null);
    }

    // send message
    if (sendMsg) {
      MessageSchema? _msg = await chatOutCommon.sendTopicInvitee(clientAddress, topic);
      if (_msg == null) {
        if (toast) Toast.show(S.of(Global.appContext).failure);
        return null;
      }
    } else if (isOldStatusInvitedReceived) {
      await subscriberCommon.setStatus(_subscriber?.id, SubscriberStatus.InvitedReceipt, notify: true);
    }
    if (toast) Toast.show(S.of(Global.appContext).invitation_sent);
    return _subscriber;
  }

  // caller = private + owner
  Future<SubscriberSchema?> kick(String? topic, bool isPrivate, bool isOwner, String? clientAddress, {bool toast = false}) async {
    if (topic == null || topic.isEmpty || clientAddress == null || clientAddress.isEmpty || !clientCommon.isClientCreated || clientCommon.clientClosing) return null;
    if (clientAddress == clientCommon.address) return null;
    if (!isPrivate || !isOwner) return null; // enable just private + owner

    // check status
    SubscriberSchema? _subscriber = await subscriberCommon.queryByTopicChatId(topic, clientAddress);
    if (_subscriber == null) return null;
    if (_subscriber.canBeKick == false) return null; // checked in UI

    // check permission
    List<dynamic> permission = await subscriberCommon.findPermissionFromNode(topic, isPrivate, clientAddress);
    int? permPage = permission[0] ?? _subscriber.permPage;
    bool? acceptAll = permission[1];
    if (permPage == null) {
      if (toast) Toast.show(S.of(Global.appContext).failure);
      return null;
    }

    // update DB
    _subscriber = await subscriberCommon.onKickOut(topic, clientAddress, permPage: permPage);

    // update meta (private + owner + no_accept_all)
    if (acceptAll != true) {
      Map<String, dynamic> meta = await _getMetaByNodePage(topic, permPage);
      meta = await _buildMetaByAppend(topic, meta, _subscriber);
      bool subscribeSuccess = await _clientSubscribe(topic, permissionPage: permPage, meta: meta, toast: toast, clientAddress: clientAddress, status: SubscriberStatus.Unsubscribed);
      if (!subscribeSuccess) {
        logger.w("$TAG - kick - clientSubscribe error - permPage:$permPage - meta:$meta");
        return null;
      }
    }

    // send message
    await chatOutCommon.sendTopicKickOut(topic, clientAddress);
    if (toast) Toast.show(S.of(Global.appContext).rejected);
    return _subscriber;
  }

  Future<Map<String, dynamic>> _buildMetaByAppend(String? topic, Map<String, dynamic> meta, SubscriberSchema? append) async {
    if (topic == null || topic.isEmpty || append == null) return Map();
    // permPage
    if ((append.permPage ?? -1) <= 0) {
      append.permPage = (await subscriberCommon.findPermissionFromNode(topic, true, append.clientAddress))[0] ?? 0;
    }

    // node meta
    List<dynamic> acceptList = meta['accept'] ?? [];
    List<dynamic> rejectList = meta['reject'] ?? [];
    if (append.status == SubscriberStatus.InvitedSend || append.status == SubscriberStatus.InvitedReceipt || append.status == SubscriberStatus.Subscribed) {
      // add to accepts
      rejectList = rejectList.where((element) => !element.toString().contains(append.clientAddress)).toList();
      if (acceptList.where((element) => element.toString().contains(append.clientAddress)).toList().isEmpty) {
        acceptList.add({'addr': append.clientAddress});
      }
    } else if (append.status == SubscriberStatus.Unsubscribed) {
      // add to rejects
      acceptList = acceptList.where((element) => !element.toString().contains(append.clientAddress)).toList();
      if (rejectList.where((element) => element.toString().contains(append.clientAddress)).toList().isEmpty) {
        rejectList.add({'addr': append.clientAddress});
      }
    } else {
      // remove from all
      acceptList = acceptList.where((element) => !element.toString().contains(append.clientAddress)).toList();
      rejectList = rejectList.where((element) => !element.toString().contains(append.clientAddress)).toList();
    }

    // DB meta (maybe in txPool)
    List<SubscriberSchema> subscribers = await subscriberCommon.queryListByTopicPerm(topic, append.permPage, SubscriberSchema.PermPageSize);
    subscribers.forEach((SubscriberSchema element) {
      if (element.clientAddress.isNotEmpty == true && element.clientAddress != append.clientAddress) {
        int updateAt = element.updateAt ?? DateTime.now().millisecondsSinceEpoch;
        if ((DateTime.now().millisecondsSinceEpoch - updateAt) < Global.txPoolDelayMs) {
          logger.i("$TAG - _buildMetaByAppend - subscriber update just now, maybe in txPool - element:$element");
          if (element.status == SubscriberStatus.InvitedSend || element.status == SubscriberStatus.InvitedReceipt || element.status == SubscriberStatus.Subscribed) {
            // add to accepts
            rejectList = rejectList.where((e) => !e.toString().contains(element.clientAddress)).toList();
            if (acceptList.where((e) => e.toString().contains(element.clientAddress)).toList().isEmpty) {
              acceptList.add({'addr': element.clientAddress});
            }
          } else if (element.status == SubscriberStatus.Unsubscribed) {
            // add to rejects
            acceptList = acceptList.where((e) => !e.toString().contains(element.clientAddress)).toList();
            if (rejectList.where((e) => e.toString().contains(element.clientAddress)).toList().isEmpty) {
              rejectList.add({'addr': element.clientAddress});
            }
          } else {
            // remove from all
            acceptList = acceptList.where((e) => !e.toString().contains(element.clientAddress)).toList();
            rejectList = rejectList.where((e) => !e.toString().contains(element.clientAddress)).toList();
          }
        } else {
          var betweenS = (DateTime.now().millisecondsSinceEpoch - updateAt) / 1000;
          logger.d("$TAG - _buildMetaByAppend - subscriber update to long - between:${betweenS}s - subscriber:$element");
        }
      }
    });

    // new meta
    meta['accept'] = acceptList;
    meta['reject'] = rejectList;
    logger.d("$TAG - _buildMetaByAppend - permPage:${append.permPage} - meta:${meta.toString()}");
    return meta;
  }

  /// ***********************************************************************************************************
  /// *********************************************** callback **************************************************
  /// ***********************************************************************************************************

  // caller = everyone
  Future<SubscriberSchema?> onSubscribe(String? topic, String? clientAddress, {int tryCount = 1}) async {
    if (topic == null || topic.isEmpty || clientAddress == null || clientAddress.isEmpty) return null;
    // topic exist
    TopicSchema? _topic = await queryByTopic(topic);
    if (_topic == null) {
      logger.w("$TAG - onSubscribe - null - topic:$topic");
      return null;
    }

    // permission check
    if (_topic.isPrivate && !_topic.isOwner(clientAddress)) {
      List permission = await subscriberCommon.findPermissionFromNode(topic, _topic.isPrivate, clientAddress);
      // int? permPage = permission[0];
      bool? acceptAll = permission[1];
      bool? isAccept = permission[2];
      bool? isReject = permission[3];
      if (acceptAll == null || acceptAll != true) {
        if (isReject == true || isAccept != true) {
          if (tryCount >= (Global.txPoolDelayMs / (5 * 1000))) {
            logger.e("$TAG - onSubscribe - subscriber permission is not ok - topic:$_topic - clientAddress:$clientAddress - permission:$permission");
            return null;
          }
          logger.w("$TAG - onSubscribe - subscriber permission is not ok (maybe in txPool) - tryCount:$tryCount - topic:$_topic - clientAddress:$clientAddress - permission:$permission");
          await Future.delayed(Duration(seconds: 5));
          return onSubscribe(topic, clientAddress, tryCount: ++tryCount);
        } else {
          logger.i("$TAG - onSubscribe - subscriber permission is ok - topic:$_topic - clientAddress:$clientAddress - permission:$permission");
        }
      } else {
        logger.i("$TAG - onSubscribe - topic is accept all - topic:$_topic - clientAddress:$clientAddress - permission:$permission");
      }
    }

    // permission modify in invitee action by owner

    // subscriber update
    SubscriberSchema? _subscriber = await subscriberCommon.onSubscribe(topic, clientAddress, null);
    if (_subscriber == null) return null;

    // subscribers sync
    // if (_topic.isPrivate) {
    //   Future.delayed(Duration(seconds: 1), () {
    //     subscriberCommon.refreshSubscribers(topic, meta: _topic.isPrivate);
    //   });
    // }
    return _subscriber;
  }

  // caller = everyone
  Future<SubscriberSchema?> onUnsubscribe(String? topic, String? clientAddress, {int tryCount = 1}) async {
    if (topic == null || topic.isEmpty || clientAddress == null || clientAddress.isEmpty) return null; // || clientCommon.address == null || clientCommon.address!.isEmpty
    // topic exist
    TopicSchema? _topic = await topicCommon.queryByTopic(topic);
    if (_topic == null) {
      logger.w("$TAG - onUnsubscribe - null - topic:$topic");
      return null;
    }

    // subscriber update
    SubscriberSchema? _subscriber = await subscriberCommon.onUnsubscribe(topic, clientAddress);
    if (_subscriber == null) {
      logger.w("$TAG - onUnsubscribe - subscriber is null - topic:$topic - clientAddress:$clientAddress");
      return null;
    }

    // private + owner
    if (_topic.isPrivate && _topic.isOwner(clientCommon.address) && clientCommon.address != clientAddress) {
      List<dynamic> permission = await subscriberCommon.findPermissionFromNode(topic, _topic.isPrivate, clientAddress);
      int? permPage = permission[0] ?? _subscriber.permPage;
      bool? acceptAll = permission[1];
      if (acceptAll == true) {
        // do nothing
      } else {
        if (permPage == null) {
          logger.w("$TAG - onUnsubscribe - permPage is null - permission:$permission");
          return null;
        } else {
          if (_subscriber.permPage != permPage) {
            await subscriberCommon.setPermPage(_subscriber.id, permPage, notify: true);
            _subscriber.permPage = permPage; // if (success)
          }
        }
        // meta update
        Map<String, dynamic> meta = await _getMetaByNodePage(topic, permPage);
        _subscriber.status = SubscriberStatus.None;
        meta = await _buildMetaByAppend(topic, meta, _subscriber);
        _subscriber.status = SubscriberStatus.Unsubscribed;
        bool subscribeSuccess = await _clientSubscribe(topic, permissionPage: permPage, meta: meta, clientAddress: clientAddress, status: SubscriberStatus.Unsubscribed);
        if (!subscribeSuccess) {
          if (tryCount >= (Global.txPoolDelayMs / (5 * 1000))) {
            logger.e("$TAG - onUnsubscribe - clientSubscribe error - permPage:$permPage - meta:$meta");
            return null;
          }
          logger.w("$TAG - onUnsubscribe - clientSubscribe error - tryCount:$tryCount - permPage:$permPage - meta:$meta");
          await Future.delayed(Duration(seconds: 5));
          return onUnsubscribe(topic, clientAddress, tryCount: ++tryCount);
        }
      }
    }

    // owner unsubscribe
    if (_topic.isPrivate && _topic.isOwner(clientAddress) && clientCommon.address == clientAddress) {
      // do nothing now
    }

    // DB update (just node sync can delete)
    bool setSuccess = await setCount(_topic.id, (_topic.count ?? 1) - 1, notify: true);
    if (setSuccess) _topic.count = (_topic.count ?? 1) - 1;
    // await subscriberCommon.delete(_subscriber.id, notify: true);

    // subscribers sync
    // if (_topic.isPrivate) {
    //   Future.delayed(Duration(seconds: 1), () {
    //     subscriberCommon.refreshSubscribers(topic, meta: _topic.isPrivate);
    //   });
    // }
    return _subscriber;
  }

  // caller = everyone
  Future<SubscriberSchema?> onKickOut(String? topic, String? senderAddress, String? clientAddress, {int tryCount = 1}) async {
    if (topic == null || topic.isEmpty || senderAddress == null || senderAddress.isEmpty || clientAddress == null || clientAddress.isEmpty) return null; // || clientCommon.address == null || clientCommon.address!.isEmpty
    // topic exist
    TopicSchema? _exist = await topicCommon.queryByTopic(topic);
    if (_exist == null) {
      logger.w("$TAG - onKickOut - null - topic:$topic");
      return null;
    } else if (!_exist.isOwner(senderAddress)) {
      logger.w("$TAG - onKickOut - sender error - topic:$topic - senderAddress:$senderAddress");
      return null;
    }

    // subscriber update
    SubscriberSchema? _subscriber = await subscriberCommon.onKickOut(topic, clientAddress);
    if (_subscriber == null) {
      logger.w("$TAG - onKickOut - subscriber is null - topic:$topic - clientAddress:$clientAddress");
      return null;
    }

    // permission modify in kick action by owner

    // self unsubscribe
    if (clientAddress == clientCommon.address) {
      bool exitSuccess = await _clientUnsubscribe(topic);
      if (!exitSuccess) {
        if (tryCount >= (Global.txPoolDelayMs / (5 * 1000))) {
          logger.e("$TAG - onKickOut - clientUnsubscribe error - topic:$topic - subscriber:$_subscriber");
          return null;
        }
        logger.w("$TAG - onKickOut - clientUnsubscribe error - tryCount:$tryCount - topic:$topic - subscriber:$_subscriber");
        await Future.delayed(Duration(seconds: 5));
        return onKickOut(topic, senderAddress, clientAddress, tryCount: ++tryCount);
      }
      bool setSuccess = await setJoined(_exist.id, false, notify: true);
      if (setSuccess) {
        _exist.joined = false;
        _exist.subscribeAt = 0;
        _exist.expireBlockHeight = 0;
      }
      // DB update (just node sync can delete)
      // await subscriberCommon.deleteByTopic(topic); // stay is useful
      // await delete(_topic.id, notify: true); // replace by setJoined
    } else {
      bool setSuccess = await setCount(_exist.id, (_exist.count ?? 1) - 1, notify: true);
      if (setSuccess) _exist.count = (_exist.count ?? 1) - 1;
      // await subscriberCommon.delete(_subscriber.id, notify: true);

      // subscribers sync
      // if (_topic.isPrivate) {
      //   Future.delayed(Duration(seconds: 1), () {
      //     subscriberCommon.refreshSubscribers(topic, meta: _topic.isPrivate);
      //   });
      // }
    }
    return _subscriber;
  }

  /// ***********************************************************************************************************
  /// ************************************************* common **************************************************
  /// ***********************************************************************************************************

  Future<TopicSchema?> add(TopicSchema? schema, {bool notify = false, bool checkDuplicated = true}) async {
    if (schema == null || schema.topic.isEmpty) return null;
    schema.type = schema.type ?? (Validate.isPrivateTopicOk(schema.topic) ? TopicType.privateTopic : TopicType.publicTopic);
    if (checkDuplicated) {
      TopicSchema? exist = await queryByTopic(schema.topic);
      if (exist != null) {
        logger.i("$TAG - add - duplicated - schema:$exist");
        return null;
      }
    }
    TopicSchema? added = await _topicStorage.insert(schema);
    if (added != null && notify) _addSink.add(added);
    return added;
  }

  // Future<bool> delete(int? topicId, {bool notify = false}) async {
  //   if (topicId == null || topicId == 0) return false;
  //   TopicSchema? topic = await query(topicId);
  //   if (topic == null) return false;
  //   bool success = await _topicStorage.delete(topicId);
  //   // if (success && notify) _deleteSink.add(topic.topic);
  //   return success;
  // }

  Future<TopicSchema?> query(int? topicId) {
    return _topicStorage.query(topicId);
  }

  Future<TopicSchema?> queryByTopic(String? topic) async {
    if (topic == null || topic.isEmpty) return null;
    return await _topicStorage.queryByTopic(topic);
  }

  Future<List<TopicSchema>> queryList({int? topicType, String? orderBy, int offset = 0, int limit = 20}) {
    return _topicStorage.queryList(topicType: topicType, orderBy: orderBy, offset: offset, limit: limit);
  }

  Future<List<TopicSchema>> queryListJoined({int? topicType, String? orderBy, int offset = 0, int limit = 20}) {
    return _topicStorage.queryListJoined(topicType: topicType, orderBy: orderBy, offset: offset, limit: limit);
  }

  Future<bool> setJoined(int? topicId, bool joined, {int? subscribeAt, int? expireBlockHeight, bool notify = false}) async {
    if (topicId == null || topicId == 0) return false;
    bool success = await _topicStorage.setJoined(
      topicId,
      joined,
      subscribeAt: subscribeAt,
      expireBlockHeight: expireBlockHeight,
      createAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (success && notify) queryAndNotify(topicId);
    return success;
  }

  Future<bool> setAvatar(int? topicId, String? avatarLocalPath, {bool notify = false}) async {
    if (topicId == null || topicId == 0) return false;
    bool success = await _topicStorage.setAvatar(topicId, avatarLocalPath);
    if (success && notify) queryAndNotify(topicId);
    return success;
  }

  Future<bool> setCount(int? topicId, int? count, {bool notify = false}) async {
    if (topicId == null || topicId == 0) return false;
    bool success = await _topicStorage.setCount(topicId, count ?? 0);
    if (success && notify) queryAndNotify(topicId);
    return success;
  }

  Future<bool> setTop(int? topicId, bool top, {bool notify = false}) async {
    if (topicId == null || topicId == 0) return false;
    bool success = await _topicStorage.setTop(topicId, top);
    if (success && notify) queryAndNotify(topicId);
    return success;
  }

  Future<bool> setData(int? topicId, Map<String, dynamic>? newData, {bool notify = false}) async {
    if (topicId == null || topicId == 0) return false;
    bool success = await _topicStorage.setData(topicId, newData);
    if (success && notify) queryAndNotify(topicId);
    return success;
  }

  Future queryAndNotify(int? topicId) async {
    if (topicId == null || topicId == 0) return;
    TopicSchema? updated = await query(topicId);
    if (updated != null) {
      _updateSink.add(updated);
    }
  }
}

import 'dart:convert';

import 'package:nmobile/common/client/client.dart';
import 'package:nmobile/utils/util.dart';

class SubscriberStatus {
  static const int None = 0;
  static const int InvitedSend = 1;
  static const int InvitedReceipt = 2;
  static const int Subscribed = 3;
  static const int Unsubscribed = 4;
}

class SubscriberSchema {
  static const int PermPageSize = 10;

  int? id; // (required) <-> id
  int? createAt; // <-> create_at
  int? updateAt; // <-> update_at

  String topic; // (required) <-> topic
  String contactAddress; // (required) <-> contact_address

  int status; // <-> status
  int? permPage; // <-> perm_page
  Map<String, dynamic>? data; // <-> data[...]

  Map<String, dynamic>? temp; // no_sql

  SubscriberSchema({
    this.id,
    required this.topic,
    required this.contactAddress,
    this.createAt,
    this.updateAt,
    this.status = SubscriberStatus.None,
    this.permPage,
    this.data,
  }) {
    if (this.data == null) this.data = Map();
  }

  String get pubKey {
    return getPubKeyFromTopicOrChatId(contactAddress) ?? contactAddress;
  }

  bool get canBeKick {
    return (status == SubscriberStatus.InvitedSend) || (status == SubscriberStatus.InvitedReceipt) || (status == SubscriberStatus.Subscribed);
  }

  int? isPermissionProgress() {
    return int.tryParse(data?['permission_progress']?.toString() ?? "");
  }

  int? getProgressPermissionNonce() {
    int? nonce = int.tryParse(data?['progress_permission_nonce']?.toString() ?? "");
    if (nonce == null || nonce < 0) return null;
    return nonce;
  }

  double getProgressPermissionFee() {
    double? fee = double.tryParse(data?['progress_permission_fee']?.toString() ?? "");
    if (fee == null || fee < 0) return 0;
    return fee;
  }

  static SubscriberSchema? create(String? topic, String? contactAddress, int? status, int? permPage) {
    if ((topic == null) || topic.isEmpty || (contactAddress == null) || contactAddress.isEmpty) return null;
    return SubscriberSchema(
      topic: topic,
      contactAddress: contactAddress,
      createAt: DateTime.now().millisecondsSinceEpoch,
      updateAt: DateTime.now().millisecondsSinceEpoch,
      status: status ?? SubscriberStatus.None,
      permPage: permPage,
    );
  }

  Map<String, dynamic> toMap() {
    Map<String, dynamic> map = {
      'id': id,
      'create_at': createAt ?? DateTime.now().millisecondsSinceEpoch,
      'update_at': updateAt ?? DateTime.now().millisecondsSinceEpoch,
      'topic': topic,
      'contact_address': contactAddress,
      'status': status,
      'perm_page': permPage,
      'data': data != null ? jsonEncode(data) : Map(),
    };
    return map;
  }

  static SubscriberSchema fromMap(Map<String, dynamic> e) {
    var subscribeSchema = SubscriberSchema(
      id: e['id'],
      createAt: e['create_at'],
      updateAt: e['update_at'],
      topic: e['topic'] ?? "",
      contactAddress: e['contact_address'] ?? "",
      status: e['status'] ?? SubscriberStatus.None,
      permPage: e['perm_page'],
    );
    // data
    if (e['data']?.toString().isNotEmpty == true) {
      Map<String, dynamic>? data = Util.jsonFormatMap(e['data']);
      if (data != null) subscribeSchema.data?.addAll(data);
    }
    return subscribeSchema;
  }

  @override
  String toString() {
    return 'SubscriberSchema{id: $id, createAt: $createAt, updateAt: $updateAt, topic: $topic, clientAddress: $contactAddress, status: $status, permPage: $permPage, data: $data, temp: $temp}';
  }
}

import 'dart:convert';

import 'package:nmobile/common/locator.dart';
import 'package:nmobile/helpers/error.dart';
import 'package:nmobile/schema/device_info.dart';
import 'package:nmobile/utils/logger.dart';
import 'package:nmobile/utils/parallel_queue.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

class DeviceInfoStorage with Tag {
  static String get tableName => 'DeviceInfo'; // v5

  static DeviceInfoStorage instance = DeviceInfoStorage();

  Database? get db => dbCommon.database;

  ParallelQueue _queue = ParallelQueue("storage_deviceInfo", onLog: (log, error) => error ? logger.w(log) : null);

  static String createSQL = '''
      CREATE TABLE `$tableName` (
        `id` INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        `create_at` BIGINT,
        `update_at` BIGINT,
        `contact_address` VARCHAR(200),
        `device_id` TEXT,
        `data` TEXT
      )''';

  static create(Database db) async {
    // create table
    await db.execute(createSQL);

    // index
    await db.execute('CREATE UNIQUE INDEX `index_unique_device_info_contact_address_device_id` ON `$tableName` (`contact_address`, `device_id`)'); // TODO:GG 升级
    await db.execute('CREATE INDEX `index_device_info_device_id` ON `$tableName` (`device_id`)');
    await db.execute('CREATE INDEX `index_device_info_contact_address_update_at` ON `$tableName` (`contact_address`, `update_at`)');
    await db.execute('CREATE INDEX `index_device_info_contact_address_device_id_update_at` ON `$tableName` (`contact_address`, `device_id`, `update_at`)');
  }

  Future<DeviceInfoSchema?> insert(DeviceInfoSchema? schema) async {
    if (db?.isOpen != true) return null;
    if (schema == null || schema.contactAddress.isEmpty) return null;
    Map<String, dynamic> entity = schema.toMap();
    return await _queue.add(() async {
      try {
        int? id = await db?.transaction((txn) {
          return txn.insert(tableName, entity);
        });
        if (id != null) {
          DeviceInfoSchema schema = DeviceInfoSchema.fromMap(entity);
          schema.id = id;
          logger.v("$TAG - insert - success - schema:$schema");
          return schema;
        }
        logger.w("$TAG - insert - fail - schema:$schema");
      } catch (e, st) {
        handleError(e, st);
      }
      return null;
    });
  }

  Future<DeviceInfoSchema?> queryLatest(String? contactAddress) async {
    if (db?.isOpen != true) return null;
    if (contactAddress == null || contactAddress.isEmpty) return null;
    try {
      List<Map<String, dynamic>>? res = await db?.transaction((txn) {
        return txn.query(
          tableName,
          columns: ['*'],
          where: 'contact_address = ?',
          whereArgs: [contactAddress],
          offset: 0,
          limit: 1,
          orderBy: 'update_at DESC',
        );
      });
      if (res != null && res.length > 0) {
        DeviceInfoSchema schema = DeviceInfoSchema.fromMap(res.first);
        logger.v("$TAG - queryLatest - success - contactAddress:$contactAddress - schema:$schema");
        return schema;
      }
      logger.v("$TAG - queryLatest - empty - contactAddress:$contactAddress");
    } catch (e, st) {
      handleError(e, st);
    }
    return null;
  }

  Future<List<DeviceInfoSchema>> queryLatestList(String? contactAddress, {int offset = 0, int limit = 20}) async {
    if (db?.isOpen != true) return [];
    if (contactAddress == null || contactAddress.isEmpty) return [];
    try {
      List<Map<String, dynamic>>? res = await db?.transaction((txn) {
        return txn.query(
          tableName,
          columns: ['*'],
          where: 'contact_address = ?',
          whereArgs: [contactAddress],
          offset: offset,
          limit: limit,
          orderBy: 'update_at DESC',
        );
      });
      if (res == null || res.isEmpty) {
        logger.v("$TAG - queryLatestList - empty - contactAddress:$contactAddress");
        return [];
      }
      List<DeviceInfoSchema> results = <DeviceInfoSchema>[];
      String logText = '';
      res.forEach((map) {
        logText += "\n      $map";
        results.add(DeviceInfoSchema.fromMap(map));
      });
      logger.v("$TAG - queryLatestList - items:$logText");
      return results;
    } catch (e, st) {
      handleError(e, st);
    }
    return [];
  }

  /*Future<List<DeviceInfoSchema>> queryListLatest(List<String>? contactAddressList) async {
    if (db?.isOpen != true) return [];
    if (contactAddressList == null || contactAddressList.isEmpty) return [];
    try {
      List? res = await db?.transaction((txn) {
        Batch batch = txn.batch();
        contactAddressList.forEach((contactAddress) {
          if (contactAddress.isNotEmpty) {
            batch.query(
              tableName,
              columns: ['*'],
              where: 'contact_address = ?',
              whereArgs: [contactAddress],
              offset: 0,
              limit: 1,
              orderBy: 'update_at DESC',
            );
          }
        });
        return batch.commit();
      });
      if (res != null && res.length > 0) {
        List<DeviceInfoSchema> schemaList = [];
        for (var i = 0; i < res.length; i++) {
          if (res[i] == null || res[i].isEmpty || res[i][0].isEmpty) continue;
          Map<String, dynamic> map = res[i][0];
          DeviceInfoSchema schema = DeviceInfoSchema.fromMap(map);
          schemaList.add(schema);
        }
        logger.v("$TAG - queryListLatest - success - contactAddressList:$contactAddressList - schemaList:$schemaList");
        return schemaList;
      }
      logger.v("$TAG - queryListLatest - empty - contactAddressList:$contactAddressList");
    } catch (e, st) {
      handleError(e, st);
    }
    return [];
  }*/

  Future<DeviceInfoSchema?> queryByDeviceId(String? contactAddress, String? deviceId) async {
    if (db?.isOpen != true) return null;
    if (contactAddress == null || contactAddress.isEmpty || deviceId == null || deviceId.isEmpty) return null;
    try {
      List<Map<String, dynamic>>? res = await db?.transaction((txn) {
        return txn.query(
          tableName,
          columns: ['*'],
          where: 'contact_address = ? AND device_id = ?',
          whereArgs: [contactAddress, deviceId],
          offset: 0,
          limit: 1,
          orderBy: 'update_at DESC',
        );
      });
      if (res != null && res.length > 0) {
        DeviceInfoSchema schema = DeviceInfoSchema.fromMap(res.first);
        logger.v("$TAG - queryByDeviceId - success - contactAddress:$contactAddress - schema:$schema");
        return schema;
      }
      logger.v("$TAG - queryByDeviceId - empty - contactAddress:$contactAddress");
    } catch (e, st) {
      handleError(e, st);
    }
    return null;
  }

  Future<bool> setData(int? deviceInfoId, Map<String, dynamic>? newData) async {
    if (db?.isOpen != true) return false;
    if (deviceInfoId == null || deviceInfoId == 0) return false;
    return await _queue.add(() async {
          try {
            int? count = await db?.transaction((txn) {
              return txn.update(
                tableName,
                {
                  'data': newData != null ? jsonEncode(newData) : null,
                  'update_at': DateTime.now().millisecondsSinceEpoch,
                },
                where: 'id = ?',
                whereArgs: [deviceInfoId],
              );
            });
            if (count != null && count > 0) {
              logger.v("$TAG - setData - success - deviceInfoId:$deviceInfoId - data:$newData");
              return true;
            }
            logger.w("$TAG - setData - fail - deviceInfoId:$deviceInfoId - data:$newData");
          } catch (e, st) {
            handleError(e, st);
          }
          return false;
        }) ??
        false;
  }

  Future<bool> setUpdate(String? contactAddress, String? deviceId, {int? updateAt}) async {
    if (db?.isOpen != true) return false;
    return await _queue.add(() async {
          try {
            int? count = await db?.transaction((txn) {
              return txn.update(
                tableName,
                {
                  'update_at': updateAt ?? DateTime.now().millisecondsSinceEpoch,
                },
                where: 'contact_address = ? AND device_id = ?',
                whereArgs: [contactAddress, deviceId],
              );
            });
            if (count != null && count > 0) {
              logger.v("$TAG - setUpdate - success - contactAddress:$contactAddress - deviceId:$deviceId");
              return true;
            }
            logger.w("$TAG - setUpdate - fail - contactAddress:$contactAddress - deviceId:$deviceId");
          } catch (e, st) {
            handleError(e, st);
          }
          return false;
        }) ??
        false;
  }
}

import 'dart:convert';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/meter_device.dart';
import '../models/reading_record.dart';

/// 本地 SQLite 存储服务（单例）
///
/// 数据库文件：meter_reader.db（与 APK 一致）
/// 表结构对齐 APK 深度解析报告 §3.5 四表 DDL：
///   meters       设备表（serial_number / display_name / location / type / model /
///                status / metadata_json / last_seen_at / created_at / updated_at）
///   readings     读数表（source / meter_id / flow_rate / unit / pressure /
///                temperature / signal_strength / status / recorded_at /
///                received_at / battery_level / metrics_json / metadata_json /
///                meter_json / raw_payload_json / notes）
///   saved_devices 已存设备（设备标识 / rssi / connection_phase）
///   sync_queue   同步队列（待同步任务 / last_attempt_at / last_error / synced_at）
///
/// 流量系数与原始系数存于 meters.metadata_json（{"coefficient":x,"originalCoefficient":y}）。
class StorageService {
  StorageService._internal();

  static final StorageService instance = StorageService._internal();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _openDatabase();
    return _db!;
  }

  Future<Database> _openDatabase() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = join(dir.path, 'meter_reader.db');
    return openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE meters (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            serial_number TEXT,
            display_name TEXT,
            location TEXT,
            type TEXT,
            model TEXT,
            status TEXT,
            metadata_json TEXT,
            last_seen_at TEXT,
            created_at TEXT,
            updated_at TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE readings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT,
            meter_id INTEGER,
            flow_rate REAL,
            unit TEXT DEFAULT 'm³',
            pressure REAL,
            temperature REAL,
            signal_strength INTEGER,
            status TEXT,
            recorded_at TEXT,
            received_at TEXT,
            battery_level INTEGER,
            metrics_json TEXT,
            metadata_json TEXT,
            meter_json TEXT,
            raw_payload_json TEXT,
            notes TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE saved_devices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            device_id TEXT,
            name TEXT,
            mac TEXT,
            rssi INTEGER,
            connection_phase TEXT,
            last_seen_at TEXT,
            created_at TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE sync_queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_type TEXT,
            payload_json TEXT,
            status TEXT DEFAULT 'pending',
            last_attempt_at TEXT,
            last_error TEXT,
            synced_at TEXT,
            created_at TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_readings_meter ON readings(meter_id)');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_readings_time ON readings(recorded_at)');
      },
    );
  }

  // ==================== meters ====================

  /// 保存/更新设备（按 serial_number upsert，返回 meters.id）
  Future<int> upsertMeter(MeterDevice device) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final existing = await db.query(
      'meters',
      where: 'serial_number = ?',
      whereArgs: [device.serialNumber],
      limit: 1,
    );
    final Map<String, dynamic> values = {
      'serial_number': device.serialNumber,
      'display_name': device.displayName,
      'location': device.location,
      'type': device.type,
      'model': device.model,
      'status': device.status ?? 'active',
      'metadata_json': device.metadataJson,
      'last_seen_at': device.lastSeenAt ?? now,
      'updated_at': now,
    };
    if (existing.isEmpty) {
      values['created_at'] = device.createdAt ?? now;
      return db.insert('meters', values);
    }
    final id = existing.first['id'] as int;
    await db.update('meters', values, where: 'id = ?', whereArgs: [id]);
    return id;
  }

  Future<MeterDevice?> getMeterBySerial(String serialNumber) async {
    final db = await database;
    final rows = await db.query(
      'meters',
      where: 'serial_number = ?',
      whereArgs: [serialNumber],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return MeterDevice.fromMap(rows.first);
  }

  Future<MeterDevice?> getMeterById(int id) async {
    final db = await database;
    final rows = await db.query('meters', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return MeterDevice.fromMap(rows.first);
  }

  Future<List<MeterDevice>> getAllMeters() async {
    final db = await database;
    final rows = await db.query('meters', orderBy: 'updated_at DESC');
    return rows.map(MeterDevice.fromMap).toList();
  }

  Future<int> deleteMeter(int id) async {
    final db = await database;
    return db.delete('meters', where: 'id = ?', whereArgs: [id]);
  }

  // ---- 流量系数（存 meters.metadata_json） ----

  /// 保存/更新设备流量系数（upsert，保留原始系数）
  Future<void> saveCoefficient(String serial, String name, double coeff) async {
    final existing = await getMeterBySerial(serial);
    final meta = existing?.metadataJson;
    Map<String, dynamic> map = const {};
    if (meta != null && meta.isNotEmpty) {
      try {
        map = Map<String, dynamic>.from(jsonDecode(meta));
      } catch (_) {}
    }
    map['coefficient'] = coeff;
    final device = (existing ?? MeterDevice(serialNumber: serial, displayName: name))
        .copyWith(metadataJson: jsonEncode(map));
    await upsertMeter(device);
  }

  /// 读取设备流量系数；无则返回 null
  Future<double?> getCoefficient(String serial) async {
    final device = await getMeterBySerial(serial);
    return device?.coefficient;
  }

  /// 保存/更新原始系数（upsert，保留当前系数）
  Future<void> saveOriginalCoefficient(
      String serial, String name, double original) async {
    final existing = await getMeterBySerial(serial);
    final meta = existing?.metadataJson;
    Map<String, dynamic> map = const {};
    if (meta != null && meta.isNotEmpty) {
      try {
        map = Map<String, dynamic>.from(jsonDecode(meta));
      } catch (_) {}
    }
    map['originalCoefficient'] = original;
    final device = (existing ?? MeterDevice(serialNumber: serial, displayName: name))
        .copyWith(metadataJson: jsonEncode(map));
    await upsertMeter(device);
  }

  /// 读取原始系数；无则返回 null
  Future<double?> getOriginalCoefficient(String serial) async {
    final device = await getMeterBySerial(serial);
    return device?.originalCoefficient;
  }

  // ==================== readings ====================

  Future<int> insertReading(ReadingRecord record) async {
    final db = await database;
    return db.insert('readings', record.toMap());
  }

  Future<List<ReadingRecord>> getReadings({int limit = 500}) async {
    final db = await database;
    final rows = await db.query(
      'readings',
      orderBy: 'recorded_at DESC',
      limit: limit,
    );
    return rows.map(ReadingRecord.fromMap).toList();
  }

  Future<List<ReadingRecord>> getReadingsByMeter(int meterId) async {
    final db = await database;
    final rows = await db.query(
      'readings',
      where: 'meter_id = ?',
      whereArgs: [meterId],
      orderBy: 'recorded_at DESC',
    );
    return rows.map(ReadingRecord.fromMap).toList();
  }

  Future<List<ReadingRecord>> getReadingsByDateRange(
      DateTime start, DateTime end) async {
    final db = await database;
    final rows = await db.query(
      'readings',
      where: 'recorded_at >= ? AND recorded_at <= ?',
      whereArgs: [start.toIso8601String(), end.toIso8601String()],
      orderBy: 'recorded_at DESC',
    );
    return rows.map(ReadingRecord.fromMap).toList();
  }

  Future<int> deleteReading(int id) async {
    final db = await database;
    return db.delete('readings', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteReadingsByMeter(int meterId) async {
    final db = await database;
    return db.delete('readings', where: 'meter_id = ?', whereArgs: [meterId]);
  }

  // ==================== saved_devices ====================

  Future<void> upsertSavedDevice({
    required String deviceId,
    String? name,
    String? mac,
    int? rssi,
    String? connectionPhase,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final existing = await db.query(
      'saved_devices',
      where: 'device_id = ?',
      whereArgs: [deviceId],
      limit: 1,
    );
    final values = <String, dynamic>{
      'device_id': deviceId,
      'name': name,
      'mac': mac,
      'rssi': rssi,
      'connection_phase': connectionPhase,
      'last_seen_at': now,
    };
    if (existing.isEmpty) {
      values['created_at'] = now;
      await db.insert('saved_devices', values);
    } else {
      await db.update('saved_devices', values,
          where: 'device_id = ?', whereArgs: [deviceId]);
    }
  }

  Future<Map<String, dynamic>?> getSavedDevice(String deviceId) async {
    final db = await database;
    final rows = await db.query(
      'saved_devices',
      where: 'device_id = ?',
      whereArgs: [deviceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first;
  }

  Future<List<Map<String, dynamic>>> getAllSavedDevices() async {
    final db = await database;
    final rows = await db.query('saved_devices', orderBy: 'last_seen_at DESC');
    return rows;
  }

  Future<int> deleteSavedDevice(String deviceId) async {
    final db = await database;
    return db.delete('saved_devices',
        where: 'device_id = ?', whereArgs: [deviceId]);
  }

  Future<void> updateConnectionPhase(String deviceId, String phase) async {
    final db = await database;
    await db.update(
      'saved_devices',
      {'connection_phase': phase},
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
  }

  // ==================== sync_queue ====================

  /// 入队同步任务（如抄表记录上行）
  Future<int> enqueueSyncTask({
    required String taskType,
    required Map<String, dynamic> payload,
  }) async {
    final db = await database;
    return db.insert('sync_queue', {
      'task_type': taskType,
      'payload_json': jsonEncode(payload),
      'status': 'pending',
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> getPendingSyncTasks() async {
    final db = await database;
    final rows = await db.query(
      'sync_queue',
      where: "status = 'pending' OR status = 'failed'",
      orderBy: 'created_at ASC',
    );
    return rows;
  }

  Future<void> markSyncSynced(int id) async {
    final db = await database;
    await db.update(
      'sync_queue',
      {'status': 'synced', 'synced_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markSyncFailed(int id, String error) async {
    final db = await database;
    await db.update(
      'sync_queue',
      {
        'status': 'failed',
        'last_error': error,
        'last_attempt_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}

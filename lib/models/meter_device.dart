import 'dart:convert';

/// 表具设备模型（对应 SQLite meters 表）
///
/// 字段对齐 APK 深度解析报告 §3.5 的 meters 表 DDL：
/// id, serial_number, display_name, location, type, model, status,
/// metadata_json, last_seen_at, created_at, updated_at
class MeterDevice {
  final int? id;
  final String serialNumber; // 序列号（如 VMS-2720147-KXMJ）
  final String displayName; // 显示名称
  final String? location; // 安装位置
  final String? type; // 类型
  final String? model; // 型号
  final String? status; // 状态
  final String? metadataJson; // 扩展元数据（含系数：{"coefficient":x,"originalCoefficient":y}）
  final String? lastSeenAt; // 最近在线时间
  final String? createdAt;
  final String? updatedAt;

  const MeterDevice({
    this.id,
    required this.serialNumber,
    required this.displayName,
    this.location,
    this.type,
    this.model,
    this.status,
    this.metadataJson,
    this.lastSeenAt,
    this.createdAt,
    this.updatedAt,
  });

  double? get coefficient => _meta()['coefficient']?.toDouble();
  double? get originalCoefficient => _meta()['originalCoefficient']?.toDouble();

  Map<String, dynamic> _meta() {
    final raw = metadataJson;
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return const {};
    } catch (_) {
      return const {};
    }
  }

  MeterDevice copyWith({
    int? id,
    String? serialNumber,
    String? displayName,
    String? location,
    String? type,
    String? model,
    String? status,
    String? metadataJson,
    String? lastSeenAt,
    String? createdAt,
    String? updatedAt,
  }) {
    return MeterDevice(
      id: id ?? this.id,
      serialNumber: serialNumber ?? this.serialNumber,
      displayName: displayName ?? this.displayName,
      location: location ?? this.location,
      type: type ?? this.type,
      model: model ?? this.model,
      status: status ?? this.status,
      metadataJson: metadataJson ?? this.metadataJson,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'serial_number': serialNumber,
      'display_name': displayName,
      'location': location,
      'type': type,
      'model': model,
      'status': status,
      'metadata_json': metadataJson,
      'last_seen_at': lastSeenAt,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }

  factory MeterDevice.fromMap(Map<String, dynamic> m) {
    return MeterDevice(
      id: m['id'] as int?,
      serialNumber: (m['serial_number'] as String?) ?? '',
      displayName: (m['display_name'] as String?) ?? '',
      location: m['location'] as String?,
      type: m['type'] as String?,
      model: m['model'] as String?,
      status: m['status'] as String?,
      metadataJson: m['metadata_json'] as String?,
      lastSeenAt: m['last_seen_at'] as String?,
      createdAt: m['created_at'] as String?,
      updatedAt: m['updated_at'] as String?,
    );
  }
}

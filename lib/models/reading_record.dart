/// 抄表读数记录模型（对应 SQLite readings 表）
///
/// 字段对齐 APK 深度解析报告 §3.5 的 readings 表 DDL：
/// id, source, meter_id, flow_rate, unit, pressure, temperature,
/// signal_strength, status, recorded_at, received_at, battery_level,
/// metrics_json, metadata_json, meter_json, raw_payload_json, notes
class ReadingRecord {
  final int? id;
  final String source; // 数据来源：ble / manual（离线手工录入）
  final int? meterId; // 关联 meters.id
  final double flowRate; // 读数（瞬时或累计，按 recordedAs 语义）
  final String unit; // 单位（默认 m³）
  final double? pressure; // 压力（kPa）
  final double? temperature; // 温度（℃）
  final int? signalStrength; // 信号强度（RSSI）
  final String? status; // 状态
  final String? recordedAt; // 抄表时间
  final String? receivedAt; // 接收时间
  final int? batteryLevel; // 电量
  final String? metricsJson; // 扩展指标（如瞬时流量、系数）
  final String? metadataJson; // 扩展元数据
  final String? meterJson; // 设备快照
  final String? rawPayloadJson; // 原始 A5 载荷 hex
  final String? notes; // 现场备注

  const ReadingRecord({
    this.id,
    required this.source,
    this.meterId,
    required this.flowRate,
    this.unit = 'm³',
    this.pressure,
    this.temperature,
    this.signalStrength,
    this.status,
    this.recordedAt,
    this.receivedAt,
    this.batteryLevel,
    this.metricsJson,
    this.metadataJson,
    this.meterJson,
    this.rawPayloadJson,
    this.notes,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'source': source,
      'meter_id': meterId,
      'flow_rate': flowRate,
      'unit': unit,
      'pressure': pressure,
      'temperature': temperature,
      'signal_strength': signalStrength,
      'status': status,
      'recorded_at': recordedAt,
      'received_at': receivedAt,
      'battery_level': batteryLevel,
      'metrics_json': metricsJson,
      'metadata_json': metadataJson,
      'meter_json': meterJson,
      'raw_payload_json': rawPayloadJson,
      'notes': notes,
    };
  }

  factory ReadingRecord.fromMap(Map<String, dynamic> m) {
    return ReadingRecord(
      id: m['id'] as int?,
      source: (m['source'] as String?) ?? 'ble',
      meterId: m['meter_id'] as int?,
      flowRate: (m['flow_rate'] as num?)?.toDouble() ?? 0,
      unit: (m['unit'] as String?) ?? 'm³',
      pressure: (m['pressure'] as num?)?.toDouble(),
      temperature: (m['temperature'] as num?)?.toDouble(),
      signalStrength: m['signal_strength'] as int?,
      status: m['status'] as String?,
      recordedAt: m['recorded_at'] as String?,
      receivedAt: m['received_at'] as String?,
      batteryLevel: m['battery_level'] as int?,
      metricsJson: m['metrics_json'] as String?,
      metadataJson: m['metadata_json'] as String?,
      meterJson: m['meter_json'] as String?,
      rawPayloadJson: m['raw_payload_json'] as String?,
      notes: m['notes'] as String?,
    );
  }
}

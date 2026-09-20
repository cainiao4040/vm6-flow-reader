/// VM6 实时数据模型（0x47 响应解析结果）
///
/// 字段顺序对齐 APK 深度解析报告 §3.3：瞬时流量 / 压力 / 温度 / 累计流量 / 系数。
class LiveMetrics {
  final double instantFlow; // 瞬时流量
  final double? pressure; // 压力（kPa）
  final double? temperature; // 温度（℃）
  final double? cumulativeFlow; // 累计流量
  final double? coefficient; // 仪表系数 K
  final int? signalStrength; // 信号强度
  final String rawHex; // 原始帧 hex（诊断/落库）
  final DateTime timestamp;

  const LiveMetrics({
    required this.instantFlow,
    this.pressure,
    this.temperature,
    this.cumulativeFlow,
    this.coefficient,
    this.signalStrength,
    this.rawHex = '',
    required this.timestamp,
  });

  LiveMetrics copyWith({
    double? instantFlow,
    double? pressure,
    double? temperature,
    double? cumulativeFlow,
    double? coefficient,
    int? signalStrength,
    String? rawHex,
    DateTime? timestamp,
  }) {
    return LiveMetrics(
      instantFlow: instantFlow ?? this.instantFlow,
      pressure: pressure ?? this.pressure,
      temperature: temperature ?? this.temperature,
      cumulativeFlow: cumulativeFlow ?? this.cumulativeFlow,
      coefficient: coefficient ?? this.coefficient,
      signalStrength: signalStrength ?? this.signalStrength,
      rawHex: rawHex ?? this.rawHex,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'instantFlow': instantFlow,
      'pressure': pressure,
      'temperature': temperature,
      'cumulativeFlow': cumulativeFlow,
      'coefficient': coefficient,
      'signalStrength': signalStrength,
      'timestamp': timestamp.toIso8601String(),
    };
  }
}

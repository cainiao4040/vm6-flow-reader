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

  /// true  = 来自 0x47 实时帧，五个字段齐全；
  /// false = 来自 0x03 读系数帧，只有 [coefficient] 有效，其余字段无意义。
  ///
  /// UI 必须区分两者：0x03 帧的 instantFlow 是占位的 0，直接显示会把
  /// 「瞬时流量」错误地渲染成 0.0000。
  final bool isRealtime;

  const LiveMetrics({
    required this.instantFlow,
    this.pressure,
    this.temperature,
    this.cumulativeFlow,
    this.coefficient,
    this.signalStrength,
    this.rawHex = '',
    required this.timestamp,
    this.isRealtime = true,
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
    bool? isRealtime,
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
      isRealtime: isRealtime ?? this.isRealtime,
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

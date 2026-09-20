import 'dart:typed_data';

/// A5 私有帧协议（VM6 超声波流量计）
///
/// 协议规格来源：APK 深度解析报告 §3.2（CRC16/MODBUS + A5 私有帧，非标准 Modbus RTU）。
///
/// 帧结构（字段大端，CRC 低字节在前发送）：
///   偏移  0     1            ...     n+1    n+2
///        [A5]  [功能码]  [载荷 n 字节]  [CRC低] [CRC高]
///
/// CRC16/MODBUS：多项式 0xA001，初值 0xFFFF，覆盖 A5+功能码+载荷（不含 CRC），
/// 发送顺序低字节在前。
///
/// 功能码：
///   0x03  读保持寄存器    req: A5 03 regHi regLo cntHi cntLo crcLo crcHi
///   0x47  读实时数据      req: A5 47 crcLo crcHi       resp 载荷 20B = 5×float32
///   0x4D  读参数表        req: A5 4D crcLo crcHi       resp 载荷 140B
///   0x10  写多个寄存器    req: A5 10 regHi regLo cntHi cntLo byteCnt data... crc
///   0x06  写单个寄存器    req: A5 06 regHi regLo valHi valLo crcLo crcHi
///   func|0x80  异常响应   固定 5B：A5 errFunc errCode crcLo crcHi（0x06=从机繁忙）
///
/// 寄存器表：
///   0x0008            温度（只读）
///   0x0010~0x0011     仪表系数 K（读 0x03、写 0x10 / 0x06）
///
/// 已验证帧样本（CRC 复算一致）：
///   A5 47 3A D2                读实时
///   A5 4D BA D5                读参数表
///   A5 03 00 10 00 02 DC EA    读 K(0x0010, 2 寄存器)
///   写 K 示例（0x06 两段，K=2.318）：
///     A5 06 00 10 40 14 A0 E4
///     A5 06 00 11 5A 1D 3A 42
class A5Protocol {
  A5Protocol._();

  static const int header = 0xA5;

  // ---- 功能码 ----
  static const int funcReadHolding = 0x03;
  static const int funcReadRealtime = 0x47;
  static const int funcReadParam = 0x4D;
  static const int funcWriteMulti = 0x10;
  static const int funcWriteSingle = 0x06;

  // ---- 异常码 ----
  static const int errBusy = 0x06; // 从机繁忙

  // ---- 寄存器 ----
  static const int regTemperature = 0x0008; // 温度（只读）
  static const int regCoeff = 0x0010; // 仪表系数 K 起始寄存器（0x0010~0x0011）

  // ---- CRC16/MODBUS（多项式 0xA001、初值 0xFFFF、低字节在前） ----
  static int crc16(List<int> data, [int off = 0, int? len]) {
    int crc = 0xFFFF;
    final n = len ?? data.length - off;
    for (var i = off; i < off + n; i++) {
      crc ^= data[i] & 0xFF;
      for (var j = 0; j < 8; j++) {
        crc = (crc & 0x0001) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
      }
    }
    return crc & 0xFFFF;
  }

  /// 构建 A5 帧：A5 + 功能码 + 载荷 + CRC低 + CRC高
  static List<int> frame(int func, List<int>? payload) {
    final plen = payload?.length ?? 0;
    final out = List<int>.filled(2 + plen + 2, 0);
    out[0] = header;
    out[1] = func;
    if (plen > 0) {
      out.setRange(2, 2 + plen, payload!);
    }
    final crc = crc16(out, 0, 2 + plen);
    out[out.length - 2] = crc & 0xFF;
    out[out.length - 1] = (crc >> 8) & 0xFF;
    return out;
  }

  /// 0x03 读保持寄存器：A5 03 regHi regLo cntHi cntLo crc
  static List<int> readHolding(int startRegister, int count) {
    return frame(funcReadHolding, <int>[
      (startRegister >> 8) & 0xFF,
      startRegister & 0xFF,
      (count >> 8) & 0xFF,
      count & 0xFF,
    ]);
  }

  /// 0x47 读实时数据：A5 47 crc
  static List<int> readRealtime() => frame(funcReadRealtime, null);

  /// 0x4D 读参数表：A5 4D crc
  static List<int> readParamTable() => frame(funcReadParam, null);

  /// 0x10 写多个寄存器（一次写两寄存器，载荷 = reg/cnt/byteCnt + float32 大端）
  static List<int> writeCoeffMulti(double value) {
    final bits = _floatToBits(value);
    return frame(funcWriteMulti, <int>[
      (regCoeff >> 8) & 0xFF,
      regCoeff & 0xFF, // reg 0x0010
      0x00,
      0x02, // 数量 2
      0x04, // 字节数 4
      (bits >> 24) & 0xFF,
      (bits >> 16) & 0xFF,
      (bits >> 8) & 0xFF,
      bits & 0xFF,
    ]);
  }

  /// 0x06 写单个寄存器（K 高 16 位 → 0x0010）：与抓包样本 A5 06 00 10 40 14 A0 E4 对齐
  static List<int> writeCoeffSingleHigh(double value) {
    final bits = _floatToBits(value);
    return frame(funcWriteSingle, <int>[
      (regCoeff >> 8) & 0xFF,
      regCoeff & 0xFF,
      (bits >> 24) & 0xFF,
      (bits >> 16) & 0xFF,
    ]);
  }

  /// 0x06 写单个寄存器（K 低 16 位 → 0x0011）：与抓包样本 A5 06 00 11 5A 1D 3A 42 对齐
  static List<int> writeCoeffSingleLow(double value) {
    final bits = _floatToBits(value);
    return frame(funcWriteSingle, <int>[
      ((regCoeff + 1) >> 8) & 0xFF,
      (regCoeff + 1) & 0xFF,
      (bits >> 8) & 0xFF,
      bits & 0xFF,
    ]);
  }

  static int _floatToBits(double value) {
    final bd = ByteData(4);
    bd.setFloat32(0, value, Endian.big);
    return bd.getUint32(0, Endian.big) & 0xFFFFFFFF;
  }

  // ---- 帧校验 ----

  /// 校验一帧 A5 的 CRC，返回载荷长度（不含 CRC 2 字节）；非法返回 -1
  static int validate(List<int> frameData) {
    if (frameData.length < 4) return -1;
    if (frameData[0] != header) return -1;
    final plen = frameData.length - 4;
    final calc = crc16(frameData, 0, 2 + plen);
    final got = (frameData[frameData.length - 2] & 0xFF) |
        ((frameData[frameData.length - 1] & 0xFF) << 8);
    return calc == got ? plen : -1;
  }

  /// 在通知流字节中定位合法 A5 整帧（CRC 通过），返回首个匹配 func 的帧；失败返回 null
  static List<int>? extractFrame(Uint8List data, int func) {
    for (var i = 0; i + 3 < data.length; i++) {
      if (data[i] != header) continue;
      if (data[i + 1] != func) continue;
      for (var total = 4; i + total <= data.length; total++) {
        final cover = total - 2;
        final calc = crc16(data, i, cover);
        final got = (data[i + total - 2] & 0xFF) |
            ((data[i + total - 1] & 0xFF) << 8);
        if (calc == got) {
          return data.sublist(i, i + total);
        }
      }
    }
    return null;
  }

  // ---- 响应解析 ----

  /// 解析 0x47 实时响应：载荷 20B = 5×float32（大端）。
  /// 字段顺序按解析报告 §3.3：瞬时流量 / 压力 / 温度 / 累计流量 / 系数。
  static List<double>? parseRealtime(List<int> frameData) {
    if (validate(frameData) != 20) return null;
    if (frameData[1] != funcReadRealtime) return null;
    final out = <double>[];
    for (var i = 0; i < 5; i++) {
      out.add(_bitsToFloat(_uint32At(frameData, 2 + i * 4)));
    }
    return out;
  }

  /// 解析 0x03 读保持寄存器响应（2 寄存器 = 1 个 float32 大端）
  static double? parseHoldingFloat(List<int> frameData) {
    final plen = validate(frameData);
    if (plen < 5 || frameData[1] != funcReadHolding) return null;
    final byteCount = frameData[2] & 0xFF;
    if (byteCount != 4 || plen != 1 + byteCount) return null;
    return _bitsToFloat(_uint32At(frameData, 3));
  }

  /// 解析 0x4D 参数表响应：载荷 140B = 35 个 float32（大端）。
  /// 报告 §3.2：编号 04~19，0x0A 为密度滚动值（非系数）。
  /// 返回 35 项数值列表；索引 = 编号（0 起）。非法返回 null。
  static List<double>? parseParamTable(List<int> frameData) {
    final plen = validate(frameData);
    if (plen != 140 || frameData[1] != funcReadParam) return null;
    final out = <double>[];
    for (var i = 0; i < 35; i++) {
      out.add(_bitsToFloat(_uint32At(frameData, 2 + i * 4)));
    }
    return out;
  }

  /// 解析 0x10 写多寄存器回执：合法回执返回 true。
  /// 回执载荷 5B：regHi regLo cntHi cntLo（Modbus 惯例回显起始寄存器+数量）。
  static bool parseWriteMultiAck(List<int> frameData) {
    final plen = validate(frameData);
    if (plen < 5 || frameData[1] != funcWriteMulti) return false;
    return true;
  }

  /// 解析 0x06 写单寄存器回执：Modbus 惯例回显完整请求帧（A5 06 regHi regLo valHi valLo crc）。
  /// 合法回执返回 true。
  static bool parseWriteSingleAck(List<int> frameData) {
    final plen = validate(frameData);
    if (plen != 5 || frameData[1] != funcWriteSingle) return false;
    return true;
  }

  /// 检测异常响应帧（func|0x80）。返回异常码；非异常帧返回 null。
  static int? parseException(List<int> frameData) {
    final plen = validate(frameData);
    if (plen != 2) return null;
    final func = frameData[1];
    if ((func & 0x80) == 0) return null;
    return frameData[2] & 0xFF;
  }

  static int _uint32At(List<int> b, int off) =>
      (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];

  static double _bitsToFloat(int bits) {
    final bd = ByteData(4)..setUint32(0, bits, Endian.big);
    final f = bd.getFloat32(0, Endian.big);
    return f.isFinite ? f : double.nan;
  }

  /// 字节数组转大写十六进制（空格分隔）
  static String hex(List<int> bytes) {
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
  }
}

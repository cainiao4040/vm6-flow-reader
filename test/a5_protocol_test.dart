import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vm6_flow_reader/services/a5_protocol.dart';

/// 十六进制字符串 → 字节数组（空格分隔）
List<int> hx(String s) => s
    .trim()
    .split(RegExp(r'\s+'))
    .where((e) => e.isNotEmpty)
    .map((e) => int.parse(e, radix: 16))
    .toList();

/// 构建一帧：A5 + func + payload + CRC低 + CRC高
List<int> build(int func, List<int> payload) {
  final body = <int>[A5Protocol.header, func, ...payload];
  final crc = A5Protocol.crc16(body, 0, body.length);
  return [...body, crc & 0xFF, (crc >> 8) & 0xFF];
}

void main() {
  // ---------------------------------------------------------------------------
  // 抓包来源：BLE调试宝_realtime_log_20260403221411.txt
  //   21:52:55> [0000ffe9] 成功写入: "A5 47 3A D2"
  //   21:52:55> [0000ffe4] Notify: "A5 47 5A 04 3A 1F 05 4E C1 1A 69 79 1F 6C 1A 01 85 6F 15 3A"
  //   21:52:55> [0000ffe4] Notify: "8D 4C C8 00"
  //   21:54:36> [0000ffe9] 成功写入: "A5 4D BA D5"
  //   22:05:29> [0000ffe9] 成功写入: "A5 47 3A D2"
  //   22:05:29> [0000ffe4] Notify: "A5 47 B1 70 51 8B 08 75 45 2F F5 E7 B6 18 2F F5 BF C8 A1 51"
  //   22:05:29> [0000ffe4] Notify: "F9 47 89 8C"
  // ---------------------------------------------------------------------------

  group('帧构建与真实抓包逐字节一致', () {
    test('readRealtime() == A5 47 3A D2', () {
      expect(A5Protocol.hex(A5Protocol.readRealtime()), 'A5 47 3A D2');
    });

    test('readParamTable() == A5 4D BA D5', () {
      expect(A5Protocol.hex(A5Protocol.readParamTable()), 'A5 4D BA D5');
    });

    test('readHolding(0x0010, 2) == A5 03 00 10 00 02 DC EA', () {
      expect(
        A5Protocol.hex(A5Protocol.readHolding(A5Protocol.regCoeff, 2)),
        'A5 03 00 10 00 02 DC EA',
      );
    });

    test('writeCoeffMulti(9.99) == A5 10 00 10 00 02 04 41 1F D7 0A 1F 9C', () {
      expect(
        A5Protocol.hex(A5Protocol.writeCoeffMulti(9.99)),
        'A5 10 00 10 00 02 04 41 1F D7 0A 1F 9C',
      );
    });

    test('0x06 两段写 K=2.318（float 位型 0x40145A1D）', () {
      expect(
        A5Protocol.hex(A5Protocol.writeCoeffSingleHigh(2.318)),
        'A5 06 00 10 40 14 A0 E4',
      );
      expect(
        A5Protocol.hex(A5Protocol.writeCoeffSingleLow(2.318)),
        'A5 06 00 11 5A 1D 3A 42',
      );
    });

    test('CRC16/MODBUS 覆盖 A5 + 功能码 + 载荷，低字节在前', () {
      // A5 47 -> CRC 0xD23A，发送顺序 3A D2
      expect(A5Protocol.crc16(hx('A5 47'), 0, 2), 0xD23A);
      // A5 4D -> CRC 0xD5BA，发送顺序 BA D5
      expect(A5Protocol.crc16(hx('A5 4D'), 0, 2), 0xD5BA);
    });
  });

  group('真实响应帧校验与解析', () {
    test('22:05:29 的 0x47 响应 validate == 20 且能解析出 5 个 float', () {
      final frame = hx('A5 47 B1 70 51 8B 08 75 45 2F F5 E7 B6 18 2F F5 BF C8 A1 51 F9 47 89 8C');
      expect(A5Protocol.validate(frame), 20);

      final vals = A5Protocol.parseRealtime(frame);
      expect(vals, isNotNull);
      expect(vals!.length, 5);
      // 五个字段都是有限数（设备回的是合法 float，即使数值本身是 0）
      for (final v in vals) {
        expect(v.isNaN, isFalse);
      }
    });

    test('21:52:55 的 0x47 响应 validate == 20', () {
      final frame = hx('A5 47 5A 04 3A 1F 05 4E C1 1A 69 79 1F 6C 1A 01 85 6F 15 3A 8D 4C C8 00');
      expect(A5Protocol.validate(frame), 20);
      expect(A5Protocol.parseRealtime(frame), isNotNull);
    });

    test('功能码不匹配时 parseRealtime 返回 null', () {
      final frame = hx('A5 03 04 41 1F AE 14 46 6C');
      expect(A5Protocol.validate(frame), 5);
      expect(A5Protocol.parseRealtime(frame), isNull);
    });

    test('CRC 被破坏时 validate 返回 -1', () {
      expect(A5Protocol.validate(hx('A5 47 3A 00')), -1);
      expect(A5Protocol.validate(hx('A5 47 3A')), -1);
    });
  });

  group('分片重组（抓包中 24B 的 0x47 帧被拆成 20B + 4B）', () {
    final part1 = hx('A5 47 B1 70 51 8B 08 75 45 2F F5 E7 B6 18 2F F5 BF C8 A1 51');
    final part2 = hx('F9 47 89 8C');

    test('分片长度确实是 20 + 4 = 24', () {
      expect(part1.length, 20);
      expect(part2.length, 4);
      expect(part1.length + part2.length, 24);
    });

    test('单独看任一分片都取不到完整帧', () {
      expect(
        A5Protocol.extractFrame(Uint8List.fromList(part1), A5Protocol.funcReadRealtime),
        isNull,
      );
      expect(
        A5Protocol.extractFrame(Uint8List.fromList(part2), A5Protocol.funcReadRealtime),
        isNull,
      );
    });

    test('拼接重组后可取到完整帧并解析（BleService._rxBuffer 的行为）', () {
      final joined = Uint8List.fromList([...part1, ...part2]);
      final frame = A5Protocol.extractFrame(joined, A5Protocol.funcReadRealtime);
      expect(frame, isNotNull);
      expect(frame!.length, 24);
      expect(A5Protocol.validate(frame), 20);

      final vals = A5Protocol.parseRealtime(frame);
      expect(vals, isNotNull);
      expect(vals!.length, 5);
    });

    test('extractFrame 能在噪声前缀之后定位帧', () {
      final noisy = Uint8List.fromList([0x00, 0xFF, 0x12, ...part1, ...part2]);
      final frame = A5Protocol.extractFrame(noisy, A5Protocol.funcReadRealtime);
      expect(frame, isNotNull);
      expect(frame!.length, 24);
    });
  });

  group('0x03 系数回读解析', () {
    test('9.98 的读回帧', () {
      final bd = ByteData(4)..setFloat32(0, 9.98, Endian.big);
      final bits = bd.getUint32(0, Endian.big);
      final frame = build(A5Protocol.funcReadHolding, <int>[
        0x04, // 字节数
        (bits >> 24) & 0xFF,
        (bits >> 16) & 0xFF,
        (bits >> 8) & 0xFF,
        bits & 0xFF,
      ]);
      expect(A5Protocol.validate(frame), 5);
      final v = A5Protocol.parseHoldingFloat(frame);
      expect(v, isNotNull);
      expect(v!, closeTo(9.98, 0.001));
    });

    test('字节数不是 4 时返回 null', () {
      final frame = build(A5Protocol.funcReadHolding, <int>[0x02, 0x12, 0x34]);
      expect(A5Protocol.parseHoldingFloat(frame), isNull);
    });
  });

  group('写回执与异常帧', () {
    test('0x10 回执：只要 CRC 通过即认为是回执（与原安卓实现一致）', () {
      // Modbus 惯例：回显 reg + count（4 字节载荷）
      expect(
        A5Protocol.parseWriteMultiAck(build(A5Protocol.funcWriteMulti, <int>[0x00, 0x10, 0x00, 0x02])),
        isTrue,
      );
      // 某些固件回显 5 字节载荷，也必须接受
      expect(
        A5Protocol.parseWriteMultiAck(build(A5Protocol.funcWriteMulti, <int>[0x00, 0x10, 0x00, 0x02, 0x04])),
        isTrue,
      );
      // 功能码不符
      expect(
        A5Protocol.parseWriteMultiAck(build(A5Protocol.funcReadRealtime, <int>[])),
        isFalse,
      );
    });

    test('0x06 回执：回显完整请求帧（5 字节载荷）', () {
      expect(
        A5Protocol.parseWriteSingleAck(build(A5Protocol.funcWriteSingle, <int>[0x00, 0x10, 0x40, 0x14])),
        isTrue,
      );
    });

    test('异常帧 A5 D3 06 crc 解析出从机繁忙 0x06', () {
      // 0x47 | 0x80 == 0xC7；0x10 | 0x80 == 0x90；此处用 0xC7 示例
      final frame = build(0xC7, <int>[0x06]);
      expect(frame.length, 5, reason: '异常帧固定 5 字节');
      expect(A5Protocol.validate(frame), 1, reason: '载荷长度应为 1');
      expect(A5Protocol.parseException(frame), A5Protocol.errBusy);
    });

    test('异常帧：0x90（0x10|0x80）+ 忙碌码', () {
      final frame = build(0x90, <int>[0x06]);
      expect(A5Protocol.parseException(frame), 0x06);
    });

    test('普通帧不会被误判为异常帧', () {
      expect(A5Protocol.parseException(A5Protocol.readRealtime()), isNull);
      expect(A5Protocol.parseException(hx('A5 47 B1 70 51 8B 08 75 45 2F F5 E7 B6 18 2F F5 BF C8 A1 51 F9 47 89 8C')), isNull);
    });
  });
}

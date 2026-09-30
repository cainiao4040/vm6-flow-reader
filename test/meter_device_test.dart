import 'package:flutter_test/flutter_test.dart';
import 'package:vm6_flow_reader/models/meter_device.dart';

void main() {
  group('MeterDevice 人工备注', () {
    test('toMap / fromMap 往返保留 note', () {
      const m = MeterDevice(
        id: 7,
        serialNumber: 'B4:52:A9:D0:10:FB',
        displayName: '1号井流量计',
        note: '王家坡计量间，负责人王工 138xxxx',
      );
      final back = MeterDevice.fromMap(m.toMap());
      expect(back.id, 7);
      expect(back.serialNumber, 'B4:52:A9:D0:10:FB');
      expect(back.displayName, '1号井流量计');
      expect(back.note, '王家坡计量间，负责人王工 138xxxx');
      expect(back.hasNote, isTrue);
    });

    test('旧库没有 note 列时 fromMap 不崩，note 为 null', () {
      // 这是 v1 数据库里的一行：没有 note 键
      final legacy = <String, dynamic>{
        'id': 1,
        'serial_number': 'AA:BB:CC:DD:EE:FF',
        'display_name': '旧设备',
        'metadata_json': '{"coefficient":9.99}',
      };
      final m = MeterDevice.fromMap(legacy);
      expect(m.note, isNull);
      expect(m.hasNote, isFalse);
      expect(m.coefficient, closeTo(9.99, 1e-9));
    });

    test('hasNote 对纯空白字符串返回 false', () {
      const m = MeterDevice(serialNumber: 'x', displayName: 'x', note: '   ');
      expect(m.hasNote, isFalse);
    });

    test('copyWith 保留 note（saveCoefficient 走的就是这条路）', () {
      const m = MeterDevice(serialNumber: 'x', displayName: 'x', note: '备注A');
      final updated = m.copyWith(metadataJson: '{"coefficient":1.5}');
      expect(updated.note, '备注A',
          reason: '只更新系数不应该把人工备注清掉');
      expect(updated.coefficient, closeTo(1.5, 1e-9));
    });

    test('coefficient / originalCoefficient 解析', () {
      const m = MeterDevice(
        serialNumber: 'x',
        displayName: 'x',
        metadataJson: '{"coefficient":9.99,"originalCoefficient":2.318}',
      );
      expect(m.coefficient, closeTo(9.99, 1e-9));
      expect(m.originalCoefficient, closeTo(2.318, 1e-9));
    });

    test('metadata_json 损坏时不抛异常', () {
      const m = MeterDevice(
          serialNumber: 'x', displayName: 'x', metadataJson: 'not json');
      expect(m.coefficient, isNull);
      expect(m.originalCoefficient, isNull);
    });

    test('toMap 一定带 note 键（供 upsert 使用）', () {
      const m = MeterDevice(serialNumber: 'x', displayName: 'x');
      expect(m.toMap().containsKey('note'), isTrue);
    });
  });
}

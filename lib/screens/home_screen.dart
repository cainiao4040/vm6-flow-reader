import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import '../models/live_metrics.dart';
import '../services/ble_service.dart';
import '../services/storage_service.dart';
import 'coefficient_screen.dart';
import 'devices_screen.dart';
import 'records_screen.dart';
import 'scan_screen.dart';
import 'settings_screen.dart';

/// 主界面：连接状态 + 实时数据 + 操作入口
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final BleService _ble = BleService.instance;
  final StorageService _storage = StorageService.instance;

  LiveMetrics? _latest; // 仅接受 0x47 实时帧
  double? _coefficient; // 0x47 与 0x03 都会更新
  String _statusText = '未连接';
  final List<String> _logs = [];
  String? _coefficientHint;

  @override
  void initState() {
    super.initState();
    _ble.initStatusListener();
    _ble.liveDataStream.listen((m) {
      if (!mounted) return;
      setState(() {
        if (m.isRealtime) {
          // 0x47：五个字段齐全，整帧替换
          _latest = m;
          _coefficient = m.coefficient ?? _coefficient;
        } else {
          // 0x03 读系数帧：只有 coefficient 有效。绝不能覆盖 _latest，
          // 否则占位的 instantFlow=0 会把「瞬时流量」显示成 0.0000。
          _coefficient = m.coefficient ?? _coefficient;
        }
      });
    });
    _ble.logStream.listen((line) {
      if (_logs.length > 200) _logs.removeAt(0);
      _logs.add(line);
    });
    _ble.statusStream.listen((s) {
      setState(() {
        if (s == BleStatus.poweredOff) {
          _statusText = '蓝牙未开启';
        } else if (s == BleStatus.unauthorized) {
          _statusText = '蓝牙未授权';
        } else {
          _statusText = _ble.isConnected ? '已连接' : '未连接';
        }
      });
    });
    _loadCoefficientHint();
  }

  Future<void> _loadCoefficientHint() async {
    final saved = await _storage.getAllSavedDevices();
    if (saved.isEmpty) return;
    final last = saved.first;
    final serial = (last['device_id'] as String?) ?? '';
    final c = await _storage.getCoefficient(serial);
    if (mounted && c != null) {
      setState(() => _coefficientHint = '最近设备 ${last['name'] ?? serial} 系数 K=$c');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('VM6 流量计'),
        actions: [
          IconButton(
            tooltip: '设备与备注',
            icon: const Icon(Icons.edit_note_outlined),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const DevicesScreen())),
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _ble.refreshData();
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildConnectionCard(),
            const SizedBox(height: 12),
            _buildLiveCard(),
            const SizedBox(height: 12),
            _buildActionRow(),
            const SizedBox(height: 12),
            _buildLogCard(),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionCard() {
    final connected = _ble.isConnected;
    return Card(
      child: ListTile(
        leading: Icon(
          connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
          color: connected ? Colors.green : Colors.grey,
          size: 36,
        ),
        title: Text(_statusText),
        subtitle: Text(
          connected
              ? '${_ble.deviceName ?? ''} ${_ble.deviceId ?? ''}'
              : '点击下方按钮连接设备',
        ),
        trailing: IconButton(
          icon: const Icon(Icons.search),
          tooltip: '扫描设备',
          onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const ScanScreen())),
        ),
      ),
    );
  }

  Widget _buildLiveCard() {
    final m = _latest;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('实时数据', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _metric('瞬时流量', m?.instantFlow, 'm³/h'),
                ),
                Expanded(
                  child: _metric('累计流量', m?.cumulativeFlow, 'm³'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _metric('压力', m?.pressure, 'kPa')),
                Expanded(child: _metric('温度', m?.temperature, '℃')),
                Expanded(child: _metric('系数 K', _coefficient, '')),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '原始帧: ${m?.rawHex ?? '-'}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            Text(
              '时间: ${m == null ? '-' : m.timestamp.toIso8601String()}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, double? v, String unit) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Text(
          v == null ? '-' : v.toStringAsFixed(4),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        if (unit.isNotEmpty)
          Text(unit, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }

  Widget _buildActionRow() {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: _ble.isConnected ? () => _ble.refreshData() : null,
            icon: const Icon(Icons.refresh),
            label: const Text('手动抄表'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.icon(
            onPressed: _ble.isConnected
                ? () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const CoefficientScreen()))
                : null,
            icon: const Icon(Icons.tune),
            label: const Text('系数设置'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const RecordsScreen())),
            icon: const Icon(Icons.history),
            label: const Text('历史记录'),
          ),
        ),
      ],
    );
  }

  Widget _buildLogCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('通信日志', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('包 ${_ble.packetCount} / 解析 ${_ble.parsedCount}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
            if (_coefficientHint != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_coefficientHint!,
                    style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
              ),
            const Divider(height: 12),
            ..._logs.reversed.take(12).map(
                  (l) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(l,
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

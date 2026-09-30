import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/meter_device.dart';
import '../services/ble_service.dart';
import '../services/storage_service.dart';

/// 设备扫描界面：权限申请 → 扫描 → 连接
///
/// 连接状态是**按行独立**的（_connectingId），不再用一个全局布尔值——
/// 之前点任意一行都会让整个列表变成转圈，看起来像在同时连接所有设备。
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final BleService _ble = BleService.instance;
  final StorageService _storage = StorageService.instance;
  final List<DiscoveredDevice> _devices = [];

  /// 正在连接的设备 id。null = 空闲。只影响对应的那一行。
  String? _connectingId;

  /// 默认只看 VM 系列表具，避免列表被耳机、手表等设备淹没。
  /// 若表具没有广播名称，关掉这个开关就能看到全部设备。
  bool _onlyMeters = true;

  @override
  void initState() {
    super.initState();
    _ble.deviceStream.listen((d) {
      if (!mounted) return;
      setState(() {
        final i = _devices.indexWhere((e) => e.id == d.id);
        if (i < 0) {
          _devices.add(d);
        } else {
          _devices[i] = d; // 刷新 RSSI
        }
      });
    });
    _requestPermissionsAndStartScan();
  }

  /// 表具（VM 开头）置顶，其余按信号强度降序。
  List<DiscoveredDevice> get _visible {
    final list = _devices
        .where((d) => !_onlyMeters || BleService.isVm6Device(d.name))
        .toList();
    list.sort((a, b) {
      final av = BleService.isVm6Device(a.name);
      final bv = BleService.isVm6Device(b.name);
      if (av != bv) return av ? -1 : 1;
      return b.rssi.compareTo(a.rssi);
    });
    return list;
  }

  Future<void> _requestPermissionsAndStartScan() async {
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.location.request();
    _ble.startScan();
  }

  @override
  void dispose() {
    _ble.stopScan();
    super.dispose();
  }

  Future<void> _connect(DiscoveredDevice d) async {
    if (_connectingId != null) return; // 同一时间只允许一个连接流程
    setState(() => _connectingId = d.id);
    try {
      final ok = await _ble.connectToDevice(d.id, d.name);
      if (!mounted) return;
      if (ok) {
        await _storage.upsertSavedDevice(
          deviceId: d.id,
          name: d.name,
          rssi: d.rssi,
          connectionPhase: 'connected',
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已连接 ${d.name}，开始自动抄表（3 秒轮询）')),
        );
        _ble.startAutoPolling(intervalSeconds: 3);
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('连接失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  /// 点设备名称即可先写人工备注（不必先连接）。
  Future<void> _editNote(DiscoveredDevice d) async {
    final existing = await _storage.getMeterBySerial(d.id);
    if (!mounted) return;

    final defaultName = (existing != null && existing.displayName.isNotEmpty)
        ? existing.displayName
        : (d.name.isEmpty ? d.id : d.name);
    final nameCtrl = TextEditingController(text: defaultName);
    final noteCtrl = TextEditingController(text: existing?.note ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设备备注'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('设备标识：${d.id}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 14),
              const Text('显示名称', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                    hintText: '例如：1号井流量计',
                    border: OutlineInputBorder(),
                    isDense: true),
              ),
              const SizedBox(height: 16),
              const Text('人工备注', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              TextField(
                controller: noteCtrl,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                    hintText: '例如：王家坡计量间，负责人王工 138xxxx',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (saved != true) return;

    final name = nameCtrl.text.trim().isEmpty ? defaultName : nameCtrl.text.trim();
    final note = noteCtrl.text.trim();
    final id = existing?.id;
    if (existing == null || id == null) {
      await _storage.upsertMeter(MeterDevice(
        serialNumber: d.id,
        displayName: name,
        type: 'flow-meter',
        model: 'VM6',
        status: 'seen',
        note: note,
        lastSeenAt: DateTime.now().toIso8601String(),
      ));
    } else {
      await _storage.updateMeterInfo(id, displayName: name, note: note);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已保存「$name」的备注')));
  }

  Widget _header() {
    final connecting = _connectingId;
    final shown = _visible.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _onlyMeters ? 'VM 系列表具（$shown）' : '附近蓝牙设备（$shown）',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              TextButton.icon(
                onPressed: connecting != null
                    ? null
                    : () {
                        _devices.clear();
                        _ble.startScan();
                      },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新扫描'),
              ),
            ],
          ),
          Row(
            children: [
              Switch(
                value: _onlyMeters,
                onChanged: connecting != null
                    ? null
                    : (v) => setState(() => _onlyMeters = v),
              ),
              const SizedBox(width: 4),
              const Expanded(
                child: Text(
                  '只看表具（关闭可显示全部蓝牙设备）· 点设备名可写备注',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          ),
          if (connecting != null)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 8),
                  Text('正在连接…', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = _visible;
    return Scaffold(
      appBar: AppBar(title: const Text('扫描设备')),
      body: Column(
        children: [
          _header(),
          if (_devices.isEmpty)
            const Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('正在扫描...'),
                  ],
                ),
              ),
            )
          else if (list.isEmpty)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.search_off, size: 40, color: Colors.grey),
                      const SizedBox(height: 12),
                      Text(
                        '已发现 ${_devices.length} 个蓝牙设备，但没有 VM 系列表具。\n'
                        '关闭上面的「只看表具」开关查看全部。',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final d = list[i];
                  final isMeter = BleService.isVm6Device(d.name);
                  final isThis = _connectingId == d.id;
                  final busy = _connectingId != null;

                  return ListTile(
                    onTap: busy ? null : () => _editNote(d),
                    leading: Icon(
                      isMeter ? Icons.speed : Icons.bluetooth_searching,
                      color: isMeter ? Colors.teal : null,
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            d.name.isEmpty ? '(未命名设备)' : d.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isMeter)
                          const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Text('表具',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.teal)),
                          ),
                      ],
                    ),
                    subtitle: Text(
                      '${d.id}\nRSSI: ${d.rssi.toString()}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    isThreeLine: true,
                    // 只有被点的那一行显示转圈；其余行保持按钮但禁用
                    trailing: isThis
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : FilledButton(
                            onPressed: busy ? null : () => _connect(d),
                            child: const Text('连接'),
                          ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

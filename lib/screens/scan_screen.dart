import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/ble_service.dart';
import '../services/storage_service.dart';

/// 设备扫描界面：权限申请 → 扫描 → 连接
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final BleService _ble = BleService.instance;
  final StorageService _storage = StorageService.instance;
  final List<DiscoveredDevice> _devices = [];
  bool _connecting = false;

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
  List<DiscoveredDevice> get _sorted {
    final list = [..._devices];
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
    if (_connecting) return;
    setState(() => _connecting = true);
    try {
      final ok = await _ble.connectToDevice(d.id, d.name);
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
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('连接失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫描设备')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Expanded(
                  child: Text('附近蓝牙设备（VM 系列表具置顶）：'),
                ),
                TextButton.icon(
                  onPressed: () {
                    _devices.clear();
                    _ble.startScan();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新扫描'),
                ),
              ],
            ),
          ),
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
          else
            Expanded(
              child: ListView.builder(
                itemCount: _sorted.length,
                itemBuilder: (context, i) {
                  final d = _sorted[i];
                  final isMeter = BleService.isVm6Device(d.name);
                  return ListTile(
                    leading: Icon(
                      isMeter
                          ? Icons.speed
                          : Icons.bluetooth_searching,
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
                    trailing: _connecting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : FilledButton(
                            onPressed: () => _connect(d),
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

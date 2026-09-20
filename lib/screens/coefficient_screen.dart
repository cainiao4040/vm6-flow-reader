import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/ble_service.dart';
import '../services/storage_service.dart';

/// 流量系数设置页：
/// 读取当前系数 → 输入新系数 → 写入（0x10 一次写，可选 0x06 两段）→
/// 延时 1s 回读 0x03 容差校验 ±max(0.0001, |K|×0.001)
class CoefficientScreen extends StatefulWidget {
  const CoefficientScreen({super.key});

  @override
  State<CoefficientScreen> createState() => _CoefficientScreenState();
}

class _CoefficientScreenState extends State<CoefficientScreen> {
  final BleService _ble = BleService.instance;
  final StorageService _storage = StorageService.instance;
  final TextEditingController _kController = TextEditingController();
  bool _useSplitWrite = false;
  bool _busy = false;
  String? _deviceSerial;
  String? _deviceName;
  double? _currentK;
  double? _originalK;
  final List<String> _verifyLogs = [];

  @override
  void initState() {
    super.initState();
    _load();
    _ble.verificationStream.listen((msg) {
      if (!mounted) return;
      setState(() {
        _verifyLogs.insert(0, msg);
        _busy = false;
      });
    });
  }

  Future<void> _load() async {
    final saved = await _storage.getAllSavedDevices();
    if (saved.isEmpty) return;
    final last = saved.first;
    final serial = (last['device_id'] as String?) ?? '';
    final name = (last['name'] as String?) ?? serial;
    final k = await _storage.getCoefficient(serial);
    final orig = await _storage.getOriginalCoefficient(serial);
    if (mounted) {
      setState(() {
        _deviceSerial = serial;
        _deviceName = name;
        _currentK = k;
        _originalK = orig;
        _kController.text = (k ?? orig ?? 1.0).toStringAsFixed(4);
      });
    }
  }

  Future<void> _readCurrent() async {
    await _ble.refreshData();
    final k = _ble.lastVerifiedCoefficient ?? _currentK;
    if (mounted && k != null) {
      setState(() => _currentK = k);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('当前系数 K=$k')));
    }
  }

  Future<void> _write() async {
    final v = double.tryParse(_kController.text);
    if (v == null || !v.isFinite || v <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入有效的正数系数')));
      return;
    }
    if (!_ble.isConnected) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('未连接设备')));
      return;
    }
    setState(() => _busy = true);
    _verifyLogs.clear();
    final ok = await _ble.writeCoefficient(v, useSplitWrite: _useSplitWrite);
    // 无论 ok 与否，写入值都已持久化，回读校验结果见日志
    await _storage.saveCoefficient(
        _deviceSerial ?? _ble.deviceId ?? '', _deviceName ?? '', v);
    await _storage.saveOriginalCoefficient(
        _deviceSerial ?? _ble.deviceId ?? '',
        _deviceName ?? '',
        _originalK ?? _currentK ?? 1.0);
    if (mounted) {
      setState(() {
        _currentK = v;
        _busy = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '写入并校验通过' : '写入完成但校验未通过，详见日志')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tol = _currentK == null
        ? '--'
        : _toleranceText(_currentK!);
    return Scaffold(
      appBar: AppBar(title: const Text('流量系数设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              title: Text(_deviceName ?? '未连接设备'),
              subtitle: Text(_deviceSerial ?? '--'),
              trailing: Text(_ble.isConnected ? '已连接' : '未连接',
                  style: TextStyle(
                      color: _ble.isConnected ? Colors.green : Colors.red)),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前系数 K: ${_currentK?.toStringAsFixed(4) ?? '-'}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  if (_originalK != null)
                    Text('原始系数: ${_originalK!.toStringAsFixed(4)}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  Text('校验容差: ±max(0.0001, |K|×0.001) = $tol',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _kController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: const InputDecoration(
                      labelText: '新系数 K',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: const Text('使用 0x06 分两段写入'),
                    subtitle: const Text('高16位@0x0010 → 低16位@0x0011，对齐抓包样本'),
                    value: _useSplitWrite,
                    onChanged: (v) => setState(() => _useSplitWrite = v),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _busy ? null : _readCurrent,
                          child: const Text('读取'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: _busy ? null : _write,
                          child: _busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('写入并校验'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('校验日志', style: TextStyle(fontWeight: FontWeight.bold)),
                  const Divider(height: 12),
                  if (_verifyLogs.isEmpty)
                    const Text('暂无校验记录', style: TextStyle(color: Colors.grey))
                  else
                    ..._verifyLogs.take(20).map((l) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(l,
                              style: const TextStyle(
                                  fontSize: 12, fontFamily: 'monospace')),
                        )),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _toleranceText(double k) {
    final t = k.abs() * 0.001;
    return t < 0.0001 ? '0.0001' : t.toStringAsFixed(4);
  }
}

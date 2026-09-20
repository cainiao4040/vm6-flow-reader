import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/ble_service.dart';

/// 设置页：轮询间隔 / 看门狗 / 权限状态 / 参数表读取
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final BleService _ble = BleService.instance;
  int _interval = 3;
  bool _watchdog = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _interval = prefs.getInt('poll_interval') ?? 3;
        _watchdog = prefs.getBool('watchdog_enabled') ?? true;
      });
    }
  }

  Future<void> _apply() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('poll_interval', _interval);
    await prefs.setBool('watchdog_enabled', _watchdog);
    if (_ble.isConnected) {
      _ble.startAutoPolling(intervalSeconds: _interval);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已应用：轮询 ${_interval}s，看门狗${_watchdog ? '开' : '关'}')),
      );
    }
  }

  Future<void> _readParamTable() async {
    setState(() => _busy = true);
    await _ble.sendReadParamTable();
    unawaited(_consumeParamTable());
  }

  Future<void> _consumeParamTable() async {
    StreamSubscription<List<double>>? sub;
    sub = _ble.paramTableStream.listen((vals) {
      if (!mounted) return;
      sub?.cancel();
      setState(() => _busy = false);
      _showParamTable(vals);
    });
    Timer(const Duration(seconds: 6), () {
      if (_busy && mounted) {
        sub?.cancel();
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('等待参数表响应超时（6s）')),
        );
      }
    });
  }

  void _showParamTable(List<double> vals) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('参数表（0x4D，35 项）',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Divider(),
          for (var i = 0; i < vals.length; i++)
            ListTile(
              dense: true,
              title: Text('参数 ${i.toString().padLeft(2, '0')}'),
              trailing: Text(vals[i].toStringAsFixed(4),
                  style: const TextStyle(fontFamily: 'monospace')),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          TextButton(onPressed: _apply, child: const Text('应用')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('自动轮询间隔'),
                  subtitle: Text('$_interval 秒（默认 3s）'),
                  trailing: DropdownButton<int>(
                    value: _interval,
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('1s')),
                      DropdownMenuItem(value: 3, child: Text('3s')),
                      DropdownMenuItem(value: 5, child: Text('5s')),
                      DropdownMenuItem(value: 10, child: Text('10s')),
                    ],
                    onChanged: (v) => setState(() => _interval = v ?? 3),
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.security_outlined),
                  title: const Text('看门狗自动重连'),
                  subtitle: const Text('连续 3 次轮询无有效帧时断开并 800ms 退避重连'),
                  value: _watchdog,
                  onChanged: (v) => setState(() => _watchdog = v),
                ),
              ],
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.table_chart_outlined),
              title: const Text('读取设备参数表'),
              subtitle: const Text('发送 A5 0x4D，解析 140B = 35×float32'),
              trailing: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      icon: const Icon(Icons.play_arrow),
                      onPressed: _ble.isConnected ? _readParamTable : null,
                    ),
            ),
          ),
          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.bluetooth),
                  title: Text('蓝牙权限'),
                  subtitle: Text('iOS 需授权蓝牙与定位才能扫描连接'),
                ),
                ListTile(
                  title: const Text('请求权限'),
                  trailing: FilledButton.tonal(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await Permission.bluetoothScan.request();
                      await Permission.bluetoothConnect.request();
                      await Permission.location.request();
                      messenger.showSnackBar(
                        const SnackBar(content: Text('权限请求已发送')),
                      );
                    },
                    child: const Text('请求'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

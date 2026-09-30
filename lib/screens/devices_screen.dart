import 'package:flutter/material.dart';

import '../models/meter_device.dart';
import '../services/storage_service.dart';

/// 设备与备注：列出所有表具，人工修改显示名称与备注信息。
///
/// 备注存在 meters.note（v2 新增列），与读数、系数互不影响。
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  final StorageService _storage = StorageService.instance;
  List<MeterDevice> _meters = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await _storage.getAllMeters();
    if (!mounted) return;
    setState(() {
      _meters = list;
      _loading = false;
    });
  }

  Future<void> _edit(MeterDevice m) async {
    final nameCtrl = TextEditingController(text: m.displayName);
    final noteCtrl = TextEditingController(text: m.note ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设备信息'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('设备标识：${m.serialNumber}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 14),
              const Text('显示名称', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  hintText: '例如：1号井流量计',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
              const Text('人工备注', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              TextField(
                controller: noteCtrl,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  hintText: '例如：王家坡计量间，2026-03 更换电池，负责人王工 138xxxx',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (saved != true) return;
    final id = m.id;
    if (id == null) return;

    final newName = nameCtrl.text.trim();
    await _storage.updateMeterInfo(
      id,
      displayName: newName.isEmpty ? m.displayName : newName,
      note: noteCtrl.text.trim(),
    );
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已保存')));
  }

  Future<void> _delete(MeterDevice m) async {
    final id = m.id;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除设备'),
        content: Text('确定删除「${m.displayName.isEmpty ? m.serialNumber : m.displayName}」？\n'
            '该设备的读数记录不会被删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _storage.deleteMeter(id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设备与备注'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _meters.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '还没有设备记录。\n\n先到「扫描设备」连接一台表具，或者\n在扫描列表里点一下设备名称就能先写备注。',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: _meters.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final m = _meters[i];
                    return ListTile(
                      leading: const Icon(Icons.speed, color: Colors.teal),
                      title: Text(
                        m.displayName.isEmpty ? m.serialNumber : m.displayName,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(m.serialNumber,
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey)),
                          if (m.hasNote)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text('备注：${m.note}',
                                  style: const TextStyle(fontSize: 12)),
                            )
                          else
                            const Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: Text('（无备注，点击添加）',
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.grey)),
                            ),
                          if (m.coefficient != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                  '系数 K=${m.coefficient!.toStringAsFixed(4)}',
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.grey)),
                            ),
                        ],
                      ),
                      isThreeLine: true,
                      onTap: () => _edit(m),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'edit') {
                            _edit(m);
                          } else if (v == 'delete') {
                            _delete(m);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('编辑名称/备注')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}

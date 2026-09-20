import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/reading_record.dart';
import '../services/storage_service.dart';

/// 历史抄表记录页
class RecordsScreen extends StatefulWidget {
  const RecordsScreen({super.key});

  @override
  State<RecordsScreen> createState() => _RecordsScreenState();
}

class _RecordsScreenState extends State<RecordsScreen> {
  final StorageService _storage = StorageService.instance;
  List<ReadingRecord> _records = [];
  bool _loading = true;
  String _filter = '全部';

  static const _filters = ['全部', '今天', '本周'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    List<ReadingRecord> list;
    final now = DateTime.now();
    if (_filter == '今天') {
      final start = DateTime(now.year, now.month, now.day);
      list = await _storage.getReadingsByDateRange(
          start, start.add(const Duration(days: 1)));
    } else if (_filter == '本周') {
      final start =
          now.subtract(Duration(days: now.weekday - 1)); // 周一起
      list = await _storage.getReadingsByDateRange(
          start, now.add(const Duration(days: 1)));
    } else {
      list = await _storage.getReadings(limit: 500);
    }
    if (mounted) {
      setState(() {
        _records = list;
        _loading = false;
      });
    }
  }

  Future<void> _delete(int id) async {
    await _storage.deleteReading(id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('历史抄表记录'),
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: SegmentedButton<String>(
              segments: _filters
                  .map((f) => ButtonSegment(value: f, label: Text(f)))
                  .toList(),
              selected: {_filter},
              onSelectionChanged: (s) {
                setState(() => _filter = s.first);
                _load();
              },
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _records.isEmpty
                    ? const Center(child: Text('暂无记录'))
                    : ListView.builder(
                        itemCount: _records.length,
                        itemBuilder: (context, i) {
                          final r = _records[i];
                          final time = r.recordedAt ?? r.receivedAt;
                          return Dismissible(
                            key: ValueKey('${r.id}_$i'),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              color: Colors.red,
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              child: const Icon(Icons.delete,
                                  color: Colors.white),
                            ),
                            onDismissed: (_) {
                              final id = r.id;
                              if (id != null) _delete(id);
                            },
                            child: ListTile(
                              leading: const Icon(Icons.water_drop),
                              title: Text(
                                  '流量 ${r.flowRate.toStringAsFixed(4)} ${r.unit}'),
                              subtitle: Text(
                                '${time == null ? '-' : DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.parse(time))}'
                                '${r.temperature != null ? '  温度 ${r.temperature!.toStringAsFixed(2)}℃' : ''}'
                                '${r.pressure != null ? '  压力 ${r.pressure!.toStringAsFixed(4)}MPa' : ''}',
                                style: const TextStyle(fontSize: 12),
                              ),
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

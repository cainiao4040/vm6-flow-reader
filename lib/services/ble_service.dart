import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import '../models/live_metrics.dart';
import 'a5_protocol.dart';

/// BLE 核心服务（单例）
///
/// 规格来源：APK 深度解析报告 §3.1/§3.2/§3.3/§3.4。
///
/// 连接方案（与原版 APK 等价）：
///   - 目标特征：写 0000ffe9、通知 0000ffe4（报告确认 APK 内置 UUID 直接命中）；
///   - 连接后 discoverServices → 订阅通知特征（优先 ffe4，未命中则订阅全部
///     NOTIFY/INDICATE）→ 写通道优先 ffe9，未命中则逐个候选写通道发 A5 测试命令探测。
///
/// 业务流：
///   - 3 秒自动轮询 2 条 A5 读命令（0x47 实时 5×float32 / 0x03 读系数 K@0x0010），
///     命令间隔 300ms；
///   - 系数写入：默认 0x10 一次写两寄存器（可选 0x06 两段写，对齐抓包样本），
///     写后延时 1s 回读 0x03 容差校验（|回读-写入| ≤ max(0.0001, |K|×0.001)）；
///   - 从机繁忙（异常码 0x06）自动重发当前段（最多 3 次，间隔 300ms）；
///   - 看门狗：连续 3 次轮询无有效帧 → 自动断开并带 800ms 退避重连（含风暴锁）。
class BleService {
  BleService._internal();

  static final BleService instance = BleService._internal();

  final FlutterReactiveBle _ble = FlutterReactiveBle();

  // ---- 目标特征 UUID（报告 §3.1 确认） ----
  static const String kWriteUuid = '0000ffe9-0000-1000-8000-00805f9b34fb';
  static const String kNotifyUuid = '0000ffe4-0000-1000-8000-00805f9b34fb';

  // ---- 状态 ----
  bool _isScanning = false;
  bool _isConnected = false;
  String? _deviceId;
  String? _deviceName;
  QualifiedCharacteristic? _writeQc;
  StreamSubscription<ConnectionStateUpdate>? _connectionSub;
  StreamSubscription<DiscoveredDevice>? _scanSub;
  final List<StreamSubscription> _notifySubs = [];

  Timer? _pollingTimer;
  bool _pollingRunning = false;
  int _pollCmdsSent = 0;
  int _emptyPollRounds = 0; // 连续无有效帧轮询次数（看门狗）
  bool _watchdogArmed = false;
  bool _reconnecting = false; // 风暴锁
  bool _noDataDiagnosed = false;

  // ---- 系数校验状态 ----
  bool _verifyPending = false;
  double _pendingCoeff = 0;
  Completer<bool>? _verifyCompleter;
  double? _lastVerifiedCoefficient;

  // ---- 统计 ----
  int _packetCount = 0;
  int _parsedCount = 0;

  // ---- 流 ----
  final StreamController<LiveMetrics> _liveDataController =
      StreamController<LiveMetrics>.broadcast();
  final StreamController<Uint8List> _rawDataController =
      StreamController<Uint8List>.broadcast();
  final StreamController<List<double>> _paramTableController =
      StreamController<List<double>>.broadcast();
  final StreamController<String> _logController =
      StreamController<String>.broadcast();
  final StreamController<String> _verifyResultController =
      StreamController<String>.broadcast();
  final StreamController<BleStatus> _statusController =
      StreamController<BleStatus>.broadcast();
  final StreamController<DiscoveredDevice> _deviceController =
      StreamController<DiscoveredDevice>.broadcast();

  // ---- getter ----
  bool get isScanning => _isScanning;
  bool get isConnected => _isConnected;
  String? get deviceId => _deviceId;
  String? get deviceName => _deviceName;
  bool get hasWriteCharacteristic => _writeQc != null;
  int get packetCount => _packetCount;
  int get parsedCount => _parsedCount;
  double? get lastVerifiedCoefficient => _lastVerifiedCoefficient;

  Stream<LiveMetrics> get liveDataStream => _liveDataController.stream;
  Stream<Uint8List> get rawDataStream => _rawDataController.stream;
  Stream<List<double>> get paramTableStream => _paramTableController.stream;
  Stream<String> get logStream => _logController.stream;
  Stream<String> get verificationStream => _verifyResultController.stream;
  Stream<BleStatus> get statusStream => _statusController.stream;
  Stream<DiscoveredDevice> get deviceStream => _deviceController.stream;

  // ---- 权限/状态监听 ----
  void initStatusListener() {
    _ble.statusStream.listen((status) {
      _statusController.add(status);
    });
    _statusController.add(_ble.status);
  }

  // ==================== 扫描 ====================

  /// 扫描 BLE 设备，筛选目标表具（名称以 VM / VMS 开头，报告：VMS-2720147-KXMJ）
  void startScan() {
    if (_isScanning) return;
    _isScanning = true;
    _log('开始扫描 BLE 设备（筛选: VM / VMS 前缀）');
    try {
      _scanSub?.cancel();
      _scanSub = _ble
          .scanForDevices(
            withServices: const [],
            scanMode: ScanMode.lowLatency,
          )
          .listen(
            (device) {
              final name = device.name.trim();
              if (name.toUpperCase().startsWith('VM') ||
                  name.toUpperCase().startsWith('VMS')) {
                _deviceController.add(device);
              }
            },
            onError: (Object e) {
              _log('扫描出错: $e');
              _isScanning = false;
            },
            onDone: () {
              _isScanning = false;
            },
          );
    } catch (e) {
      _isScanning = false;
      _log('扫描启动失败: $e');
    }
  }

  void stopScan() {
    _isScanning = false;
    _scanSub?.cancel();
    _scanSub = null;
    _log('停止扫描');
  }

  // ==================== 连接 ====================

  Future<bool> connectToDevice(String id, String name) async {
    if (_isConnected && _deviceId == id) return true;
    await disconnect();
    _deviceId = id;
    _deviceName = name;
    _log('正在连接 $name ($id) ...');

    final connected = Completer<bool>();
    try {
      _connectionSub = _ble
          .connectToDevice(
            id: id,
            connectionTimeout: const Duration(seconds: 15),
          )
          .listen(
            (update) {
              if (update.connectionState == DeviceConnectionState.connected) {
                _log('已连接: $name');
                _isConnected = true;
                if (!connected.isCompleted) connected.complete(true);
              } else if (update.connectionState ==
                      DeviceConnectionState.disconnected ||
                  update.connectionState == DeviceConnectionState.disconnecting) {
                if (update.failure != null) {
                  _log('连接中断: ${update.failure}');
                }
                _isConnected = false;
                if (!connected.isCompleted) connected.complete(false);
              }
            },
            onError: (Object e) {
              _log('连接流错误: $e');
              _isConnected = false;
              if (!connected.isCompleted) connected.complete(false);
            },
            onDone: () {
              if (!connected.isCompleted) connected.complete(false);
            },
          );

      final ok = await connected.future;
      if (!ok) {
        _isConnected = false;
        _log('连接失败');
        return false;
      }

      try {
        await _ble.requestMtu(deviceId: id, mtu: 512);
      } catch (_) {}

      await _setupCharacteristics(id);
      return true;
    } catch (e) {
      _isConnected = false;
      _log('连接失败: $e');
      return false;
    }
  }

  Future<void> disconnect() async {
    _stopPolling();
    _isConnected = false;
    for (final s in _notifySubs) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    _notifySubs.clear();
    try {
      await _connectionSub?.cancel();
    } catch (_) {}
    _connectionSub = null;
    _writeQc = null;
    _deviceId = null;
    _deviceName = null;
    _log('已断开连接');
  }

  // ==================== 特征发现/订阅/写通道 ====================

  Future<void> _setupCharacteristics(String deviceId) async {
    List<Service> services;
    try {
      await _ble.discoverAllServices(deviceId);
      services = await _ble.getDiscoveredServices(deviceId);
    } catch (e) {
      _log('服务发现失败: $e');
      return;
    }

    _log('发现服务 ${services.length} 个');

    // 1) 订阅通知特征：优先目标 ffe4，未命中则订阅全部 NOTIFY/INDICATE
    final notifiableChars = <QualifiedCharacteristic>[];
    QualifiedCharacteristic? notifyTarget;
    for (final svc in services) {
      for (final ch in svc.characteristics) {
        if (!ch.isNotifiable && !ch.isIndicatable) continue;
        final qc = QualifiedCharacteristic(
          serviceId: svc.id,
          characteristicId: ch.id,
          deviceId: deviceId,
        );
        notifiableChars.add(qc);
        if (ch.id.toString().toLowerCase() == kNotifyUuid) {
          notifyTarget = qc;
        }
      }
    }
    final toSubscribe = notifyTarget != null
        ? <QualifiedCharacteristic>[notifyTarget]
        : notifiableChars;
    for (final qc in toSubscribe) {
      try {
        final sub = _ble.subscribeToCharacteristic(qc).listen((data) {
          _handleIncoming(Uint8List.fromList(data));
        });
        _notifySubs.add(sub);
        _log('已订阅通知: ${qc.characteristicId}');
      } catch (e) {
        _log('订阅失败 ${qc.characteristicId}: $e');
      }
    }

    // 等待 CCCD 就绪（iOS 时序）
    await Future.delayed(const Duration(milliseconds: 500));

    // 2) 写通道：优先目标 ffe9，未命中则逐个候选写通道发送 A5 读实时测试命令探测
    QualifiedCharacteristic? writeTarget;
    final candidateWrites = <QualifiedCharacteristic>[];
    for (final svc in services) {
      for (final ch in svc.characteristics) {
        if (!ch.isWritableWithResponse && !ch.isWritableWithoutResponse) {
          continue;
        }
        final qc = QualifiedCharacteristic(
          serviceId: svc.id,
          characteristicId: ch.id,
          deviceId: deviceId,
        );
        candidateWrites.add(qc);
        if (ch.id.toString().toLowerCase() == kWriteUuid) {
          writeTarget = qc;
        }
      }
    }
    if (writeTarget != null) {
      final ok = await _probeWrite(writeTarget, A5Protocol.readRealtime());
      if (ok) {
        _writeQc = writeTarget;
        _log('写通道就绪: ${writeTarget.characteristicId} (0000ffe9)');
      }
    }
    if (_writeQc == null) {
      for (final qc in candidateWrites) {
        if (qc == writeTarget) continue;
        final ok = await _probeWrite(qc, A5Protocol.readRealtime());
        if (ok) {
          _writeQc = qc;
          _log('写通道探测成功: ${qc.characteristicId}');
          break;
        }
      }
    }
    if (_writeQc == null) {
      _log('未找到可用写通道');
    }
  }

  Future<bool> _probeWrite(QualifiedCharacteristic qc, List<int> data) async {
    try {
      await _ble.writeCharacteristicWithResponse(qc, value: data);
      return true;
    } catch (_) {
      try {
        await _ble.writeCharacteristicWithoutResponse(qc, value: data);
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  // ==================== 数据接收 ====================

  void _handleIncoming(Uint8List data) {
    _packetCount++;
    _rawDataController.add(data);

    // 写入回执 / 从机繁忙异常优先处理（写系数流程依赖）
    _handleIncomingInternal(data);

    // 异常帧（func|0x80）
    final exc = A5Protocol.parseException(data);
    if (exc != null) {
      _log('异常响应: 功能码 0x${data[1].toRadixString(16).padLeft(2, '0')}'
          ' 异常码 0x${exc.toRadixString(16).padLeft(2, '0')}'
          '${exc == A5Protocol.errBusy ? '（从机繁忙）' : ''}');
      return;
    }

    final parsed = _parseResponse(data);
    if (parsed != null) {
      _parsedCount++;
      _emptyPollRounds = 0;
      _liveDataController.add(parsed);
    }
  }

  // ==================== 轮询 ====================

  /// 3 秒自动轮询（默认 intervalSeconds=3）
  void startAutoPolling({int intervalSeconds = 3, bool enableWatchdog = true}) {
    _stopPolling();
    _pollingRunning = true;
    _pollCmdsSent = 0;
    _emptyPollRounds = 0;
    _noDataDiagnosed = false;
    _watchdogArmed = enableWatchdog;
    _pollingTimer = Timer.periodic(Duration(seconds: intervalSeconds), (_) {
      _pollOnce();
    });
  }

  void stopAutoPolling() => _stopPolling();

  void _stopPolling() {
    _pollingRunning = false;
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  Future<void> _pollOnce() async {
    if (!_isConnected || _writeQc == null) return;
    if (_verifyPending) return; // 系数校验中暂停轮询
    final commands = [A5Protocol.readRealtime(), A5Protocol.readHolding(A5Protocol.regCoeff, 2)];
    for (final cmd in commands) {
      if (!_pollingRunning) return;
      await _sendCommand(cmd);
      await Future.delayed(const Duration(milliseconds: 300));
    }
    // 看门狗：连续 3 次轮询无有效帧 → 断开并 800ms 退避重连（风暴锁）
    _emptyPollRounds++;
    if (_watchdogArmed &&
        _emptyPollRounds >= 3 &&
        _isConnected &&
        !_reconnecting &&
        _deviceId != null) {
      _emptyPollRounds = 0;
      final id = _deviceId!;
      final name = _deviceName ?? id;
      _log('看门狗：连续 3 次轮询无有效帧，断开并尝试重连');
      _reconnecting = true;
      unawaited(_watchdogReconnect(id, name));
    }
    if (!_noDataDiagnosed && _pollCmdsSent >= 12 && _packetCount == 0) {
      _noDataDiagnosed = true;
      _log('已发送 $_pollCmdsSent 条读命令但未收到任何 notify，请检查设备/写类型');
    }
  }

  Future<void> _watchdogReconnect(String id, String name) async {
    try {
      await disconnect();
      await Future.delayed(const Duration(milliseconds: 800));
      if (!_isConnected && !_reconnecting) return;
      _log('看门狗重连中...');
      final ok = await connectToDevice(id, name);
      if (ok) startAutoPolling(intervalSeconds: 3);
    } catch (_) {
    } finally {
      _reconnecting = false;
    }
  }

  /// 主动刷新实时数据
  Future<void> refreshData() async {
    if (_verifyPending) return;
    await _sendCommand(A5Protocol.readRealtime());
  }

  /// 读参数表（0x4D）
  Future<void> sendReadParamTable() async {
    if (_verifyPending) return;
    await _sendCommand(A5Protocol.readParamTable());
  }

  Future<void> _sendCommand(List<int> bytes) async {
    if (!_isConnected || _writeQc == null) return;
    _log('发送: ${A5Protocol.hex(bytes)}');
    try {
      await _ble.writeCharacteristicWithResponse(_writeQc!, value: bytes);
      _pollCmdsSent++;
    } catch (_) {
      try {
        await _ble.writeCharacteristicWithoutResponse(_writeQc!, value: bytes);
        _pollCmdsSent++;
      } catch (e) {
        _log('发送失败: $e');
      }
    }
  }

  // ==================== 系数写入与容差回读校验 ====================

  /// 写流量系数到设备。
  /// [useSplitWrite] 为 true 时用 0x06 分两段写（高16位@0x0010 → 低16位@0x0011，
  /// 对齐抓包样本 A5 06 00 10 40 14 A0 E4 / A5 06 00 11 5A 1D 3A 42）；
  /// 默认 false 用 0x10 一次写两寄存器。
  /// 写后延时 1s 回读 0x03 @0x0010，容差 |回读-写入| ≤ max(0.0001, |K|×0.001) 即通过；
  /// 从机繁忙（异常码 0x06）自动重发当前段（最多 3 次，间隔 300ms）。
  Future<bool> writeCoefficient(double value,
      {bool useSplitWrite = false}) async {
    if (!_isConnected || _writeQc == null) return false;
    if (_verifyPending) {
      _log('当前有读写任务进行中，请稍候');
      return false;
    }

    _pendingCoeff = value;
    _verifyPending = true;
    _verifyCompleter = Completer<bool>();
    _log('系数写入 K=$value (${useSplitWrite ? '0x06 两段' : '0x10 一次两寄存器'})');

    try {
      if (useSplitWrite) {
        // 0x06 两段：高16位 → 0x0010；低16位 → 0x0011
        final hi = A5Protocol.writeCoeffSingleHigh(value);
        final lo = A5Protocol.writeCoeffSingleLow(value);
        final hiOk = await _writeWithBusyRetry(hi, A5Protocol.funcWriteSingle);
        if (!hiOk) {
          _finishVerify(false, '高16位写入失败');
          return false;
        }
        await Future.delayed(const Duration(milliseconds: 50));
        final loOk = await _writeWithBusyRetry(lo, A5Protocol.funcWriteSingle);
        if (!loOk) {
          _finishVerify(false, '低16位写入失败');
          return false;
        }
      } else {
        final frame = A5Protocol.writeCoeffMulti(value);
        final ok = await _writeWithBusyRetry(frame, A5Protocol.funcWriteMulti);
        if (!ok) {
          _finishVerify(false, '写入失败');
          return false;
        }
      }

      // 写后延时 1s 回读 0x03 @0x0010 做容差校验
      Timer(const Duration(seconds: 1), () {
        if (!_verifyPending) return;
        _sendCommand(A5Protocol.readHolding(A5Protocol.regCoeff, 2));
      });

      return await _verifyCompleter!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          _verifyPending = false;
          _verifyCompleter = null;
          _verifyResultController.add('校验超时，请重试');
          return false;
        },
      );
    } catch (e) {
      _finishVerify(false, '写入异常: $e');
      return false;
    }
  }

  /// 发送并处理从机繁忙重发（最多 3 次，间隔 300ms）。返回最终是否收到合法回执。
  Future<bool> _writeWithBusyRetry(List<int> frame, int func) async {
    for (var attempt = 1; attempt <= 3; attempt++) {
      _log('写入尝试 $attempt/3: ${A5Protocol.hex(frame)}');
      try {
        await _ble.writeCharacteristicWithResponse(_writeQc!, value: frame);
      } catch (_) {
        try {
          await _ble.writeCharacteristicWithoutResponse(
              _writeQc!, value: frame);
        } catch (e) {
          _log('写入发送失败: $e');
          return false;
        }
      }
      // 等待回执/异常
      final ack = await _waitForWriteAck(func);
      if (ack == WriteAckResult.ack) return true;
      if (ack == WriteAckResult.busy) {
        _log('从机繁忙，300ms 后重发');
        await Future.delayed(const Duration(milliseconds: 300));
        continue;
      }
      if (ack == WriteAckResult.timeout) {
        _log('未收到写回执');
        return false;
      }
    }
    return false;
  }

  Completer<WriteAckResult>? _ackCompleter;

  Future<WriteAckResult> _waitForWriteAck(int func) {
    _ackCompleter = Completer<WriteAckResult>();
    return _ackCompleter!.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => WriteAckResult.timeout,
    );
  }

  /// 写入回执/异常检测：优先于常规 A5 解析处理
  void _handleIncomingInternal(Uint8List data) {
    final c = _ackCompleter;
    if (c == null || c.isCompleted) return;
    final exc = A5Protocol.parseException(data);
    if (exc != null) {
      if (exc == A5Protocol.errBusy) {
        c.complete(WriteAckResult.busy);
      }
      return;
    }
    if (A5Protocol.parseWriteMultiAck(data) ||
        A5Protocol.parseWriteSingleAck(data)) {
      c.complete(WriteAckResult.ack);
      return;
    }
  }

  /// 设备回读 0x0010 后的容差校验：
  /// |回读 - 写入| ≤ max(0.0001, |写入| × 0.001) 即通过
  void _handleCoefficientReadBack(double value) {
    if (!_verifyPending) return;
    final pending = _pendingCoeff;
    final diff = (value - pending).abs();
    final tol = math.max(0.0001, pending.abs() * 0.001);
    final ok = diff <= tol;
    _verifyPending = false;
    final c = _verifyCompleter;
    _verifyCompleter = null;
    if (ok) {
      _lastVerifiedCoefficient = value;
      _verifyResultController.add('校验通过: ${value.toStringAsFixed(4)}');
      if (c != null && !c.isCompleted) c.complete(true);
    } else {
      _verifyResultController.add(
          '校验不一致: 设备返回 ${value.toStringAsFixed(4)}，期望 ${pending.toStringAsFixed(4)}');
      if (c != null && !c.isCompleted) c.complete(false);
    }
  }

  void _finishVerify(bool ok, String msg) {
    _verifyPending = false;
    final c = _verifyCompleter;
    _verifyCompleter = null;
    if (!ok) {
      _verifyResultController.add(msg);
      if (c != null && !c.isCompleted) c.complete(false);
    }
  }

  // ==================== A5 响应解析 ====================

  LiveMetrics? _parseResponse(Uint8List byte) {
    if (byte.isEmpty) return null;

    // 1. A5 0x47 读实时：载荷 20B = 5×float32
    final realtime = A5Protocol.extractFrame(byte, A5Protocol.funcReadRealtime);
    if (realtime != null) {
      final vals = A5Protocol.parseRealtime(realtime);
      if (vals != null && vals.length == 5) {
        _handleCoefficientReadBack(vals[4]);
        _log(
            '解析[0x47 实时] 瞬时${vals[0].toStringAsFixed(4)} 压力${vals[1].toStringAsFixed(4)} 温度${vals[2].toStringAsFixed(4)} 累计${vals[3].toStringAsFixed(4)} 系数${vals[4].toStringAsFixed(4)}');
        return LiveMetrics(
          instantFlow: vals[0],
          pressure: vals[1],
          temperature: vals[2],
          cumulativeFlow: vals[3],
          coefficient: vals[4],
          rawHex: A5Protocol.hex(realtime),
          timestamp: DateTime.now(),
        );
      }
    }

    // 2. A5 0x03 读保持寄存器：系数 K @0x0010（2 寄存器 = 1 float32）
    final holding = A5Protocol.extractFrame(byte, A5Protocol.funcReadHolding);
    if (holding != null) {
      final val = A5Protocol.parseHoldingFloat(holding);
      if (val != null && val.isFinite) {
        _handleCoefficientReadBack(val);
        _log('解析[0x03 系数K@0x0010]: ${val.toStringAsFixed(4)}');
        return LiveMetrics(
          instantFlow: 0,
          coefficient: val,
          rawHex: A5Protocol.hex(holding),
          timestamp: DateTime.now(),
        );
      }
    }

    // 3. A5 0x4D 参数表：载荷 140B = 35×float32
    final param = A5Protocol.extractFrame(byte, A5Protocol.funcReadParam);
    if (param != null) {
      final vals = A5Protocol.parseParamTable(param);
      if (vals != null) {
        _paramTableController.add(vals);
        _log('解析[0x4D 参数表]: ${vals.length} 项，编号04=${vals.length > 4 ? vals[4].toStringAsFixed(4) : '-'}');
        return null;
      }
    }

    return null;
  }

  void _log(String msg) {
    _logController.add(msg);
  }
}

enum WriteAckResult { waiting, ack, busy, timeout }

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:usb_measurement/scan_function.dart';

// ... (文件上半部分的 enum 和 Config 保持不变) ...

// ==========================================
// 0. 数据类型定义
// ==========================================
enum UsbDataType { int8, uint8, int16, uint16, int32, uint32, float32 }

extension UsbDataTypeExt on UsbDataType {
  int get byteSize {
    switch (this) {
      case UsbDataType.int8:
      case UsbDataType.uint8: return 1;
      case UsbDataType.int16:
      case UsbDataType.uint16: return 2;
      case UsbDataType.int32:
      case UsbDataType.uint32:
      case UsbDataType.float32: return 4;
    }
  }

  String get label {
    return toString().split('.').last;
  }
}

// ==========================================
// 1. 状态机及协议配置的数据结构定义
// ==========================================

enum SerialStatus {
  connecting,    
  active,        
  disconnected,  
}

class ProtocolConfig {
  final int sps;           
  final int duration;      
  final UsbDataType dataType; 
  final int channels;      
  
  final int baudRate;      
  final int dataBits;      
  final int stopBits;      
  final int parity;        

  ProtocolConfig({
    this.sps = 30,
    this.duration = 10,    
    this.dataType = UsbDataType.int16, 
    this.channels = 1,     
    this.baudRate = 115200,
    this.dataBits = 8,
    this.stopBits = 1,
    this.parity = 0,
  });

  int get targetByteLength => duration * sps * channels * dataType.byteSize;

  List<int> get controlBytes {
    return [
      0x43,
      sps & 0xFF,
      (duration >> 8) & 0xFF, 
      duration & 0xFF,
    ];
  }

  ProtocolConfig copyWith({
    int? sps,
    int? duration,
    UsbDataType? dataType,
    int? channels,
    int? baudRate,
    int? dataBits,
    int? stopBits,
    int? parity,
  }) {
    return ProtocolConfig(
      sps: sps ?? this.sps,
      duration: duration ?? this.duration,
      dataType: dataType ?? this.dataType,
      channels: channels ?? this.channels,
      baudRate: baudRate ?? this.baudRate,
      dataBits: dataBits ?? this.dataBits,
      stopBits: stopBits ?? this.stopBits,
      parity: parity ?? this.parity,
    );
  }
}

class SerialPageState {
  final SerialStatus status;
  final MySerialDevice device;
  final ProtocolConfig config;
  final List<int> currentDisplayData; 
  final String errorMessage;

  SerialPageState({
    required this.status,
    required this.device,
    required this.config,
    this.currentDisplayData = const [],
    this.errorMessage = "",
  });

  SerialPageState copyWith({
    SerialStatus? status,
    MySerialDevice? device,
    ProtocolConfig? config,
    List<int>? currentDisplayData,
    String? errorMessage,
  }) {
    return SerialPageState(
      status: status ?? this.status,
      device: device ?? this.device,
      config: config ?? this.config,
      currentDisplayData: currentDisplayData ?? this.currentDisplayData,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

// ==========================================
// 2. Riverpod 状态机控制器逻辑
// ==========================================

class SerialPageNotifier extends FamilyNotifier<SerialPageState, MySerialDevice> {
  // 核心：只保留这一个与平台无关的底层接口
  LowLevelSerialPort? _hardwarePort;

  bool _isConnecting = false;
  final Queue<int> _buffer = Queue<int>();

  @override
  SerialPageState build(MySerialDevice arg) {
    ref.onDispose(() => _cleanup());
    Future.microtask(() => connectDevice());

    return SerialPageState(
      status: SerialStatus.connecting,
      device: arg,
      config: ProtocolConfig(),
    );
  }

  Future<void> _cleanup() async {
    await _hardwarePort?.closeAndDispose();
    _hardwarePort = null;
    _buffer.clear();
  }

  void _handleStreamDisconnect(String reason) {
    if (state.status != SerialStatus.disconnected) {
      state = state.copyWith(status: SerialStatus.disconnected, errorMessage: reason);
      _cleanup();
    }
  }

  Future<void> connectDevice() async {
    if (_isConnecting) return;
    _isConnecting = true;

    state = state.copyWith(status: SerialStatus.connecting, errorMessage: "");
    await _cleanup(); 

    try {
      if (kIsWeb) {
        state = state.copyWith(
          status: SerialStatus.disconnected,
          errorMessage: "Web 浏览器沙盒限制，暂不支持原生串行硬件通信，请使用客户端版本。",
        );
        return;
      }

      // 1. 初始化统一控制器
      _hardwarePort = LowLevelSerialPort();
      
      // 2. 打开设备通道
      bool success = await _hardwarePort!.open(state.device.devicePath);
      if (!success) {
        throw Exception("无法打开设备硬件通道，端口可能不存在或被独占");
      }

      // 3. 配置默认参数 (比如首次连接默认 115200 8N1)
      await _hardwarePort!.configure(
        baudRate: state.config.baudRate,
        dataBits: state.config.dataBits,
        stopBits: state.config.stopBits,
        parity: state.config.parity,
      );

      // 4. 监听统一的数据流
      _hardwarePort!.listenStream.listen(
        (data) => _handleIncomingData(data),
        onError: (err) => _handleStreamDisconnect("硬件流异常中断: $err"),
        onDone: () => _handleStreamDisconnect("物理设备已断开连接"),
      );

      state = state.copyWith(status: SerialStatus.active); 

    } catch (e) {
      state = state.copyWith(
        status: SerialStatus.disconnected,
        errorMessage: e.toString(),
      );
      await _cleanup();
    } finally {
      _isConnecting = false;
    }
  }

  Future<void> sendCommand(ProtocolConfig config) async {
    try {
      if (_hardwarePort == null) {
        throw Exception("通信通道未打开或已断开");
      }

      // 1. 应用新的物理层参数配置
      await _hardwarePort!.configure(
        baudRate: config.baudRate,
        dataBits: config.dataBits,
        stopBits: config.stopBits,
        parity: config.parity,
      );

      _buffer.clear();
      state = state.copyWith(config: config, currentDisplayData: []);

      // 2. 将协议层的控制指令转化为字节并下发
      final cmd = Uint8List.fromList(config.controlBytes);
      await _hardwarePort!.writeData(cmd);

    } catch (e) {
      debugPrint("向MCU下发控制命令失败: $e");
      state = state.copyWith(
        status: SerialStatus.disconnected,
        errorMessage: "控制命令下发或配置应用失败: $e",
      );
    }
  }

  void disconnectDevice() async {
    await _cleanup();
    state = state.copyWith(status: SerialStatus.disconnected, errorMessage: "用户手动断开连接");
  }

  void _handleIncomingData(List<int> data) {
    if (state.status != SerialStatus.active) return;
    
    final targetLength = state.config.targetByteLength;
    if (_buffer.length >= targetLength) return;

    int remaining = targetLength - _buffer.length;
    if (data.length > remaining) {
      _buffer.addAll(data.take(remaining));
    } else {
      _buffer.addAll(data);
    }
    
    state = state.copyWith(
      currentDisplayData: _buffer.toList(),
    );
  }
}

final serialPageProvider = NotifierProvider.family<SerialPageNotifier, SerialPageState, MySerialDevice>(
  SerialPageNotifier.new,
);
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:math' as math; // 用于生成优美的模拟正弦波数据
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:usb_measurement/scan_function.dart';

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
// 2. Riverpod 状态机控制器逻辑 (MOCK 模拟版)
// ==========================================

class SerialPageNotifier extends FamilyNotifier<SerialPageState, MySerialDevice> {
  bool _isConnecting = false;
  final Queue<int> _buffer = Queue<int>();
  
  Timer? _mockDataTimer; // 模拟数据定时器
  double _timeStep = 0.0; // 模拟波形时间轴

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
    _mockDataTimer?.cancel();
    _buffer.clear();
  }

  Future<void> connectDevice() async {
    if (_isConnecting) return;
    _isConnecting = true;

    state = state.copyWith(status: SerialStatus.connecting, errorMessage: "");
    await _cleanup(); 

    // 模拟连接延迟 (1.5秒) 让你能看到转圈圈的动画效果
    await Future.delayed(const Duration(milliseconds: 1500));
    
    // 强制转为 active 状态
    state = state.copyWith(status: SerialStatus.active); 
    _isConnecting = false;
  }

  Future<void> sendCommand(ProtocolConfig config) async {
    try {
      _cleanup(); // 停止旧定时器
      state = state.copyWith(config: config, currentDisplayData: []);
      _timeStep = 0.0;

      // 模拟下发指令耗时
      await Future.delayed(const Duration(milliseconds: 300));
      
      // 开始模拟生成对应协议配置的底层数据流
      _startMockDataStream(config);

    } catch (e) {
      state = state.copyWith(
        status: SerialStatus.disconnected,
        errorMessage: "虚拟设备指令下发失败: $e",
      );
    }
  }

  void _startMockDataStream(ProtocolConfig config) {
    int frameSize = config.channels * config.dataType.byteSize;
    int targetBytes = config.targetByteLength;
    
    // 每 100ms 触发一次数据生成，计算每次该生成多少帧
    const int intervalMs = 100;
    double framesPerInterval = (config.sps * intervalMs) / 1000.0;
    int bytesPerInterval = (framesPerInterval * frameSize).round();
    if (bytesPerInterval == 0) bytesPerInterval = frameSize;

    _mockDataTimer = Timer.periodic(const Duration(milliseconds: intervalMs), (timer) {
      if (state.status != SerialStatus.active) {
        timer.cancel();
        return;
      }

      int currentLen = state.currentDisplayData.length;
      if (currentLen >= targetBytes) {
        timer.cancel();
        return; // 数据接收完毕
      }

      int bytesToGen = bytesPerInterval;
      if (currentLen + bytesToGen > targetBytes) {
        bytesToGen = targetBytes - currentLen;
      }

      int framesToGen = bytesToGen ~/ frameSize;
      if (framesToGen <= 0) return;

      Uint8List newBytes = Uint8List(framesToGen * frameSize);
      ByteData bd = ByteData.sublistView(newBytes);

      // 为所选数据类型注入符合其范围的模拟正弦波
      for (int f = 0; f < framesToGen; f++) {
        for (int c = 0; c < config.channels; c++) {
          int offset = f * frameSize + c * config.dataType.byteSize;
          
          // 给不同通道加一点相位差和振幅差，使图表更好看
          double amplitude = 100.0 + (c * 20); 
          double phaseOffset = c * 1.5; 
          double val = math.sin(_timeStep + phaseOffset) * amplitude;

          switch (config.dataType) {
            case UsbDataType.int8: bd.setInt8(offset, val.toInt().clamp(-128, 127)); break;
            case UsbDataType.uint8: bd.setUint8(offset, (val + amplitude).toInt().clamp(0, 255)); break;
            case UsbDataType.int16: bd.setInt16(offset, (val * 10).toInt(), Endian.little); break;
            case UsbDataType.uint16: bd.setUint16(offset, ((val + amplitude) * 10).toInt(), Endian.little); break;
            case UsbDataType.int32: bd.setInt32(offset, (val * 1000).toInt(), Endian.little); break;
            case UsbDataType.uint32: bd.setUint32(offset, ((val + amplitude) * 1000).toInt(), Endian.little); break;
            case UsbDataType.float32: bd.setFloat32(offset, val, Endian.little); break;
          }
        }
        // 调节正弦波频率步进
        _timeStep += 0.1; 
      }

      _handleIncomingData(newBytes.toList());
    });
  }

  void disconnectDevice() async {
    await _cleanup();
    state = state.copyWith(status: SerialStatus.disconnected, errorMessage: "用户手动断开了虚拟设备的连接");
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
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:usb_measurement/scan_function.dart';
import 'package:usb_serial/usb_serial.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

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
  UsbPort? _androidPort;
  StreamSubscription? _androidSub;
  SerialPort? _desktopPort;
  SerialPortReader? _desktopReader;
  StreamSubscription? _desktopSub;

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
    await _androidSub?.cancel();
    _androidSub = null;
    if (_androidPort != null) {
      try { await _androidPort!.close(); } catch (_) {}
      _androidPort = null;
    }

    await _desktopSub?.cancel();
    _desktopSub = null;
    
    try {
      _desktopReader?.close();
    } catch (e) {
      debugPrint("Reader close error: $e");
    }
    _desktopReader = null;

    try {
      if (_desktopPort != null) {
        if (_desktopPort!.isOpen) _desktopPort!.close();
        _desktopPort!.dispose();
      }
    } catch (e) {
      debugPrint("Port close error: $e");
    }
    _desktopPort = null;

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

      if (defaultTargetPlatform == TargetPlatform.android) {
        List<UsbDevice> devices = await UsbSerial.listDevices();
        UsbDevice? targetDevice;
        for (var d in devices) {
            if (d.deviceName == state.device.devicePath) {
                targetDevice = d;
                break;
            }
        }
        if (targetDevice == null) throw Exception("未找到对应底层路径的安卓USB设备");
        
        _androidPort = await targetDevice.create();
        if (_androidPort == null) throw Exception("无法获取安卓USB端口");

        bool openResult = await _androidPort!.open();
        if (!openResult) throw Exception("无法打开安卓USB端口");

        await _androidPort!.setDTR(true);
        await _androidPort!.setRTS(true);
        
        int androidParity = UsbPort.PARITY_NONE;
        if (state.config.parity == 1) androidParity = UsbPort.PARITY_ODD;
        if (state.config.parity == 2) androidParity = UsbPort.PARITY_EVEN;

        await _androidPort!.setPortParameters(
          state.config.baudRate, 
          state.config.dataBits, 
          state.config.stopBits, 
          androidParity
        );

        final stream = _androidPort!.inputStream;
        if (stream == null) throw Exception("无法拉取 Android USB 核心输入流");

        _androidSub = stream.listen(
          (data) => _handleIncomingData(data),
          onError: (err) => _handleStreamDisconnect("USB 流异常中断: $err"),
          onDone: () => _handleStreamDisconnect("USB 物理设备已断开连接"),
        );
        state = state.copyWith(status: SerialStatus.active); 

      } else if (defaultTargetPlatform == TargetPlatform.windows || 
                 defaultTargetPlatform == TargetPlatform.macOS || 
                 defaultTargetPlatform == TargetPlatform.linux) {
        
        _desktopPort = SerialPort(state.device.devicePath);
        if (!_desktopPort!.openReadWrite()) {
          final lastErr = SerialPort.lastError;
          _desktopPort = null;
          throw Exception("打开串口失败: $lastErr");
        }

        final spConfig = _desktopPort!.config;
        spConfig.baudRate = state.config.baudRate;
        spConfig.bits = state.config.dataBits;
        spConfig.stopBits = state.config.stopBits;
        
        int desktopParity = SerialPortParity.none;
        if (state.config.parity == 1) desktopParity = SerialPortParity.odd;
        if (state.config.parity == 2) desktopParity = SerialPortParity.even;
        spConfig.parity = desktopParity;
        
        _desktopPort!.config = spConfig; 

        try {
          _desktopReader = SerialPortReader(_desktopPort!);
          _desktopSub = _desktopReader!.stream.listen(
            (data) => _handleIncomingData(data),
            onError: (err) => _handleStreamDisconnect("串口流异常中断: $err"),
            onDone: () => _handleStreamDisconnect("串口被意外关闭或移除"),
          );
        } catch (e) {
          throw Exception("创建硬件流监听失败，端口可能被独占: $e");
        }

        state = state.copyWith(status: SerialStatus.active); 
      } else {
        throw Exception("当前操作系统平台无匹配的串口驱动链");
      }
    } catch (e) {
      state = state.copyWith(
        status: SerialStatus.disconnected,
        errorMessage: e.toString(),
      );
    } finally {
      _isConnecting = false;
    }
  }

  Future<void> sendCommand(ProtocolConfig config) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android && _androidPort != null) {
        int androidParity = UsbPort.PARITY_NONE;
        if (config.parity == 1) androidParity = UsbPort.PARITY_ODD;
        if (config.parity == 2) androidParity = UsbPort.PARITY_EVEN;

        await _androidPort!.setPortParameters(
          config.baudRate, 
          config.dataBits, 
          config.stopBits, 
          androidParity,
        );
      } else if (_desktopPort != null && _desktopPort!.isOpen) {
        final spConfig = _desktopPort!.config;
        spConfig.baudRate = config.baudRate;
        spConfig.bits = config.dataBits;
        spConfig.stopBits = config.stopBits;
        
        int desktopParity = SerialPortParity.none;
        if (config.parity == 1) desktopParity = SerialPortParity.odd;
        if (config.parity == 2) desktopParity = SerialPortParity.even;
        
        spConfig.parity = desktopParity;
        _desktopPort!.config = spConfig; 
      } else {
        throw Exception("通信通道未打开或已断开");
      }

      _buffer.clear();
      state = state.copyWith(config: config, currentDisplayData: []);

      final cmd = Uint8List.fromList(config.controlBytes);
      if (defaultTargetPlatform == TargetPlatform.android && _androidPort != null) {
        await _androidPort!.write(cmd); 
      } else if (_desktopPort != null && _desktopPort!.isOpen) {
        _desktopPort!.write(cmd);
      }

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
    state = state.copyWith(status: SerialStatus.disconnected, errorMessage: "用户手动断开串口");
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
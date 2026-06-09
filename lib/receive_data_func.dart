import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:usb_measurement/scan_function.dart';
import 'package:usb_measurement/custom_protocol.dart';
import 'package:usb_measurement/basic_func.dart';
import 'package:usb_measurement/custom_rx_protocol.dart';
import 'package:usb_measurement/rx_packet_parser.dart';


// ==========================================
// 1. 状态机及协议配置的数据结构定义
// ==========================================

enum SerialStatus {
  connecting,    
  active,        
  disconnected,  
}

class ProtocolConfig {
  final int sps;           // 采样率 (Hz)
  final int duration;      // 传输时间 (秒)
  final UsbDataType dataType; // 数据类型
  final int channels;      // 通道数
  
  final int baudRate;      // 波特率
  final int dataBits;      // 数据位
  final int stopBits;      // 停止位
  final int parity;        // 校验位 (0:None, 1:Odd, 2:Even)

  // ====== 新增：存储用户自定义的发送协议结构 ======
  final CustomTxProtocol txProtocol; 

  ProtocolConfig({
    required this.sps,
    required this.duration,
    required this.dataType,
    required this.channels,
    required this.baudRate,
    required this.dataBits,
    required this.stopBits,
    required this.parity,
    required this.txProtocol, // 必须传入
  });

  // ====== 核心重构：利用自定类动态构建原本硬编码的字节流 ======
  Uint8List get controlBytes {
    return txProtocol.buildBytes(sps: sps, duration: duration);
  }

  // ====== 以下是原先被你硬编码保留的接收端逻辑，必须保留 ======
  
  /// 计算单个数据包（即所有通道采样一次）所占用的字节大小
  int get wordSize => dataType.byteSize;

  /// 计算一帧（包含所有通道当前点的数据）的字节总数
  int get frameSize => wordSize * channels;

  /// 计算在指定的采样率和时间内，预期的总帧数
  int get totalExpectedFrames => sps * duration;

  /// 整个采集生命周期中，下位机应当上传的理论二进制总字节数
  int get targetByteLength => frameSize * totalExpectedFrames;

  // ====== 记得同步修改的 copyWith 方法，把 txProtocol 传进去 ======
  ProtocolConfig copyWith({
    int? sps,
    int? duration,
    UsbDataType? dataType,
    int? channels,
    int? baudRate,
    int? dataBits,
    int? stopBits,
    int? parity,
    CustomTxProtocol? txProtocol,
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
      txProtocol: txProtocol ?? this.txProtocol,
    );
  }
}

class SerialPageState {
  final SerialStatus status;
  final MySerialDevice device;
  final ProtocolConfig config;
  final List<List<double>> currentDisplayData; 
  final String? errorMessage;
  // 新增：用户当前配置的接收解包协议
  final CustomRxProtocol? rxProtocol; 

  SerialPageState({
    required this.device,
    required this.status,
    required this.config,
    required this.currentDisplayData,
    this.errorMessage,
    this.rxProtocol, // 新增
  });

  SerialPageState copyWith({
    MySerialDevice? device,
    SerialStatus? status,
    ProtocolConfig? config,
    List<List<double>>? currentDisplayData,
    String? errorMessage,
    CustomRxProtocol? rxProtocol, // 新增
  }) {
    return SerialPageState(
      device: device ?? this.device,
      status: status ?? this.status,
      config: config ?? this.config,
      currentDisplayData: currentDisplayData ?? this.currentDisplayData,
      errorMessage: errorMessage ?? this.errorMessage,
      rxProtocol: rxProtocol ?? this.rxProtocol, // 新增
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
      currentDisplayData: const [],
      config: ProtocolConfig(
        sps: 100,
        duration: 10,
        dataType: UsbDataType.float32,
        channels: 1,
        baudRate: 115200,
        dataBits: 8,
        stopBits: 1,
        parity: 0,
        txProtocol: CustomTxProtocol(items: []), // 确保传入一个初始TX协议实例
      ),
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

  // 【新增方法1】仅更新配置不发送指令（用于配置TX）
  void updateConfigWithoutSending(ProtocolConfig newConfig) {
    state = state.copyWith(config: newConfig);
  }

  // 【新增方法2】更新RX接收协议
  void updateRxProtocol(CustomRxProtocol protocol) {
    // 同时把协议更新到 config 和外层的 rxProtocol 中
    state = state.copyWith(rxProtocol: protocol);
  }

  void _handleIncomingData(List<int> data) {
    if (state.status != SerialStatus.active) return;
    
    _buffer.addAll(data);

    if (state.rxProtocol == null) return;

    // 高性能解析
    List<List<double>> parsedFrames = RxPacketParser.parseStream(_buffer, state.rxProtocol!);

    if (parsedFrames.isEmpty) return;

    // 【修复占位符】将新解析出的帧追加到历史记录中
    List<List<double>> updatedHistory = List.from(state.currentDisplayData);
    updatedHistory.addAll(parsedFrames);

    // 内存保护：限制最大显示帧数（例如最大缓存100万点，按需调整）
    if (updatedHistory.length > 50000) {
       updatedHistory = updatedHistory.sublist(updatedHistory.length - 50000);
    }

    state = state.copyWith(currentDisplayData: updatedHistory); 
  }
}

final serialPageProvider = NotifierProvider.family<SerialPageNotifier, SerialPageState, MySerialDevice>(
  SerialPageNotifier.new,
);
// desktop_basic_func.dart
import 'dart:async';
import 'dart:io'; // 引入以支持 File 操作
import 'dart:typed_data';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:file_picker/file_picker.dart'; // 桌面端使用文件选择器保存

/// 统一的串行设备模型 (与 Android 端完全同构)
class MySerialDevice {
  final String name;
  final String devicePath;

  MySerialDevice({required this.name, required this.devicePath});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MySerialDevice &&
          runtimeType == other.runtimeType &&
          devicePath == other.devicePath;

  @override
  int get hashCode => devicePath.hashCode;
}

/// 扫描可用的底层串口设备
Future<List<MySerialDevice>> lowLevelScanDevices() async {
  List<MySerialDevice> availableDevices = [];
  try {
    final ports = SerialPort.availablePorts;
    for (var portAddress in ports) {
      final port = SerialPort(portAddress);
      try {
        String displayName = port.description ?? 'Unknown Serial Port';
        availableDevices.add(
          MySerialDevice(
            name: '$portAddress - $displayName',
            devicePath: portAddress,
          ),
        );
      } finally {
        port.dispose(); // 严格释放临时实例
      }
    }
  } catch (e) {
    print("Desktop 扫描设备失败: $e");
  }
  return availableDevices;
}

/// 统一的底层端口操作封装 (与 Android 端完全同构)
class LowLevelSerialPort {
  SerialPort? _desktopPort;
  SerialPortReader? _reader;
  StreamController<Uint8List>? _streamController;
  StreamSubscription? _subscription;

  /// 打开指定路径的设备
  Future<bool> open(String path) async {
    try {
      _desktopPort = SerialPort(path);
      if (!_desktopPort!.openReadWrite()) {
        _desktopPort!.dispose();
        _desktopPort = null;
        return false;
      }

      // 建立统一的广播流通道
      _streamController = StreamController<Uint8List>.broadcast();
      _reader = SerialPortReader(_desktopPort!);
      _subscription = _reader!.stream.listen((data) {
        _streamController?.add(Uint8List.fromList(data));
      });

      return true;
    } catch (e) {
      print("Desktop 打开串口失败: $e");
      return false;
    }
  }

  /// 配置串口通信参数
  /// [parity] 映射关系: 0 = None, 1 = Odd, 2 = Even
  /// [stopBits] 映射关系: 1 = 1位, 2 = 2位
  Future<void> configure({
    required int baudRate,
    required int dataBits,
    required int stopBits,
    required int parity,
  }) async {
    if (_desktopPort == null) return;

    final config = SerialPortConfig();
    config.baudRate = baudRate;
    config.bits = dataBits;

    if (stopBits == 1) config.stopBits = 1;
    if (stopBits == 2) config.stopBits = 2;

    if (parity == 0) config.parity = SerialPortParity.none;
    if (parity == 1) config.parity = SerialPortParity.odd;
    if (parity == 2) config.parity = SerialPortParity.even;

    _desktopPort!.config = config;
  }

  /// 向底层硬件写入数据
  Future<void> writeData(Uint8List data) async {
    if (_desktopPort != null && _desktopPort!.isOpen) {
      _desktopPort!.write(data);
    }
  }

  /// 关闭端口并释放资源
  Future<void> closeAndDispose() async {
    await _subscription?.cancel();
    await _streamController?.close();
    if (_desktopPort != null) {
      if (_desktopPort!.isOpen) {
        _desktopPort!.close();
      }
      _desktopPort!.dispose();
      _desktopPort = null;
    }
  }

  /// 供外部监听的数据流
  Stream<Uint8List> get listenStream {
    return _streamController?.stream ?? const Stream.empty();
  }
}

/// 统一的跨平台 CSV 导出函数 (Desktop 平台实现)
/// 弹出桌面系统原生的保存对话框，由用户选择路径保存
Future<bool> lowLevelExportCsv({
  required String defaultFileName,
  required String content,
}) async {
  try {
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: '选择 CSV 文件的保存路径',
      fileName: defaultFileName,
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (outputFile != null) {
      final file = File(outputFile);
      await file.writeAsString(content);
      return true;
    }
  } catch (e) {
    print("Desktop 保存文件失败: $e");
  }
  return false;
}
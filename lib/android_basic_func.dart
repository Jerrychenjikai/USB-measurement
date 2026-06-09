// android_basic_func.dart
import 'dart:async';
import 'dart:io'; // 引入以支持 File 操作
import 'dart:typed_data';
import 'package:usb_serial/usb_serial.dart';
import 'package:path_provider/path_provider.dart'; // 用于获取安卓临时目录
import 'package:share_plus/share_plus.dart';         // 用于触发安卓原生分享面板

/// 统一的串行设备模型
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

/// 扫描可用的底层 USB 设备
Future<List<MySerialDevice>> lowLevelScanDevices() async {
  List<MySerialDevice> availableDevices = [];
  try {
    List<UsbDevice> devices = await UsbSerial.listDevices();
    for (var device in devices) {
      String displayName = device.productName ?? 'Unknown USB Device';
      availableDevices.add(
        MySerialDevice(
          name: displayName,
          devicePath: device.deviceName ?? 'Unknown Path',
        ),
      );
    }
  } catch (e) {
    print("Android 扫描设备失败: $e");
  }
  return availableDevices;
}

/// 统一的底层端口操作封装
class LowLevelSerialPort {
  UsbPort? _androidPort;
  StreamController<Uint8List>? _streamController;
  StreamSubscription? _subscription;

  /// 打开指定路径的设备
  Future<bool> open(String path) async {
    try {
      List<UsbDevice> devices = await UsbSerial.listDevices();
      UsbDevice? targetDevice;
      for (var d in devices) {
        if (d.deviceName == path) {
          targetDevice = d;
          break;
        }
      }
      if (targetDevice == null) return false;

      _androidPort = await targetDevice.create();
      if (_androidPort == null) return false;

      bool openResult = await _androidPort!.open();
      if (!openResult) {
        _androidPort = null;
        return false;
      }

      // 建立统一的广播流通道
      _streamController = StreamController<Uint8List>.broadcast();
      _subscription = _androidPort!.inputStream?.listen((data) {
        _streamController?.add(Uint8List.fromList(data));
      });

      return true;
    } catch (e) {
      print("Android 打开串口失败: $e");
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
    if (_androidPort == null) return;

    int usbParity = UsbPort.PARITY_NONE;
    if (parity == 1) usbParity = UsbPort.PARITY_ODD;
    if (parity == 2) usbParity = UsbPort.PARITY_EVEN;

    int usbStopBits = UsbPort.STOPBITS_1;
    if (stopBits == 2) usbStopBits = UsbPort.STOPBITS_2;

    await _androidPort!.setPortParameters(baudRate, dataBits, usbStopBits, usbParity);
  }

  /// 向底层硬件写入数据
  Future<void> writeData(Uint8List data) async {
    if (_androidPort != null) {
      await _androidPort!.write(data);
    }
  }

  /// 关闭端口并释放流资源
  Future<void> closeAndDispose() async {
    await _subscription?.cancel();
    await _streamController?.close();
    await _androidPort?.close();
    _androidPort = null;
  }

  /// 供外部监听的数据流
  Stream<Uint8List> get listenStream {
    return _streamController?.stream ?? const Stream.empty();
  }
}

/// 统一的跨平台 CSV 导出函数 (Android 平台实现)
/// 先将文本写入缓存，随后直接拉起安卓系统级分享面板
Future<bool> lowLevelExportCsv({
  required String defaultFileName,
  required String content,
}) async {
  try {
    // 获取安卓应用临时缓存目录
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/$defaultFileName');
    
    // 写入文件
    await file.writeAsString(content);
    
    // 唤起安卓系统的原生分享面板
    await Share.shareXFiles(
      [XFile(file.path)], 
      text: '串口采集数据导出: $defaultFileName',
    );
    return true;
  } catch (e) {
    print("Android 导出并分享文件失败: $e");
    return false;
  }
}
import 'dart:io' show Platform;
import 'package:usb_serial/usb_serial.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

/// 统一的设备数据结构，方便 UI 列表展示
class MySerialDevice {
  final String name;        // 友好的显示名称 (例如: CP2102 USB to UART)
  final String devicePath;  // 系统的底层路径或 COM 号 (例如: COM3, /dev/ttyUSB0)

  MySerialDevice({required this.name, required this.devicePath});

  // 【PR 修补 3】重写 == 和 hashCode，防止 Riverpod family 频繁重建状态导致断连
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MySerialDevice &&
          runtimeType == other.runtimeType &&
          devicePath == other.devicePath; // 以底层物理路径为唯一标识

  @override
  int get hashCode => devicePath.hashCode;
}

/// 扫描所有可用的 USB/串口 设备
Future<List<MySerialDevice>> getAvailablePorts() async {
  List<MySerialDevice> availableDevices = [];

  try {
    // ------------------------------------------
    // Android 端：使用 usb_serial 扫描底层 USB 设备
    // ------------------------------------------
    if (Platform.isAndroid) {
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
    } 
    // ------------------------------------------
    // Windows & macOS & Linux 端：使用 flutter_libserialport 扫描可用串口
    // ------------------------------------------
    else if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final ports = SerialPort.availablePorts;
      for (var portAddress in ports) {
        final port = SerialPort(portAddress);
        
        String displayName = port.description ?? 'Unknown Serial Port';
        
        availableDevices.add(
          MySerialDevice(
            name: '$portAddress - $displayName', 
            devicePath: portAddress, 
          ),
        );
        
        port.dispose(); 
      }
    }
  } catch (e) {
    print("扫描设备时发生错误: $e");
  }

  return availableDevices;
}
import 'dart:io' show Platform;
import 'package:usb_serial/usb_serial.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

/// 统一的设备数据结构，方便 UI 列表展示
class MySerialDevice {
  final String name;        // 友好的显示名称 (例如: CP2102 USB to UART)
  final String devicePath;  // 系统的底层路径或 COM 号 (例如: COM3, /dev/ttyUSB0)

  MySerialDevice({required this.name, required this.devicePath});
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
        // 过滤一下，最好只显示有实际产品名称的设备
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
    // Windows & macOS 端：使用 flutter_libserialport 扫描可用串口
    // ------------------------------------------
    else if (Platform.isWindows || Platform.isMacOS) {
      final ports = SerialPort.availablePorts;
      for (var portAddress in ports) {
        final port = SerialPort(portAddress);
        
        // 获取串口的描述信息（例如 "USB Serial Port"）
        String displayName = port.description ?? 'Unknown Serial Port';
        
        availableDevices.add(
          MySerialDevice(
            name: '$portAddress - $displayName', 
            devicePath: portAddress, // 这里的 portAddress 就是 COM3 或 /dev/cu.usbserial
          ),
        );
        
        port.dispose(); // 获取完信息后释放资源，防止内存泄漏
      }
    }
  } catch (e) {
    print("扫描设备时发生错误: $e");
  }

  return availableDevices;
}
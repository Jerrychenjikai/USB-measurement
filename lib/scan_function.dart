import 'dart:io' show Platform;
import 'package:usb_serial/usb_serial.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

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

Future<List<MySerialDevice>> getAvailablePorts() async {
  List<MySerialDevice> availableDevices = [];

  try {
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
    } else if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
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
          // 【修复】无论获取描述是否抛错，严格释放临时端口实例
          port.dispose(); 
        }
      }
    }
  } catch (e) {
    print("扫描设备时发生错误: $e");
  }

  return availableDevices;
}
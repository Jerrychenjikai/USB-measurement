import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:usb_measurement/scan_function.dart';
import 'package:usb_measurement/receive_data.dart';


void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: MaterialApp(
        title: 'USB measurement',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        ),
        home: const MyHomePage(),
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  List<MySerialDevice> available_devices = [];
  List<Widget> device_list = [];

  String hint = "Click the button to search for devices";

  List<Widget> _render_devices(List<MySerialDevice> devices) {
    return devices.map((device) {
      return ListTile(
        // 左侧显示 USB 图标或串口图标
        leading: const Icon(Icons.usb), 
        
        // 主标题显示设备名称 (例如: CP2102 USB to UART)
        title: Text(device.name),
        
        // 副标题显示系统路径 (例如: COM3 或 /dev/ttyUSB0)
        subtitle: Text(
          device.devicePath,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        
        // 右侧添加一个连接箭头的图标
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        
        // 点击后的处理逻辑
        onTap: () {
          _handleDeviceSelection(device);
        },
      );
    }).toList();
  }

  void _handleDeviceSelection(MySerialDevice device) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SerialMonitorPage(device: device),
      ),
    );
  }

  void _start_scan() async {
    available_devices = await getAvailablePorts();

    setState(() {
      device_list = _render_devices(available_devices);
    });
    
    hint = "found ${device_list.length} devices";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text("Home Page"),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(hint),
            ...device_list,
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _start_scan,
        tooltip: 'start scan',
        child: const Icon(Icons.add),
      ),
    );
  }
}

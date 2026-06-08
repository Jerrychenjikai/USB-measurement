import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:usb_measurement/scan_function.dart';
import 'package:usb_measurement/receive_data.dart';


void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: MaterialApp(
        title: 'USB measurement (Mock Mode)',
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

  String hint = "点击右下角按钮扫描(模拟)设备";

  List<Widget> _render_devices(List<MySerialDevice> devices) {
    return devices.map((device) {
      return ListTile(
        leading: const Icon(Icons.usb, color: Colors.deepPurple), 
        title: Text(device.name, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(
          device.devicePath,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
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
    // 注入虚拟设备，不调用底层真实扫描
    available_devices = [
      MySerialDevice(name: "虚拟传感器 A (正弦波模拟)", devicePath: "COM_MOCK_A"),
      MySerialDevice(name: "虚拟测试节点 B", devicePath: "/dev/ttyMOCK_B"),
    ];

    setState(() {
      device_list = _render_devices(available_devices);
    });
    
    hint = "找到了 ${device_list.length} 个虚拟设备，点击进入UI预览";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text("主页 (脱机模拟模式)"),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                hint,
                style: const TextStyle(fontSize: 16, color: Colors.blueGrey),
              ),
            ),
            Expanded(
              child: ListView(
                children: device_list,
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _start_scan,
        tooltip: 'start scan',
        child: const Icon(Icons.search),
      ),
    );
  }
}
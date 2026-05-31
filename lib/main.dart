import 'package:flutter/material.dart';

import 'package:usb_measurement/scan_function.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'USB measurement',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(),
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

  // 模拟点击后的处理逻辑
  void _handleDeviceSelection(MySerialDevice device) {
    print("用户选择了设备: ${device.name}，路径: ${device.devicePath}");
    // 这里跳转到数据监测页面，或者开始执行串口连接逻辑
  }

  void _start_scan() async {
    available_devices = await getAvailablePorts();

    print("scanned");

    setState(() {
      device_list = _render_devices(available_devices);
    });
    
    print("found ${device_list.length} devices");
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
          children: device_list,
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

import 'dart:async';
import 'dart:collection'; 
import 'dart:typed_data'; 
import 'package:flutter/foundation.dart'; 
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:usb_measurement/scan_function.dart'; 

import 'package:usb_serial/usb_serial.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

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
  final int dataLength;    
  
  final int baudRate;      // 【新增】波特率支持
  final int dataBits;      
  final int stopBits;      
  final int parity;        

  ProtocolConfig({
    this.sps = 30,
    this.dataLength = 1024,
    this.baudRate = 115200,
    this.dataBits = 8,
    this.stopBits = 1,
    this.parity = 0,
  });

  List<int> get controlBytes {
    return [
      0x43,
      sps & 0xFF,
      (dataLength >> 8) & 0xFF,
      dataLength & 0xFF,
    ];
  }

  ProtocolConfig copyWith({
    int? sps,
    int? dataLength,
    int? baudRate,
    int? dataBits,
    int? stopBits,
    int? parity,
  }) {
    return ProtocolConfig(
      sps: sps ?? this.sps,
      dataLength: dataLength ?? this.dataLength,
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

  Future<void> connectDevice() async {
    if (_isConnecting) return;
    _isConnecting = true;

    state = state.copyWith(status: SerialStatus.connecting, errorMessage: "");
    await _cleanup(); 

    try {
      // 【修复】Web 端优雅断开提示
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
        
        // 【修复】强制 await 参数配置，防止异步时序失控
        await _androidPort!.setPortParameters(
          state.config.baudRate, 
          UsbPort.DATABITS_8, 
          UsbPort.STOPBITS_1, 
          UsbPort.PARITY_NONE
        );

        final stream = _androidPort!.inputStream;
        if (stream == null) throw Exception("无法拉取 Android USB 核心输入流");

        _androidSub = stream.listen((data) => _handleIncomingData(data));
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
        spConfig.bits = 8;
        spConfig.stopBits = 1;
        spConfig.parity = SerialPortParity.none;
        _desktopPort!.config = spConfig; 

        try {
          _desktopReader = SerialPortReader(_desktopPort!);
          _desktopSub = _desktopReader!.stream.listen((data) => _handleIncomingData(data));
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

        // 【修复】加上 await
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

      // 【修复】调换顺序：先清空缓冲并切状态，再往底层写命令，防止 MCU 秒回数据被意外清掉
      _buffer.clear();
      state = state.copyWith(config: config, currentDisplayData: []);

      final cmd = Uint8List.fromList(config.controlBytes);
      if (defaultTargetPlatform == TargetPlatform.android && _androidPort != null) {
        await _androidPort!.write(cmd); // 【修复】加上 await
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
    final targetLength = state.config.dataLength;
    if (_buffer.length >= targetLength) return;

    _buffer.addAll(data);
    state = state.copyWith(
      currentDisplayData: _buffer.toList(),
    );
  }
}

final serialPageProvider = NotifierProvider.family<SerialPageNotifier, SerialPageState, MySerialDevice>(
  SerialPageNotifier.new,
);

// ==========================================
// 3. 页面主体渲染及交互视图
// ==========================================

class SerialMonitorPage extends ConsumerWidget {
  final MySerialDevice device;
  const SerialMonitorPage({super.key, required this.device});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pageState = ref.watch(serialPageProvider(device));
    final notifier = ref.read(serialPageProvider(device).notifier);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text("监测: ${pageState.device.name}"),
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: _buildStateView(context, pageState, notifier),
      ),
    );
  }

  Widget _buildStateView(BuildContext context, SerialPageState pageState, SerialPageNotifier notifier) {
    switch (pageState.status) {
      case SerialStatus.connecting:
        return _ConnectingView(device: pageState.device);
      case SerialStatus.active:
        return _ActiveInteractiveView(
          pageState: pageState,
          onSend: (config) => notifier.sendCommand(config),
          onDisconnect: () => notifier.disconnectDevice(),
        );
      case SerialStatus.disconnected:
        return _DisconnectedView(
          errorMessage: pageState.errorMessage,
          onRetry: () => notifier.connectDevice(),
        );
    }
  }
}

class _ConnectingView extends StatelessWidget {
  final MySerialDevice device;
  const _ConnectingView({required this.device});

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('connecting'),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          const Text("正在获取权限并打开串口句柄...", style: TextStyle(fontSize: 15)),
          const SizedBox(height: 8),
          Text(device.devicePath, style: const TextStyle(color: Colors.grey, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

class _ActiveInteractiveView extends StatefulWidget {
  final SerialPageState pageState;
  final ValueChanged<ProtocolConfig> onSend;
  final VoidCallback onDisconnect;

  const _ActiveInteractiveView({
    required this.pageState,
    required this.onSend,
    required this.onDisconnect,
  });

  @override
  State<_ActiveInteractiveView> createState() => _ActiveInteractiveViewState();
}

class _ActiveInteractiveViewState extends State<_ActiveInteractiveView> {
  final _formKey = GlobalKey<FormState>();
  
  late TextEditingController _spsController;
  late TextEditingController _lengthController;
  
  late int _baudRate;
  late int _dataBits;
  late int _stopBits;
  late int _parity;

  @override
  void initState() {
    super.initState();
    _spsController = TextEditingController(text: widget.pageState.config.sps.toString());
    _lengthController = TextEditingController(text: widget.pageState.config.dataLength.toString());
    
    _baudRate = widget.pageState.config.baudRate;
    _dataBits = widget.pageState.config.dataBits;
    _stopBits = widget.pageState.config.stopBits;
    _parity = widget.pageState.config.parity;
  }

  // 【修复】处理外部重置导致的 UI 状态脱节
  @override
  void didUpdateWidget(covariant _ActiveInteractiveView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pageState.config != oldWidget.pageState.config) {
      if (_spsController.text != widget.pageState.config.sps.toString()) {
        _spsController.text = widget.pageState.config.sps.toString();
      }
      if (_lengthController.text != widget.pageState.config.dataLength.toString()) {
        _lengthController.text = widget.pageState.config.dataLength.toString();
      }
      setState(() {
        _baudRate = widget.pageState.config.baudRate;
        _dataBits = widget.pageState.config.dataBits;
        _stopBits = widget.pageState.config.stopBits;
        _parity = widget.pageState.config.parity;
      });
    }
  }

  @override
  void dispose() {
    _spsController.dispose();
    _lengthController.dispose();
    super.dispose();
  }

  // 【修复】大数据渲染截断防卡死
  String _buildHexDisplay(List<int> rawData) {
    if (rawData.isEmpty) return "等待应用配置并下发指令后唤醒流数据...";
    
    // 如果数据量小，直接全量渲染
    if (rawData.length <= 1000) {
      return "收齐数据 Hex 视图:\n${rawData.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ')}";
    }

    // 数据量超大时，只渲染头尾各 400 字节，中间折叠
    final head = rawData.take(400).map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
    final tail = rawData.skip(rawData.length - 400).map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
    
    return "收齐数据 Hex 视图 (超大载荷自动折叠):\n$head\n\n... [省略展示中间的 ${rawData.length - 800} 字节] ...\n\n$tail";
  }

  @override
  Widget build(BuildContext context) {
    final rawData = widget.pageState.currentDisplayData;
    final targetLength = widget.pageState.config.dataLength;
    final isCompleted = rawData.length >= targetLength;

    return Padding(
      key: const ValueKey('active_interactive'),
      padding: const EdgeInsets.all(16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧：Configuration 表单区
          Expanded(
            flex: 1,
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.only(right: 8.0),
                children: [
                  Row(
                    children: const [
                      Icon(Icons.settings_input_component, color: Colors.deepPurple),
                      SizedBox(width: 8),
                      Text("通信参数配置", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const Divider(height: 24),
                  
                  TextFormField(
                    controller: _spsController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: "每秒采集数据量 (SPS)",
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                    validator: (val) {
                      if (val == null || val.isEmpty) return "不能为空";
                      final parsed = int.tryParse(val.trim());
                      if (parsed == null || parsed <= 0 || parsed > 255) return "需1-255内整数";
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  
                  TextFormField(
                    controller: _lengthController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: "传输数据长度 (Bytes)",
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                    validator: (val) {
                      if (val == null || val.isEmpty) return "不能为空";
                      final parsed = int.tryParse(val.trim());
                      if (parsed == null || parsed <= 0 || parsed > 65535) return "越界";
                      return null;
                    },
                  ),
                  const SizedBox(height: 24),
                  const Text("物理层参数", style: TextStyle(color: Colors.grey, fontSize: 13)),
                  const SizedBox(height: 12),

                  DropdownButtonFormField<int>(
                    value: _baudRate,
                    decoration: const InputDecoration(
                      labelText: "波特率", 
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                    items: [9600, 19200, 38400, 57600, 115200, 256000, 921600]
                        .map((e) => DropdownMenuItem(value: e, child: Text("$e bps")))
                        .toList(),
                    onChanged: (v) => setState(() => _baudRate = v!),
                  ),
                  const SizedBox(height: 16),
                  
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          value: _dataBits,
                          decoration: const InputDecoration(
                            labelText: "数据位", 
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                          items: [5, 6, 7, 8].map((e) => DropdownMenuItem(value: e, child: Text("$e位"))).toList(),
                          onChanged: (v) => setState(() => _dataBits = v!),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          value: _stopBits,
                          decoration: const InputDecoration(
                            labelText: "停止位", 
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                          items: [1, 2].map((e) => DropdownMenuItem(value: e, child: Text("$e位"))).toList(),
                          onChanged: (v) => setState(() => _stopBits = v!),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          value: _parity,
                          decoration: const InputDecoration(
                            labelText: "校验", 
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                          items: const [
                            DropdownMenuItem(value: 0, child: Text("N")),
                            DropdownMenuItem(value: 1, child: Text("O")),
                            DropdownMenuItem(value: 2, child: Text("E")),
                          ],
                          onChanged: (v) => setState(() => _parity = v!),
                        ),
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 32),
                  ElevatedButton.icon(
                    onPressed: () {
                      if (_formKey.currentState?.validate() ?? false) {
                        final config = ProtocolConfig(
                          sps: int.parse(_spsController.text.trim()),
                          dataLength: int.parse(_lengthController.text.trim()),
                          baudRate: _baudRate,
                          dataBits: _dataBits,
                          stopBits: _stopBits,
                          parity: _parity,
                        );
                        widget.onSend(config);
                      }
                    },
                    icon: const Icon(Icons.send),
                    label: const Text("应用配置并发送指令"),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.deepPurple,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: widget.onDisconnect,
                    icon: const Icon(Icons.power_off),
                    label: const Text("断开串口连接"),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          const VerticalDivider(width: 32, thickness: 1),

          // 右侧：实时输出显示区
          Expanded(
            flex: 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      isCompleted ? Icons.check_circle : Icons.sync,
                      color: isCompleted ? Colors.green : Colors.amber,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isCompleted 
                          ? "单次数据已收齐 (${rawData.length} 字节)" 
                          : "正在接收数据 (${rawData.length} / $targetLength 字节)",
                      style: TextStyle(
                        fontSize: 16, 
                        fontWeight: FontWeight.bold,
                        color: isCompleted ? Colors.green : Colors.amber.shade800
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
                Expanded(
                  child: Card(
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: SizedBox(
                        width: double.infinity,
                        height: double.infinity,
                        child: SingleChildScrollView(
                          child: Text(
                            _buildHexDisplay(rawData),
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Colors.blueGrey),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DisconnectedView extends StatelessWidget {
  final String errorMessage;
  final VoidCallback onRetry;
  const _DisconnectedView({required this.errorMessage, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('disconnected'),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.power_off, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            const Text("通信链路状态反馈", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            if (errorMessage.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
                child: Text(errorMessage, style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
              ),
            ],
            const SizedBox(height: 40),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: onRetry, 
                  icon: const Icon(Icons.sync),
                  label: const Text("建立通道"),
                ),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text("退出监控"),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}
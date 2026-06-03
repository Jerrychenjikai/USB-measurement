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
  configuring,   
  receiving,     
  completed,     
  disconnected,  
}

class ProtocolConfig {
  final int sps;           
  final int dataLength;    

  ProtocolConfig({
    this.sps = 30,
    this.dataLength = 1024,
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
  }) {
    return ProtocolConfig(
      sps: sps ?? this.sps,
      dataLength: dataLength ?? this.dataLength,
    );
  }
}

class SerialPageState {
  final SerialStatus status;
  final MySerialDevice device;
  final ProtocolConfig config;
  final List<List<int>> receivedFrames; 
  final String errorMessage;

  SerialPageState({
    required this.status,
    required this.device,
    required this.config,
    this.receivedFrames = const [],
    this.errorMessage = "",
  });

  SerialPageState copyWith({
    SerialStatus? status,
    MySerialDevice? device,
    ProtocolConfig? config,
    List<List<int>>? receivedFrames,
    String? errorMessage,
  }) {
    return SerialPageState(
      status: status ?? this.status,
      device: device ?? this.device,
      config: config ?? this.config,
      receivedFrames: receivedFrames ?? this.receivedFrames,
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
  bool _isCompleted = false; // 【PR 修补 1】新增：数据流同步防重入锁

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
    
    // 【PR 修补 5】彻底拆分异常捕获，防备硬件级雪崩
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
      if (kIsWeb) throw Exception("Web 平台暂不支持原生串行硬件通信");

      const int hardcodedBaudRate = 115200;

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
        _androidPort!.setPortParameters(hardcodedBaudRate, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);

        final stream = _androidPort!.inputStream;
        if (stream == null) throw Exception("无法拉取 Android USB 核心输入流");

        _androidSub = stream.listen((data) => _handleIncomingData(data));
        state = state.copyWith(status: SerialStatus.configuring);

      } else if (defaultTargetPlatform == TargetPlatform.windows || 
                 defaultTargetPlatform == TargetPlatform.macOS || 
                 defaultTargetPlatform == TargetPlatform.linux) {
        
        _desktopPort = SerialPort(state.device.devicePath);
        if (!_desktopPort!.openReadWrite()) {
          final lastErr = SerialPort.lastError;
          _desktopPort = null;
          throw Exception("打开串口失败: $lastErr");
        }

        // 【PR 修补 2】将配置抽取成对象设置后再反向覆写回串口实例，强制生效
        final spConfig = _desktopPort!.config;
        spConfig.baudRate = hardcodedBaudRate;
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

        state = state.copyWith(status: SerialStatus.configuring);
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

  Future<void> startReceiving(ProtocolConfig config) async {
    final cmd = Uint8List.fromList(config.controlBytes);

    try {
      // 【PR 修补 8】先往底层硬灌数据，没有抛出异常后再进行视图和状态切换
      if (defaultTargetPlatform == TargetPlatform.android && _androidPort != null) {
        await _androidPort!.write(cmd);
      } else if (_desktopPort != null && _desktopPort!.isOpen) {
        _desktopPort!.write(cmd);
      } else {
        throw Exception("通信通道未打开或已断开");
      }

      // 下发成功，此时才重置环境
      _buffer.clear();
      _isCompleted = false; // 重置防重入锁

      state = state.copyWith(
        status: SerialStatus.receiving,
        config: config,
        receivedFrames: [],
      );
    } catch (e) {
      debugPrint("向MCU下发控制命令失败: $e");
      state = state.copyWith(
        status: SerialStatus.disconnected,
        errorMessage: "控制命令下发失败: $e",
      );
    }
  }

  void disconnectDevice() async {
    await _cleanup();
    state = state.copyWith(status: SerialStatus.disconnected);
  }

  // ==========================================
  // 3. 核心定长截取算法
  // ==========================================
  
  void _handleIncomingData(List<int> data) async {
    // 【PR 修补 1】拦截在 await 挂起期间，底层 Stream 扔过来的“幽灵数据”
    if (state.status != SerialStatus.receiving || _isCompleted) return;

    _buffer.addAll(data);
    final targetLength = state.config.dataLength;

    if (_buffer.length >= targetLength) {
      // 第一时间同步关上闸门
      _isCompleted = true;
      _androidSub?.cancel(); 
      _desktopSub?.cancel();

      final frame = <int>[];
      for (int i = 0; i < targetLength; i++) {
        frame.add(_buffer.removeFirst());
      }

      // 放心大胆地去交出线程控制权，释放底层
      await _cleanup();

      state = state.copyWith(
        status: SerialStatus.completed,
        receivedFrames: [frame],
      );
    }
  }
}

final serialPageProvider = NotifierProvider.family<SerialPageNotifier, SerialPageState, MySerialDevice>(
  SerialPageNotifier.new,
);

// ==========================================
// 4. 页面主体渲染及交互视图 (此处无需修改)
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
      case SerialStatus.configuring:
        return _ConfiguringView(
          initialConfig: pageState.config,
          onConfirm: (config) => notifier.startReceiving(config),
        );
      case SerialStatus.receiving:
        return _ReceivingView(
          pageState: pageState,
          onStop: () => notifier.disconnectDevice(),
        );
      case SerialStatus.completed:
        return _CompletedView(
          pageState: pageState,
          onRetry: () => notifier.connectDevice(),
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
          const Text("正在配置底层并打开串口句柄...", style: TextStyle(fontSize: 15)),
          const SizedBox(height: 8),
          Text(device.devicePath, style: const TextStyle(color: Colors.grey, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

class _ConfiguringView extends StatefulWidget {
  final ProtocolConfig initialConfig;
  final ValueChanged<ProtocolConfig> onConfirm;
  const _ConfiguringView({required this.initialConfig, required this.onConfirm});

  @override
  State<_ConfiguringView> createState() => _ConfiguringViewState();
}

class _ConfiguringViewState extends State<_ConfiguringView> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _spsController;
  late TextEditingController _lengthController;

  @override
  void initState() {
    super.initState();
    _spsController = TextEditingController(text: widget.initialConfig.sps.toString());
    _lengthController = TextEditingController(text: widget.initialConfig.dataLength.toString());
  }

  @override
  void dispose() {
    _spsController.dispose();
    _lengthController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Padding(
        key: const ValueKey('configuring'),
        padding: const EdgeInsets.all(20.0),
        child: ListView(
          children: [
            Row(
              children: const [
                Icon(Icons.settings_input_component, color: Colors.deepPurple),
                SizedBox(width: 8),
                Text("下发控制字段配置 (Baud: 115200)", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              ],
            ),
            const Divider(height: 24),

            TextFormField(
              controller: _spsController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: "每秒采集数据量 (SPS / Second Byte)",
                border: OutlineInputBorder(),
                hintText: "例如: 30",
              ),
              validator: (val) {
                if (val == null || val.trim().isEmpty) return "数据量不能为空";
                final parsed = int.tryParse(val.trim());
                if (parsed == null || parsed <= 0 || parsed > 255) return "请输入1-255之间的有效整数";
                return null;
              },
            ),
            const SizedBox(height: 16),
            
            TextFormField(
              controller: _lengthController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: "传输数据长度 (Bytes / 16位大端序)",
                border: OutlineInputBorder(),
                hintText: "例如: 1024",
              ),
              validator: (val) {
                if (val == null || val.trim().isEmpty) return "传输数据长度不能为空";
                final parsed = int.tryParse(val.trim());
                if (parsed == null || parsed <= 0 || parsed > 65535) return "请输入1-65535之间的字节长度";
                return null;
              },
            ),
            const SizedBox(height: 32),
            
            ElevatedButton.icon(
              onPressed: () {
                if (_formKey.currentState?.validate() ?? false) {
                  final config = ProtocolConfig(
                    sps: int.parse(_spsController.text.trim()),
                    dataLength: int.parse(_lengthController.text.trim()),
                  );
                  widget.onConfirm(config);
                }
              },
              icon: const Icon(Icons.send),
              label: const Text("下发指令并注入接收监听"),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: Colors.deepPurple,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReceivingView extends StatelessWidget {
  final SerialPageState pageState;
  final VoidCallback onStop;
  const _ReceivingView({required this.pageState, required this.onStop});

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('receiving'),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.outbound, size: 56, color: Colors.amber),
            const SizedBox(height: 16),
            const Text("控制信号已成功送达 MCU", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.amber)),
            const SizedBox(height: 8),
            const Text("下位机正根据指令采集并回吐流数据...", style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 24),
            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(" 运行波特率: 115200 bps (固定)"),
                    const SizedBox(height: 6),
                    Text(" 下发配置SPS: ${pageState.config.sps} sps"),
                    const SizedBox(height: 6),
                    Text(" 期望总截取长度: ${pageState.config.dataLength} 字节"),
                    const Divider(height: 20),
                    const Text(" 提示：一旦本地物理流字节凑齐目标长度，将自动执行安全断开。", style: TextStyle(color: Colors.blueGrey, fontSize: 12)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 40),
            ElevatedButton.icon(
              onPressed: onStop,
              icon: const Icon(Icons.stop_screen_share),
              label: const Text("强行中止并解绑端口"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              ),
            )
          ],
        ),
      ),
    );
  }
}

class _CompletedView extends StatelessWidget {
  final SerialPageState pageState;
  final VoidCallback onRetry;
  const _CompletedView({required this.pageState, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final rawData = pageState.receivedFrames.isNotEmpty ? pageState.receivedFrames.first : <int>[];

    return Center(
      key: const ValueKey('completed'),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, size: 64, color: Colors.green),
            const SizedBox(height: 16),
            const Text("单次请求数据已完整收齐", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green)),
            const SizedBox(height: 8),
            const Text("底层硬件通道已按预期安全自动切断", style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 24),
            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(" 成功截获有效载荷: ${rawData.length} 字节"),
                    const Divider(height: 20),
                    if (rawData.isNotEmpty)
                      SizedBox(
                        height: 180,
                        child: SingleChildScrollView(
                          child: Text(
                            "收齐数据 Hex 视图:\n${rawData.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ')}",
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Colors.blueGrey),
                          ),
                        ),
                      )
                    else
                      const Text("缓冲器为空", style: TextStyle(color: Colors.grey)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 40),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.sync),
                  label: const Text("再次唤醒通道"),
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
            const Text("通信链路闭合中断", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            if (errorMessage.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
                child: Text("硬件底层抛出: $errorMessage", style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
              ),
            ],
            const SizedBox(height: 40),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: onRetry, 
                  icon: const Icon(Icons.sync),
                  label: const Text("重新唤醒通道"),
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
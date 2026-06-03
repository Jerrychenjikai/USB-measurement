import 'dart:async';
import 'dart:collection'; // 引入 Queue 优化双端队列性能
import 'package:flutter/foundation.dart'; // 引入 kIsWeb & defaultTargetPlatform 规避跨平台编译错误
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// 引入统一设备模型
import 'package:usb_measurement/scan_function.dart'; 

// 底层硬件依赖
import 'package:usb_serial/usb_serial.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

// ==========================================
// 1. 状态机及协议配置的数据结构定义
// ==========================================

enum SerialStatus {
  connecting,    // 连接中
  configuring,   // 配置协议
  receiving,     // 接收数据中
  disconnected,  // 停止接收数据并断开连接
}

/// 用户自定义的协议配置模型
class ProtocolConfig {
  final String frameHeader;    // 帧头（如 "5A" 或 "5AA5"）
  final int baudRate;          // 【新增】可自定义波特率
  final int channelCount;      // 通道数
  final int bytesPerChannel;   // 每个通道的字节数
  final String variableType;   // 每个通道的变量类型

  ProtocolConfig({
    this.frameHeader = "5A",
    this.baudRate = 115200,    // 默认 115200
    this.channelCount = 2,
    this.bytesPerChannel = 2,
    this.variableType = "int16",
  });

  /// 【归一化逻辑】统一由解析器生成标准字节数组，供长度计算和滑动窗口复用
  List<int> get headerBytes {
    String cleanHex = frameHeader.replaceAll('0x', '').replaceAll(' ', '').replaceAll('x', '');
    if (cleanHex.isEmpty) return [0x5A]; 
    if (cleanHex.length % 2 != 0) cleanHex = '0$cleanHex'; // 奇数长度前补0
    List<int> bytes = [];
    for (int i = 0; i < cleanHex.length; i += 2) {
      bytes.add(int.parse(cleanHex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  /// 【消除计算不一致】直接通过统一的 headerBytes.length 叠加计算，绝不劈叉
  int get totalFrameLength {
    return headerBytes.length + (channelCount * bytesPerChannel);
  }

  ProtocolConfig copyWith({
    String? frameHeader,
    int? baudRate,
    int? channelCount,
    int? bytesPerChannel,
    String? variableType,
  }) {
    return ProtocolConfig(
      frameHeader: frameHeader ?? this.frameHeader,
      baudRate: baudRate ?? this.baudRate,
      channelCount: channelCount ?? this.channelCount,
      bytesPerChannel: bytesPerChannel ?? this.bytesPerChannel,
      variableType: variableType ?? this.variableType,
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
  // 硬件持有句柄
  UsbPort? _androidPort;
  StreamSubscription? _androidSub;
  SerialPort? _desktopPort;
  SerialPortReader? _desktopReader;
  StreamSubscription? _desktopSub;

  // 【防连点并发锁】
  bool _isConnecting = false;

  // 【性能优化】改用 Queue 替代 List，使头部滑窗 removeFirst() 达到 O(1) 效率
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

  /// 【异步资源安全释放】彻底等待上一次关闭完成后再释放句柄，规避半开或独占死锁
  Future<void> _cleanup() async {
    await _androidSub?.cancel();
    _androidSub = null;
    if (_androidPort != null) {
      try { await _androidPort!.close(); } catch (_) {}
      _androidPort = null;
    }

    await _desktopSub?.cancel();
    _desktopSub = null;
    _desktopReader?.close();
    _desktopReader = null;
    try {
      if (_desktopPort != null) {
        if (_desktopPort!.isOpen) _desktopPort!.close();
        _desktopPort!.dispose();
      }
    } catch (_) {}
    _desktopPort = null;

    _buffer.clear();
  }

  /// 硬件连接逻辑
  Future<void> connectDevice() async {
    // 【并发控制】防止异步任务多重叠加修改 state
    if (_isConnecting) return;
    _isConnecting = true;

    state = state.copyWith(status: SerialStatus.connecting, errorMessage: "");
    await _cleanup(); // await 确保前一次清理干净

    try {
      // 【Web 编译防护】杜绝直接读取 Platform 导致的红屏
      if (kIsWeb) {
        throw Exception("Web 平台暂不支持原生串行硬件通信");
      }

      else if (defaultTargetPlatform == TargetPlatform.android) {
        // 1. 查找设备
        List<UsbDevice> devices = await UsbSerial.listDevices();
        UsbDevice? targetDevice;
        for (var d in devices) {
            if (d.deviceName == state.device.devicePath) {
                targetDevice = d;
                break;
            }
        }
        if (targetDevice == null) throw Exception("未找到对应底层路径的安卓USB设备");

        // 2. 获取端口并请求权限 (create 方法会弹出授权对话框)
        _androidPort = await targetDevice.create();
        if (_androidPort == null) throw Exception("无法获取安卓USB端口");

        // 3. 打开端口
        bool openResult = await _androidPort!.open();
        if (!openResult) throw Exception("无法打开安卓USB端口");

        // 4. 配置端口参数
        await _androidPort!.setDTR(true);
        await _androidPort!.setRTS(true);
        _androidPort!.setPortParameters(state.config.baudRate, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);

        // 5. 监听数据流
        final stream = _androidPort!.inputStream;
        if (stream == null) throw Exception("无法拉取 Android USB 核心输入流");

        _androidSub = stream.listen((data) => _handleIncomingData(data));
        state = state.copyWith(status: SerialStatus.configuring);

      } else if (defaultTargetPlatform == TargetPlatform.windows || 
                 defaultTargetPlatform == TargetPlatform.macOS || 
                 defaultTargetPlatform == TargetPlatform.linux) { // 【新增 Linux 支持】
        
        _desktopPort = SerialPort(state.device.devicePath);
        if (!_desktopPort!.openReadWrite()) {
          final lastErr = SerialPort.lastError;
          _desktopPort = null;
          throw Exception("打开串口失败: $lastErr");
        }

        // 初始化默认配置
        _desktopPort!.config.baudRate = state.config.baudRate;
        _desktopPort!.config.bits = 8;
        _desktopPort!.config.stopBits = 1;
        _desktopPort!.config.parity = SerialPortParity.none;

        // 【异常流验证】捕获端口被独占或底层异常导致的 Reader 崩溃
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

  /// 保存协议配置、动态调整波特率并开始接收
  void startReceiving(ProtocolConfig config) {
    _buffer.clear();

    // 【动态波特率热重载】在不销毁串口句柄的情况下，直接修改底层波特率
    try {
      if (defaultTargetPlatform == TargetPlatform.android && _androidPort != null) {
        _androidPort!.setPortParameters(config.baudRate, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);
      } else if (_desktopPort != null && _desktopPort!.isOpen) {
        _desktopPort!.config.baudRate = config.baudRate;
      }
    } catch (e) {
      debugPrint("底层硬件动态调整波特率失败: $e");
    }

    state = state.copyWith(
      status: SerialStatus.receiving,
      config: config,
      receivedFrames: [],
    );
  }

  void disconnectDevice() async {
    await _cleanup();
    state = state.copyWith(status: SerialStatus.disconnected);
  }

  // ==========================================
  // 3. 核心 O(1) 滑动窗口算法
  // ==========================================
  
  void _handleIncomingData(List<int> data) {
    if (state.status != SerialStatus.receiving) return;

    _buffer.addAll(data);
    final header = state.config.headerBytes;
    final frameLength = state.config.totalFrameLength;

    // 基于 Queue 的 $O(1)$ 高效滑动扫描
    while (_buffer.length >= frameLength) {
      bool isMatch = true;
      
      // 检查队列头部是否与指定的多字节帧头匹配
      for (int i = 0; i < header.length; i++) {
        if (_buffer.elementAt(i) != header[i]) {
          isMatch = false;
          break;
        }
      }

      if (isMatch) {
        // 匹配成功：提取出固定长度的一帧
        final frame = <int>[];
        for (int i = 0; i < frameLength; i++) {
          frame.add(_buffer.removeFirst());
        }

        // 【内存泄露防护】限制内存状态树中最大保留 500 帧，防止长时间运行导致 OOM
        List<List<int>> nextFrames = List.from(state.receivedFrames);
        if (nextFrames.length >= 500) {
          nextFrames.removeAt(0); 
        }
        nextFrames.add(frame);

        state = state.copyWith(receivedFrames: nextFrames);
      } else {
        // 头字节未对齐，滑出头部 1 字节继续检索
        _buffer.removeFirst();
      }
    }
  }
}

final serialPageProvider = NotifierProvider.family<SerialPageNotifier, SerialPageState, MySerialDevice>(
  SerialPageNotifier.new,
);

// ==========================================
// 4. 页面主体渲染及交互视图
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
  late TextEditingController _headerController;
  late TextEditingController _channelsController;
  late TextEditingController _bytesController;
  late int _selectedBaudRate;
  String _variableType = "int16";

  @override
  void initState() {
    super.initState();
    _headerController = TextEditingController(text: widget.initialConfig.frameHeader);
    _channelsController = TextEditingController(text: widget.initialConfig.channelCount.toString());
    _bytesController = TextEditingController(text: widget.initialConfig.bytesPerChannel.toString());
    _selectedBaudRate = widget.initialConfig.baudRate;
    _variableType = widget.initialConfig.variableType;
  }

  @override
  void dispose() {
    _headerController.dispose();
    _channelsController.dispose();
    _bytesController.dispose();
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
                Text("自定义动态协议参数", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              ],
            ),
            const Divider(height: 24),
            
            // 【新增】波特率选择器
            DropdownButtonFormField<int>(
              value: _selectedBaudRate,
              decoration: const InputDecoration(labelText: "通信波特率 (Baud Rate)", border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 9600, child: Text("9600 bps")),
                DropdownMenuItem(value: 19200, child: Text("19200 bps")),
                DropdownMenuItem(value: 38400, child: Text("38400 bps")),
                DropdownMenuItem(value: 57600, child: Text("57600 bps")),
                DropdownMenuItem(value: 115200, child: Text("115200 bps")),
                DropdownMenuItem(value: 921600, child: Text("921600 bps")),
              ],
              onChanged: (val) { if (val != null) _selectedBaudRate = val; },
            ),
            const SizedBox(height: 16),

            // 【严格输入校验】禁止非法十六进制输入
            TextFormField(
              controller: _headerController,
              decoration: const InputDecoration(
                labelText: "自定义数据帧头 (Hex String，支持多字节如 5AA5)",
                border: OutlineInputBorder(),
                hintText: "5A",
              ),
              validator: (val) {
                if (val == null || val.trim().isEmpty) return "帧头不能为空";
                final clean = val.replaceAll('0x', '').replaceAll(' ', '').replaceAll('x', '');
                if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(clean)) return "请输入合法的十六进制字符串";
                return null;
              },
            ),
            const SizedBox(height: 16),
            
            TextFormField(
              controller: _channelsController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "物理通道数量 (Channels)", border: OutlineInputBorder()),
              validator: (val) => (int.tryParse(val ?? '') ?? 0) <= 0 ? "通道数必须大于0" : null,
            ),
            const SizedBox(height: 16),
            
            TextFormField(
              controller: _bytesController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "单通道占用字节数 (Bytes/Channel)", border: OutlineInputBorder()),
              validator: (val) => (int.tryParse(val ?? '') ?? 0) <= 0 ? "字节数必须大于0" : null,
            ),
            const SizedBox(height: 16),
            
            DropdownButtonFormField<String>(
              value: _variableType,
              decoration: const InputDecoration(labelText: "数据段原始变量解析解析类型", border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: "int16", child: Text("Int16 (16位有符号整数)")),
                DropdownMenuItem(value: "uint16", child: Text("Uint16 (16位无符号整数)")),
                DropdownMenuItem(value: "int32", child: Text("Int32 (32位有符号整数)")),
                DropdownMenuItem(value: "float32", child: Text("Float32 (32位单精度浮点数)")),
              ],
              onChanged: (val) { if (val != null) setState(() => _variableType = val); },
            ),
            const SizedBox(height: 32),
            
            ElevatedButton.icon(
              onPressed: () {
                if (_formKey.currentState?.validate() ?? false) {
                  final config = ProtocolConfig(
                    frameHeader: _headerController.text.trim(),
                    baudRate: _selectedBaudRate,
                    channelCount: int.parse(_channelsController.text.trim()),
                    bytesPerChannel: int.parse(_bytesController.text.trim()),
                    variableType: _variableType,
                  );
                  widget.onConfirm(config);
                }
              },
              icon: const Icon(Icons.bolt),
              label: const Text("锁定协议并注入监听"),
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
            // 【UX 改进】移除了产生“一直在加载未就绪”错觉的滚动进度条，换成脉冲式运行图标
            const Icon(Icons.sensors, size: 56, color: Colors.green),
            const SizedBox(height: 16),
            const Text("串口硬件流正在实时截取...", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green)),
            const SizedBox(height: 24),
            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(" 运行波特率: ${pageState.config.baudRate} bps"),
                    const SizedBox(height: 6),
                    Text(" 期望单帧跨度: ${pageState.config.totalFrameLength} 字节"),
                    const SizedBox(height: 6),
                    Text(" 本地有效帧计数 (Max 500): ${pageState.receivedFrames.length}"),
                    const Divider(height: 20),
                    if (pageState.receivedFrames.isNotEmpty)
                      Text(
                        " 最新包 Hex 原文:\n${pageState.receivedFrames.last.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ')}",
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Colors.blueGrey),
                      )
                    else
                      const Text(" 等待下位机吐出首个满足滑窗对齐的有效物理数据包...", style: TextStyle(color: Colors.grey, fontSize: 12)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 40),
            ElevatedButton.icon(
              onPressed: onStop,
              icon: const Icon(Icons.stop_screen_share),
              label: const Text("安全切断并解绑端口"),
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
                  onPressed: onRetry, // 界面连接按钮由于 _isConnecting 的保护具有天然的防连击防抖
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
import 'dart:async';
import 'dart:collection'; 
import 'dart:typed_data'; 
import 'dart:io'; 
import 'package:flutter/foundation.dart'; 
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart'; // 【修复-10】引入 file_picker

import 'package:usb_measurement/scan_function.dart'; 

import 'package:usb_serial/usb_serial.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

// ==========================================
// 0. 数据类型定义
// ==========================================
enum UsbDataType { int8, uint8, int16, uint16, int32, uint32, float32 }

extension UsbDataTypeExt on UsbDataType {
  int get byteSize {
    switch (this) {
      case UsbDataType.int8:
      case UsbDataType.uint8: return 1;
      case UsbDataType.int16:
      case UsbDataType.uint16: return 2;
      case UsbDataType.int32:
      case UsbDataType.uint32:
      case UsbDataType.float32: return 4;
    }
  }

  String get label {
    return toString().split('.').last;
  }
}

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
  final int duration;      
  final UsbDataType dataType; 
  final int channels;      
  
  final int baudRate;      
  final int dataBits;      
  final int stopBits;      
  final int parity;        

  ProtocolConfig({
    this.sps = 30,
    this.duration = 10,    
    this.dataType = UsbDataType.int16, 
    this.channels = 1,     
    this.baudRate = 115200,
    this.dataBits = 8,
    this.stopBits = 1,
    this.parity = 0,
  });

  int get targetByteLength => duration * sps * channels * dataType.byteSize;

  List<int> get controlBytes {
    return [
      0x43,
      sps & 0xFF,
      (duration >> 8) & 0xFF, 
      duration & 0xFF,
    ];
  }

  ProtocolConfig copyWith({
    int? sps,
    int? duration,
    UsbDataType? dataType,
    int? channels,
    int? baudRate,
    int? dataBits,
    int? stopBits,
    int? parity,
  }) {
    return ProtocolConfig(
      sps: sps ?? this.sps,
      duration: duration ?? this.duration,
      dataType: dataType ?? this.dataType,
      channels: channels ?? this.channels,
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

  // 【修复-1】统一处理流异常断开的逻辑
  void _handleStreamDisconnect(String reason) {
    if (state.status != SerialStatus.disconnected) {
      state = state.copyWith(status: SerialStatus.disconnected, errorMessage: reason);
      _cleanup();
    }
  }

  Future<void> connectDevice() async {
    if (_isConnecting) return;
    _isConnecting = true;

    state = state.copyWith(status: SerialStatus.connecting, errorMessage: "");
    await _cleanup(); 

    try {
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
        
        // 【修复-5】连接初始化时，读取 state.config 里的用户参数，而不是硬编码
        int androidParity = UsbPort.PARITY_NONE;
        if (state.config.parity == 1) androidParity = UsbPort.PARITY_ODD;
        if (state.config.parity == 2) androidParity = UsbPort.PARITY_EVEN;

        await _androidPort!.setPortParameters(
          state.config.baudRate, 
          state.config.dataBits, 
          state.config.stopBits, 
          androidParity
        );

        final stream = _androidPort!.inputStream;
        if (stream == null) throw Exception("无法拉取 Android USB 核心输入流");

        // 【修复-1】加上 onError 和 onDone 监听物理断开
        _androidSub = stream.listen(
          (data) => _handleIncomingData(data),
          onError: (err) => _handleStreamDisconnect("USB 流异常中断: $err"),
          onDone: () => _handleStreamDisconnect("USB 物理设备已断开连接"),
        );
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
        // 【修复-5】桌面端也同步读取 config 里的设置
        spConfig.baudRate = state.config.baudRate;
        spConfig.bits = state.config.dataBits;
        spConfig.stopBits = state.config.stopBits;
        
        int desktopParity = SerialPortParity.none;
        if (state.config.parity == 1) desktopParity = SerialPortParity.odd;
        if (state.config.parity == 2) desktopParity = SerialPortParity.even;
        spConfig.parity = desktopParity;
        
        _desktopPort!.config = spConfig; 

        try {
          _desktopReader = SerialPortReader(_desktopPort!);
          // 【修复-1】桌面端硬件断开监控
          _desktopSub = _desktopReader!.stream.listen(
            (data) => _handleIncomingData(data),
            onError: (err) => _handleStreamDisconnect("串口流异常中断: $err"),
            onDone: () => _handleStreamDisconnect("串口被意外关闭或移除"),
          );
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

      _buffer.clear();
      state = state.copyWith(config: config, currentDisplayData: []);

      final cmd = Uint8List.fromList(config.controlBytes);
      if (defaultTargetPlatform == TargetPlatform.android && _androidPort != null) {
        await _androidPort!.write(cmd); 
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
    
    final targetLength = state.config.targetByteLength;
    if (_buffer.length >= targetLength) return;

    // 【修复-6】防止末尾收到的数据超出 buffer 导致永远塞不进去
    int remaining = targetLength - _buffer.length;
    if (data.length > remaining) {
      _buffer.addAll(data.take(remaining));
    } else {
      _buffer.addAll(data);
    }
    
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
        title: Text("监测: ${pageState.device.name} | v1.1.1 (Build 20260606)"),
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
  late TextEditingController _durationController; 
  // 【修复-10】删除手写的导出路径 Controller
  
  late UsbDataType _dataType;
  late int _channels;
  
  late int _baudRate;
  late int _dataBits;
  late int _stopBits;
  late int _parity;

  @override
  void initState() {
    super.initState();
    _spsController = TextEditingController(text: widget.pageState.config.sps.toString());
    _durationController = TextEditingController(text: widget.pageState.config.duration.toString());
    
    _dataType = widget.pageState.config.dataType;
    _channels = widget.pageState.config.channels;
    
    _baudRate = widget.pageState.config.baudRate;
    _dataBits = widget.pageState.config.dataBits;
    _stopBits = widget.pageState.config.stopBits;
    _parity = widget.pageState.config.parity;
  }

  @override
  void didUpdateWidget(covariant _ActiveInteractiveView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pageState.config != oldWidget.pageState.config) {
      if (_spsController.text != widget.pageState.config.sps.toString()) {
        _spsController.text = widget.pageState.config.sps.toString();
      }
      if (_durationController.text != widget.pageState.config.duration.toString()) {
        _durationController.text = widget.pageState.config.duration.toString();
      }
      setState(() {
        _dataType = widget.pageState.config.dataType;
        _channels = widget.pageState.config.channels;
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
    _durationController.dispose();
    super.dispose();
  }

  num _readValueFromByteData(ByteData bd, int offset, UsbDataType type) {
    const endian = Endian.little;
    switch(type) {
      case UsbDataType.int8: return bd.getInt8(offset);
      case UsbDataType.uint8: return bd.getUint8(offset);
      case UsbDataType.int16: return bd.getInt16(offset, endian);
      case UsbDataType.uint16: return bd.getUint16(offset, endian);
      case UsbDataType.int32: return bd.getInt32(offset, endian);
      case UsbDataType.uint32: return bd.getUint32(offset, endian);
      case UsbDataType.float32: return bd.getFloat32(offset, endian);
    }
  }

  String _formatValue(num val, UsbDataType type) {
    // 【修复-3】拦截 NaN 和 Infinity 防止引发 FormatException
    if (val is double && !val.isFinite) {
      return val.toString(); 
    }
    return type == UsbDataType.float32 ? val.toStringAsFixed(4) : val.toString();
  }

  String _buildChannelDisplay(List<int> rawData, ProtocolConfig config) {
    if (rawData.isEmpty) return "等待应用配置并下发指令后唤醒流数据...";
    
    int bytesPerSample = config.dataType.byteSize;
    int frameSize = config.channels * bytesPerSample;
    int numFrames = rawData.length ~/ frameSize;

    if (numFrames == 0) return "正在接收，当前数据量不足一个完整帧(至少需 $frameSize 字节)...";

    ByteData bd = ByteData.sublistView(Uint8List.fromList(rawData));
    List<String> lines = [];
    
    String header = List.generate(config.channels, (i) => "CH${i+1}".padRight(12)).join();
    lines.add(header);
    lines.add("-" * (config.channels * 12));

    String formatFrame(int frameIdx) {
      int offset = frameIdx * frameSize;
      List<String> vals = [];
      for(int c=0; c<config.channels; c++) {
        num val = _readValueFromByteData(bd, offset, config.dataType);
        String strVal = _formatValue(val, config.dataType); // 调用安全转换方法
        vals.add(strVal.padRight(12));
        offset += bytesPerSample;
      }
      return vals.join();
    }

    if (numFrames <= 1000) {
      for(int i = 0; i < numFrames; i++) lines.add(formatFrame(i));
    } else {
      for(int i = 0; i < 400; i++) lines.add(formatFrame(i));
      lines.add("\n... [省略展示中间的 ${numFrames - 800} 帧数据] ...\n");
      for(int i = numFrames - 400; i < numFrames; i++) lines.add(formatFrame(i));
    }

    int remainingBytes = rawData.length % frameSize;
    String footer = remainingBytes > 0 ? "\n\n(提示: 尾部残留未对齐字节数: $remainingBytes)" : "";

    return lines.join('\n') + footer;
  }

  Future<void> _exportToCsv() async {
    final rawData = widget.pageState.currentDisplayData;
    final config = widget.pageState.config;
    
    int bytesPerSample = config.dataType.byteSize;
    int frameSize = config.channels * bytesPerSample;
    int numFrames = rawData.length ~/ frameSize;

    if (numFrames == 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("没有足够的数据可供导出")));
      return;
    }

    // 【修复-10】调用系统级 FilePicker 对话框
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: '保存 CSV 数据表',
      fileName: 'usb_data_export.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );

    if (outputFile == null) {
      return; // 用户取消了保存
    }

    try {
      File file = File(outputFile);
      StringBuffer csvBuffer = StringBuffer();

      csvBuffer.writeln(List.generate(config.channels, (i) => "CH${i+1}").join(','));

      ByteData bd = ByteData.sublistView(Uint8List.fromList(rawData));
      for(int i = 0; i < numFrames; i++) {
        int offset = i * frameSize;
        List<String> row = [];
        for(int c = 0; c < config.channels; c++) {
          num val = _readValueFromByteData(bd, offset, config.dataType);
          row.add(_formatValue(val, config.dataType)); // 调用安全转换方法
          offset += bytesPerSample;
        }
        csvBuffer.writeln(row.join(','));
      }

      await file.writeAsString(csvBuffer.toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("成功导出 $numFrames 条数据至 $outputFile"),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("导出失败: $e"),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rawData = widget.pageState.currentDisplayData;
    final targetByteLength = widget.pageState.config.targetByteLength;
    final isCompleted = rawData.length >= targetByteLength;
    
    final double progress = (targetByteLength == 0) 
        ? 0.0 
        : (rawData.length / targetByteLength).clamp(0.0, 1.0);

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
                      labelText: "采样率 (SPS)",
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
                    controller: _durationController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: "传输数据时间 (Seconds)",
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                    validator: (val) {
                      if (val == null || val.isEmpty) return "不能为空";
                      final parsed = int.tryParse(val.trim());
                      if (parsed == null || parsed <= 0 || parsed > 65535) return "越界(最大65535)";
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<UsbDataType>(
                          value: _dataType,
                          decoration: const InputDecoration(
                            labelText: "数据类型", 
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                          items: UsbDataType.values
                              .map((e) => DropdownMenuItem(value: e, child: Text(e.label)))
                              .toList(),
                          onChanged: (v) => setState(() => _dataType = v!),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          value: _channels,
                          decoration: const InputDecoration(
                            labelText: "通道数", 
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                          items: [1, 2, 3, 4, 8, 16] 
                              .map((e) => DropdownMenuItem(value: e, child: Text("$e CH")))
                              .toList(),
                          onChanged: (v) => setState(() => _channels = v!),
                        ),
                      ),
                    ],
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
                        // 【修复-7】发送前进行 OOM 保护拦截
                        final parsedSps = int.parse(_spsController.text.trim());
                        final parsedDur = int.parse(_durationController.text.trim());
                        if (parsedSps * parsedDur * _channels > 1000000) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text("警告：预估数据量超过一百万点，极易导致内存溢出闪退，请调小参数！"),
                            backgroundColor: Colors.redAccent,
                            duration: Duration(seconds: 4),
                          ));
                          return;
                        }

                        final config = ProtocolConfig(
                          sps: parsedSps,
                          duration: parsedDur,
                          dataType: _dataType,
                          channels: _channels,
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
                  
                  const SizedBox(height: 32),
                  const Divider(),
                  const SizedBox(height: 8),
                  Row(
                    children: const [
                      Icon(Icons.save_alt, color: Colors.teal),
                      SizedBox(width: 8),
                      Text("数据导出", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // 【修复-10】替换掉之前硬编码路径的输入框
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: isCompleted ? _exportToCsv : null,
                      icon: const Icon(Icons.download),
                      label: Text(isCompleted ? "选择目录并导出 CSV" : "请等待数据接收完毕"),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
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
                          ? "本次数据已收齐 (${rawData.length} Bytes / ${widget.pageState.config.duration} 秒)" 
                          : "正在接收数据 (${rawData.length} / $targetByteLength Bytes)",
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
                            _buildChannelDisplay(rawData, widget.pageState.config),
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Colors.blueGrey),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text(
                      "接收进度:",
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey.shade700),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 10,
                          backgroundColor: Colors.grey.shade300,
                          color: isCompleted ? Colors.green : Colors.deepPurple,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 48,
                      child: Text(
                        "${(progress * 100).toStringAsFixed(1)}%",
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
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
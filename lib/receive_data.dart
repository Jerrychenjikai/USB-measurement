import 'dart:typed_data'; 
import 'dart:io'; 
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart'; 

import 'package:usb_measurement/scan_function.dart'; 
import 'package:usb_measurement/template.dart';
import 'package:usb_measurement/receive_data_func.dart'; // 引入已分离的状态机与逻辑

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
        title: Text("监测: ${pageState.device.name} | (Build 20260608)"),
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
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          Text(
            "正在尝试与设备建立通信信道...",
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey.shade700),
          ),
          const SizedBox(height: 8),
          Text(
            device.devicePath,
            style: const TextStyle(fontFamily: 'monospace', color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

// 补充：连接断开/失败视图
class _DisconnectedView extends StatelessWidget {
  final String errorMessage;
  final VoidCallback onRetry;

  const _DisconnectedView({required this.errorMessage, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
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
                label: const Text("重新连接"),
              ),
              const SizedBox(width: 16),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back),
                label: const Text("返回主页"),
              ),
            ],
          )
        ],
      ),
    );
  }
}

class _ActiveInteractiveView extends StatefulWidget {
  final SerialPageState pageState;
  final Function(ProtocolConfig) onSend;
  final VoidCallback onDisconnect;

  const _ActiveInteractiveView({
    super.key,
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
  
  UsbDataType _dataType = UsbDataType.float32;
  int _channels = 1;
  int _baudRate = 115200;
  int _dataBits = 8;
  int _stopBits = 1;
  int _parity = 0;

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
  void dispose() {
    _spsController.dispose();
    _durationController.dispose();
    super.dispose();
  }

  String _buildChannelDisplay(Uint8List rawData, ProtocolConfig config) {
    if (rawData.isEmpty) return "等待数据流输入...";
    final int wordSize = config.dataType.byteSize;
    final int frameSize = wordSize * config.channels;
    final int totalFrames = rawData.length ~/ frameSize;
    
    if (totalFrames == 0) return "接收数据不足单帧长度 (${rawData.length} Bytes)";
    
    final ByteData byteData = ByteData.sublistView(rawData);
    final StringBuffer sb = StringBuffer();
    
    sb.write("Frame".padRight(8));
    for (int c = 0; c < config.channels; c++) {
      sb.write("CH${c + 1}".padRight(14));
    }
    sb.writeln();
    sb.writeln("-" * (8 + 14 * config.channels));

    final int startFrame = (totalFrames > 30) ? totalFrames - 30 : 0;
    
    for (int f = startFrame; f < totalFrames; f++) {
      sb.write("${f + 1}".padRight(8));
      final int frameOffset = f * frameSize;
      
      for (int c = 0; c < config.channels; c++) {
        final int byteOffset = frameOffset + (c * wordSize);
        dynamic val = 0;
        
        switch (config.dataType) {
          case UsbDataType.int8: val = byteData.getInt8(byteOffset); break;
          case UsbDataType.uint8: val = byteData.getUint8(byteOffset); break;
          case UsbDataType.int16: val = byteData.getInt16(byteOffset, Endian.little); break;
          case UsbDataType.uint16: val = byteData.getUint16(byteOffset, Endian.little); break;
          case UsbDataType.int32: val = byteData.getInt32(byteOffset, Endian.little); break;
          case UsbDataType.uint32: val = byteData.getUint32(byteOffset, Endian.little); break;
          case UsbDataType.float32: val = byteData.getFloat32(byteOffset, Endian.little); break;
        }
        
        String valStr = (val is double) ? val.toStringAsFixed(4) : val.toString();
        sb.write(valStr.padRight(14));
      }
      sb.writeln();
    }
    
    if (totalFrames > 30) {
      sb.writeln("\n... 已省略前期 ${totalFrames - 30} 帧历史数据 (仅展示最新30条) ...");
    }
    
    return sb.toString();
  }

  List<List<double>> _parseChartData(Uint8List rawData, ProtocolConfig config) {
    if (rawData.isEmpty) return [];
    final int wordSize = config.dataType.byteSize;
    final int frameSize = wordSize * config.channels;
    final int totalFrames = rawData.length ~/ frameSize;
    if (totalFrames == 0) return [];

    final ByteData byteData = ByteData.sublistView(rawData);
    
    int step = 1;
    if (totalFrames > 300) {
      step = totalFrames ~/ 300; 
    }

    List<List<double>> series = List.generate(config.channels, (_) => []);

    for (int f = 0; f < totalFrames; f += step) {
      final int frameOffset = f * frameSize;
      for (int c = 0; c < config.channels; c++) {
        final int byteOffset = frameOffset + (c * wordSize);
        double val = 0.0;
        switch (config.dataType) {
          case UsbDataType.int8: val = byteData.getInt8(byteOffset).toDouble(); break;
          case UsbDataType.uint8: val = byteData.getUint8(byteOffset).toDouble(); break;
          case UsbDataType.int16: val = byteData.getInt16(byteOffset, Endian.little).toDouble(); break;
          case UsbDataType.uint16: val = byteData.getUint16(byteOffset, Endian.little).toDouble(); break;
          case UsbDataType.int32: val = byteData.getInt32(byteOffset, Endian.little).toDouble(); break;
          case UsbDataType.uint32: val = byteData.getUint32(byteOffset, Endian.little).toDouble(); break;
          case UsbDataType.float32: val = byteData.getFloat32(byteOffset, Endian.little); break;
        }
        series[c].add(val);
      }
    }
    return series;
  }

  void _exportToCsv() async {
    final rawData = widget.pageState.currentDisplayData;
    final config = widget.pageState.config;
    final int wordSize = config.dataType.byteSize;
    final int frameSize = wordSize * config.channels;
    final int totalFrames = rawData.length ~/ frameSize;

    if (totalFrames == 0) return;

    final ByteData byteData = ByteData.sublistView(Uint8List.fromList(rawData));
    final StringBuffer csvContent = StringBuffer();
    
    List<String> headers = ["Frame Index"];
    for (int c = 0; c < config.channels; c++) {
      headers.add("Channel ${c + 1}");
    }
    csvContent.writeln(headers.join(","));

    for (int f = 0; f < totalFrames; f++) {
      List<String> row = ["${f + 1}"];
      final int frameOffset = f * frameSize;
      
      for (int c = 0; c < config.channels; c++) {
        final int byteOffset = frameOffset + (c * wordSize);
        dynamic val = 0;
        switch (config.dataType) {
          case UsbDataType.int8: val = byteData.getInt8(byteOffset); break;
          case UsbDataType.uint8: val = byteData.getUint8(byteOffset); break;
          case UsbDataType.int16: val = byteData.getInt16(byteOffset, Endian.little); break;
          case UsbDataType.uint16: val = byteData.getUint16(byteOffset, Endian.little); break;
          case UsbDataType.int32: val = byteData.getInt32(byteOffset, Endian.little); break;
          case UsbDataType.uint32: val = byteData.getUint32(byteOffset, Endian.little); break;
          case UsbDataType.float32: val = byteData.getFloat32(byteOffset, Endian.little); break;
        }
        row.add(val.toString());
      }
      csvContent.writeln(row.join(","));
    }

    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: '请选择 CSV 报告导出路径',
      fileName: 'serial_monitor_export_${DateTime.now().millisecondsSinceEpoch}.csv',
      type: Platform.isAndroid ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isAndroid ? null : ['csv'],
    );

    if (outputFile != null) {
      try {
        final file = File(outputFile);
        await file.writeAsString(csvContent.toString());
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text("导出成功！文件已保存至:\n$outputFile"),
            backgroundColor: Colors.green,
          ));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text("文件写入失败: $e"),
            backgroundColor: Colors.redAccent,
          ));
        }
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

    final Widget formConfigSection = Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0), 
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
                  items: [1, 2, 3, 4, 5, 6, 7, 8] 
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
                final parsedSps = int.parse(_spsController.text.trim());
                final parsedDur = int.parse(_durationController.text.trim());
                if (parsedSps * parsedDur * _channels > 1000000) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text("警告：预估数据量超过一百万点，易导致内存溢出闪退，请调小参数！"),
                    backgroundColor: Colors.redAccent,
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
    );

    final Widget dataDisplaySection = Padding(
      padding: const EdgeInsets.only(left: 4.0, right: 16.0, top: 12.0, bottom: 12.0),
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
              Expanded(
                child: Text(
                  isCompleted 
                      ? "本次数据已收齐 (${rawData.length} Bytes)" 
                      : "正在接收数据 (${rawData.length} / $targetByteLength Bytes)",
                  style: TextStyle(
                    fontSize: 14, 
                    fontWeight: FontWeight.bold,
                    color: isCompleted ? Colors.green : Colors.amber.shade800
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const Divider(height: 24),
          
          Expanded(
            child: ScreenSplitter(
              defaultSplit: 0.5,
              maxSplit: 0.9,
              childA: Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: SizedBox(
                    width: double.infinity,
                    height: double.infinity,
                    child: SingleChildScrollView(
                      child: Text(
                        _buildChannelDisplay(Uint8List.fromList(rawData), widget.pageState.config),
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Colors.blueGrey),
                      ),
                    ),
                  ),
                ),
              ),
              childB: Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: SizedBox(
                    width: double.infinity,
                    height: double.infinity,
                    child: _ChannelChart(
                      series: _parseChartData(Uint8List.fromList(rawData), widget.pageState.config),
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
    );

    return ScreenSplitter(
      defaultSplit: 0.7,   
      maxSplit: 0.9,       
      childA: formConfigSection,  
      childB: dataDisplaySection, 
    );
  }
}

// ==========================================
// 4. 自定义高性能多通道折线图画布组件
// ==========================================

class _ChannelChart extends StatelessWidget {
  final List<List<double>> series;
  const _ChannelChart({required this.series});

  static const List<Color> channelColors = [
    Colors.red,
    Colors.blue,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.teal,
    Colors.indigo,
    Colors.brown,
  ];

  @override
  Widget build(BuildContext context) {
    if (series.isEmpty || series[0].isEmpty) {
      return const Center(
        child: Text("等待数据流入以生成图表...", style: TextStyle(color: Colors.grey, fontSize: 13)),
      );
    }

    double minY = double.infinity;
    double maxY = -double.infinity;
    for (var channelData in series) {
      for (var val in channelData) {
        if (val < minY) minY = val;
        if (val > maxY) maxY = val;
      }
    }

    if (minY == maxY) {
      minY -= 1.0;
      maxY += 1.0;
    } else {
      double padding = (maxY - minY) * 0.1; 
      minY -= padding;
      maxY += padding;
    }

    return Column(
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: List.generate(series.length, (index) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: channelColors[index % channelColors.length],
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Text("CH${index + 1}", style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              ],
            );
          }),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(36, 10, 10, 20),
            child: CustomPaint(
              size: Size.infinite,
              painter: _ChartPainter(
                series: series,
                minY: minY,
                maxY: maxY,
                colors: channelColors,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<List<double>> series;
  final double minY;
  final double maxY;
  final List<Color> colors;

  _ChartPainter({
    required this.series,
    required this.minY,
    required this.maxY,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paintGrid = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;

    final paintAxis = Paint()
      ..color = Colors.blueGrey.shade700
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    const int gridCount = 4;
    final double heightStep = size.height / gridCount;
    final double valueStep = (maxY - minY) / gridCount;

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: 1,
    );

    for (int i = 0; i <= gridCount; i++) {
      double y = size.height - (i * heightStep);
      if (i > 0 && i < gridCount) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paintGrid);
      }
      
      double currentVal = minY + (i * valueStep);
      textPainter.text = TextSpan(
        text: currentVal.toStringAsFixed(1),
        style: TextStyle(color: Colors.grey.shade600, fontSize: 10, fontFamily: 'monospace'),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(-32, y - textPainter.height / 2));
    }

    canvas.drawLine(Offset(0, size.height), Offset(size.width, size.height), paintAxis); 
    canvas.drawLine(Offset(0, 0), Offset(0, size.height), paintAxis);                 

    textPainter.text = TextSpan(
      text: "Time / Frame Index (自适应下采样)",
      style: TextStyle(color: Colors.grey.shade500, fontSize: 9),
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(size.width / 2 - textPainter.width / 2, size.height + 6));

    int pointCount = series[0].length;
    if (pointCount < 2) return;

    final double xStep = size.width / (pointCount - 1);

    for (int c = 0; c < series.length; c++) {
      final channelData = series[c];
      final linePaint = Paint()
        ..color = colors[c % colors.length]
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;

      final path = Path();
      for (int p = 0; p < channelData.length; p++) {
        double x = p * xStep;
        double yRatio = (channelData[p] - minY) / (maxY - minY);
        double y = size.height - (yRatio * size.height);

        if (p == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) => true;
}
import 'package:flutter/material.dart';
import 'package:usb_measurement/custom_protocol.dart';
import 'package:usb_measurement/custom_rx_protocol.dart';
import 'package:usb_measurement/receive_data_func.dart'; // 引入相关的类定义
import 'package:usb_measurement/protocol_storage.dart';

class SavedProtocolsDialog extends StatefulWidget {
  final SerialPageNotifier notifier;
  final ProtocolConfig currentConfig;

  const SavedProtocolsDialog({
    super.key,
    required this.notifier,
    required this.currentConfig,
  });

  @override
  State<SavedProtocolsDialog> createState() => _SavedProtocolsDialogState();
}

class _SavedProtocolsDialogState extends State<SavedProtocolsDialog> {
  Map<String, CustomTxProtocol> _txProtocols = {};
  Map<String, CustomRxProtocol> _rxProtocols = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAllSavedProtocols();
  }

  Future<void> _loadAllSavedProtocols() async {
    setState(() => _isLoading = true);
    final tx = await ProtocolStorage.getAllTxProtocols();
    final rx = await ProtocolStorage.getAllRxProtocols();
    setState(() {
      _txProtocols = tx;
      _rxProtocols = rx;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: AlertDialog(
        titlePadding: EdgeInsets.zero,
        title: Container(
          color: Theme.of(context).primaryColor.withOpacity(0.05),
          child: const TabBar(
            labelColor: Colors.blue,
            unselectedLabelColor: Colors.grey,
            indicatorColor: Colors.blue,
            tabs: [
              Tab(icon: Icon(Icons.unarchive), text: "已存控制协议 (TX)"),
              Tab(icon: Icon(Icons.archive), text: "已存解读协议 (RX)"),
            ],
          ),
        ),
        content: SizedBox(
          width: 500,
          height: 450,
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  children: [
                    _buildTxProtocolList(),
                    _buildRxProtocolList(),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("关闭仓库"),
          )
        ],
      ),
    );
  }

  // 构建控制协议列表
  Widget _buildTxProtocolList() {
    if (_txProtocols.isEmpty) {
      return const Center(child: Text("暂无保存的控制协议", style: TextStyle(color: Colors.grey)));
    }
    return ListView.builder(
      itemCount: _txProtocols.length,
      itemBuilder: (context, index) {
        String name = _txProtocols.keys.elementAt(index);
        CustomTxProtocol protocol = _txProtocols[name]!;
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: const Icon(Icons.tune, color: Colors.teal),
            title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text("包含字段数: ${protocol.items.length}"),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              onPressed: () async {
                await ProtocolStorage.deleteTxProtocol(name);
                _loadAllSavedProtocols();
              },
            ),
            onTap: () {
              // 重新组装完整的 ProtocolConfig 结构体
              final oldConf = widget.currentConfig;
              final newConfig = ProtocolConfig(
                sps: oldConf.sps,
                duration: oldConf.duration,
                baudRate: oldConf.baudRate,
                dataBits: oldConf.dataBits,
                stopBits: oldConf.stopBits,
                parity: oldConf.parity,
                txProtocol: protocol, // 替换为载入的控制协议
              );
              // 立刻应用到全局状态机
              widget.notifier.updateConfigWithoutSending(newConfig);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("已切换并应用控制协议: $name")));
            },
          ),
        );
      },
    );
  }

  // 构建解读协议列表
  Widget _buildRxProtocolList() {
    if (_rxProtocols.isEmpty) {
      return const Center(child: Text("暂无保存的解读协议", style: TextStyle(color: Colors.grey)));
    }
    return ListView.builder(
      itemCount: _rxProtocols.length,
      itemBuilder: (context, index) {
        String name = _rxProtocols.keys.elementAt(index);
        CustomRxProtocol protocol = _rxProtocols[name]!;
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: const Icon(Icons.analytics, color: Colors.orange),
            title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text("映射通道数: ${protocol.items.length} | 校验: ${protocol.checksumType.name.toUpperCase()}"),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              onPressed: () async {
                await ProtocolStorage.deleteRxProtocol(name);
                _loadAllSavedProtocols();
              },
            ),
            onTap: () {
              // 立刻更新接收侧协议状态机，并且内部会自动清空旧缓冲区防止错位
              widget.notifier.updateRxProtocol(protocol);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("已切换并应用数据解读协议: $name")));
            },
          ),
        );
      },
    );
  }
}
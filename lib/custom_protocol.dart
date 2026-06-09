import 'dart:typed_data';
import 'package:flutter/material.dart';

/// 1. 定义控制指令中变量的类型
enum TxItemType {
  fixedBytes, // 固定值（如 0x43）
  sps,        // 动态变量：采样率
  duration,   // 动态变量：时长（秒数）
}

extension TxItemTypeExt on TxItemType {
  String get label {
    switch (this) {
      case TxItemType.fixedBytes: return "固定值(HEX/INT)";
      case TxItemType.sps: return "采样率 {sps}";
      case TxItemType.duration: return "时长 {seconds}";
    }
  }
}

/// 2. 协议中的每一个“行/项”描述
class TxProtocolItem {
  TxItemType type;
  int length;      // 字节长度：1, 2, 4 字节
  int fixedValue;  // 如果是固定值，存储具体数值
  bool isBigEndian;// 字节序：大端还是小端（默认大端，符合你原本的协议）

  TxProtocolItem({
    required this.type,
    required this.length,
    this.fixedValue = 0,
    this.isBigEndian = true,
  });

  // 深拷贝，用于弹窗编辑时不直接污染原数据
  TxProtocolItem clone() {
    return TxProtocolItem(
      type: type,
      length: length,
      fixedValue: fixedValue,
      isBigEndian: isBigEndian,
    );
  }
}

/// 3. 自定义控制协议整体描述类
class CustomTxProtocol {
  List<TxProtocolItem> items;

  CustomTxProtocol({required this.items});

  /// 核心方法：根据配置规则，动态将当前配置面板的值动态组装成二进制 Uint8List
  Uint8List buildBytes({required int sps, required int duration}) {
    final builder = BytesBuilder();

    for (var item in items) {
      // 1. 确定当前项的实际数值
      int rawValue = 0;
      switch (item.type) {
        case TxItemType.fixedBytes:
          rawValue = item.fixedValue;
          break;
        case TxItemType.sps:
          rawValue = sps;
          break;
        case TxItemType.duration:
          rawValue = duration;
          break;
      }

      // 2. 将数值转换为指定长度和字节序的字节数组
      final itemBytes = Uint8List(item.length);
      for (int i = 0; i < item.length; i++) {
        int shift;
        if (item.isBigEndian) {
          // 大端序：高位在前（如你原本的 duration >> 8 然后 duration & 0xFF）
          shift = (item.length - 1 - i) * 8;
        } else {
          // 小端序：低位在前
          shift = i * 8;
        }
        itemBytes[i] = (rawValue >> shift) & 0xFF;
      }

      builder.add(itemBytes);
    }

    return builder.takeBytes();
  }

  // 生成默认协议配置（即你原本硬编码的：0x43(1B) + sps(1B) + duration(2B)）
  static CustomTxProtocol createDefault() {
    return CustomTxProtocol(items: [
      TxProtocolItem(type: TxItemType.fixedBytes, length: 1, fixedValue: 0x43),
      TxProtocolItem(type: TxItemType.sps, length: 1),
      TxProtocolItem(type: TxItemType.duration, length: 2, isBigEndian: true),
    ]);
  }
}

/// 4. 可视化配置弹窗 (Popup Window)
class ProtocolConfigDialog extends StatefulWidget {
  final CustomTxProtocol initialProtocol;

  const ProtocolConfigDialog({super.key, required this.initialProtocol});

  @override
  State<ProtocolConfigDialog> createState() => _ProtocolConfigDialogState();
}

class _ProtocolConfigDialogState extends State<ProtocolConfigDialog> {
  late List<TxProtocolItem> _localItems;

  @override
  void initState() {
    super.initState();
    // 拷贝一份数据到本地，防止未点击确定时直接修改了全局配置
    _localItems = widget.initialProtocol.items.map((e) => e.clone()).toList();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("配置自定义控制协议 (TX)"),
      content: SizedBox(
        width: double.maxFinite,
        height: 350,
        child: _localItems.isEmpty
            ? const Center(child: Text("请点击左下角加号添加协议字段"))
            : ListView.builder(
                itemCount: _localItems.length,
                itemBuilder: (context, index) {
                  final item = _localItems[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Row(
                        children: [
                          // 序号
                          CircleAvatar(
                            radius: 12,
                            child: Text("${index + 1}", style: const TextStyle(fontSize: 12)),
                          ),
                          const SizedBox(width: 8),
                          
                          // 1. 类型选择下拉框
                          Expanded(
                            flex: 3,
                            child: DropdownButton<TxItemType>(
                              value: item.type,
                              isExpanded: true,
                              items: TxItemType.values.map((type) {
                                return DropdownMenuItem(value: type, child: Text(type.label, style: const TextStyle(fontSize: 13)));
                              }).toList(),
                              onChanged: (val) {
                                if (val != null) setState(() => item.type = val);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),

                          // 2. 字节长度下拉框
                          Expanded(
                            flex: 2,
                            child: DropdownButton<int>(
                              value: item.length,
                              items: [1, 2, 4].map((len) {
                                return DropdownMenuItem(value: len, child: Text("$len 字节", style: const TextStyle(fontSize: 13)));
                              }).toList(),
                              onChanged: (val) {
                                if (val != null) setState(() => item.length = val);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),

                          // 3. 固定值输入框（仅在选择固定值类型时展示）
                          Expanded(
                            flex: 2,
                            child: item.type == TxItemType.fixedBytes
                                ? TextFormField(
                                    initialValue: item.fixedValue.toRadixString(16).toUpperCase(),
                                    decoration: const InputDecoration(hintText: "HEX", contentPadding: EdgeInsets.zero),
                                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                                    onChanged: (val) {
                                      // 支持16进制输入解析，如 43 或 0x43
                                      String cleanVal = val.toLowerCase().replaceAll("0x", "");
                                      int? parsed = int.tryParse(cleanVal, radix: 16);
                                      if (parsed != null) {
                                        item.fixedValue = parsed;
                                      }
                                    },
                                  )
                                : const SizedBox(),
                          ),

                          // 4. 字节序切换（如果是多个字节，允许选大小端）
                          if (item.length > 1)
                            TextButton(
                              onPressed: () {
                                setState(() => item.isBigEndian = !item.isBigEndian);
                              },
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                minimumSize: Size.zero, // 移除最小尺寸限制
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap, // 减小点击区域
                              ),
                              child: Text(
                                item.isBigEndian ? "MSB" : "LSB",
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),

                          // 5. 删除行按钮
                          IconButton(
                            icon: const Icon(Icons.delete, color: Colors.redAccent, size: 20),
                            onPressed: () {
                              setState(() => _localItems.removeAt(index));
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
      // 底部操作区
      actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      actions: [
        // 左下角：加号按钮
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text("添加字段"),
              onPressed: () {
                setState(() {
                  _localItems.add(TxProtocolItem(type: TxItemType.fixedBytes, length: 1));
                });
              },
            ),
            // 右下角：取消与完成
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: const Text("取消"),
                ),
                ElevatedButton(
                  onPressed: () {
                    // 点击完成，向调用者回传组装完成的 CustomTxProtocol 类
                    Navigator.pop(context, CustomTxProtocol(items: _localItems));
                  },
                  child: const Text("完成"),
                ),
              ],
            )
          ],
        )
      ],
    );
  }
}
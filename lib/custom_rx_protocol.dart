// custom_rx_protocol.dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:usb_measurement/basic_func.dart'; // 引入 UsbDataType
import 'package:usb_measurement/protocol_storage.dart';

/// 偏移量参考点
enum OffsetReference {
  fromHeader, // 相对于帧头（正偏移量，如 +0, +2）
  fromTail,   // 相对于帧尾（逆向偏移量，如 -2, -1）
}

/// 校验算法类型
enum ChecksumType { none, sum8, xor8, crc16 }

/// 接收协议中单个变量/通道的描述
class RxProtocolItem {
  String name;
  UsbDataType type;
  int offset; 
  OffsetReference reference;
  bool isRepeatable; // 是否为可重复出现的动态变量（用于覆盖动态帧长）
  bool isBigEndian;

  RxProtocolItem({
    required this.name,
    required this.type,
    this.offset = 0,
    this.reference = OffsetReference.fromHeader,
    this.isRepeatable = false,
    this.isBigEndian = true,
  });

  RxProtocolItem clone() {
    return RxProtocolItem(
      name: name,
      type: type,
      offset: offset,
      reference: reference,
      isRepeatable: isRepeatable,
      isBigEndian: isBigEndian,
    );
  }
}

/// 自定义接收协议整体描述类
class CustomRxProtocol {
  Uint8List? header;       // 帧头（null 表示无帧头）
  Uint8List? tail;         // 帧尾（null 表示无帧尾）
  bool isLengthFixed;      // 是否为固定帧长
  int? fixedLength;        // 固定帧长大小（无帧头时必填）
  List<RxProtocolItem> items;
  
  ChecksumType checksumType;
  int checksumOffset;      // 校验码偏移量
  OffsetReference checksumRef;

  CustomRxProtocol({
    this.header,
    this.tail,
    this.isLengthFixed = true,
    this.fixedLength,
    required this.items,
    this.checksumType = ChecksumType.none,
    this.checksumOffset = 0,
    this.checksumRef = OffsetReference.fromHeader,
  });
}

/// 接收协议动态配置弹窗
class RxProtocolDialog extends StatefulWidget {
  final CustomRxProtocol? initialProtocol;
  const RxProtocolDialog({super.key, this.initialProtocol});

  @override
  State<RxProtocolDialog> createState() => _RxProtocolDialogState();
}

class _RxProtocolDialogState extends State<RxProtocolDialog> {
  final _formKey = GlobalKey<FormState>();
  
  // 核心配置状态
  String _headerStr = "";
  String _tailStr = "";
  bool _isLengthFixed = true;
  TextEditingController _lengthController = TextEditingController();
  
  List<RxProtocolItem> _localItems = [];
  
  ChecksumType _checksumType = ChecksumType.none;
  TextEditingController _checksumOffsetController = TextEditingController(text: "0");
  OffsetReference _checksumRef = OffsetReference.fromHeader;

  @override
  void initState() {
    super.initState();
    if (widget.initialProtocol != null) {
      final p = widget.initialProtocol!;
      _headerStr = p.header != null ? p.header!.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ') : "";
      _tailStr = p.tail != null ? p.tail!.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ') : "";
      _isLengthFixed = p.isLengthFixed;
      if (p.fixedLength != null) _lengthController.text = p.fixedLength.toString();
      _localItems = p.items.map((i) => i.clone()).toList();
      _checksumType = p.checksumType;
      _checksumOffsetController.text = p.checksumOffset.toString();
      _checksumRef = p.checksumRef;
    }
  }

  // 辅助解析 Hex 字符串
  Uint8List? _parseHex(String hex) {
    String clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (clean.isEmpty) return null;
    if (clean.length % 2 != 0) clean = '0' + clean;
    List<int> bytes = [];
    for (int i = 0; i < clean.length; i += 2) {
      bytes.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Widget build(BuildContext context) {
    bool hasHeader = _parseHex(_headerStr) != null;

    // 协议联动核心逻辑：如果无帧头，则强制固定长度
    if (!hasHeader) {
      _isLengthFixed = true;
    }

    return AlertDialog(
      title: const Text("配置接收协议 (RX)"),
      content: SizedBox(
        width: 550,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. 帧头配置 (第一步，作为级联开关)
                TextFormField(
                  initialValue: _headerStr,
                  decoration: const InputDecoration(
                    labelText: "1. 帧头 (十六进制，空格隔开，如: AA BB。不填视为 null)",
                    hintText: "留空表示无帧头（数据流无对齐标志）",
                  ),
                  onChanged: (val) => setState(() => _headerStr = val),
                ),
                const SizedBox(height: 12),

                if (!hasHeader)
                  Card(
                    color: Colors.amber.shade100,
                    child: Padding(
                      padding: EdgeInsets.all(8.0),
                      child: Text("⚠️ 警告: 未指定帧头，系统将依赖硬性帧长顺序切包。由于链路丢包或抖动引起的流失步风险，需由用户自行承担。",
                        style: TextStyle(fontSize: 12, color: Colors.black87)),
                    ),
                  ),

                const Divider(),
                // 2. 帧长与帧尾配置 (根据帧头状态联动开放)
                Text("2. 帧结构与边界控制", style: Theme.of(context).textTheme.titleSmall),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<bool>(
                        initialValue: _isLengthFixed,
                        decoration: const InputDecoration(labelText: "帧长模式"),
                        // 如果没有帧头，禁用此下拉框，强制设为固定值
                        items: !hasHeader 
                          ? [const DropdownMenuItem(value: true, child: Text("固定长度 (强制)"))]
                          : [
                              const DropdownMenuItem(value: true, child: Text("固定长度")),
                              const DropdownMenuItem(value: false, child: Text("动态/变长帧")),
                            ],
                        onChanged: (val) {
                          if (val != null) setState(() => _isLengthFixed = val);
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _lengthController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: _isLengthFixed ? "帧总长度 (字节) *" : "帧总长度 (选填)",
                        ),
                        validator: (val) {
                          if (_isLengthFixed && (val == null || val.isEmpty)) {
                            return "固定长模式下必填";
                          }
                          return null;
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextFormField(
                  initialValue: _tailStr,
                  enabled: hasHeader, // 只有有帧头才允许配置帧尾
                  decoration: const InputDecoration(
                    labelText: "帧尾 (十六进制，可选，如: 0D 0A)",
                  ),
                  onChanged: (val) => setState(() => _tailStr = val),
                ),

                const Divider(),
                // 3. 校验位配置
                Text("3. 校验码配置", style: Theme.of(context).textTheme.titleSmall),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<ChecksumType>(
                        initialValue: _checksumType,
                        decoration: const InputDecoration(labelText: "校验算法"),
                        items: ChecksumType.values.map((t) => DropdownMenuItem(value: t, child: Text(t.name.toUpperCase()))).toList(),
                        onChanged: (val) => setState(() => _checksumType = val!),
                      ),
                    ),
                    if (_checksumType != ChecksumType.none) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextFormField(
                          controller: _checksumOffsetController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: "校验码偏移量"),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<OffsetReference>(
                          initialValue: _checksumRef,
                          items: const [
                            DropdownMenuItem(value: OffsetReference.fromHeader, child: Text("从头计算")),
                            DropdownMenuItem(value: OffsetReference.fromTail, child: Text("从尾逆向")),
                          ],
                          onChanged: (val) => setState(() => _checksumRef = val!),
                        ),
                      ),
                    ]
                  ],
                ),

                const Divider(),
                // 4. 变量/通道映射表
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("4. 变量/数据通道解析表", style: Theme.of(context).textTheme.titleSmall),
                    IconButton(
                      icon: const Icon(Icons.add_circle, color: Colors.blue),
                      onPressed: () {
                        setState(() {
                          _localItems.add(RxProtocolItem(
                            name: "CH${_localItems.length + 1}",
                            type: UsbDataType.int16,
                          ));
                        });
                      },
                    )
                  ],
                ),

                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _localItems.length,
                  itemBuilder: (context, index) {
                    final item = _localItems[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  flex: 2,
                                  child: TextFormField(
                                    initialValue: item.name,
                                    decoration: const InputDecoration(labelText: "变量名"),
                                    onChanged: (v) => item.name = v,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  flex: 3,
                                  child: DropdownButtonFormField<UsbDataType>(
                                    initialValue: item.type,
                                    decoration: const InputDecoration(labelText: "类型"),
                                    items: UsbDataType.values.map((t) => DropdownMenuItem(value: t, child: Text(t.label))).toList(),
                                    onChanged: (v) => setState(() => item.type = v!),
                                  ),
                                ),
                                if (item.type.byteSize > 1)
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
                                  )
                              ],
                            ),
                            Row(
                              children: [
                                Expanded(
                                  flex: 2,
                                  child: TextFormField(
                                    initialValue: item.offset.toString(),
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(labelText: "偏移值"),
                                    onChanged: (v) => item.offset = int.tryParse(v) ?? 0,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  flex: 3,
                                  child: DropdownButtonFormField<OffsetReference>(
                                    initialValue: item.reference,
                                    decoration: const InputDecoration(labelText: "偏移参考点"),
                                    items: [
                                      const DropdownMenuItem(value: OffsetReference.fromHeader, child: Text("正向 (自流头/正轴)")),
                                      // 只有固定长度或者有明确长度限制时，允许自尾部逆向偏移
                                      DropdownMenuItem(
                                        value: OffsetReference.fromTail,
                                        enabled: _isLengthFixed || _parseHex(_tailStr) != null,
                                        child: const Text("逆向 (自流尾/负轴)"),
                                      ),
                                    ],
                                    onChanged: (v) => setState(() => item.reference = v!),
                                  ),
                                ),
                                if (!_isLengthFixed) ...[
                                  const SizedBox(width: 8),
                                  Column(
                                    children: [
                                      const Text("多包重复", style: TextStyle(fontSize: 10)),
                                      Checkbox(
                                        value: item.isRepeatable,
                                        onChanged: (v) {
                                          setState(() {
                                            // 严格约束：全解析表中有且只能有一个变量可勾选重复
                                            for (var element in _localItems) {
                                              element.isRepeatable = false;
                                            }
                                            item.isRepeatable = v ?? false;
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                ],
                                IconButton(
                                  icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                                  onPressed: () => setState(() => _localItems.removeAt(index)),
                                )
                              ],
                            )
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      actions: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // 左下角：永久保存解读协议
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.teal.shade700, foregroundColor: Colors.white),
              icon: const Icon(Icons.save),
              label: const Text("永久保存协议"),
              onPressed: () async {
                // 执行原表单校验
                if (!_formKey.currentState!.validate()) return;
                
                // 执行原变长协议核心业务校验
                if (!_isLengthFixed && _localItems.isNotEmpty) {
                  int repeatCount = _localItems.where((i) => i.isRepeatable).length;
                  if (repeatCount != 1) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("错误：非固定帧长协议下，必须有且仅有一个变量勾选为'多包重复'。")),
                    );
                    return;
                  }
                }

                // 弹出输入框获取名字
                final name = await showNameInputDialog(context, "保存解读协议(RX)");
                if (name != null && name.isNotEmpty) {
                  final protocolToSave = CustomRxProtocol(
                    header: _parseHex(_headerStr),
                    tail: _parseHex(_tailStr),
                    isLengthFixed: _isLengthFixed,
                    fixedLength: int.tryParse(_lengthController.text),
                    items: _localItems,
                    checksumType: _checksumType,
                    checksumOffset: int.tryParse(_checksumOffsetController.text) ?? 0,
                    checksumRef: _checksumRef,
                  );
                  await ProtocolStorage.saveRxProtocol(name, protocolToSave);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("解读协议 '$name' 已长久保存")));
                  }
                }
              },
            ),
            
            // 右下角：原有取消与完成
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: const Text("取消"),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (!_formKey.currentState!.validate()) return;
                    if (!_isLengthFixed && _localItems.isNotEmpty) {
                      int repeatCount = _localItems.where((i) => i.isRepeatable).length;
                      if (repeatCount != 1) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("错误：非固定帧长协议下，必须有且仅有一个变量勾选为'多包重复'。")),
                        );
                        return;
                      }
                    }

                    Navigator.pop(
                      context,
                      CustomRxProtocol(
                        header: _parseHex(_headerStr),
                        tail: _parseHex(_tailStr),
                        isLengthFixed: _isLengthFixed,
                        fixedLength: int.tryParse(_lengthController.text),
                        items: _localItems,
                        checksumType: _checksumType,
                        checksumOffset: int.tryParse(_checksumOffsetController.text) ?? 0,
                        checksumRef: _checksumRef,
                      ),
                    );
                  },
                  child: const Text("完成"),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
import 'package:flutter/material.dart';

enum UsbDataType { int8, uint8, int16, uint16, int32, uint32, float32 }

// ==========================================
// 0. 数据类型定义
// ==========================================
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

Future<String?> showNameInputDialog(BuildContext context, String title) async {
  String name = '';
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        autofocus: true,
        decoration: const InputDecoration(hintText: '请输入协议保存的别名', border: OutlineInputBorder()),
        onChanged: (value) => name = value,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('取消')),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, name.trim()),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}
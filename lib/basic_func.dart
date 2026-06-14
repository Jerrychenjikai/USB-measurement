import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

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

// ==========================================
// 全局激活状态缓存 (建议在 main.dart 启动时调用 initProStatus())
// ==========================================
bool gIsProVersion = false;

Future<void> initProStatus() async {
  final prefs = await SharedPreferences.getInstance();
  final code = prefs.getString('activation_code') ?? '';
  gIsProVersion = verifyActivationCode(code);
}

// ==========================================
// 激活码弹窗 (复用 showNameInputDialog 风格)
// ==========================================
Future<void> showActivationDialog(BuildContext context) async {
  String inputCode = '';
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('输入高级版激活码'),
      content: TextField(
        autofocus: true,
        maxLines: 3, // 激活码通常较长
        decoration: const InputDecoration(
          hintText: '请输入Base64格式的激活码', 
          border: OutlineInputBorder()
        ),
        onChanged: (value) => inputCode = value,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('取消')),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, inputCode.trim()),
          child: const Text('验证并激活'),
        ),
      ],
    ),
  );

  if (result != null && result.isNotEmpty) {
    bool isValid = verifyActivationCode(result);
    if (isValid) {
      // 验证通过，永久保存
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('activation_code', result);
      gIsProVersion = true;
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("激活成功！已解锁全部协议编辑功能。重启app以生效")));
      }
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("激活码无效或已过期！")));
      }
    }
  }
}

// ==========================================
// 激活码核心校验逻辑 (RSA-SHA256)
// ==========================================
bool verifyActivationCode(String token) {
  if (token.isEmpty) return false;

  const String publicKeyPEM = '''
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnpO/0hfKtWz0wVM1Xhcd
a0ykCR+CHFNiBZnTwlQL6dMVCSUe4eBkUdHfkyDy+MNZe9X3Q5VIMs/JNK4MdDQZ
kqHoJg00QumaCm/2s4Mv6Lxj73FbOlWuekDOzkMUbcnwZIy6koLUXwR2KsyS5c3f
AoD1jEfBHd7mRThmaGqorvmHFsXP3aj9LfhERko5+dHZPmsyUvSTK626qsK54vXk
oryErfIcD35st2oxY5cuPpd/JyPLLPSEW5cUkgqfTlnGPvz4GiyCTzqX6zaO33vc
3WakTcn06spBawvmrG9+oHlQ/6lB/lk+NgzboXfjwig2I/y7g8xQavYKgI3vcxjn
sQIDAQAB
-----END PUBLIC KEY-----
''';

  try {
    // 1. 验证签名是否被篡改
    final jwt = JWT.verify(
      token,
      RSAPublicKey(publicKeyPEM),
    );

    // 2. 解析 JSON 判断是否过期
    final payload = jwt.payload as Map<String, dynamic>;
    if (payload.containsKey('exp_date')) {
      DateTime expDate = DateTime.parse(payload['exp_date']);
      if (DateTime.now().isBefore(expDate)) {
        return true; // 签名合法且未过期
      }
    }
    return false;
  } catch (e) {
    debugPrint('激活码校验失败: $e');
    return false;
  }
}
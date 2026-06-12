import 'dart:convert';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:usb_measurement/custom_protocol.dart';
import 'package:usb_measurement/custom_rx_protocol.dart';
import 'package:usb_measurement/basic_func.dart'; // 包含 UsbDataType

class ProtocolStorage {
  static const String _txKey = 'saved_tx_protocols';
  static const String _rxKey = 'saved_rx_protocols';

  // ==========================================
  // 1. TX (控制协议) 序列化与反序列化
  // ==========================================
  static Map<String, dynamic> _txItemToMap(TxProtocolItem item) => {
        'type': item.type.name,
        'length': item.length,
        'fixedValue': item.fixedValue,
        'isBigEndian': item.isBigEndian,
      };

  static TxProtocolItem _txItemFromMap(Map<String, dynamic> map) => TxProtocolItem(
        type: TxItemType.values.byName(map['type']),
        length: map['length'],
        fixedValue: map['fixedValue'],
        isBigEndian: map['isBigEndian'] ?? true,
      );

  static Map<String, dynamic> _customTxToMap(CustomTxProtocol protocol) => {
        'items': protocol.items.map((e) => _txItemToMap(e)).toList(),
      };

  static CustomTxProtocol _customTxFromMap(Map<String, dynamic> map) => CustomTxProtocol(
        items: (map['items'] as List).map((e) => _txItemFromMap(e as Map<String, dynamic>)).toList(),
      );

  // ==========================================
  // 2. RX (解读协议) 序列化与反序列化
  // ==========================================
  static Map<String, dynamic> _rxItemToMap(RxProtocolItem item) => {
        'name': item.name,
        'type': item.type.name,
        'offset': item.offset,
        'reference': item.reference.name,
        'isRepeatable': item.isRepeatable,
        'isBigEndian': item.isBigEndian,
      };

  static RxProtocolItem _rxItemFromMap(Map<String, dynamic> map) => RxProtocolItem(
        name: map['name'],
        type: UsbDataType.values.byName(map['type']),
        offset: map['offset'],
        reference: OffsetReference.values.byName(map['reference']),
        isRepeatable: map['isRepeatable'] ?? false,
        isBigEndian: map['isBigEndian'] ?? true,
      );

  static Map<String, dynamic> _customRxToMap(CustomRxProtocol protocol) => {
        'header': protocol.header,
        'tail': protocol.tail,
        'isLengthFixed': protocol.isLengthFixed,
        'fixedLength': protocol.fixedLength,
        'items': protocol.items.map((e) => _rxItemToMap(e)).toList(),
        'checksumType': protocol.checksumType.name,
        'checksumOffset': protocol.checksumOffset,
        'checksumRef': protocol.checksumRef.name,
      };

  static CustomRxProtocol _customRxFromMap(Map<String, dynamic> map) => CustomRxProtocol(
      // 修改这里：使用 Uint8List.fromList 进行显式转换
      header: map['header'] != null ? Uint8List.fromList(List<int>.from(map['header'])) : null,
      tail: map['tail'] != null ? Uint8List.fromList(List<int>.from(map['tail'])) : null,
      
      isLengthFixed: map['isLengthFixed'] ?? true,
      fixedLength: map['fixedLength'],
      items: (map['items'] as List).map((e) => _rxItemFromMap(e as Map<String, dynamic>)).toList(),
      checksumType: ChecksumType.values.byName(map['checksumType'] ?? 'none'),
      checksumOffset: map['checksumOffset'] ?? 0,
      checksumRef: OffsetReference.values.byName(map['checksumRef'] ?? 'fromHeader'),
    );

  // ==========================================
  // 3. SharedPreferences 磁盘持久化接口
  // ==========================================
  
  // 保存控制协议
  static Future<void> saveTxProtocol(String name, CustomTxProtocol protocol) async {
    final prefs = await SharedPreferences.getInstance();
    final savedStr = prefs.getString(_txKey) ?? '{}';
    final Map<String, dynamic> currentMap = jsonDecode(savedStr);
    currentMap[name] = _customTxToMap(protocol);
    await prefs.setString(_txKey, jsonEncode(currentMap));
  }

  // 获取所有保存的控制协议
  static Future<Map<String, CustomTxProtocol>> getAllTxProtocols() async {
    final prefs = await SharedPreferences.getInstance();
    final savedStr = prefs.getString(_txKey) ?? '{}';
    final Map<String, dynamic> currentMap = jsonDecode(savedStr);
    return currentMap.map((key, value) => MapEntry(key, _customTxFromMap(value)));
  }

  static Future<void> deleteTxProtocol(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final savedStr = prefs.getString(_txKey) ?? '{}';
    final Map<String, dynamic> currentMap = jsonDecode(savedStr);
    currentMap.remove(name);
    await prefs.setString(_txKey, jsonEncode(currentMap));
  }

  // 保存解读协议
  static Future<void> saveRxProtocol(String name, CustomRxProtocol protocol) async {
    final prefs = await SharedPreferences.getInstance();
    final savedStr = prefs.getString(_rxKey) ?? '{}';
    final Map<String, dynamic> currentMap = jsonDecode(savedStr);
    currentMap[name] = _customRxToMap(protocol);
    await prefs.setString(_rxKey, jsonEncode(currentMap));
  }

  // 获取所有保存的解读协议
  static Future<Map<String, CustomRxProtocol>> getAllRxProtocols() async {
    final prefs = await SharedPreferences.getInstance();
    final savedStr = prefs.getString(_rxKey) ?? '{}';
    final Map<String, dynamic> currentMap = jsonDecode(savedStr);
    return currentMap.map((key, value) => MapEntry(key, _customRxFromMap(value)));
  }

  static Future<void> deleteRxProtocol(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final savedStr = prefs.getString(_rxKey) ?? '{}';
    final Map<String, dynamic> currentMap = jsonDecode(savedStr);
    currentMap.remove(name);
    await prefs.setString(_rxKey, jsonEncode(currentMap));
  }
}
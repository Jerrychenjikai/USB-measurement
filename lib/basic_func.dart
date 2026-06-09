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
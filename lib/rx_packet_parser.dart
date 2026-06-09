// rx_packet_parser.dart
import 'dart:collection';
import 'dart:typed_data';
import 'package:usb_measurement/basic_func.dart';
import 'custom_rx_protocol.dart';

class RxPacketParser {
  /// 从底层的环形缓冲区内剥离出合法数据帧并提取多通道数值
  static List<List<double>> parseStream(Queue<int> buffer, CustomRxProtocol protocol) {
    List<List<double>> outputFrames = [];

    while (buffer.isNotEmpty) {
      // ==========================================
      // 情况 A: 用户未指定帧头 (无标志位)
      // ==========================================
      if (protocol.header == null || protocol.header!.isEmpty) {
        int expectedLen = protocol.fixedLength ?? 0;
        if (expectedLen <= 0) break; // 规避非法配置

        // 缓冲区厚度不够一帧，保留等待后续流
        if (buffer.length < expectedLen) break; 

        // 强行切出固定长度进行解析
        Uint8List frameBytes = Uint8List.fromList(buffer.take(expectedLen).toList());
        
        if (_validateChecksum(frameBytes, protocol, expectedLen)) {
          outputFrames.add(_extractValues(frameBytes, protocol, expectedLen));
        }
        
        // 顺序消费掉，不论校验成功与否（无头协议无法执行滑窗重对齐，风险自担）
        for (int i = 0; i < expectedLen; i++) {
          buffer.removeFirst();
        }
        continue;
      }

      // ==========================================
      // 情况 B: 用户配置了明确的帧头
      // ==========================================
      Uint8List head = protocol.header!;
      
      // 1. 滑窗探测寻找帧头对齐
      bool headMatched = true;
      if (buffer.length < head.length) break; 
      
      List<int> currentBufferList = buffer.toList();
      int headIndex = -1;
      
      for (int i = 0; i <= currentBufferList.length - head.length; i++) {
        bool match = true;
        for (int j = 0; j < head.length; j++) {
          if (currentBufferList[i + j] != head[j]) {
            match = false;
            break;
          }
        }
        if (match) {
          headIndex = i;
          break;
        }
      }

      // 帧头没找到
      if (headIndex == -1) {
        // 仅仅保留最后可能被截断的几个字节，前面确认全为无效脏数据，直接洗掉
        int preserveCount = head.length - 1;
        while (buffer.length > preserveCount) {
          buffer.removeFirst();
        }
        break; 
      }

      // 如果帧头不在最前面，切除帧头之前的无效杂质，实现自动流对齐
      if (headIndex > 0) {
        for (int i = 0; i < headIndex; i++) {
          buffer.removeFirst();
        }
        continue; // 重新进入循环，此时帧头必然在最前端
      }

      // 2. 帧头已完全对齐索引0，确认本帧的总长度
      int currentFrameLength = 0;
      
      if (protocol.isLengthFixed) {
        currentFrameLength = protocol.fixedLength ?? 0;
      } else {
        // 变长协议：依赖帧尾物理标志位来识别边界
        if (protocol.tail == null || protocol.tail!.isEmpty) {
          // 如果没有设定帧尾也没有设定固定长，则无法判断边界，直接剔除1字节防止死循环
          buffer.removeFirst();
          continue;
        }
        
        Uint8List tail = protocol.tail!;
        int tailIndex = -1;
        // 在当前流中检索帧尾
        for (int i = head.length; i <= currentBufferList.length - tail.length; i++) {
          bool match = true;
          for (int j = 0; j < tail.length; j++) {
            if (currentBufferList[i + j] != tail[j]) {
              match = false;
              break;
            }
          }
          if (match) {
            tailIndex = i;
            break;
          }
        }

        if (tailIndex == -1) {
          // 帧尾还没流过来，等待后续
          break; 
        }
        currentFrameLength = tailIndex + tail.length;
      }

      // 长度检查：缓冲区数据还不满当前计算出的这一帧
      if (buffer.length < currentFrameLength) break;

      // 3. 完整提取一帧字节进行校验与解包
      Uint8List frameBytes = Uint8List.fromList(buffer.take(currentFrameLength).toList());

      if (_validateChecksum(frameBytes, protocol, currentFrameLength)) {
        outputFrames.add(_extractValues(frameBytes, protocol, currentFrameLength));
      }

      // 4. 将这一帧从内存缓冲区移出
      for (int i = 0; i < currentFrameLength; i++) {
        buffer.removeFirst();
      }
    }

    return outputFrames;
  }

  /// 核心校验计算
  static bool _validateChecksum(Uint8List frame, CustomRxProtocol protocol, int frameLen) {
    if (protocol.checksumType == ChecksumType.none) return true;

    // 定位校验位
    int targetIdx = protocol.checksumRef == OffsetReference.fromHeader 
        ? protocol.checksumOffset 
        : frameLen + protocol.checksumOffset; // 负偏移量如 -1

    if (targetIdx < 0 || targetIdx >= frameLen) return false;
    int receivedChecksum = frame[targetIdx];

    // 计算实际算力覆盖区 (一般不包含校验位自身)
    int calculatedValue = 0;
    if (protocol.checksumType == ChecksumType.sum8) {
      int sum = 0;
      for (int i = 0; i < frameLen; i++) {
        if (i == targetIdx) continue;
        sum += frame[i];
      }
      calculatedValue = sum & 0xFF;
    } else if (protocol.checksumType == ChecksumType.xor8) {
      int xor = 0;
      for (int i = 0; i < frameLen; i++) {
        if (i == targetIdx) continue;
        xor ^= frame[i];
      }
      calculatedValue = xor & 0xFF;
    }
    // 注：可在次继续扩充标准CRC16等查表法

    return calculatedValue == receivedChecksum;
  }

  /// 核心解包映射函数：将原始一帧字节切片为用户所期望的浮点型多通道数组
  static List<double> _extractValues(Uint8List frame, CustomRxProtocol protocol, int frameLen) {
    List<double> parsedRecord = [];
    ByteData dataView = ByteData.sublistView(frame);

    for (var item in protocol.items) {
      // 算出基准首地址
      int baseOffset = item.reference == OffsetReference.fromHeader
          ? item.offset
          : frameLen + item.offset;

      if (!item.isRepeatable) {
        // 普通确定性变量提取
        if (baseOffset < 0 || baseOffset + item.type.byteSize > frameLen) {
          parsedRecord.add(0.0);
          continue;
        }
        parsedRecord.add(_readFromByteData(dataView, baseOffset, item.type));
      } else {
        // 核心亮点：如果是变长段下的可重复变量，其吸纳范围是除去所有已知固定开销后的剩余全部空间
        int currentPos = baseOffset;
        int elementSize = item.type.byteSize;
        
        // 结束边界取决于是否有帧尾或者限制
        int endLimit = frameLen;
        if (protocol.tail != null) {
          endLimit = frameLen - protocol.tail!.length;
        }
        if (protocol.checksumType != ChecksumType.none && protocol.checksumRef == OffsetReference.fromTail) {
          endLimit = endLimit - 1; // 扣除倒数校验位占位
        }

        while (currentPos + elementSize <= endLimit) {
          parsedRecord.add(_readFromByteData(dataView, currentPos, item.type));
          currentPos += elementSize;
        }
      }
    }
    return parsedRecord;
  }

  static double _readFromByteData(ByteData data, int offset, UsbDataType type) {
    // 默认小端序（硬件高频使用），可根据Tx习惯加入Endian配置
    switch (type) {
      case UsbDataType.int8: return data.getInt8(offset).toDouble();
      case UsbDataType.uint8: return data.getUint8(offset).toDouble();
      case UsbDataType.int16: return data.getInt16(offset, Endian.little).toDouble();
      case UsbDataType.uint16: return data.getUint16(offset, Endian.little).toDouble();
      case UsbDataType.int32: return data.getInt32(offset, Endian.little).toDouble();
      case UsbDataType.uint32: return data.getUint32(offset, Endian.little).toDouble();
      case UsbDataType.float32: return data.getFloat32(offset, Endian.little);
    }
  }
}
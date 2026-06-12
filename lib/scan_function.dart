// scan_function.dart
import 'dart:io' show Platform;

// ==================== 平台切换分水岭 ====================
// 如果编译 Android，请注释掉 desktop，打开 android：
// export 'android_basic_func.dart';

export 'android_basic_func.dart';
// =======================================================

// 依然提供这个函数名，供外部（如主页）调用，内部直接代理给底层函数
import 'android_basic_func.dart'; // 这里的引入需要和上面 export 保持一致

Future<List<MySerialDevice>> getAvailablePorts() async {
  // 直接调用我们在底层文件中封装好的同名函数
  return await lowLevelScanDevices();
}
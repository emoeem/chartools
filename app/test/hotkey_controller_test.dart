// HotkeyController 的轻量单测（fix(#8 DS-8)）：只测平台门控与退出清理
// stop() 的空操作契约。真正的注册/激活路径走 Win32 FFI——单测里绝不能起泵
// 线程（会真的抢注系统热键、弹真窗口），那部分由桌面端手工验证（线程模型
// 与生命周期见 hotkey_controller.dart 的类注释）。
import 'package:chartools_app/application/hotkey_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fix(#8 DS-8) stop()：非 Windows 平台是空操作', () async {
    // 单测宿主可能在 Windows 上（isSupported 会放行进真实路径），这里强制
    // 模拟非 Windows 平台，验证 isSupported 门控让 stop() 什么都不做。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await HotkeyController.instance.stop();
    expect(HotkeyController.instance.enabled.value, isFalse);
    expect(HotkeyController.instance.error.value, isNull);
  });

  test('fix(#8 DS-8) stop()：热键未启动时是幂等空操作', () async {
    // 不先 startup()。宿主是 Windows 时走 setEnabled 的幂等分支（value 与
    // _running 都是 false），其它平台走 isSupported 门控——两条路都不得起
    // 泵线程、不得改 [enabled]/[error]。
    await HotkeyController.instance.stop();
    expect(HotkeyController.instance.enabled.value, isFalse);
    expect(HotkeyController.instance.error.value, isNull);
  });
}

/// M0「注入采集(实验)」设置区（main.dart SettingsPage 的 [_injectionSection]）
/// widget 测试——root-module-design.md §4-M0「设置页逐 App 开关 + 已连接状态」
/// 的设置面契约，钉住四条：
///
/// 1. 区域渲染：区标题、Telegram 逐 App 开关（HookTargets 同值清单，当前仅
///    一项）、已连接状态行同页可见。
/// 2. 默认关：开关出厂值 false（映射里没有的包一律按关，fail-closed）。
/// 3. 切换即时写 store（JudgeRouteSection 同款即时写风格，不经保存按钮合并）：
///    开 → `{'org.telegram.messenger': true}`，关 → 显式 false 落表。
/// 4. 风险声明原文在场（§3.3-4「不可谈判」条目）：微信条款摘要、
///    「只读、不发消息」不能推导出不会封号、Telegram 同类风险句逐字可见。
///
/// 附加钉（M0 红线）：状态行恒显「未检测到注入模块」——本仓库此刻没有任何
/// xposed 声明，UI 不假装已连接（M1 接 hello 账本后才改为真实回显）。
library;

import 'package:capture_android/capture_android.dart';
import 'package:chartools_app/application/settings_store.dart';
import 'package:chartools_app/main.dart';
import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // 安全区通道 fake（judge_route_settings_section_test.dart 同款）：页面交互
  // 触发的落盘写 secure storage，不 mock 时调用永不回执。
  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  // 开关镜像推送的落点（本会话无完整载荷底稿时 store 监听只记录、不碰通道；
  // mock 一并挂上，让 Messenger 静默）。
  const controlChannel = MethodChannel('capture_android/control');

  setUp(() {
    CaptureAndroid.resetInjectionMirrorForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(controlChannel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(controlChannel, null);
  });

  /// 区在页面深处的「关系与悬浮窗」之后，ListView 折叠外子项未建 element，
  /// find/交互前必须先滚到（judge_route_settings_section_test.dart 同款）。
  Future<void> scrollToSection(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.text('注入采集(实验)'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  const switchKey =
      ValueKey('injection-switch-org.telegram.messenger');

  testWidgets('默认渲染：区标题、状态行恒显未检测到、开关默认关、风险原文在场',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore();
    await tester.pumpWidget(
        MaterialApp(home: SettingsPage(store: store, kbStore: KbStore())));

    await scrollToSection(tester);

    expect(find.text('注入采集(实验)'), findsOneWidget);
    // M0：无模块 → 恒显「未检测到注入模块」，不假装已连接。
    expect(find.textContaining('未检测到注入模块'), findsOneWidget);
    // 逐 App 开关：仅 Telegram 一项（HookTargets.SCOPED 同值清单的渲染源）。
    // 页面另有悬浮窗/主推模式两个 SwitchListTile，按 ValueKey 过滤后数出 1。
    final injectionTiles = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .where((w) => w.key == switchKey)
        .toList();
    expect(injectionTiles, hasLength(1));
    final sw =
        tester.widget<SwitchListTile>(find.byKey(switchKey));
    expect(sw.value, isFalse);
    expect(store.injectionEnabled.value, isEmpty);

    // 风险声明原文（§3.3-4）：微信条款摘要 + 「只读不发不能推导不封号」 +
    // Telegram 同类风险句，逐字在场。
    expect(find.textContaining('微信协议 8.2.1.4'), findsOneWidget);
    expect(find.textContaining('8.5.1 处置含功能限制与账号封禁'), findsOneWidget);
    expect(find.textContaining('「只读、不发消息」不能推导出不会封号'),
        findsOneWidget);
    expect(find.textContaining('同类风险适用于任何被注入的 App'), findsOneWidget);
  });

  testWidgets('切换即时写 store：开 → true，关 → 显式 false（不经保存按钮合并）',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore();
    await tester.pumpWidget(
        MaterialApp(home: SettingsPage(store: store, kbStore: KbStore())));

    await scrollToSection(tester);
    await tester.ensureVisible(find.byKey(switchKey));
    await tester.pumpAndSettle();

    // 开：notifier 立即拿到 true（内存即时生效；落盘走页面既有保存按钮）。
    await tester.tap(find.byKey(switchKey));
    await tester.pumpAndSettle();
    expect(store.injectionEnabled.value, {'org.telegram.messenger': true});
    expect(
        tester.widget<SwitchListTile>(find.byKey(switchKey)).value, isTrue);

    // 关：显式 false 落表（映射保留键值形式，不靠缺键表达关）。
    await tester.tap(find.byKey(switchKey));
    await tester.pumpAndSettle();
    expect(store.injectionEnabled.value, {'org.telegram.messenger': false});
    expect(
        tester.widget<SwitchListTile>(find.byKey(switchKey)).value, isFalse);
  });
}

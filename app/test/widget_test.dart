// 首页冒烟测试：五个内置场景要能全部渲染出来；场景卡的选中态与点击切换
// （本轮接线）：点击 → store.scenarioId 变化并落盘 → 重进页面选中态保持。
import 'dart:convert';

import 'package:chartools_app/application/settings_store.dart';
import 'package:chartools_app/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 安全区通道 fake（与 settings_store_test.dart:20 同款、通道名逐字一致）：
/// 场景切换的落盘走 SettingsStore.save()，它的第一步是写
/// flutter_secure_storage 的 MethodChannel——测试不 mock 该通道时调用永不
/// 完成（测试环境无平台侧回执），save() 卡死在第一步，「settings」键永远
/// 写不进 mock prefs，落盘断言必然落空。
const secureChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  testWidgets('首页展示五个内置场景', (WidgetTester tester) async {
    // 冒烟测试只看渲染：不给 store 调 load()（那要走平台通道），
    // 直接用内存默认值。
    await tester.pumpWidget(ChartoolsApp(store: SettingsStore()));

    expect(find.text('通用沟通助手'), findsOneWidget);
    expect(find.text('聊天副驾'), findsOneWidget);
    expect(find.text('客服坐席辅助'), findsOneWidget);
    expect(find.text('外语学习陪练'), findsOneWidget);
    expect(find.text('直播/社群互动'), findsOneWidget);
    expect(find.text('社交辅助（无障碍）'), findsOneWidget);
    // 采集目标标签：'微信' 出现在外语陪练与社交辅助两个场景，'千牛' 只在客服坐席。
    expect(find.text('微信'), findsNWidgets(2));
    expect(find.text('千牛'), findsOneWidget);
  });

  testWidgets('场景卡点击切换：store 值变化、落盘、选中态给视觉反馈', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore();
    await store.load();
    await tester.pumpWidget(ChartoolsApp(store: store));
    await tester.pumpAndSettle();

    // 「不选场景」的路径保持：初始明确说明未指定，不强制选，无选中卡。
    expect(find.textContaining('当前未指定场景'), findsOneWidget);
    expect(find.text('当前场景'), findsNothing);

    // 点「客服坐席辅助」卡片：store.scenarioId 更新 + 选中徽标与说明条切换。
    await tester.ensureVisible(find.text('客服坐席辅助'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客服坐席辅助'));
    await tester.pumpAndSettle();

    expect(store.scenarioId.value, 'support_agent');
    expect(find.text('当前场景'), findsOneWidget); // 选中徽标（仅一张卡）
    expect(find.textContaining('当前场景：客服坐席辅助'), findsOneWidget);
    // 落盘：settings 存档里能读到新场景 id（SettingsStore.save 整包写）。
    // 存档键 'settings' 是 SettingsStore._storageKey 的约定值（私有常量，
    // 测试按存档形状直接读）。
    final prefs = await SharedPreferences.getInstance();
    final saved =
        jsonDecode(prefs.getString('settings')!) as Map<String, dynamic>;
    expect(saved['scenarioId'], 'support_agent');
  });

  testWidgets('重进页面：持久化的场景 id 决定选中态（选择会记住）', (WidgetTester tester) async {
    // 预置存档：上次会话选过 support_agent。
    SharedPreferences.setMockInitialValues({
      'settings': jsonEncode(<String, dynamic>{'scenarioId': 'support_agent'}),
    });
    final store = SettingsStore();
    await store.load();
    // 重新 pump 根组件 = 重进页面：选中态从持久化值恢复，而不是恒无选中。
    await tester.pumpWidget(ChartoolsApp(store: store));
    await tester.pumpAndSettle();

    expect(find.text('当前场景'), findsOneWidget);
    expect(find.textContaining('当前场景：客服坐席辅助'), findsOneWidget);
    // 其他卡（含默认聊天副驾）不出现选中态。
    expect(find.textContaining('当前场景：聊天副驾'), findsNothing);
    expect(find.textContaining('当前未指定场景'), findsNothing);
  });
}

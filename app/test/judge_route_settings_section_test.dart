/// 判断路由配置区（app/lib/ui/settings_page.dart 的 JudgeRouteSection）widget
/// 测试——P0「判断路由默认关闭 + 可配」的设置面契约。
///
/// 钉住四条：
/// 1. 出厂默认渲染：降级状态行明说「未配置 → 跳过判断、直接起草」——默认
///    关闭是产品裁定，设置页必须如实可见，不能让用户对着一个悄悄关掉的
///    判断路由猜为什么候选没定调。
/// 2. 「跟随回复路由」档：选中即写 provider/protocol，端点预览切换成回复
///    端点，地址与 Key 框禁用（跟回复走，填了也不生效——禁用是诚实 UI）。
/// 3. 字段即时写 config.value（与悬浮窗开关同款「内存即时生效、保存落盘」
///    节奏），trim 语义与旧仓库 Prefs setter 一致。
/// 4. 回显口径：jev/deepseek/custom+chat 与存档值互查；高级组合
///    （bocha/typesafe/vercel/zen、custom+decisions）落「自定义」占位且
///    字段照常可编辑——下拉只是起点，不锁死配置。
///
/// 连通性测试按钮本轮留白（分路由测试下轮做），测试同时钉住「按钮不存在」，
/// 防止有人顺手把半成品 UI 放进来。
/// 5. 接线钉（P0 三步，settings_page.dart:10-15）：真实 SettingsPage 的模型
///    路由区出现本区、旧单行判断模型框已删、判断字段即时写 store、保存按钮
///    不覆盖判断区写入——此前 6 个用例只测孤岛组件，main.dart 接线断链照
///    不到（独立复核 high ①）。
library;

import 'package:chartools_app/application/settings_store.dart';
import 'package:chartools_app/main.dart';
import 'package:chartools_app/ui/settings_page.dart';
import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('出厂默认渲染：降级状态行可见、端点预览如实、三个字段可编辑', (tester) async {
    final config = ValueNotifier<JevConfig>(JevConfig());
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [JudgeRouteSection(config: config)]),
      ),
    ));

    // 默认关闭的如实呈现（P0 产品裁定的可见面）。降级状态行用「本轮将」
    // 定位——「跳过判断、直接起草」八个字同时出现在副标题（默认关闭的
    // 裁定说明）与状态行里，必须用只属于状态行的前缀才能钉住单条。
    expect(find.textContaining('判断路由未配置'), findsOneWidget);
    expect(find.textContaining('本轮将跳过判断、直接起草'), findsOneWidget);
    // 端点预览显示的是真实的相对地址产物（判据的根因对照）。同样用「端点
    // 无法发请求：」前缀钉住状态行——jev 档的提示行也带 /alpha/decisions。
    expect(find.textContaining('端点无法发请求：/alpha/decisions'), findsOneWidget);
    // 三个字段在场且可编辑。
    final base =
        tester.widget<TextField>(find.widgetWithText(TextField, '判断接口地址'));
    final key = tester
        .widget<TextField>(find.widgetWithText(TextField, '判断接口 API Key'));
    final model =
        tester.widget<TextField>(find.widgetWithText(TextField, '判断模型'));
    expect(base.enabled, isTrue);
    expect(key.enabled, isTrue);
    expect(model.enabled, isTrue);
    expect(base.controller!.text, '');
  });

  testWidgets('选「跟随回复路由」：provider/protocol 即写、端点切回复端点、地址与 Key 禁用',
      (tester) async {
    final config = ValueNotifier<JevConfig>(JevConfig());
    var edits = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            JudgeRouteSection(config: config, onEdited: () => edits++),
          ],
        ),
      ),
    ));

    await tester.tap(find.byWidgetPredicate((w) => w is DropdownButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跟随回复路由').last);
    await tester.pumpAndSettle();

    // 配置写入：provider 换档、protocol 清空（协议由档位强制 chat）。
    expect(config.value.judgeProvider, JevConfig.judgeProviderFollowReply);
    expect(config.value.judgeProtocol, '');
    expect(config.value.effectiveJudgeProtocol(), 'chat');
    // 端点预览切到回复端点（出厂默认 replyBaseUrl 是 openrouter）。
    expect(
      find.textContaining('https://openrouter.ai/api/v1/chat/completions'),
      findsOneWidget,
    );
    expect(find.textContaining('判断路由未配置'), findsNothing,
        reason: '跟随档默认回复地址可用：不再显示未配置降级行');
    // 地址与 Key 框禁用（填了也不生效——诚实 UI），helper 文案说明跟谁走。
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '判断接口地址'))
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '判断接口 API Key'))
          .enabled,
      isFalse,
    );
    expect(find.textContaining('随回复接口 Key'), findsOneWidget);
    // 模型框仍可编辑（显式判断模型优先，留空沿用回复模型）。
    expect(
      tester.widget<TextField>(find.widgetWithText(TextField, '判断模型')).enabled,
      isTrue,
    );
    expect(find.textContaining('留空 = 沿用回复模型'), findsOneWidget);
    // 每档位提示行带成本说明（裁定原文：每轮多一次调用的成本在副标题说明）。
    expect(find.textContaining('多一次判断调用'), findsOneWidget);
    expect(edits, greaterThanOrEqualTo(1), reason: 'onEdited 钩子已触发宿主刷新');
  });

  testWidgets('字段即时写 config.value（trim 语义），配置齐了降级行消失', (tester) async {
    final config = ValueNotifier<JevConfig>(JevConfig());
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [JudgeRouteSection(config: config)]),
      ),
    ));

    // 先选「Jev 决策协议」再填地址（出厂默认就是 jev，选一次不改变语义）。
    await tester.tap(find.byWidgetPredicate((w) => w is DropdownButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jev 决策协议').last);
    await tester.pumpAndSettle();
    expect(config.value.judgeProvider, 'jev');
    expect(config.value.judgeProtocol, '');

    await tester.enterText(find.widgetWithText(TextField, '判断接口地址'),
        ' https://judge.example.com/ ');
    await tester.pump();
    // 旧仓库 Prefs setter 的习惯：写入即 trim（空白去掉）。**尾部斜杠保留**
    // ——斜杠的剥离在 jev_config.judgeEndpoint 的拼接处做（_stripTrailingSlashes，
    // 旧仓库 Prefs.kt:518 的位置），存档值不预剥：与 judge_route_config_test
    // 「follow_reply 尾斜杠」用例同一口径（存 raw、端点剥）。
    expect(config.value.judgeBaseUrl, 'https://judge.example.com/');
    // 判据联动：地址齐了 → 已配置 → 降级行消失，端点预览显示拼接结果。
    expect(config.value.judgeRouteConfigured(), isTrue);
    expect(
      find.textContaining('https://judge.example.com/alpha/decisions'),
      findsOneWidget,
    );
    expect(find.textContaining('判断路由未配置'), findsNothing);

    await tester.enterText(
        find.widgetWithText(TextField, '判断接口 API Key'), ' sk-judge ');
    await tester.pump();
    expect(config.value.judgeKey, 'sk-judge');

    await tester.enterText(
        find.widgetWithText(TextField, '判断模型'), ' judge-model-x ');
    await tester.pump();
    expect(config.value.judgeModel, 'judge-model-x');
  });

  testWidgets('回显：custom+chat 存档显示 OpenAI 兼容档，改选 Jev 即换档', (tester) async {
    final config = ValueNotifier<JevConfig>(JevConfig()
      ..judgeProvider = 'custom'
      ..judgeProtocol = 'chat'
      ..judgeBaseUrl = 'https://compat.example.com/v1');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [JudgeRouteSection(config: config)]),
      ),
    ));

    // 回显到 OpenAI 兼容档（provider + protocol 互查）。
    expect(find.text('OpenAI 兼容（自定义，chat 协议）'), findsOneWidget);
    expect(
        find.textContaining('https://compat.example.com/v1/chat/completions'),
        findsOneWidget);

    // 改选 Jev 决策协议：provider/protocol 一起落。
    await tester.tap(find.byWidgetPredicate((w) => w is DropdownButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jev 决策协议').last);
    await tester.pumpAndSettle();
    expect(config.value.judgeProvider, 'jev');
    expect(config.value.judgeProtocol, '');
    // 地址原样保留（预设是起点，不清用户的地址）。
    expect(config.value.judgeBaseUrl, 'https://compat.example.com/v1');
    // 端点改按 decisions 拼法。
    expect(find.textContaining('https://compat.example.com/v1/alpha/decisions'),
        findsOneWidget);
  });

  testWidgets('高级组合（bocha）回显自定义占位，字段照常可编辑不被顶掉', (tester) async {
    final config = ValueNotifier<JevConfig>(JevConfig()
      ..judgeProvider = 'bocha'
      ..judgeBaseUrl = 'https://bocha.example.com');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [JudgeRouteSection(config: config)]),
      ),
    ));

    // 不属于任何下拉档 → hint 占位（与 ModelPresetPicker「预设只是起点」同口径）。
    expect(find.text('自定义（保留当前高级配置）'), findsOneWidget);
    // 字段仍可编辑：下拉不是锁，改地址立即生效。
    await tester.enterText(
        find.widgetWithText(TextField, '判断接口地址'), 'https://bocha2.example.com');
    await tester.pump();
    expect(config.value.judgeBaseUrl, 'https://bocha2.example.com');
    expect(config.value.judgeProvider, 'bocha',
        reason: '改地址不动 provider：高级组合不被下拉顶掉');
  });

  testWidgets('连通性测试按钮留白：分路由测试下轮做，本轮不放半成品', (tester) async {
    final config = ValueNotifier<JevConfig>(JevConfig());
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [JudgeRouteSection(config: config)]),
      ),
    ));
    expect(find.text('判断连通性测试'), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('接线（P0 三步）：真实设置页出现判断配置区，判断字段即时写 store、保存不覆盖', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // 安全区通道 fake（settings_store_test.dart:20 同款）：保存按钮的落盘
    // 第一步写 secure storage，测试不 mock 该通道时调用永不回执，save 卡死
    // 在第一步（与 widget_test.dart 的场景落盘同一坑）。
    const secureChannel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async => null);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null));

    final store = SettingsStore();
    // 生产页面本体（自带 Scaffold + AppBar + ListView）：pump 的是 main.dart
    // 里用户真实看到的那一页，不是孤岛组件。
    await tester.pumpWidget(
        MaterialApp(home: SettingsPage(store: store, kbStore: KbStore())));

    // 判断配置区滚进视口（模型路由区在资料入口组之后，远在首屏折叠线以下；
    // ListView 的折叠外子项未建 element，find 前必须先滚到）。
    await tester.scrollUntilVisible(
      find.text('判断模型（判断路由）'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('判断模型（判断路由）'), findsOneWidget);
    expect(find.text('判断服务商'), findsOneWidget);
    expect(find.textContaining('判断路由未配置'), findsOneWidget);

    // 三步②：旧的单行判断模型输入框已删——全页只剩本区那一个「判断模型」
    // 框（谁把旧行加回来，这里会数出 2）。
    expect(find.widgetWithText(TextField, '判断模型'), findsOneWidget);

    // 三步③的正面：判断字段即时写 config.value 的链路经真实页面也通。
    final addr = find.widgetWithText(TextField, '判断接口地址');
    await tester.ensureVisible(addr);
    await tester.pumpAndSettle();
    await tester.enterText(addr, 'https://judge.example.com');
    await tester.pump();
    expect(store.config.value.judgeBaseUrl, 'https://judge.example.com');
    expect(store.config.value.judgeRouteConfigured(), isTrue);
    expect(find.textContaining('判断路由未配置'), findsNothing);

    // 三步③的反面：保存按钮的合并行已删——判断区写入不被 initState 时的
    // 陈旧控制器值覆盖（谁把 judgeModel 合并行加回来，这里必红）。保存按钮
    // 在页面更下方（超出 ListView 的 cacheExtent，未建 element）——
    // ensureVisible 只对已建 element 有效，得先拖拽滚到它。
    await tester.scrollUntilVisible(
      find.text('保存'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(store.config.value.judgeBaseUrl, 'https://judge.example.com');
    // 落盘链路真的走完（成功提示可见），不是被异常吞掉后「看起来还在」。
    expect(find.textContaining('已保存'), findsOneWidget);
  });
}

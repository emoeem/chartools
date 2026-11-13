// 专家库页的 widget 测试（#13 收敛版）：目录浏览/搜索/标签、详情 promptText
// 预览、「套用为全局风格」的 StyleSource 确认弹窗、「套用为联系人人设」的
// needsChoice 覆盖/并存二选一（core ExpertApply 语义）、资产包管理区（粘贴
// 安装走 core PackCodec 严格校验 + 卸载）。
//
// fake 注入：StyleSinkPort / ContactPersonaSink 用内存实现（experts_controller
// 的接口就是为此定义的），持久化用 SharedPreferences.setMockInitialValues。
// 页面接线留 #13——这里直接 pump 页面本体，不经过 main.dart。
// 内置包：控制器构造期走 core 磁盘探测（读 packages/core 真文件），load 前
// 页面即有货架。
import 'package:chartools_app/application/experts_controller.dart';
import 'package:chartools_app/ui/experts_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryStyleSink implements StyleSinkPort {
  String _style = '';

  @override
  String get style => _style;

  @override
  set style(String value) => _style = value;

  @override
  Future<void> flush() async {}
}

class _MemoryContactSink implements ContactPersonaSink {
  _MemoryContactSink(this._targets);

  final List<ContactTarget> _targets;

  @override
  List<ContactTarget> get targets => _targets;

  @override
  Future<void> writePersona(String contactId, String persona) async {
    final i = _targets.indexWhere((t) => t.id == contactId);
    if (i < 0) throw StateError('联系人不存在');
    _targets[i] = ContactTarget(
        id: contactId, displayName: _targets[i].displayName, persona: persona);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MemoryStyleSink sink;
  late _MemoryContactSink contactSink;
  late ExpertsController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sink = _MemoryStyleSink();
    // 一位已写专用人设的联系人：触发 StyleSource 优先级的确认弹窗（core
    // ExpertApply 的 needsChoice 判定）。
    contactSink = _MemoryContactSink([
      const ContactTarget(id: 'c1', displayName: '小测', persona: '旧人设'),
    ]);
    controller = ExpertsController(styleSink: sink, contactSink: contactSink);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ExpertsPage(controller: controller))));
    await tester.pumpAndSettle();
  }

  testWidgets('目录浏览：搜索命中正文，标签筛选生效', (tester) async {
    await pumpPage(tester);

    // 内置示例包整架在列（按名字序，断言两位代表即可）。
    expect(find.text('日常闲聊'), findsOneWidget);
    expect(find.text('销售·跟单'), findsOneWidget);

    // 搜索命中正文里的「避谈：稳赚」——用户记得的是卡上那句话。
    await tester.enterText(find.byKey(const Key('experts_search')), '稳赚');
    await tester.pumpAndSettle();
    expect(find.text('日常闲聊'), findsNothing);
    expect(find.text('销售·跟单'), findsOneWidget);

    // 清空搜索，改走标签筛选：#先接情绪 只留客服·投诉安抚。
    await tester.enterText(find.byKey(const Key('experts_search')), '');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('#先接情绪'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#先接情绪'));
    await tester.pumpAndSettle();
    expect(find.text('客服·投诉安抚'), findsOneWidget);
    expect(find.text('日常闲聊'), findsNothing);
  });

  testWidgets('详情：promptText 预览 + 套用为全局风格（StyleSource 确认后生效）', (tester) async {
    await pumpPage(tester);
    final item = controller.shelfUnfiltered
        .firstWhere((i) => i.presetKey == 'daily.friend');

    await tester.tap(find.text('日常闲聊'));
    await tester.pumpAndSettle();

    // 预览与真实进提示词的东西同一条路径（PersonaCard.promptText）。
    expect(find.textContaining('<persona_card>'), findsOneWidget);
    expect(find.textContaining('称呼：用平时的叫法'), findsOneWidget);
    // 来源追踪：内置包样品标明来自哪个包（core 来源：builtin@1.0.0）。
    expect(find.textContaining('来源：seed:builtin'), findsOneWidget);

    // 联系人已有专用人设 → StyleSource 优先级提示弹窗，确认才套用。
    await tester.ensureVisible(find.byKey(const Key('experts_apply_global')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('experts_apply_global')));
    await tester.pumpAndSettle();
    expect(find.text('部分联系人不会生效'), findsOneWidget);
    expect(find.textContaining('专用人设优先于全局风格'), findsOneWidget);

    await tester.tap(find.byKey(const Key('experts_confirm_shadowed')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已套用为全局风格'), findsOneWidget);
    // 全局风格正文 = 专家正文原样。
    expect(sink.style, item.body);
    // 套用同时落库（我的专家库有了这条，货架不再出样品）。
    expect(controller.installed.value, hasLength(1));
    expect(controller.installed.value.first.key, 'daily.friend');
  });

  testWidgets('套用为联系人人设：needsChoice → 覆盖确认 → 写入 persona', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('恋爱·冷战破冰'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('experts_apply_contact')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('experts_apply_contact')));
    await tester.pumpAndSettle();

    // 目标列表标出「已有专用人设（套用将覆盖）」。
    expect(find.text('小测'), findsOneWidget);
    expect(find.text('已有专用人设（套用将覆盖）'), findsOneWidget);
    await tester.tap(find.text('小测'));
    await tester.pumpAndSettle();

    // core ExpertApply 判定冲突（needsChoice）→ 弹覆盖/并存二选一。
    expect(find.text('覆盖「小测」的专用人设？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('experts_confirm_overwrite')));
    await tester.pumpAndSettle();

    expect(find.textContaining('已套用为「小测」的专用人设'), findsOneWidget);
    expect(
        contactSink.targets.first.persona,
        controller.shelfUnfiltered
            .firstWhere((i) => i.presetKey == 'love.coldwar')
            .body);
  });

  testWidgets('套用为联系人人设：并存套用 → 只写全局风格，专用人设保留', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('恋爱·冷战破冰'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('experts_apply_contact')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('experts_apply_contact')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('小测'));
    await tester.pumpAndSettle();

    // 冲突选择收敛到 core ExpertApply 的 needsChoice 语义：除覆盖外还要提供
    // 并存（只写全局风格，专用人设保留并继续压全局）。
    expect(find.text('覆盖「小测」的专用人设？'), findsOneWidget);
    await tester.tap(find.text('并存套用'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已并存套用'), findsOneWidget);
    // 全局风格换成专家正文……
    expect(
        sink.style,
        controller.shelfUnfiltered
            .firstWhere((i) => i.presetKey == 'love.coldwar')
            .body);
    // ……而专用人设原句未动（StyleSource：TA 继续压全局）。
    expect(contactSink.targets.first.persona, '旧人设');
  });

  testWidgets('资产包管理区：已安装列表 + 粘贴安装（坏包如实报错、好包走 core 校验、卸载）',
      (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byTooltip('资产包'));
    await tester.pumpAndSettle();
    expect(find.text('内置示例专家'), findsOneWidget);
    expect(find.textContaining('5 位专家'), findsOneWidget);
    expect(find.textContaining('文件选择器入口预留'), findsOneWidget);
    // 内置包是货架底座：不给卸载按钮（core 也会拒绝，双保险）。
    expect(find.byIcon(Icons.delete_outline), findsNothing);

    // 安装入口（文件选择器预留 #13，当前粘贴 JSON）：坏包报错不留半装的包。
    await tester.tap(find.byKey(const Key('experts_install_pack')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('experts_pack_json')), 'not-json');
    await tester.tap(find.byKey(const Key('experts_pack_install_confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('安装失败'), findsOneWidget);
    expect(controller.packs, hasLength(1));

    // 等失败 SnackBar 走完（默认 4s），避免它盖住 sheet 里的安装按钮。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // 好包（core 形状）：重开安装弹层，粘贴安装成功，货架出现新专家，
    // 出现卸载按钮。
    await tester.tap(find.byKey(const Key('experts_install_pack')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('experts_pack_json')),
      '{"format":"jev-expert-pack/1",'
      '"pack":{"id":"external","version":"1.0.0","name":"外部包"},'
      '"experts":[{"id":"ext.1","name":"外部专家","promptText":"称呼：你","domain":"日常"}]}',
    );
    await tester.tap(find.byKey(const Key('experts_pack_install_confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已安装「外部包」'), findsOneWidget);
    expect(controller.packs, hasLength(2));
    expect(
        controller.shelfUnfiltered.any((i) => i.presetKey == 'ext.1'), isTrue);

    // 等成功 SnackBar 走完（默认 4s，与上方失败 SnackBar 的处理同一招）：
    // SnackBar 是排队的——「已安装」还挂着时卸载提示只能进队列，而排队不
    // 调度帧，pumpAndSettle 的静帧窗口里它永远不会进树，find 就扑空。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // 卸载外部包：core uninstall 语义。
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.textContaining('已卸载「外部包」'), findsOneWidget);
    expect(controller.packs, hasLength(1));
    expect(
        controller.shelfUnfiltered.any((i) => i.presetKey == 'ext.1'), isFalse);
  });
}

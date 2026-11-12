// 人设库页的 widget 测试：新建/编辑表单（六字段对应 PersonaCard 键）、
// CCV2 导入的解析预览 → 确认导入、复制与删除。
//
// fake 注入：PersonasController 只依赖 shared_preferences，用
// SharedPreferences.setMockInitialValues 提供内存存档（与
// contact_store_test.dart 同一口径）。页面接线留 #13——直接 pump 页面本体。
import 'package:chartools_app/application/personas_controller.dart';
import 'package:chartools_app/ui/personas_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一张 CCV2 包裹卡：persona 里的 \\n 是 JSON 转义，解码后才是真换行。
const String ccv2Json = '{"spec":"chara_card_v2","spec_version":"2.0","data":{'
    '"name":"夜航星",'
    '"description":"一位沉稳的星空摄影师",'
    '"scenario":"山顶露营的深夜",'
    '"persona":"称呼：小航\\n关系：旅伴\\n语气：温和、简短\\n硬边界：不聊工作\\n避谈：加班",'
    '"first_mes":"今晚的银河很清楚，要一起看吗？"}}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PersonasController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = PersonasController();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: PersonasPage(controller: controller))));
    await tester.pumpAndSettle();
  }

  testWidgets('新建：六字段保存后进列表，详情预览是组装后的 PersonaCard 块', (tester) async {
    await pumpPage(tester);
    expect(find.textContaining('还没有人设'), findsOneWidget);

    await tester.tap(find.byKey(const Key('personas_new')));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const Key('personas_field_name')), '测试人设');
    await tester.enterText(find.widgetWithText(TextFormField, '称呼'), '先生');
    await tester.enterText(find.widgetWithText(TextFormField, '关系'), '朋友');
    await tester.enterText(find.widgetWithText(TextFormField, '语气'), '克制、短句');
    await tester.enterText(
        find.byKey(const Key('personas_field_boundaries')), '家人、前任');
    await tester.enterText(
        find.widgetWithText(TextFormField, '避谈（顿号分隔，约束我的措辞）'), '鸡汤');
    await tester.enterText(find.widgetWithText(TextFormField, '安全词'), '红灯');

    await tester.ensureVisible(find.byKey(const Key('personas_save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('personas_save')));
    await tester.pumpAndSettle();

    expect(find.text('测试人设'), findsOneWidget);
    expect(controller.entries.value, hasLength(1));
    expect(controller.entries.value.first.boundaries, ['家人', '前任']);

    // 详情：promptText 预览与起草提示词同一条路径。
    await tester.tap(find.text('测试人设'));
    await tester.pumpAndSettle();
    expect(find.textContaining('<persona_card>'), findsOneWidget);
    expect(find.textContaining('称呼：先生'), findsOneWidget);
    expect(find.textContaining('硬边界（这些内容绝不可以出现在回复里）：家人、前任'), findsOneWidget);
    expect(find.textContaining('安全词：红灯'), findsOneWidget);
  });

  testWidgets('CCV2 导入：解析预览看清映射，确认后落库且情境/开场白进提示词', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byTooltip('导入 Character Card (CCV2)'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('personas_ccv2_json')), ccv2Json);
    await tester.tap(find.byKey(const Key('personas_ccv2_preview')));
    await tester.pumpAndSettle();

    // 预览把映射摊开给用户看：名称、开场白落点。
    expect(find.text('夜航星'), findsOneWidget);
    expect(find.textContaining('first_mes → 开场白'), findsOneWidget);
    // 预览未确认前，确认按钮可点但没导入过：落库发生在确认之后。
    await tester.tap(find.byKey(const Key('personas_ccv2_import')));
    await tester.pumpAndSettle();

    expect(find.textContaining('已导入「夜航星」'), findsOneWidget);
    expect(find.text('夜航星'), findsOneWidget);
    expect(find.text('CCV2 2.0'), findsOneWidget); // 来源追踪徽标
    expect(controller.entries.value, hasLength(1));
    expect(controller.entries.value.first.sourceRef, 'ccv2:2.0');

    await tester.tap(find.text('夜航星'));
    await tester.pumpAndSettle();
    expect(find.textContaining('称呼：小航'), findsOneWidget);
    // scenario → 补充正文的「情境：」键行，PersonaCard 认成 scene。
    expect(find.textContaining('情境：山顶露营的深夜'), findsOneWidget);
    // first_mes → 「对方：」示例行。
    expect(find.textContaining('对方：今晚的银河很清楚'), findsOneWidget);
  });

  testWidgets('复制与删除：副本继承内容并改名，删除走确认', (tester) async {
    await pumpPage(tester);
    // 先造一条（走真实导入路径）。
    await tester.tap(find.byTooltip('导入 Character Card (CCV2)'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('personas_ccv2_json')), ccv2Json);
    await tester.tap(find.byKey(const Key('personas_ccv2_preview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('personas_ccv2_import')));
    await tester.pumpAndSettle();

    // 复制。
    await tester.tap(find.text('夜航星'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('personas_duplicate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('personas_duplicate')));
    await tester.pumpAndSettle();
    expect(find.text('夜航星（副本）'), findsOneWidget);
    expect(controller.entries.value, hasLength(2));

    // 删除原件：确认弹窗后才真删。
    await tester.tap(find.text('夜航星'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('personas_delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('personas_delete')));
    await tester.pumpAndSettle();
    expect(find.text('删除「夜航星」？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('夜航星'), findsNothing);
    expect(find.text('夜航星（副本）'), findsOneWidget);
    expect(controller.entries.value, hasLength(1));
  });
}

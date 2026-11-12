// 知识库管理页 widget 测试（M2 / #12 W4）：渲染列表 / 搜索过滤 / 新建对话框
// 打开（ask 第 4 条的三项必测），外加启用开关、标签筛选 chips、检索评测透出
// 三个行为的落地验证 —— 评测钩子不是摆设，页面要能真把 precision 标出来。
//
// 注入方式与生产同构：KnowledgeController 构造注入 KbStore；测试传纯内存
// 实例（archivePath 为空 → 不落盘），测试不碰任何真实用户数据，也不需要
// mock 平台通道（本页/本控制器零通道依赖）。
import 'package:chartools_app/application/knowledge_controller.dart';
import 'package:chartools_app/ui/knowledge_page.dart';
import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late KbStore store;
  late KnowledgeController controller;
  late String n1id;
  late String n2id;

  setUp(() {
    store = KbStore(); // archivePath 为空 → 纯内存库
    controller = KnowledgeController(store);
    n1id = controller.createNote(
      title: '部署清单',
      content: '上线前检查反向代理与证书有效期',
      tags: const ['运维'],
    );
    n2id = controller.createNote(
      title: '口味偏好',
      content: '对方不吃香菜，微辣为主',
      tags: const ['生活'],
    );
  });

  tearDown(() {
    controller.dispose();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: KnowledgePage(controller: controller)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('渲染列表：标题 / 内容预览 / 来源标签 / 启用开关 / 统计行', (tester) async {
    await pumpPage(tester);

    expect(find.text('部署清单'), findsOneWidget);
    expect(find.text('口味偏好'), findsOneWidget);
    expect(find.text('上线前检查反向代理与证书有效期'), findsOneWidget);
    // 来源标签：手写笔记一律 manual → 「手动」徽标两条。
    expect(find.text('手动'), findsNWidgets(2));
    // 统计行：总条数 / 启用数 / 检索次数（实时过滤不计检索）。
    expect(find.text('共 2 条 · 启用 2 条 · 检索 0 次'), findsOneWidget);
    // 行内启用开关已就位且为开。
    expect(
      tester.widget<Switch>(find.byKey(Key('note-switch-$n1id'))).value,
      isTrue,
    );
    expect(
      tester.widget<Switch>(find.byKey(Key('note-switch-$n2id'))).value,
      isTrue,
    );
  });

  testWidgets('搜索框实时过滤：命中一条、清空恢复，且不计入检索次数', (tester) async {
    await pumpPage(tester);

    await tester.enterText(
        find.byKey(const Key('knowledge-search-field')), '证书');
    await tester.pumpAndSettle();

    expect(find.text('部署清单'), findsOneWidget);
    expect(find.text('口味偏好'), findsNothing);
    // 过滤 ≠ 检索：检索次数不动（统计行仍为 0 次）。
    expect(find.text('共 2 条 · 启用 2 条 · 检索 0 次'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('knowledge-search-field')), '');
    await tester.pumpAndSettle();

    expect(find.text('部署清单'), findsOneWidget);
    expect(find.text('口味偏好'), findsOneWidget);
  });

  testWidgets('新建对话框：打开 → 填写 → 保存 → 列表出现新笔记', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    expect(find.text('新建笔记'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('note-title-field')), '安全词');
    await tester.enterText(
        find.byKey(const Key('note-content-field')), '红灯停，黄灯慢，绿灯继续');
    await tester.enterText(find.byKey(const Key('note-tags-field')), '约定，边界');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('新建笔记'), findsNothing); // 对话框已关
    expect(find.text('安全词'), findsOneWidget); // 新笔记在列表里
    expect(find.textContaining('共 3 条'), findsOneWidget);

    // 入库核实：出处 manual、默认启用、标签按分隔解析成两条。
    final created =
        controller.notes.value.firstWhere((t) => t.note.title == '安全词');
    expect(created.source, KbSource.manual);
    expect(created.note.enabled, isTrue);
    expect(created.note.tags, ['约定', '边界']);
    expect(store.note(created.note.id), isNotNull);
  });

  testWidgets('启用开关：关掉一条 → 存储与统计行同步，再开回来恢复', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byKey(Key('note-switch-$n2id')));
    await tester.pumpAndSettle();

    expect(store.note(n2id)!.note.enabled, isFalse);
    expect(find.text('共 2 条 · 启用 1 条 · 检索 0 次'), findsOneWidget);
    // 停用的笔记仍留在管理列表里（要能找回并重新启用）。
    expect(find.text('口味偏好'), findsOneWidget);

    await tester.tap(find.byKey(Key('note-switch-$n2id')));
    await tester.pumpAndSettle();

    expect(store.note(n2id)!.note.enabled, isTrue);
    expect(find.text('共 2 条 · 启用 2 条 · 检索 0 次'), findsOneWidget);
  });

  testWidgets('标签筛选 chips：点「生活 1」只留口味偏好，再点恢复', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('生活 1'));
    await tester.pumpAndSettle();

    expect(find.text('口味偏好'), findsOneWidget);
    expect(find.text('部署清单'), findsNothing);

    await tester.tap(find.text('生活 1'));
    await tester.pumpAndSettle();

    expect(find.text('部署清单'), findsOneWidget);
  });

  testWidgets('检索评测透出：提交 BM25 → 检索次数 +1 → 标「相关」出 precision', (tester) async {
    await pumpPage(tester);

    // 提交检索（放大镜按钮）：写日志 + 透出命中卡。
    await tester.enterText(
        find.byKey(const Key('knowledge-search-field')), '证书');
    await tester.tap(find.byKey(const Key('knowledge-search-submit')));
    await tester.pumpAndSettle();

    expect(find.textContaining('检索 1 次'), findsOneWidget);
    expect(find.textContaining('BM25 检索'), findsOneWidget);
    // 实时过滤照常生效：证书只命中部署清单。
    expect(find.text('口味偏好'), findsNothing);
    // 评测钩子的存储层落地：一条日志，命中恰为 n1。
    expect(store.searchLog().length, 1);
    expect(store.searchLog().single.hitIds, [n1id]);

    // 人工标注：点「相关」→ precision@k 写回日志并透出。
    await tester.tap(find.text('相关').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('precision@k'), findsOneWidget);
    expect(controller.lastRetrieval.value!.annotated, isNotNull);
    expect(controller.lastRetrieval.value!.precisionAtK, 1.0);
    expect(store.searchLog().single.precisionAtK, 1.0);
  });
}

/// 迁移页 widget 测试（migration_page.dart）：粘贴 → 解析预览 → 确认落盘 →
/// 结果对账的主链路 + 非法 JSON 的问题透出。
///
/// 控制器层的勾选/对账语义由 migration_controller_test 钉住，这里只验
/// 「页面上真的走得通」：按钮使能、计数展示、结果页对账文案、库内核对。
/// 测试视口刻意拉高——页面是 ListView（懒构建），默认 600 高会把尾部按钮
/// 挡在屏外。
///
/// 本文件为新增（不改既有测试文件）。
library;

import 'package:chartools_app/application/migration_controller.dart';
import 'package:chartools_app/ui/migration_page.dart';
import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpPage(WidgetTester tester, MigrationController controller) async {
  // 拉高视口让 ListView 全部子项入屏（addTearDown 恢复默认）。
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: MigrationPage(controller: controller)),
  ));
}

void main() {
  testWidgets('主链路：粘贴 → 解析预览 → 确认落盘 → 结果对账', (tester) async {
    final store = KbStore();
    final controller = MigrationController(store: store);
    await _pumpPage(tester, controller);

    // 输入阶段：只给 notes，其他留空（= 迁移包里没有这些文件）。
    await tester.enterText(
      find.byKey(const Key('migration-input-notes')),
      '[{"id":"w1","title":"待办","content":"每周五写周报"}]',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('migration-parse')));
    await tester.pumpAndSettle();

    // 预览阶段：计数 + 明细 + 默认勾选（insert 全勾）。
    expect(find.text('将导入 1'), findsOneWidget, reason: '计数 chips');
    expect(find.text('确认导入勾选项（1）'), findsOneWidget);

    // 确认落盘 → 结果页。
    await tester.tap(find.byKey(const Key('migration-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('迁移完成'), findsOneWidget);
    expect(find.textContaining('成功写入 1 条'), findsOneWidget);
    // 库内核对：真写进去了，来源标注 import。
    expect(store.note('w1'), isNotNull);
    expect(store.note('w1')!.source, KbSource.import);

    // 「再导一份」回到输入页（文本保留，便于修正后重导）。
    await tester.tap(find.byKey(const Key('migration-again')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('migration-parse')), findsOneWidget);
  });

  testWidgets('非法 JSON：问题明细如实列出，无勾选项时确认按钮禁用', (tester) async {
    final store = KbStore();
    final controller = MigrationController(store: store);
    await _pumpPage(tester, controller);

    await tester.enterText(
      find.byKey(const Key('migration-input-notes')),
      '这不是一段 JSON',
    );
    // contacts/personas 显式给空数组（「文件在但没有条目」）：留空 = 文件缺席，
    // collectLegacyBundle 的既定契约会各记一条「迁移包里没有这个文件」的文件
    // 级 problem（legacy_importer_test.dart:472 钉住）——那样问题总数是 3，
    // 与本用例「只考察非法 notes.json」的口径不符。
    await tester.enterText(
      find.byKey(const Key('migration-input-contacts')),
      '[]',
    );
    await tester.enterText(
      find.byKey(const Key('migration-input-personas')),
      '[]',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('migration-parse')));
    await tester.pumpAndSettle();

    // 解析层不连坐：整包损坏 = 文件级 problem，如实展示，不静默不炸。
    expect(find.textContaining('不是合法 JSON'), findsWidgets);
    expect(find.textContaining('另有 1 条问题已记录'), findsOneWidget);

    // 没有任何可确认条目 → 确认按钮禁用（onPressed 为 null）。
    final confirm = tester.widget<FilledButton>(
        find.byKey(const Key('migration-confirm')));
    expect(confirm.onPressed, isNull);
    expect(store.notes(), isEmpty, reason: '未确认不落盘（G8）');
  });

  testWidgets('预览阶段勾选交互：冲突项可勾、计数随勾选刷新', (tester) async {
    final store = KbStore();
    // 库里先放一条同 id 不同文的笔记，制造一个冲突条目。
    store.importNotes(const [
      Note(id: 'w1', title: '旧版', content: '旧内容'),
    ], source: KbSource.manual);
    final controller = MigrationController(store: store);
    await _pumpPage(tester, controller);

    await tester.enterText(
      find.byKey(const Key('migration-input-notes')),
      '[{"id":"w1","title":"新版","content":"新内容"}]',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('migration-parse')));
    await tester.pumpAndSettle();

    // 冲突条目：默认不勾（确认按钮禁用），明细带「冲突待确认」标签。
    expect(find.textContaining('冲突'), findsWidgets);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('migration-confirm')))
          .onPressed,
      isNull,
    );

    // 勾选冲突条目 = 「仍导入」裁决：按钮点亮，计数刷新。
    await tester.tap(find.byKey(const Key('migration-check-notes.json#0')));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('migration-confirm')))
          .onPressed,
      isNotNull,
    );
    expect(find.text('确认导入勾选项（1）'), findsOneWidget);
  });
}

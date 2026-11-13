/// 迁移控制器测试（migration_controller.dart）：预览 → 勾选 → 确认落盘 →
/// 对账的编排契约。
///
/// 钉住：预览计数（对当前库现查既有索引）、默认勾选只含 insert、冲突项
/// 点名即「仍导入」裁决、重复项不可勾、跨段失败即停（前段失败后续段不
/// 执行）、人设段暂无落盘通路的如实对账、重导幂等。落盘通路用真
/// KbStoreSink + 纯内存 KbStore（不加 archivePath），失败路径用
/// schemaVersion 超前的存档（_flush 恒拒绝的真实失败，见 kb_store.dart）。
///
/// 本文件为新增（不改既有测试文件）。
library;

import 'package:chartools_app/application/migration_controller.dart';
import 'package:chartools_core/chartools_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const notesRaw = '''
[
 {"id":"dup-1","title":"团队守则","content":"回复要简短"},
 {"id":"conflict-1","title":"新版","content":"新内容"},
 {"id":"fresh-1","title":"全新笔记","content":"全新内容"},
 {"title":"","content":""}
]
''';
  const contactsRaw = '[{"id":"c1","name":"小张","relationship":"同事"}]';
  const personasRaw = '[{"name":"某专家","body":"人设正文"}]';

  /// 造一个带既有数据的内存库：一条将被判重复，一条将被判冲突（同 id 不同文）。
  KbStore seededStore() {
    final store = KbStore();
    store.importNotes(const [
      Note(id: 'dup-1', title: '团队守则', content: '回复要简短'),
      Note(id: 'conflict-1', title: '旧版', content: '旧内容'),
    ], source: KbSource.manual);
    return store;
  }

  group('预览（对当前库现查既有索引）', () {
    test('计数：将导入 / 重复 / 冲突 / 问题，默认勾选只含 insert', () {
      final controller =
          MigrationController(store: seededStore());
      controller.loadTexts(
        notesJson: notesRaw,
        contactsJson: contactsRaw,
        personasJson: personasRaw,
      );
      final p = controller.preview.value!;
      expect(p.importCount, 3, reason: 'fresh-1 笔记 + c1 联系人 + 专家人设');
      expect(p.duplicateCount, 1, reason: 'dup-1 与库里内容全等');
      expect(p.conflictCount, 1, reason: 'conflict-1 同 id 不同文');
      expect(p.problems, hasLength(1), reason: '双空笔记一条 problem');

      // 默认勾选：insert 全勾（3），重复不可勾，冲突默认不勾。
      expect(controller.selectedCount, 3);
      controller.dispose();
    });

    test('重复项不可勾；冲突项可勾（点名 = 仍导入裁决）', () {
      final controller = MigrationController(store: seededStore());
      controller.loadTexts(notesJson: notesRaw);
      final p = controller.preview.value!;
      final dup = p.notes
          .firstWhere((i) => i.entity.id == 'dup-1');
      final conflict = p.notes
          .firstWhere((i) => i.entity.id == 'conflict-1');
      expect(controller.isTickable(dup), isFalse);
      expect(controller.isTickable(conflict), isTrue);

      final before = controller.selectedCount;
      controller.setChecked(dup, true);
      expect(controller.selectedCount, before,
          reason: '重复项勾选被静默忽略（无损跳过，写进去只会翻倍）');

      controller.setChecked(conflict, true);
      expect(controller.selectedKeys.value,
          contains(MigrationController.keyOf(conflict)));
      controller.dispose();
    });
  });

  group('确认落盘（只落勾选项）', () {
    test('主链路：确认 → sink 写库 → 对账（written == 勾选数，来源 import）', () async {
      final store = seededStore();
      final controller = MigrationController(store: store);
      controller.loadTexts(
        notesJson: notesRaw,
        contactsJson: contactsRaw,
        personasJson: personasRaw,
      );
      final report = await controller.confirm();

      expect(report.ok, isTrue);
      expect(report.notes.written, 1, reason: '只有 fresh-1');
      expect(report.contacts.written, 1);
      expect(report.writtenTotal, 2);
      expect(report.personas.deferred, 1,
          reason: '人设段暂无落盘通路，对账如实报 deferred');
      expect(report.personas.pending, 0, reason: '「没写」不谎报成「失败」');

      // 库内核对：确认的进了（source import），重复/冲突原样未动。
      final ids = store.notes().map((t) => t.note.id).toSet();
      expect(ids, {'dup-1', 'conflict-1', 'fresh-1'});
      expect(store.note('fresh-1')!.source, KbSource.import);
      expect(store.note('dup-1')!.source, KbSource.manual);
      expect(store.note('conflict-1')!.note.content, '旧内容');
      expect(store.contacts().single.name, '小张');
      expect(controller.lastReport.value, same(report));
      controller.dispose();
    });

    test('冲突项被点名后确认 → 按用户裁决落库（同 id 覆盖）', () async {
      final store = seededStore();
      final controller = MigrationController(store: store);
      controller.loadTexts(notesJson: notesRaw);

      // 默认不勾冲突：第一把确认只写 fresh-1（insert 默认勾选），冲突项
      // 原样留在库里。
      final r1 = await controller.confirm();
      expect(r1.notes.written, 1, reason: 'fresh-1 是默认勾选的 insert 项');
      expect(store.note('conflict-1')!.note.content, '旧内容');

      // 点名冲突 = 「仍导入」裁决：按 id 覆盖为冲突侧的新内容；fresh-1 同
      // 内容已在库，按幂等跳过。
      final conflict = controller.preview.value!.notes
          .firstWhere((i) => i.entity.id == 'conflict-1');
      controller.setChecked(conflict, true);
      final r2 = await controller.confirm();
      expect(r2.notes.written, 1);
      expect(r2.notes.skippedExisting, 1, reason: 'fresh-1 重导幂等');
      expect(store.note('conflict-1')!.note.content, '新内容');
      controller.dispose();
    });

    test('重导幂等：同一份内容再确认 → 全部按「已存在」跳过', () async {
      final store = KbStore();
      final controller = MigrationController(store: store);
      controller.loadTexts(
          notesJson: '[{"id":"n1","title":"标题","content":"正文"}]');
      final first = await controller.confirm();
      expect(first.writtenTotal, 1);
      final updatedAt = store.note('n1')!.note.updatedAt;

      final second = await controller.confirm();
      expect(second.ok, isTrue);
      expect(second.notes.written, 0);
      expect(second.notes.skippedExisting, 1);
      expect(store.note('n1')!.note.updatedAt, updatedAt,
          reason: '幂等跳过不重写，编辑时间不被无谓刷新');
      controller.dispose();
    });
  });

  group('跨段失败即停', () {
    test('notes 段失败 → contacts/personas 段不执行，对账如实标记', () async {
      // schemaVersion 9999：_flush 恒拒绝（真实失败路径，非注入）。
      final ahead = KbStore.fromJson(
          <String, dynamic>{'schemaVersion': 9999, 'notes': <dynamic>[]});
      final controller = MigrationController(store: ahead);
      controller.loadTexts(
        notesJson: '[{"id":"na","title":"甲","content":"甲"}]',
        contactsJson: '[{"id":"ca","name":"某人"}]',
        personasJson: '[{"name":"专家","body":"正文"}]',
      );
      final report = await controller.confirm();

      expect(report.ok, isFalse);
      expect(report.notes.error, contains('拒绝降级重写'));
      expect(report.notes.pending, 1);
      expect(report.contacts.error, contains('本段未执行'));
      expect(report.contacts.pending, 1, reason: '联系人确认了但没执行，算未落盘');
      expect(report.personas.error, contains('本段未执行'));
      expect(report.pendingTotal, 2);
      expect(report.writtenTotal, 0);
      // 库内核对：一段都不许留半截。
      expect(ahead.notes(), isEmpty);
      expect(ahead.contacts(), isEmpty);
      controller.dispose();
    });

    test('describe 汇总失败原因（成功 N/失败 M 口径）', () async {
      final ahead = KbStore.fromJson(
          <String, dynamic>{'schemaVersion': 9999, 'notes': <dynamic>[]});
      final controller = MigrationController(store: ahead);
      controller.loadTexts(
          notesJson: '[{"id":"na","title":"甲","content":"甲"}]');
      final report = await controller.confirm();
      expect(report.describe(), contains('失败 1 条'));
      expect(report.describe(), contains('拒绝降级重写'));
      controller.dispose();
    });
  });

  group('边界', () {
    test('没有预览时 confirm 返回空账，不炸', () async {
      final controller = MigrationController(store: KbStore());
      final report = await controller.confirm();
      expect(report.ok, isTrue);
      expect(report.writtenTotal, 0);
      expect(report.pendingTotal, 0);
      controller.dispose();
    });

    test('重新 loadTexts 重置勾选与对账', () async {
      final store = seededStore();
      final controller = MigrationController(store: store);
      controller.loadTexts(notesJson: notesRaw);
      final conflict = controller.preview.value!.notes
          .firstWhere((i) => i.entity.id == 'conflict-1');
      controller.setChecked(conflict, true);
      await controller.confirm();

      // 第二轮喂**新内容**（一条全新 insert）：上一轮确认过的 fresh-1 /
      // conflict-1 原样再喂会按 A8 全部判重，默认勾选集就是空集。「勾选按
      // 新预览的默认集重来」用「新预览恰有一条 insert」钉最直接——勾选若没
      // 重置，旧键（notes.json#1/#2）还在，计数是 2；重置正确则只剩新
      // insert，计数 1。
      controller.loadTexts(
          notesJson: '[{"id":"fresh-2","title":"二轮","content":"二轮内容"}]');
      expect(controller.lastReport.value, isNull,
          reason: '新预览是新的一轮确认，旧对账不再展示');
      expect(controller.selectedCount, 1, reason: '勾选按新预览的默认集重来');
      controller.dispose();
    });
  });
}

/// MigrationSink 的 KbStore 实现（`src/migration/migration_sink.dart`）测试。
///
/// 钉住三原则（legacy_importer.dart:930-949 的落盘契约）：
///
/// 1. 段级全或无——半途失败整段回滚：已写的半截从内存撤掉、被覆盖的既有
///    条目逐字恢复（含 source/importedAt/updatedAt 与聊天日志行）；
/// 2. 失败即停——出错那条之后的条目绝不尝试，错误带条目号如实上交；
/// 3. 只收确认集——写进去的就是传入的列表，不多不少；冲突/重复不在此层
///    出现（它们的过滤在预览/控制器层，由 migration_sink 的确认集入口契约
///    与 legacy_importer_test 的 confirmed 集合用例分别钉住）。
///
/// 另钉：预览 → 确认 → 落盘的计数对账（确认集大小 == written）与
/// archiveSchemaAhead（存档格式超前拒绝落盘）这条真实失败路径。
///
/// 测试通过**子类注入故障**（覆写 saveNote/saveContact 在第 N 次返回 false）
/// 与**真实失败路径**（schemaVersion 超前的存档，_flush 恒拒绝）两条路触发
/// 失败——不 mock 库内部，全部走 KbStore 公开 API。
import 'package:chartools_core/src/migration/legacy_importer.dart';
import 'package:chartools_core/src/migration/migration_sink.dart';
import 'package:chartools_core/src/persona_kb/kb_models.dart';
import 'package:chartools_core/src/persona_kb/kb_store.dart';
import 'package:test/test.dart';

/// 故障注入库：第 [failAt] 次 saveNote / saveContact 返回 false（1 起算）。
/// 其余行为与真库逐字节一致——回滚走的 deleteNote/importNotes/appendLog
/// 不受影响，正是要考察「写挂了之后撤得干不干净」。
class _FlakyStore extends KbStore {
  _FlakyStore(this.failAt) : super();

  final int failAt;
  int saveNoteCalls = 0;
  int saveContactCalls = 0;

  @override
  bool saveNote(Note note, {String source = KbSource.manual, int? importedAt}) {
    saveNoteCalls++;
    if (saveNoteCalls == failAt) {
      lastFlushError = '测试注入的笔记落盘失败';
      return false;
    }
    return super.saveNote(note, source: source, importedAt: importedAt);
  }

  @override
  bool saveContact(Contact c) {
    saveContactCalls++;
    if (saveContactCalls == failAt) {
      lastFlushError = '测试注入的联系人落盘失败';
      return false;
    }
    return super.saveContact(c);
  }
}

Note _note(String id, String title, String content,
        {bool enabled = true, int updatedAt = 0}) =>
    Note(id: id, title: title, content: content, enabled: enabled,
        updatedAt: updatedAt);

void main() {
  group('原则 1：段级全或无（半途失败整段回滚）', () {
    test('第 2 条失败：第 1 条的半截撤掉，库里一条都不剩', () async {
      final store = _FlakyStore(2);
      final sink = KbStoreSink(store);
      final report = await sink.applyNotesDetailed([
        _note('n1', '第一条', '内容一'),
        _note('n2', '第二条', '内容二'),
        _note('n3', '第三条', '内容三'),
      ]);
      expect(report.ok, isFalse);
      expect(store.notes(), isEmpty, reason: '段级全或无：半截也不许留');
      expect(report.written, 0, reason: '写过的已被回滚，成功数归零');
      expect(report.pending, 3, reason: '确认了但没落盘的 = 全部三条');
    });

    test('被覆盖的既有条目逐字恢复：正文/source/importedAt/updatedAt 全回原', () async {
      final store = _FlakyStore(1);
      // 既有条目走 importNotes 造出来，让 updatedAt/importedAt 有受控非零值。
      store.importNotes([
        _note('keep-1', '原名', '原内容', updatedAt: 1700000000000),
      ], source: KbSource.manual, importedAt: 555);
      final sink = KbStoreSink(store);
      final report = await sink.applyNotesDetailed([
        _note('keep-1', '新名', '新内容'), // 同 id 不同文 → 覆盖，然后写挂回滚
      ]);
      expect(report.ok, isFalse);
      final restored = store.note('keep-1');
      expect(restored, isNotNull);
      expect(restored!.note.title, '原名');
      expect(restored.note.content, '原内容');
      expect(restored.source, KbSource.manual, reason: '出处属于创建时刻，不因回滚改出身');
      expect(restored.importedAt, 555);
      expect(restored.note.updatedAt, 1700000000000,
          reason: '恢复走 importNotes，原时间保真');
    });

    test('新增条目回滚后不留痕；同段后续条目不被尝试（见原则 2）', () async {
      final store = _FlakyStore(1);
      final sink = KbStoreSink(store);
      final report = await sink.applyNotesDetailed([
        _note('a', '甲', '甲内容'),
        _note('b', '乙', '乙内容'),
      ]);
      expect(report.ok, isFalse);
      expect(store.notes(), isEmpty);
      expect(store.saveNoteCalls, 1, reason: '失败即停：第 2 条的 saveNote 没发生');
    });

    test('联系人段回滚：档案逐字回原，聊天日志行按原序补回', () async {
      // failAt=2：第 1 次 saveContact 是造数（种子联系人），第 2 次才是
      // apply 里的落盘——故障必须打在落盘那次，不打在造数上。
      final store = _FlakyStore(2);
      final original = Contact(
        id: 'c1',
        name: '老王',
        aliases: const ['隔壁老王'],
        relationship: '邻居',
        notes: '借过充电宝',
      );
      store.saveContact(original);
      store.appendLog('c1', const [
        LogEntry(side: 'other', text: '在吗'),
        LogEntry(side: 'me', text: '在'),
        LogEntry(side: 'other', text: '充电宝还你'),
      ]);
      final sink = KbStoreSink(store);
      final report = await sink.applyContactsDetailed([
        Contact(id: 'c1', name: '老王', relationship: '同事'), // 同 id 不同文
      ]);
      expect(report.ok, isFalse);
      final restored = store.contact('c1');
      expect(restored, isNotNull);
      expect(restored!.name, '老王');
      expect(restored.aliases, ['隔壁老王']);
      expect(restored.relationship, '邻居');
      expect(restored.notes, '借过充电宝');
      expect(store.logSize('c1'), 3, reason: 'deleteContact 连带清日志，回滚要补回');
      final log = store.recentLog('c1', 10);
      expect(log.map((e) => e.text), ['在吗', '在', '充电宝还你'],
          reason: '日志行按原序补回，不留残影也不丢行');
    });
  });

  group('原则 2：失败即停（错误不吞）', () {
    test('错误带条目号与原因上交；后续条目 pending', () async {
      final store = _FlakyStore(2);
      final sink = KbStoreSink(store);
      final report = await sink.applyNotesDetailed([
        _note('n1', '一', '一'),
        _note('n2', '二', '二'),
        _note('n3', '三', '三'),
      ]);
      expect(report.error, isNotNull);
      expect(report.error, contains('第 2 条'));
      expect(report.error, contains('测试注入的笔记落盘失败'));
      expect(report.pending, 3, reason: '第 2 条失败 + 第 3 条未尝试');
    });

    test('真实失败路径：存档格式超前（archiveSchemaAhead）拒绝落盘 → 整段回滚', () async {
      // schemaVersion 9999 > 已知 1：_flush 恒拒绝（kb_store.dart:803-809），
      // saveNote 返回 false——不走故障注入，直接钉真实失败路径。
      final store = KbStore.fromJson(<String, dynamic>{
        'schemaVersion': 9999,
        'notes': <dynamic>[],
      });
      expect(store.archiveSchemaAhead, isTrue);
      final sink = KbStoreSink(store);
      final report = await sink.applyNotesDetailed([_note('x', '标题', '正文')]);
      expect(report.ok, isFalse);
      expect(store.notes(), isEmpty);
      expect(report.error, contains('拒绝降级重写'));
      // 联系人段同路径。
      final contacts = await sink.applyContactsDetailed(
          [Contact(id: 'c', name: '某人')]);
      expect(contacts.ok, isFalse);
      expect(store.contacts(), isEmpty);
    });
  });

  group('原则 3：只收确认集（写进去的就是传入的列表）', () {
    test('全清入库：不多不少，来源标注 manual → import', () async {
      final store = KbStore();
      final sink = KbStoreSink(store);
      final report = await sink.applyNotesDetailed([
        _note('a', '甲', '甲内容'),
        _note('b', '乙', '乙内容'),
      ]);
      expect(report.ok, isTrue);
      expect(report.written, 2);
      expect(report.pending, 0);
      final notes = store.notes();
      expect(notes, hasLength(2));
      expect(notes.map((t) => t.note.id), containsAll(['a', 'b']));
      // 迁移来源标注：source = import（KbSource.manual → import），importedAt 盖章。
      for (final t in notes) {
        expect(t.source, KbSource.import);
        expect(t.importedAt, greaterThan(0));
      }
    });

    test('联系人段与空列表：空段是成功的空操作（幂等）', () async {
      final store = KbStore();
      final sink = KbStoreSink(store);
      final contacts = await sink.applyContactsDetailed(
          [Contact(id: 'c1', name: '小张', aliases: const ['小张张'])]);
      expect(contacts.ok, isTrue);
      expect(contacts.written, 1);
      expect(store.contacts().single.name, '小张');

      final empty = await sink.applyNotesDetailed(const []);
      expect(empty.ok, isTrue);
      expect(empty.written, 0);
      expect(empty.pending, 0);
    });

    test('人设段：暂无落盘通路 → 成功 + deferred 如实计数，不谎报写入', () async {
      final store = KbStore();
      final sink = KbStoreSink(store);
      final report = await sink.applyPersonasDetailed(const [
        ImportedPersona(id: 'p1', name: '某专家', body: '正文'),
      ]);
      expect(report.ok, isTrue, reason: '没有可写 ≠ 失败');
      expect(report.written, 0);
      expect(report.deferred, 1, reason: '对账里必须看到「没写」这件事本身');
      expect(store.notes(), isEmpty);
    });

    test('幂等重导：同 id 同内容第二遍跳过，updatedAt 不被盘活', () async {
      final store = KbStore();
      final sink = KbStoreSink(store);
      final first = await sink.applyNotesDetailed([_note('a', '甲', '甲内容')]);
      expect(first.written, 1);
      final afterFirst = store.note('a')!.note.updatedAt;

      final second = await sink.applyNotesDetailed([_note('a', '甲', '甲内容')]);
      expect(second.ok, isTrue);
      expect(second.written, 0);
      expect(second.skippedExisting, 1);
      expect(store.notes(), hasLength(1));
      expect(store.note('a')!.note.updatedAt, afterFirst,
          reason: '幂等跳过不重写，编辑时间不被无谓刷新');
    });
  });

  group('预览 → 确认 → 落盘计数对账', () {
    test('confirmedNotes 只含 insert；落盘 written == importCount；重复/冲突不入库', () async {
      final store = KbStore();
      // 既有数据：一条将被「重复」命中，一条将被「冲突」命中（同 id 不同文）。
      store.importNotes(const [
        Note(id: 'dup-1', title: '团队守则', content: '回复要简短'),
        Note(id: 'conflict-1', title: '旧版', content: '旧内容'),
      ], source: KbSource.manual);
      final existing = LegacyExistingIndex.fromData(
          notes: [for (final t in store.notes()) t.note]);

      const raw = '''
[
 {"id":"dup-1","title":"团队守则","content":"回复要简短"},
 {"id":"conflict-1","title":"新版","content":"新内容"},
 {"id":"fresh-1","title":"全新笔记","content":"全新内容"},
 {"title":"","content":""}
]
''';
      // contacts/personas 传空数组（「文件在但没有条目」）：缺省 null 会走
      // collectLegacyBundle 的「迁移包里没有这个文件」文件级 problem（该契约
      // 由 legacy_importer_test.dart:472 的「缺文件」用例钉住）——本用例只
      // 考察笔记段，问题清单里就只该有双空笔记这一条。
      final preview = buildMigrationPreview(
        collectLegacyBundle(notesJson: raw, contactsJson: '[]', personasJson: '[]'),
        existing: existing,
      );
      expect(preview.importCount, 1, reason: '只有 fresh-1 是全新内容');
      expect(preview.duplicateCount, 1);
      expect(preview.conflictCount, 1);
      expect(preview.problems, hasLength(1), reason: '双空笔记记一条 problem');

      // G8 确认集：只含 insert 状态（legacy_importer.dart:805-816 的契约）。
      final confirmed = preview.confirmedNotes;
      expect(confirmed, hasLength(1));
      expect(confirmed.single.id, 'fresh-1');

      final sink = KbStoreSink(store);
      final report = await sink.applyNotesDetailed(confirmed);
      expect(report.ok, isTrue);
      // 计数对账：落盘成功数 == 预览的将导入数。
      expect(report.written, preview.importCount);
      expect(report.skippedExisting, 0);
      final ids = store.notes().map((t) => t.note.id).toSet();
      expect(ids, containsAll(['dup-1', 'conflict-1', 'fresh-1']),
          reason: '重复与冲突条目不经确认绝不入库，原有两条原样保留');
      expect(ids, hasLength(3));
      expect(store.note('fresh-1')!.source, KbSource.import);
      expect(store.note('dup-1')!.source, KbSource.manual);
    });

    test('重导幂等（迁移设计 A8）：同一包第二遍全是跳过，importCount 归零', () async {
      final store = KbStore();
      const raw =
          '[{"id":"n1","title":"标题","content":"正文"}]';
      final sink = KbStoreSink(store);

      // 第一遍：空库导入。
      final first = buildMigrationPreview(collectLegacyBundle(notesJson: raw));
      expect(first.importCount, 1);
      final r1 = await sink.applyNotesDetailed(first.confirmedNotes);
      expect(r1.written, 1);

      // 第二遍：上一轮入库内容就是「已有数据」，预览判重后确认集为空。
      final second = buildMigrationPreview(
        collectLegacyBundle(notesJson: raw),
        existing: LegacyExistingIndex.fromData(
            notes: [for (final t in store.notes()) t.note]),
      );
      expect(second.importCount, 0);
      expect(second.duplicateCount, 1);
      final r2 = await sink.applyNotesDetailed(second.confirmedNotes);
      expect(r2.ok, isTrue);
      expect(r2.written, 0);
      expect(store.notes(), hasLength(1));
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:chartools_core/src/persona_kb/kb_models.dart';
import 'package:chartools_core/src/persona_kb/kb_store.dart';
import 'package:test/test.dart';

/// KbStore（超越版）测试。钉七件事：
///
///  1. Note/Contact/LogEntry 的 CRUD 往返；
///  2. JSON 存档往返 + 顶层 schemaVersion（K-7）；
///  3. schemaVersion 容错（缺失 / 更新版本 / 损坏条目 / 非本格式）；
///  4. 来源追踪字段（source / importedAt，更新不改出身）；
///  5. 导入去重（内容指纹 + 归一化复核）；
///  6. searchLog 命中评测钩子（检索落账 / 事后注入 / precision 计算）；
///  7. 文件持久化（原子写、无 .tmp 残留、clearAll 删档）。
///
/// 测试直接 import `src/` 路径：barrel（chartools_core.dart）另有归属人，
/// 挂载导出由集成方统一处理。
void main() {
  Note noteOf(
    String id,
    String title,
    String content, {
    List<String> tags = const [],
    String type = 'note',
    bool enabled = true,
  }) =>
      Note(
        id: id,
        title: title,
        content: content,
        tags: tags,
        type: type,
        enabled: enabled,
      );

  group('Note CRUD（内存档）', () {
    test('新增 → 读回 → 更新 → 删除', () {
      final store = KbStore();
      expect(store.saveNote(noteOf('n1', '标题', '内容')), isTrue);
      final got = store.note('n1');
      expect(got, isNotNull);
      expect(got!.note.title, '标题');
      expect(got.note.updatedAt, greaterThan(0)); // 落库自动盖章
      expect(got.source, KbSource.manual);

      // 同 id 再存 = 替换
      store.saveNote(noteOf('n1', '标题2', '内容2'));
      expect(store.notes(), hasLength(1));
      expect(store.note('n1')!.note.title, '标题2');

      // 删除；不存在 id 幂等成功
      expect(store.deleteNote('n1'), isTrue);
      expect(store.note('n1'), isNull);
      expect(store.deleteNote('nope'), isTrue);
    });

    test('notes() 返回副本，外部改动不影响库内', () {
      final store = KbStore();
      store.saveNote(noteOf('n1', 't', 'c'));
      store.notes().add(TrackedNote(
        note: noteOf('n2', 't', 'c'),
        source: KbSource.manual,
        importedAt: 0,
        contentHash: 'x',
      ));
      expect(store.notes(), hasLength(1));
    });
  });

  group('Contact / LogEntry CRUD', () {
    test('联系人存取 + 删除连带清聊天记录', () {
      final store = KbStore();
      store.saveContact(const Contact(
        id: 'c1',
        name: '小王',
        aliases: ['王总'],
        apps: ['com.tencent.mobileqq'],
        relationship: '同事',
      ));
      final c = store.contact('c1')!;
      expect(c.name, '小王');
      expect(c.updatedAt, greaterThan(0));

      store.appendLog('c1', [const LogEntry(side: 'me', text: '你好', ts: 1)]);
      expect(store.logSize('c1'), 1);

      store.deleteContact('c1');
      expect(store.contact('c1'), isNull);
      expect(store.logSize('c1'), 0); // 历史不留残影
    });

    test('appendLog 上限裁剪 + 空文本过滤 + recentLog 旧到新', () {
      final store = KbStore(maxLogLines: 3);
      final entries = [
        for (var i = 1; i <= 5; i++) LogEntry(side: 'me', text: 'msg$i', ts: i),
      ];
      store.appendLog('c', entries);
      expect(store.logSize('c'), 3);
      expect(store.recentLog('c', 10).map((e) => e.text),
          ['msg3', 'msg4', 'msg5']);

      store.appendLog('c', [const LogEntry(side: 'me', text: '  ', ts: 9)]);
      expect(store.logSize('c'), 3); // 空白行不入库
    });

    test('pruneLog 用注入的 now 判界', () {
      final store = KbStore();
      store.appendLog('c', [
        const LogEntry(side: 'me', text: 'a', ts: 100),
        const LogEntry(side: 'me', text: 'b', ts: 200),
      ]);
      expect(store.pruneLog('c', 0, now: 999999), 0); // days<=0 不动
      // cutoff = 86401000 - 86400000 = 1000 → 两条都早于它 → 全删
      expect(store.pruneLog('c', 1, now: 86401000), 2);
      expect(store.logSize('c'), 0);
    });

    test('removeLogWhere 按行删除（隐私清理）', () {
      final store = KbStore();
      store.appendLog('c', [
        const LogEntry(side: 'me', text: '卡号 6222', ts: 1),
        const LogEntry(side: 'other', text: '好的', ts: 2),
      ]);
      final dropped =
          store.removeLogWhere('c', (e) => e.text.contains('6222'));
      expect(dropped, 1);
      expect(store.recentLog('c', 10).map((e) => e.text), ['好的']);
    });

    test('clearLog 幂等', () {
      final store = KbStore();
      expect(store.clearLog('ghost'), isTrue);
      store.appendLog('c', [const LogEntry(side: 'me', text: 'x', ts: 1)]);
      expect(store.clearLog('c'), isTrue);
      expect(store.logSize('c'), 0);
    });
  });

  group('来源追踪', () {
    test('manual 不写 importedAt；doc 盖导入时间', () {
      final store = KbStore();
      store.saveNote(noteOf('m1', '手写', '内容'), source: KbSource.manual);
      store.saveNote(noteOf('d1', '文档', '内容二'), source: KbSource.doc);
      final m = store.note('m1')!;
      final d = store.note('d1')!;
      expect(m.source, 'manual');
      expect(m.importedAt, 0);
      expect(d.source, 'doc');
      expect(d.importedAt, greaterThan(0));
    });

    test('更新内容不改出身', () {
      final store = KbStore();
      store.saveNote(noteOf('d1', '文档', '内容'), source: KbSource.doc);
      final before = store.note('d1')!;
      // 再存时试图冒充手写 —— 出处必须保留原值
      store.saveNote(noteOf('d1', '文档改', '内容改'), source: KbSource.manual);
      final after = store.note('d1')!;
      expect(after.source, KbSource.doc);
      expect(after.importedAt, before.importedAt);
      expect(after.note.content, '内容改');
    });

    test('未知 source 字符串往返保留（向前兼容）', () {
      final store = KbStore();
      store.saveNote(noteOf('u1', 't', 'c'), source: 'legacy');
      final back = KbStore.decodeArchive(store.encodeArchive());
      expect(back.note('u1')!.source, 'legacy');
    });
  });

  group('导入去重', () {
    test('同内容重复 → duplicates；空 id 自动补', () {
      final store = KbStore();
      final report = store.importNotes([
        noteOf('', '甲', '知识库的用法'),
        noteOf('', '乙', '知识库的用法'), // 批内重复
      ]);
      expect(report.added, hasLength(1));
      expect(report.duplicates, hasLength(1));
      expect(report.duplicates.single.keptId, report.added.single.note.id);
      expect(report.duplicates.single.incoming.title, '乙');
      expect(report.added.single.note.id, isNotEmpty);
      expect(report.added.single.importedAt, greaterThan(0));
    });

    test('归一化变体（零宽 / 全角空格 / 大小写）算重复', () {
      final store = KbStore();
      store.importNotes([noteOf('a', 't', 'Sp 用法说明')]);
      final report = store.importNotes([
        // 大小写折叠 + 零宽字符剔除 + 全角空格折叠，归一化后与已入库内容全等
        noteOf('b', 't2', 'SP\u200B\u3000用法说明'),
      ]);
      expect(report.added, isEmpty);
      expect(report.duplicates, hasLength(1));
      expect(report.duplicates.single.keptId, 'a');
    });

    test('同 id 不同内容 → updated；换内容后旧内容不再判重（指纹桶同步）', () {
      final store = KbStore();
      store.saveNote(noteOf('x1', '旧', '内容甲'));
      final r1 = store.importNotes([noteOf('x1', '新', '内容乙')]);
      expect(r1.updated, hasLength(1));
      expect(r1.added, isEmpty);
      expect(store.note('x1')!.note.content, '内容乙');
      expect(store.note('x1')!.importedAt, greaterThan(0)); // 再导入刷新出处

      // x1 的内容已换成「内容乙」，旧内容「内容甲」不再是重复
      final r2 = store.importNotes([noteOf('', '再次', '内容甲')]);
      expect(r2.added, hasLength(1));
      expect(r2.duplicates, isEmpty);
    });

    test('内容相同但 id 不同 → 去重优先于按 id 更新', () {
      final store = KbStore();
      store.saveNote(noteOf('keep', '原', '同一段内容'));
      final report = store.importNotes([noteOf('same-id', '新', '同一段内容')]);
      expect(report.duplicates, hasLength(1));
      expect(report.duplicates.single.keptId, 'keep');
      expect(store.notes(), hasLength(1));
    });

    test('删除后重新导入 → 再次 added', () {
      final store = KbStore();
      store.importNotes([noteOf('a', 't', '内容')]);
      store.deleteNote('a');
      final report = store.importNotes([noteOf('a', 't', '内容')]);
      expect(report.added, hasLength(1));
      expect(report.duplicates, isEmpty);
    });
  });

  group('searchLog 命中评测钩子', () {
    KbStore seeded() {
      final store = KbStore();
      store.saveNote(noteOf('n1', '苹果', ''));
      store.saveNote(noteOf('n2', '苹果树', ''));
      store.saveNote(noteOf('n3', '苹果好吃', ''));
      store.saveNote(noteOf('n4', '香蕉', ''));
      return store;
    }

    test('每次检索落账 query→hitIds（与结果一致）', () {
      final store = seeded();
      final result = store.search('苹果');
      final entry = store.searchLog().single;
      expect(entry.query, '苹果');
      expect(entry.hitIds, [for (final h in result.hits) h.id]);
      expect(entry.relevantIds, isNull);
      expect(entry.precisionAtK, isNull);
    });

    test('检索时传 relevantIds → precision@k 直接入账', () {
      final store = seeded();
      final result = store.search('苹果', relevantIds: ['n1', 'n2']);
      expect(result.eval, isNotNull);
      expect(result.eval!.relevantInTopK, 2);
      expect(result.eval!.precisionAtK, closeTo(2 / 3, 1e-9));
      expect(store.searchLog().single.precisionAtK, closeTo(2 / 3, 1e-9));
      expect(store.searchLog().single.relevantIds, ['n1', 'n2']);
    });

    test('annotateSearch 事后补标；越界返回 null', () {
      final store = seeded();
      store.search('苹果');
      store.search('香蕉');
      final annotated = store.annotateSearch(1, ['n4']);
      expect(annotated, isNotNull);
      expect(annotated!.precisionAtK, 1.0);
      expect(annotated.relevantIds, ['n4']);
      expect(store.annotateSearch(99, ['n1']), isNull);

      // 第 0 条仍未标注
      expect(store.searchLog()[0].relevantIds, isNull);
      expect(store.searchLog()[0].precisionAtK, isNull);
    });

    test('searchLog 按容量裁掉最旧', () {
      final store = KbStore(maxSearchLog: 2);
      store.search('q1');
      store.search('q2');
      store.search('q3');
      final log = store.searchLog();
      expect(log, hasLength(2));
      expect(log[0].query, 'q2');
      expect(log[1].query, 'q3');
    });

    test('禁用笔记默认不参与检索，includeDisabled 放开', () {
      final store = seeded();
      store.saveNote(noteOf('n5', '苹果酱', '', enabled: false));
      expect(store.search('苹果').hits.map((h) => h.id), isNot(contains('n5')));
      expect(
        store.search('苹果', includeDisabled: true).hits.map((h) => h.id),
        contains('n5'),
      );
    });

    test('tags / type 过滤透传', () {
      final store = KbStore();
      store.saveNote(noteOf('w1', '苹果', '', tags: ['工作']));
      store.saveNote(noteOf('l1', '苹果', '', tags: ['生活'], type: 'style_sample'));
      expect(store.search('苹果', anyTag: ['生活']).hits.map((h) => h.id),
          ['l1']);
      expect(
        store.search('苹果', anyType: ['style_sample']).hits.map((h) => h.id),
        ['l1'],
      );
    });
  });

  group('JSON 存档往返 + schemaVersion（K-7）', () {
    test('存档顶层带 schemaVersion=1', () {
      final store = KbStore();
      final map = jsonDecode(store.encodeArchive()) as Map;
      expect(kbArchiveSchemaVersion, 1);
      expect(map['schemaVersion'], kbArchiveSchemaVersion);
    });

    test('encode → decode 全字段保真', () {
      final store = KbStore();
      store.saveNote(
        noteOf('a', '甲', '内容甲', tags: ['工作']),
        source: KbSource.doc,
      );
      store.saveNote(noteOf('b', '乙', '内容乙', tags: ['生活']));
      store.saveContact(const Contact(
        id: 'c1',
        name: '小王',
        aliases: ['王总'],
        apps: ['com.tencent.mobileqq'],
        relationship: '同事',
        notes: '备注',
        persona: '人设',
      ));
      store.appendLog('c1', [
        const LogEntry(side: 'me', text: '你好', ts: 111),
        const LogEntry(side: 'other', text: '嗯', ts: 222),
      ]);
      store.search('内容甲');
      store.annotateSearch(0, ['a']);

      final back = KbStore.decodeArchive(store.encodeArchive());

      final origA = store.note('a')!;
      final backA = back.note('a')!;
      expect(backA.note.updatedAt, origA.note.updatedAt); // 载入不盖章
      expect(backA.source, KbSource.doc);
      expect(backA.importedAt, origA.importedAt);
      expect(backA.contentHash, origA.contentHash);
      expect(backA.note.tags, ['工作']);
      expect(back.note('b')!.note.tags, ['生活']);

      final c = back.contact('c1')!;
      expect(c.name, '小王');
      expect(c.aliases, ['王总']);
      expect(c.apps, ['com.tencent.mobileqq']);

      expect(back.recentLog('c1', 10).map((e) => e.text), ['你好', '嗯']);
      expect(back.recentLog('c1', 10).map((e) => e.ts), [111, 222]);

      final log = back.searchLog();
      expect(log, hasLength(1));
      expect(log.single.hitIds, store.searchLog().single.hitIds);
      expect(log.single.relevantIds, ['a']);
      expect(log.single.precisionAtK, store.searchLog().single.precisionAtK);

      expect(back.counts().notes, 2);
      expect(back.counts().contacts, 1);
      expect(back.counts().logLines, 2);
    });

    test('容错：schemaVersion 缺失按 1 处理', () {
      final archive = jsonEncode({
        'notes': [
          {'note': {'id': 'a', 'title': 't', 'content': 'c'}},
        ],
      });
      final store = KbStore.decodeArchive(archive);
      expect(store.note('a'), isNotNull);
    });

    test('容错：未知的新版本号仍尽力解析（向前兼容）', () {
      final archive = jsonEncode({
        'schemaVersion': 99,
        'futureField': {'whatever': true},
        'notes': [
          {'note': {'id': 'a', 'title': 't', 'content': 'c'}},
        ],
      });
      expect(KbStore.decodeArchive(archive).note('a'), isNotNull);
    });

    test('容错：损坏条目跳过，其余载入', () {
      final archive = jsonEncode({
        'schemaVersion': 1,
        'notes': [
          '这不是一条笔记',
          {'note': {'id': 'ok', 'title': '能载入', 'content': 'c'}},
          {'broken': true},
        ],
        'contacts': [null, {'id': 'c1', 'name': '小王'}],
      });
      final store = KbStore.decodeArchive(archive);
      expect(store.notes(), hasLength(1));
      expect(store.note('ok'), isNotNull);
      expect(store.contact('c1'), isNotNull);
    });

    test('容错：缺 id 自动补、缺 enabled 视为启用、缺 type 回落 note', () {
      final archive = jsonEncode({
        'notes': [
          {'note': {'title': 't', 'content': 'c'}},
        ],
      });
      final note = KbStore.decodeArchive(archive).notes().single.note;
      expect(note.id, isNotEmpty);
      expect(note.enabled, isTrue);
      expect(note.type, 'note');
    });

    test('顶层不是对象 / schemaVersion 不是数字 → FormatException', () {
      expect(
          () => KbStore.decodeArchive('[{"id":"a"}]'), throwsFormatException);
      expect(
        () => KbStore.decodeArchive(jsonEncode({'schemaVersion': 'x'})),
        throwsFormatException,
      );
    });
  });

  group('文件持久化（原子写）', () {
    late Directory dir;
    late String path;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('kb_store_test');
      path = '${dir.path}${Platform.pathSeparator}kb.json';
    });
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('变更落盘 → 新实例读回一致；多次覆写无 .tmp 残留', () {
      final store = KbStore(archivePath: path);
      store.saveNote(noteOf('a', '甲', '内容甲'));
      expect(File(path).existsSync(), isTrue);
      store.saveNote(noteOf('b', '乙', '内容乙')); // 第二次写走「替换已存在文件」路径
      store.appendLog('c1', [const LogEntry(side: 'me', text: 'hi', ts: 1)]);

      final loaded = KbStore.loadFromFileSync(path);
      expect(loaded.note('a')!.note.content, '内容甲');
      expect(loaded.note('b'), isNotNull);
      expect(loaded.logSize('c1'), 1);

      final names = dir
          .listSync()
          .map((e) => e.path.split(Platform.pathSeparator).last);
      expect(names.where((n) => n.endsWith('.tmp')), isEmpty);
    });

    test('clearAll 删档：文件消失，重读为空库', () {
      final store = KbStore(archivePath: path);
      store.saveNote(noteOf('a', 't', 'c'));
      expect(store.clearAll(), isTrue);
      expect(File(path).existsSync(), isFalse);
      expect(KbStore.loadFromFileSync(path).notes(), isEmpty);
    });

    test('损坏文件抛 FormatException', () {
      File(path).writeAsStringSync('{not json', encoding: utf8);
      expect(() => KbStore.loadFromFileSync(path), throwsA(isA<FormatException>()));
    });

    test('比已知新的存档：只读向前兼容——任何变更拒绝落盘，不降级重写', () {
      // 独立复核发现：fromJson 尽力解析但记不住版本号，toJson 恒写 1——
      // schemaVersion:2 存档（futureField / note.v2Field）经一次变更落盘
      // 即被静默降级，未知字段全丢。现在：版本号入实例，落盘一律拒绝。
      File(path).writeAsStringSync(
        jsonEncode({
          'schemaVersion': 2,
          'futureField': {'whatever': true},
          'notes': [
            {
              'note': {'id': 'n1', 'title': '未来笔记', 'content': 'c', 'v2Field': 'keep-me'},
              'source': 'doc',
              'importedAt': 1,
              'contentHash': 'deadbeef',
            },
          ],
        }),
        encoding: utf8,
      );
      final store = KbStore.loadFromFileSync(path);
      expect(store.archiveSchemaVersion, 2);
      expect(store.archiveSchemaAhead, isTrue);
      expect(store.note('n1'), isNotNull); // 已知字段照常解析

      final ok = store.saveNote(noteOf('n1', '未来笔记（改）', 'c'));
      expect(ok, isFalse, reason: '降级运行的落盘必须被拒绝');
      expect(store.lastFlushError, contains('拒绝降级重写'));

      final after =
          jsonDecode(File(path).readAsStringSync(encoding: utf8)) as Map;
      expect(after['schemaVersion'], 2, reason: '存档保持原版本，不被重写');
      expect(after.containsKey('futureField'), isTrue);
      expect(
        ((after['notes'] as List).first as Map)['note'],
        containsPair('v2Field', 'keep-me'),
      );
      // 内存状态照常（持久化策略：落盘失败不回滚内存）。
      expect(store.note('n1')!.note.title, '未来笔记（改）');
    });

    test('内存档 clearAll 不落盘也不报错', () {
      final store = KbStore();
      store.saveNote(noteOf('a', 't', 'c'));
      expect(store.clearAll(), isTrue);
      expect(store.notes(), isEmpty);
    });
  });
}

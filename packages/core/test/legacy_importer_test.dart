/// legacy 导入器（`src/migration/legacy_importer.dart`）的解析与预览测试。
///
/// 样例 legacy JSON 覆盖四种情况：**正常 / 缺字段 / 坏类型 / 重复**，外加
/// 整包损坏、v1/v2 双形态、manifest 校验、G8 确认集过滤与重导幂等。
/// 字段结构对照 `_reference/chartools/.../core/kb/KbStore.kt:414-452` 与
/// `PersonaStore.kt:608-641`（ask 指定的只读参考）。
///
/// 直接 import src 路径而非 barrel：barrel（chartools_core.dart）不在本工作流
/// 的文件清单里，挂载由 barrel 所有者完成（见 legacy_importer.dart 头注释）。
import 'package:chartools_core/src/migration/legacy_importer.dart';
// Contact/Note 的新版模型本体在 kb_models（legacy_importer 只 import 不 re-export），
// 测试要直接构造既有库样例，故同走 src 路径直引。
import 'package:chartools_core/src/persona_kb/kb_models.dart';
import 'package:test/test.dart';

void main() {
  group('内容 hash（内置 SHA-256）', () {
    // 内置实现的正确性不能靠「看起来对」：钉两个 FIPS 校准向量。
    test('校准向量：空串', () {
      expect(
        sha256HexOfUtf8(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('校准向量：abc', () {
      expect(
        sha256HexOfUtf8('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('归一化后同内容同 hash（多打空格不算两条）', () {
      final a =
          parseLegacyNotesJson('[{"title":"标题","content":"正文 一 二"}]').items.single;
      final b = parseLegacyNotesJson(
              '[{"title":"  标题  ","content":"正文  一   二"}]')
          .items
          .single;
      expect(noteContentHash(a), noteContentHash(b));
    });

    test('异内容异 hash；不同类别的 hash 不串门', () {
      final a =
          parseLegacyNotesJson('[{"title":"标题","content":"正文 一 二"}]').items.single;
      final c =
          parseLegacyNotesJson('[{"title":"标题","content":"内容不同"}]').items.single;
      expect(noteContentHash(a), isNot(noteContentHash(c)));

      // 同样的文本，note 与 persona 的 hash 前缀（'note'/'persona'）不同——
      // 笔记和专家永远不会互相误判成重复。
      final persona = ImportedPersona(id: 'x', name: '标题', body: '正文 一 二');
      expect(noteContentHash(a), isNot(personaContentHash(persona)));
    });
  });

  group('parseLegacyNotesJson', () {
    test('正常：字段齐全逐字落位 + 缺 id 合成', () {
      const raw = '''
[
 {"id":"a1b2c3d4e5f6","title":"客户偏好","content":"喜欢简短回复","tags":["销售","vip"],"alwaysOn":true,"enabled":false,"updatedAt":1700000000000,"type":"style_sample"},
 {"title":"","content":"只有正文的笔记"}
]
''';
      final section = parseLegacyNotesJson(raw);
      expect(section.parsed, isTrue);
      expect(section.problems, isEmpty);
      expect(section.items, hasLength(2));

      final full = section.items[0];
      expect(full.id, 'a1b2c3d4e5f6');
      expect(full.title, '客户偏好');
      expect(full.content, '喜欢简短回复');
      expect(full.tags, ['销售', 'vip']);
      expect(full.alwaysOn, isTrue);
      expect(full.enabled, isFalse);
      expect(full.updatedAt, 1700000000000);
      expect(full.type, 'style_sample');

      final synth = section.items[1];
      // 合成 id 可追溯到内容（imp-n- 前缀 + hash 前 10 位），重导同内容同 id。
      expect(synth.id, 'imp-n-${noteContentHash(synth).substring(0, 10)}');
      expect(synth.tags, isEmpty);
      expect(synth.alwaysOn, isFalse);
      expect(synth.enabled, isTrue);
      expect(synth.updatedAt, 0);
      expect(synth.type, 'note');
    });

    test('缺字段：逐字段退默认值，条目不丢（不连坐）', () {
      const raw = '''
[
 {"id":"x1","title":"只有标题"},
 {"id":"x2","content":"只有内容","tags":["a"]}
]
''';
      final section = parseLegacyNotesJson(raw);
      expect(section.problems, isEmpty);
      expect(section.items, hasLength(2));

      final x1 = section.items[0];
      expect(x1.title, '只有标题');
      expect(x1.content, '');
      expect(x1.tags, isEmpty);
      expect(x1.alwaysOn, isFalse);
      expect(x1.enabled, isTrue);
      expect(x1.updatedAt, 0);
      expect(x1.type, 'note');

      final x2 = section.items[1];
      expect(x2.title, '');
      expect(x2.content, '只有内容');
      expect(x2.tags, ['a']);
    });

    test('坏类型：能收就收、收不了退默认值；坏条目只记 problem 不连坐', () {
      const raw = '''
[
 {"id":"t1","title":123,"content":"数字标题","tags":"销售","alwaysOn":3,"enabled":"yes","updatedAt":"1700000000000","type":7},
 {"id":"t2","title":"下一条","content":"幸存者","tags":[1,"a",null,{"x":1},"a"]},
 "not-an-object",
 42
]
''';
      final section = parseLegacyNotesJson(raw);
      expect(section.parsed, isTrue);
      expect(section.items, hasLength(2));

      // t1：数字标题收成文本（与 org.json optString 的强转同向）；tags 不是
      // 数组 → 空表；alwaysOn: 3 不是 bool → 退默认 false（legacy optBoolean
      // 对数字就是退 fallback）；enabled: "yes" 不认识 → 默认 true；
      // 时间戳写成字符串 → 照收；type: 7 → "7"。
      final t1 = section.items[0];
      expect(t1.title, '123');
      expect(t1.tags, isEmpty);
      expect(t1.alwaysOn, isFalse);
      expect(t1.enabled, isTrue);
      expect(t1.updatedAt, 1700000000000);
      expect(t1.type, '7');

      // t2：tags 里的数字收成文本、null/嵌套对象跳过、重复项去重。
      final t2 = section.items[1];
      expect(t2.tags, ['1', 'a']);
      expect(t2.content, '幸存者');

      // 两个裸元素只各记一条 problem，下标指回源文件第 3、4 条。
      expect(section.problems, hasLength(2));
      expect(section.problems[0].index, 2);
      expect(section.problems[0].toString(), contains('第 3 条'));
      expect(section.problems[1].index, 3);
    });

    test('整包损坏 / 空文件：文件级 problem，parsed=false', () {
      final broken = parseLegacyNotesJson('[{"id":"broken",');
      expect(broken.parsed, isFalse);
      expect(broken.items, isEmpty);
      expect(broken.problems, hasLength(1));
      expect(broken.problems.single.index, -1);
      expect(broken.problems.single.reason, contains('不是合法 JSON'));

      final empty = parseLegacyNotesJson('   ');
      expect(empty.parsed, isFalse);
      expect(empty.problems.single.reason, contains('内容为空'));

      // 顶层是对象但没有条目数组：JSON 本身没坏，只是没东西可导。
      final shapeless = parseLegacyNotesJson('{"version":1}');
      expect(shapeless.parsed, isTrue);
      expect(shapeless.items, isEmpty);
      expect(shapeless.problems.single.reason, contains('顶层'));
    });

    test('导出工具包了一层对象也收（wrapper 容错）', () {
      final wrapped =
          parseLegacyNotesJson('{"notes":[{"title":"包裹","content":"wrapped"}]}');
      expect(wrapped.items.single.title, '包裹');
      expect(wrapped.items.single.content, 'wrapped');
    });

    test('title 与 content 双空 → 记 problem 跳过', () {
      final section = parseLegacyNotesJson('[{"id":"e1","title":" ","content":""}]');
      expect(section.items, isEmpty);
      expect(section.problems.single.reason, contains('没有标题也没有正文'));
    });
  });

  group('parseLegacyContactsJson', () {
    test('正常：全字段落位；坏类型退默认', () {
      const raw = '''
[
 {"id":"c9","name":"张三","aliases":["zs","三儿"],"apps":["com.tencent.mobileqq"],"relationship":"客户","notes":"周四结算","persona":"客气简短","autoSummary":"","updatedAt":1700000000000},
 {"name":"李四","aliases":"不是数组","apps":null,"relationship":9,"updatedAt":1.7e12}
]
''';
      final section = parseLegacyContactsJson(raw);
      expect(section.problems, isEmpty);
      expect(section.items, hasLength(2));

      final c9 = section.items[0];
      expect(c9.id, 'c9');
      expect(c9.name, '张三');
      expect(c9.aliases, ['zs', '三儿']);
      expect(c9.apps, ['com.tencent.mobileqq']);
      expect(c9.relationship, '客户');
      expect(c9.notes, '周四结算');
      expect(c9.persona, '客气简短');
      expect(c9.autoSummary, '');
      expect(c9.updatedAt, 1700000000000);

      final bad = section.items[1];
      expect(bad.aliases, isEmpty); // 不是数组 → 空表
      expect(bad.apps, isEmpty);
      expect(bad.relationship, '9'); // 数字字段值收成文本
      expect(bad.updatedAt, 1700000000000); // 1.7e12 → 取整
    });

    test('没名字的联系人记 problem 跳过（匹配不到会话，留着是死数据）', () {
      const raw = '''
[
 {"id":"c9","name":"张三"},
 {"name":""},
 {"name":"   "}
]
''';
      final section = parseLegacyContactsJson(raw);
      expect(section.items, hasLength(1));
      expect(section.problems, hasLength(2));
      expect(section.problems[0].reason, contains('没有名字'));
      expect(section.problems[1].index, 2);
    });
  });

  group('parseLegacyPersonasJson', () {
    test('v2 完整字段 + Character Card V2 兼容卡现算', () {
      const raw = '''
{"version":2,"seeded":["daily.friend"],"removed":[],"items":[
 {"id":"p1","name":"卖货专家","body":"称呼：老板\\n语气：热情","avatar":"🧑‍💼","description":"电商话术","tags":["销售"],"category":"销售","usedCount":7,"presetKey":"sales.pro","skillRefs":["s1"],"appPkgs":["com.tencent.mobileqq"],"builtin":true,"updatedAt":1700000000000},
 {"name":"空正文","body":"   "},
 {"name":"v1风格","body":"自由文本人设"}
]}
''';
      final section = parseLegacyPersonasJson(raw);
      expect(section.parsed, isTrue);
      expect(section.items, hasLength(2));
      expect(section.problems, hasLength(1));
      expect(section.problems.single.reason, contains('正文为空'));

      final p1 = section.items[0];
      expect(p1.id, 'p1');
      expect(p1.name, '卖货专家');
      expect(p1.body, '称呼：老板\n语气：热情'); // 逐字保存，含换行
      expect(p1.avatar, '🧑‍💼');
      expect(p1.description, '电商话术');
      expect(p1.tags, ['销售']);
      expect(p1.category, '销售');
      expect(p1.usedCount, 7);
      expect(p1.presetKey, 'sales.pro');
      expect(p1.skillRefs, ['s1']);
      expect(p1.appPkgs, ['com.tencent.mobileqq']);
      expect(p1.builtin, isTrue);
      expect(p1.updatedAt, 1700000000000);

      // 人设兼容 Character Card V2：正文里的「称呼/语气」键被 PersonaCard
      // 认出 → 结构化卡，字段直接可用。
      final card = p1.card();
      expect(card.structured, isTrue);
      expect(card.address, '老板');
      expect(card.tone, '热情');

      final p2 = section.items[1];
      expect(p2.name, 'v1风格');
      expect(p2.id, startsWith('imp-p-'));
    });

    test('v1 裸数组照收；缺 items 的 v2 记文件级 problem', () {
      final v1 = parseLegacyPersonasJson('[{"name":"裸条目","body":"正文"}]');
      expect(v1.parsed, isTrue);
      expect(v1.items.single.name, '裸条目');
      expect(v1.problems, isEmpty);

      final noItems = parseLegacyPersonasJson('{"version":2}');
      expect(noItems.parsed, isTrue);
      expect(noItems.items, isEmpty);
      expect(noItems.problems.single.index, -1);
    });

    test('usedCount 负数夹回 0（legacy coerceAtLeast 同语义）', () {
      final section =
          parseLegacyPersonasJson('[{"name":"负数","body":"b","usedCount":-5}]');
      expect(section.items.single.usedCount, 0);
    });

    test('没名字的人设补默认名「导入的人设」（legacy importJson 同语义）', () {
      final section = parseLegacyPersonasJson('[{"body":"自由文本"}]');
      expect(section.items.single.name, '导入的人设');
    });
  });

  group('重复检测与冲突', () {
    const notesDup = '''
[
 {"id":"n1","title":"相同","content":"一样的内容"},
 {"id":"n2","title":"相同","content":"一样的内容"},
 {"id":"n1","title":"相同","content":"另一个版本"}
]
''';

    test('包内：同内容判重复、同 id 不同文判冲突', () {
      final preview = buildMigrationPreview(
        LegacyBundle(
          notes: parseLegacyNotesJson(notesDup),
          contacts: parseLegacyContactsJson('[]'),
          personas: parseLegacyPersonasJson('[]'),
        ),
      );
      final statuses = preview.notes.map((i) => i.status).toList();
      expect(statuses, [
        MigrationStatus.insert,
        MigrationStatus.duplicate,
        MigrationStatus.conflict,
      ]);
      expect(preview.notes[1].detail, contains('与包内第 1 条内容相同'));
      expect(preview.notes[2].detail, contains('同键（n1）'));
      expect(preview.notes[2].detail, contains('包内第 1 条'));
    });

    test('对既有数据：hash 相同判重复（无损跳过优先于人工裁决）', () {
      final parsed = parseLegacyNotesJson(notesDup);
      final preview = buildMigrationPreview(
        LegacyBundle(
          notes: parsed,
          contacts: parseLegacyContactsJson('[]'),
          personas: parseLegacyPersonasJson('[]'),
        ),
        existing: LegacyExistingIndex.fromData(notes: [parsed.items.first]),
      );
      expect(preview.notes[0].status, MigrationStatus.duplicate);
      expect(preview.notes[0].detail, contains('新版已有数据'));
      expect(preview.notes[1].status, MigrationStatus.duplicate);
      expect(preview.notes[2].status, MigrationStatus.conflict);
    });

    test('联系人：同名不同文冲突，同文重复；零宽字符不迷惑名字判定', () {
      const raw = '''
[
 {"name":"张三","notes":"v1"},
 {"name":"张三","notes":"v2"},
 {"name":"张三","notes":"v1"},
 {"name":"李四\u200B","notes":"a"}
]
''';
      // 既有库里有一个「李四」（无零宽字符）；包内那条带 U+200B——
      // 归一化后同名同文，必须判重复而不是混进两条「李四」。
      final existing = LegacyExistingIndex.fromData(contacts: [
        const Contact(id: 'e1', name: '李四', notes: 'a'),
      ]);
      final preview = buildMigrationPreview(
        LegacyBundle(
          notes: parseLegacyNotesJson('[]'),
          contacts: parseLegacyContactsJson(raw),
          personas: parseLegacyPersonasJson('[]'),
        ),
        existing: existing,
      );
      expect(preview.contacts[0].status, MigrationStatus.insert);
      expect(preview.contacts[1].status, MigrationStatus.conflict);
      expect(preview.contacts[2].status, MigrationStatus.duplicate);
      expect(preview.contacts[2].detail, contains('包内第 1 条'));
      expect(preview.contacts[3].status, MigrationStatus.duplicate);
      expect(preview.contacts[3].detail, contains('新版已有数据'));
    });

    test('重导幂等：确认过的集合再导一遍 → 全部判重复，零新增', () {
      const previewNotes = '''
[
 {"id":"n1","title":"笔记一","content":"内容一"},
 {"id":"n1","title":"笔记一","content":"内容一"},
 {"id":"n2","title":"笔记二","content":"内容二"}
]
''';
      const previewContacts = '''
[
 {"id":"k1","name":"客户甲","notes":"老客户"},
 {"id":"k2","name":"客户甲","notes":"新备注"}
]
''';
      const previewPersonas = '''
{"version":2,"items":[
 {"name":"专家一","body":"称呼：老板"},
 {"name":"专家二","body":"  "}
]}
''';
      final bundle = collectLegacyBundle(
        notesJson: previewNotes,
        contactsJson: previewContacts,
        personasJson: previewPersonas,
      );
      final first = buildMigrationPreview(bundle);
      expect(first.importCount, 4);
      expect(first.duplicateCount, 1);
      expect(first.conflictCount, 1);
      expect(first.problems, hasLength(1)); // 专家二正文为空

      final second = buildMigrationPreview(
        bundle,
        existing: LegacyExistingIndex.fromData(
          notes: first.confirmedNotes,
          contacts: first.confirmedContacts,
          personas: first.confirmedPersonas,
        ),
      );
      // 上轮确认入库的 4 条（n1/n2/k1/专家一）全部变重复；上轮没确认的
      // 冲突项（k2）原样再冲突——不确认就不消失，也不悄悄入库。
      expect(second.importCount, 0);
      expect(second.duplicateCount, 5);
      expect(second.conflictCount, 1);
      expect(second.problems, hasLength(1));
    });
  });

  group('迁移预览与 G8 确认集', () {
    test('describe 一句话报清 N/M/K 与问题数', () {
      final bundle = collectLegacyBundle(
        notesJson: '''
[
 {"id":"n1","title":"笔记一","content":"内容一"},
 {"id":"n1","title":"笔记一","content":"内容一"},
 {"id":"n2","title":"笔记二","content":"内容二"}
]
''',
        contactsJson: '''
[
 {"id":"k1","name":"客户甲","notes":"老客户"},
 {"id":"k2","name":"客户甲","notes":"新备注"}
]
''',
        // 故意带一条空正文的人设：问题数也要进摘要。
        personasJson:
            '{"version":2,"items":[{"name":"专家一","body":"称呼：老板"},{"name":"空壳","body":" "}]}',
      );
      final preview = buildMigrationPreview(bundle);
      expect(preview.describe(),
          '将导入 4 条，跳过 1 条重复，1 条冲突待确认，另有 1 条问题已记录。');
    });

    test('confirmed 集合只含 insert——冲突/重复不确认不落盘（G8）', () {
      final bundle = collectLegacyBundle(
        notesJson: '''
[
 {"id":"n1","title":"笔记一","content":"内容一"},
 {"id":"n1","title":"笔记一","content":"内容一"},
 {"id":"n2","title":"笔记二","content":"内容二"}
]
''',
        contactsJson: '''
[
 {"id":"k1","name":"客户甲","notes":"老客户"},
 {"id":"k2","name":"客户甲","notes":"新备注"}
]
''',
        personasJson: '{"version":2,"items":[{"name":"专家一","body":"称呼：老板"}]}',
      );
      final preview = buildMigrationPreview(bundle);

      expect(
        preview.confirmedNotes.map((n) => n.id).toList(),
        ['n1', 'n2'], // 重复那条（第二个 n1 内容）不在确认集
      );
      expect(preview.confirmedContacts.map((c) => c.id).toList(), ['k1']);
      expect(preview.confirmedPersonas.map((p) => p.name).toList(), ['专家一']);
    });

    test('缺文件：collectLegacyBundle 给文件级 problem，其余照常', () {
      final partial = collectLegacyBundle(notesJson: '[{"title":"t","content":"c"}]');
      final preview = buildMigrationPreview(partial);
      expect(preview.importCount, 1);
      expect(
        preview.problems
            .where((p) => p.file == 'contacts.json' && p.reason.contains('没有这个文件')),
        isNotEmpty,
      );
      expect(
        preview.problems
            .where((p) => p.file == 'personas.json' && p.reason.contains('没有这个文件')),
        isNotEmpty,
      );
    });

    test('空包：describe 报「没有可导入的数据」', () {
      final preview = buildMigrationPreview(collectLegacyBundle(
        notesJson: '[]',
        contactsJson: '[]',
        personasJson: '[]',
      ));
      expect(preview.isEmpty, isTrue);
      expect(preview.describe(), '迁移包里没有可导入的数据。');
    });
  });

  group('manifest 校验（ZIP 层格式校验的 core 半边）', () {
    const manifestOk = '''
{"kind":"chartools-legacy-export","version":1,"fromPackage":"com.jev.probe","exportedAt":1700000000000,
 "files":{"notes.json":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
 "counts":{"notes":1}}
''';

    test('合法 manifest：kind/version/来源包名/文件清单落位', () {
      final check = parseLegacyManifestJson(manifestOk);
      expect(check.ok, isTrue);
      expect(check.manifest!.fromPackage, 'com.jev.probe');
      expect(check.manifest!.exportedAt, 1700000000000);
      expect(check.manifest!.declares('notes.json'), isTrue);
      // 未知文件一律不在清单里——防夹带。
      expect(check.manifest!.declares('logs/c1.json'), isFalse);
      expect(check.manifest!.declares('../../../evil.exe'), isFalse);
    });

    test('文件内容对拍 manifest hash（大小写不敏感；没登记/长度不对 → false）', () {
      expect(
        verifyLegacyFileHash(
            'abc', 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'),
        isTrue,
      );
      expect(verifyLegacyFileHash('abc', 'deadbeef'), isFalse); // 长度不对
      expect(verifyLegacyFileHash('abc', ''), isFalse); // 没登记
      expect(verifyLegacyFileHash('abc', 'ff' * 32), isFalse); // 等长但错的 hash
    });

    test('kind 不对 / 版本超前 / 不是 JSON → 整包拒绝', () {
      final wrongKind =
          parseLegacyManifestJson('{"kind":"some-other-zip","version":1}');
      expect(wrongKind.ok, isFalse);
      expect(wrongKind.problem, contains('不是 chartools 迁移包'));

      final future =
          parseLegacyManifestJson('{"kind":"chartools-legacy-export","version":2}');
      expect(future.ok, isFalse);
      expect(future.problem, contains('请先升级'));

      final garbage = parseLegacyManifestJson('nope{');
      expect(garbage.ok, isFalse);
      expect(garbage.problem, contains('不是合法 JSON'));
    });
  });
}

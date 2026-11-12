// 人设库控制器的单测：composedBody ↔ PersonaCard 键的对应、CCV2 导入预览
// 与确认导入的字段映射、复制/删除、持久化 round trip。
//
// fake 注入：只依赖 shared_preferences，用 SharedPreferences.setMockInitialValues
// 提供内存存档（与 contact_store_test.dart 同一口径）。PersonaCard 来自 core
//（零第三方依赖）：entry.card() 的返回类型，这里用它断言「组装的正文真的
// 能被解析成结构化卡」（类型经推断引入，无需显式 import）。
import 'dart:convert';

import 'package:chartools_app/application/personas_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PersonaEntry.composedBody ↔ PersonaCard', () {
    test('六个编辑字段组装成键式正文，parse 后逐字段认得', () {
      const entry = PersonaEntry(
        id: 'p1',
        name: '测试',
        address: '叫我主人，我称你乖',
        relation: '网调关系，我定规矩',
        tone: '短句、命令式，不解释',
        boundaries: ['家人', '前任'],
        avoid: ['稳赚', '保证收益'],
        safeword: '红灯',
      );
      final card = entry.card();
      expect(card.structured, isTrue, reason: '六个键都在，必须解析成结构化卡');
      expect(card.address, '叫我主人，我称你乖');
      expect(card.relation, '网调关系，我定规矩');
      expect(card.tone, '短句、命令式，不解释');
      // PersonaCard 的关键词展开只在它那一层做：条目存原词，闸门拿展开词。
      expect(card.boundaries, containsAll(['家人', '前任']));
      expect(card.avoid, containsAll(['稳赚', '保证收益']));
      expect(card.safeword, '红灯');
      // promptText 预览与真实进提示词的东西同一条路径。
      final preview = entry.promptPreview();
      expect(preview, startsWith('<persona_card>'));
      expect(preview, contains('称呼：叫我主人，我称你乖'));
      expect(preview, contains('硬边界（这些内容绝不可以出现在回复里）：家人、前任'));
      expect(preview, contains('安全词：红灯'));
    });

    test('开场白以「对方：」示例行进 PersonaCard 的 examples', () {
      const entry = PersonaEntry(
        id: 'p2',
        name: '带开场白',
        firstMes: '今晚的银河很清楚，要一起看吗？',
      );
      final card = entry.card();
      expect(card.examples, contains('对方：今晚的银河很清楚，要一起看吗？'));
    });

    test('自由补充里的带键行（情境/主题）仍被 PersonaCard 认出', () {
      const entry = PersonaEntry(
        id: 'p3',
        name: '补充带键',
        tone: '温和',
        extraBody: '主题：网调\n随便一句散文',
      );
      final card = entry.card();
      expect(card.structured, isTrue);
      expect(card.topic, '网调');
      expect(card.extra, contains('随便一句散文'));
    });

    test('blurb：简介优先；没简介就取正文第一行并剥掉短键名', () {
      const withDesc = PersonaEntry(id: 'a', name: 'a', description: '一句话简介');
      expect(withDesc.blurb(), '一句话简介');
      const noDesc = PersonaEntry(id: 'b', name: 'b', address: '小明');
      expect(noDesc.blurb(), '小明');
    });
  });

  group('Ccv2Preview.parse（Character Card V2 兼容）', () {
    test('CCV2 包裹（spec + data）全部字段读出', () {
      final p = Ccv2Preview.parse(jsonEncode({
        'spec': 'chara_card_v2',
        'spec_version': '2.0',
        'data': {
          'name': '夜航星',
          'description': '一位沉稳的星空摄影师',
          'persona': '称呼：小航',
          'first_mes': '今晚的银河很清楚。',
        },
      }));
      expect(p.ok, isTrue);
      expect(p.name, '夜航星');
      expect(p.description, '一位沉稳的星空摄影师');
      expect(p.persona, '称呼：小航');
      expect(p.firstMes, '今晚的银河很清楚。');
      expect(p.specVersion, '2.0');
    });

    test('V1 别名（char_name / char_persona）与裸对象也认', () {
      final p = Ccv2Preview.parse(jsonEncode({
        'char_name': '旧版卡',
        'char_persona': '称呼：你',
        'first_mes': '你好',
      }));
      expect(p.ok, isTrue);
      expect(p.name, '旧版卡');
      expect(p.persona, '称呼：你');
    });

    test('非法 JSON / 缺 name 收敛成 problem，绝不外抛', () {
      expect(Ccv2Preview.parse('not json').ok, isFalse);
      expect(Ccv2Preview.parse('{"description":"无名"}').ok, isFalse);
      expect(Ccv2Preview.parse('{"description":"无名"}').problem,
          contains('缺 name'));
      expect(Ccv2Preview.parse('').problem, contains('为空'));
    });
  });

  group('CCV2 确认导入的字段映射', () {
    const cardJson = '''
{
  "spec": "chara_card_v2",
  "spec_version": "2.0",
  "data": {
    "name": "夜航星",
    "description": "一位沉稳的星空摄影师",
    "personality": "温和、话少",
    "scenario": "山顶露营的深夜",
    "persona": "称呼：小航\\n关系：旅伴\\n语气：被 personality 覆盖前先读这行\\n硬边界：不聊工作、不聊薪资\\n避谈：加班\\n情境：这条情境行认不出键时原样进补充",
    "first_mes": "今晚的银河很清楚，要一起看吗？"
  }
}
''';

    test('persona 六键 + personality + scenario + description 各就各位', () async {
      SharedPreferences.setMockInitialValues({});
      final c = PersonasController();
      final p = c.previewCcv2(cardJson);
      expect(p.ok, isTrue);
      final entry = await c.importCcv2(p);

      expect(entry.name, '夜航星');
      expect(entry.address, '小航');
      expect(entry.relation, '旅伴');
      // persona 里已有语气：personality 不覆盖既有值。
      expect(entry.tone, '被 personality 覆盖前先读这行');
      expect(entry.boundaries, ['不聊工作', '不聊薪资']);
      expect(entry.avoid, ['加班']);
      expect(entry.firstMes, '今晚的银河很清楚，要一起看吗？');
      // 来源追踪：ccv2 + spec_version。
      expect(entry.sourceRef, 'ccv2:2.0');
      // scenario → 「情境：」键行进补充；认不出键的行与 description 原样保留。
      expect(entry.extraBody, contains('情境：山顶露营的深夜'));
      expect(entry.extraBody, contains('情境：这条情境行认不出键时原样进补充'));
      expect(entry.extraBody, contains('一位沉稳的星空摄影师'));
      // 组装后的正文再过 PersonaCard：情境被认成 scene，示例认到开场白。
      final card = entry.card();
      expect(card.structured, isTrue);
      expect(card.scene, '山顶露营的深夜');
      expect(card.examples, contains('对方：今晚的银河很清楚，要一起看吗？'));
    });

    test('重名导入自动加「（导入）」后缀；personality 只在缺语气时补位', () async {
      SharedPreferences.setMockInitialValues({});
      final c = PersonasController();
      final p = c.previewCcv2(cardJson);
      await c.importCcv2(p);
      final second = await c.importCcv2(p);
      expect(second.name, '夜航星（导入）');

      final p3 = c.previewCcv2(jsonEncode({
        'spec_version': '2.0',
        'data': {
          'name': '无语气卡',
          'personality': '冷淡、简短',
          'first_mes': '嗯。',
        },
      }));
      final entry3 = await c.importCcv2(p3);
      // persona 没有语气行：personality 补位进语气。
      expect(entry3.tone, '冷淡、简短');
    });

    test('未通过预览的导入被闸住（G8：确认才入库）', () async {
      SharedPreferences.setMockInitialValues({});
      final c = PersonasController();
      final bad = c.previewCcv2('not json');
      expect(bad.ok, isFalse);
      await expectLater(c.importCcv2(bad), throwsFormatException);
      expect(c.entries.value, isEmpty);
    });
  });

  group('增改删复制与持久化', () {
    test('create/update/duplicate/remove 全链路', () async {
      SharedPreferences.setMockInitialValues({});
      final c = PersonasController();
      final e = await c.create(
        name: '甲',
        address: '先生',
        boundaries: ['家人'],
      );
      final updated =
          await c.update(e.copyWith(relation: '朋友')).then((_) => c.byId(e.id)!);
      expect(updated.relation, '朋友');
      // updatedAt 严格递增：同一毫秒连续两次 update 也要产出新实例。
      await c.update(updated);
      expect(c.byId(e.id)!.updatedAt, greaterThan(updated.updatedAt));

      final copy = await c.duplicate(e.id);
      expect(copy, isNotNull);
      expect(copy!.name, '甲（副本）');
      expect(copy.address, '先生'); // 内容继承
      expect(copy.sourceRef, e.sourceRef); // 出处继承（来源追踪）
      expect(copy.id, isNot(e.id));

      await c.remove(e.id);
      expect(c.byId(e.id), isNull);
      expect(c.entries.value, hasLength(1));
      // 幂等：再删不存在的不炸。
      await c.remove(e.id);
      expect(await c.duplicate('no-such-id'), isNull);
    });

    test('update 不存在的 id 抛 StateError（不是 upsert）', () async {
      SharedPreferences.setMockInitialValues({});
      final c = PersonasController();
      await expectLater(c.update(const PersonaEntry(id: 'ghost', name: '幽灵')),
          throwsStateError);
    });

    test('持久化 round trip：新控制器 load 还原全部结构化字段', () async {
      SharedPreferences.setMockInitialValues({});
      final c1 = PersonasController();
      await c1.create(
        name: '持久化卡',
        description: '仅浏览简介',
        address: '你',
        relation: '朋友',
        tone: '松弛',
        boundaries: ['家人', '前任'],
        avoid: ['鸡汤'],
        safeword: '暂停',
        firstMes: '在吗',
        extraBody: '情境：深夜私聊',
      );
      final c2 = PersonasController();
      await c2.load();
      expect(c2.entries.value, hasLength(1));
      final e = c2.entries.value.first;
      expect(e.name, '持久化卡');
      expect(e.address, '你');
      expect(e.boundaries, ['家人', '前任']);
      expect(e.safeword, '暂停');
      expect(e.extraBody, '情境：深夜私聊');
      expect(e.card().scene, '深夜私聊');
    });

    test('坏存档不挡启动：JSON 损坏按空清单处理', () async {
      SharedPreferences.setMockInitialValues({'personas': '{broken'});
      final c = PersonasController();
      await c.load();
      expect(c.entries.value, isEmpty);
    });
  });
}

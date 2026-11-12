import 'dart:convert';
import 'dart:io';

import 'package:chartools_core/src/persona_kb/expert_apply.dart';
import 'package:chartools_core/src/persona_kb/expert_catalog.dart';
import 'package:chartools_core/src/persona_kb/expert_pack.dart';
import 'package:chartools_core/src/persona_kb/kb_models.dart';
import 'package:chartools_core/src/persona_kb/persona_card.dart';
import 'package:chartools_core/src/persona_kb/style_source.dart';
import 'package:test/test.dart';

// 说明：直接 import src/ 而不是 barrel（usage_stats_test.dart 的同一先例）——
// 并行工作流正在改 barrel 与 pipeline 文件，本文件不应被它们的中间态拖红。

/// 内存全局 style 通道（ExpertApply 的正常测试实现）。
class MemSink implements StyleSink {
  MemSink([this.initial = '']);
  final String initial;
  String _current = '';
  bool _touched = false;
  @override
  String get style => _touched ? _current : initial;
  @override
  set style(String v) {
    _touched = true;
    _current = v;
  }
}

/// 前 [failures] 次写抛异常、之后正常的 sink：用来逼出「写失败 → 回滚 → 重试」。
class FlakySink implements StyleSink {
  FlakySink(this.initial, {this.failures = 1});
  final String initial;
  int failures;
  String _current = '';
  bool _touched = false;
  @override
  String get style => _touched ? _current : initial;
  @override
  set style(String v) {
    _touched = true;
    if (failures > 0) {
      failures--;
      throw StateError('磁盘满了');
    }
    _current = v;
  }
}

/// 专家库（目录 / 按需资产包 / 套用）的回归防护。
///
/// 五组被钉住的行为（任务规格）：目录加载、领域/标签搜索、资产包安装卸载、
/// 校验失败容错、套用优先级（覆盖/并存，复用 StyleSource.resolve 的语义）。
/// 内置目录用**真实的 assets/experts/catalog.json** 喂进来——legacy 的教训
/// （ExpertPack.kt 类注释）：解析器要被真文件逼，不要只喂构造出来的理想 JSON。
void main() {
  // ------------------------------------------------------------- 测试夹具

  /// 从 cwd 向上找内置目录 assets（覆盖「从 packages/core 跑」与「从工作区
  /// 根跑」两种 cwd；找不到就大声失败，不静默跳过）。
  String findAsset() {
    var dir = Directory.current;
    for (var i = 0; i < 8; i++) {
      for (final rel in const [
        'assets/experts/catalog.json',
        'packages/core/assets/experts/catalog.json',
      ]) {
        final f = File('${dir.path}/$rel');
        if (f.existsSync()) return f.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    fail('找不到 packages/core/assets/experts/catalog.json'
        '（cwd=${Directory.current.path}）');
  }

  final rawCatalog = File(findAsset()).readAsStringSync();

  /// 远端资产包夹具：一个最小合法清单。
  Map<String, Object?> packMap({
    String format = 'jev-expert-pack/1',
    Map<String, Object?>? pack,
    Object? experts,
  }) =>
      {
        'format': format,
        'pack': pack ??
            {
              'id': 'sales-pro',
              'version': '1.0.0',
              'name': '销售话术包',
              'origin': 'remote',
            },
        'experts': experts ??
            [
              {
                'id': 'follow',
                'name': '跟单',
                'domain': '销售',
                'tags': ['跟单'],
                'promptText': '称呼：姓＋总\n主题：销售\n示例：\n我：方案改完了',
              },
            ],
      };

  String packJson({
    String format = 'jev-expert-pack/1',
    Map<String, Object?>? pack,
    Object? experts,
  }) =>
      jsonEncode(packMap(format: format, pack: pack, experts: experts));

  Expert builtinExpert(String key) {
    final shelf = ExpertCatalog.loadBuiltin(readAsset: (_) => rawCatalog);
    return shelf.experts.firstWhere((e) => e.key == key);
  }

  const contactNoPersona = Contact(id: 'c1', name: '王总', relationship: '客户', notes: '在跟单');
  const contactWithPersona = Contact(
    id: 'c2',
    name: '李姐',
    relationship: '客户',
    persona: '称呼：李姐\n语气：客气但直接',
  );

  /// 合成一个「自定义领域包」货架（含一个没写 domain 的条目）。
  List<Expert> extraShelf() => ExpertCatalog.parseShelf(jsonEncode({
        'format': 'jev-expert-pack/1',
        'pack': {'id': 'x', 'version': '1.0.0'},
        'experts': [
          {'id': 'a', 'domain': '投放广告', 'promptText': '正文'},
          {'id': 'b', 'promptText': '正文'},
        ],
      })).experts;

  // ======================================================================
  // 1. 目录加载（真实 assets 文件）
  // ======================================================================
  group('内置目录加载', () {
    test('真实 assets JSON：5 位示例专家、包元数据齐全、来源追踪到位', () {
      final shelf = ExpertCatalog.loadBuiltin(readAsset: (_) => rawCatalog);
      expect(shelf.ok, isTrue, reason: shelf.problem);
      expect(shelf.problem, '');
      expect(shelf.experts, hasLength(5));
      expect(shelf.meta!.id, 'builtin');
      expect(shelf.meta!.version, '1.0.0');
      expect(shelf.meta!.origin, ExpertOrigin.builtin);
      for (final e in shelf.experts) {
        expect(e.source.packId, 'builtin', reason: e.id);
        expect(e.source.packVersion, '1.0.0');
        expect(e.isBuiltin, isTrue);
        expect(e.id, startsWith('pack:builtin/'), reason: e.id);
        // 铁律形状：必填字段齐。
        expect(e.name, isNotEmpty);
        expect(e.promptText, isNotEmpty);
      }
      expect(
        shelf.experts.map((e) => e.key),
        containsAll(['daily.friend', 'love.coldwar', 'sales.followup']),
      );
    });

    test('不注入 readAsset 时走磁盘探测（VM / 测试 / 桌面路径）', () {
      expect(
        readBuiltinCatalogJson(),
        isNotNull,
        reason: '从包根或工作区根跑都应能沿父目录找到 assets 文件',
      );
      final shelf = ExpertCatalog.loadBuiltin();
      expect(shelf.ok, isTrue, reason: shelf.problem);
    });

    test('读不到时返回空货架 + problem，绝不抛', () {
      final shelf = ExpertCatalog.loadBuiltin(
        readAsset: (path) => throw StateError('资源没打包'),
      );
      expect(shelf.ok, isFalse);
      expect(shelf.experts, isEmpty);
      expect(shelf.problem, contains('读不到内置目录 JSON'));
    });

    test('readBuiltinCatalogJson：注入的实现抛异常也收敛成 null', () {
      expect(
        readBuiltinCatalogJson(readAsset: (_) => throw Exception('x')),
        isNull,
      );
    });
  });

  // ======================================================================
  // 2. 解析容错（浏览路径宽容、安装路径严格）
  // ======================================================================
  group('解析容错', () {
    test('parseShelf：结构级损坏逐个拒绝，不抛', () {
      final cases = <(String, String)>[
        ('', '目录为空'),
        ('   ', '目录为空'),
        ('这不是json', '不是合法 JSON'),
        ('[1,2,3]', '顶层必须是 JSON 对象'),
        (
          jsonEncode({
            'format': 'jev-expert-pack/1',
            'pack': {'id': 'a', 'version': '1.0.0'},
          }),
          '缺少 experts 数组'
        ),
        (
          jsonEncode({
            'format': 'jev-expert-pack/1',
            'pack': {'id': 'a', 'version': '1.0.0'},
            'experts': <Object>[],
          }),
          '没有可用专家'
        ),
      ];
      for (final (raw, why) in cases) {
        final r = ExpertCatalog.parseShelf(raw);
        expect(r.ok, isFalse, reason: why);
        expect(r.problem, isNotEmpty, reason: why);
      }
    });

    test('parseShelf：坏条目跳过并计数，好条目照常上货架', () {
      final r = ExpertCatalog.parseShelf(jsonEncode({
        'format': 'jev-expert-pack/1',
        'pack': {'id': 'p1', 'version': '1.0.0'},
        'experts': [
          '不是对象',
          {'id': '', 'promptText': '没 id'},
          {'id': 'no/body', 'promptText': 'id 带 /'},
          {'id': 'nobody', 'promptText': '   '},
          {'id': 'ok1', 'promptText': '称呼：您'},
          {'id': 'ok1', 'promptText': '重复 id 按坏条目跳过'},
          {'id': 'ok2', 'promptText': '称呼：您'},
        ],
      }));
      expect(r.experts.map((e) => e.key), ['ok1', 'ok2']);
      expect(r.skipped, 5);
      expect(r.problem, contains('5 条'));
      expect(r.meta!.id, 'p1');
    });

    test('parseShelf：缺 name 回退到 id；promptText 逐字保存不 trim', () {
      final r = ExpertCatalog.parseShelf(jsonEncode({
        'format': 'jev-expert-pack/1',
        'pack': {'id': 'p1', 'version': '1.0.0'},
        'experts': [
          {'id': 'k1', 'promptText': '正文带尾随空格 '},
          {'id': 'k2', 'name': '有名字', 'promptText': '正文'},
        ],
      }));
      expect(r.experts[0].name, 'k1', reason: '名字缺省回退到 id');
      expect(r.experts[0].promptText, '正文带尾随空格 ', reason: '逐字保存');
      expect(r.experts[1].name, '有名字');
    });

    test('parseShelf：缺 pack 对象仍能出货架，但 problem 要说明来源缺失', () {
      final r = ExpertCatalog.parseShelf(jsonEncode({
        'format': 'jev-expert-pack/1',
        'experts': [
          {'id': 'k1', 'promptText': '正文'},
        ],
      }));
      expect(r.ok, isTrue);
      expect(r.meta, isNull);
      expect(r.problem, contains('缺少 pack'));
      expect(r.experts[0].source.packId, '');
    });

    test('PackCodec：清单级字段缺一即拒（安装路径严格）', () {
      final cases = <(Object, String)>[
        ('', '清单是空的'),
        ('nope', '不是合法 JSON'),
        (packMap(format: 'jev-expert-pack/2'), '格式不支持'),
        (packMap()..remove('format'), '缺少 format'),
        (packMap(pack: {'version': '1.0.0'}), '缺少 pack.id'),
        (packMap(pack: {'id': 'a/b', 'version': '1.0.0'}), '不能包含'),
        (packMap(pack: {'id': 'a'}), '缺少 pack.version'),
        (packMap(experts: '不是数组'), '缺少 experts 数组'),
      ];
      for (final (mapOrRaw, why) in cases) {
        final rawJson = mapOrRaw is String ? mapOrRaw : jsonEncode(mapOrRaw);
        final r = PackCodec.parse(rawJson);
        expect(r.ok, isFalse, reason: why);
        expect(r.problem, contains(why), reason: '$why => ${r.problem}');
        expect(r.pack, isNull);
      }
    });

    test('PackCodec：可用但带坏条目 → pack 非空、problem 是警告', () {
      final r = PackCodec.parse(jsonEncode({
        'format': 'jev-expert-pack/1',
        'pack': {'id': 'p1', 'version': '1.0.0'},
        'experts': [
          {'id': 'ok', 'promptText': '正文'},
          '垃圾',
        ],
      }));
      expect(r.ok, isTrue);
      expect(r.pack!.experts, hasLength(1));
      expect(r.problem, contains('1 条'));
    });

    test('PackCodec：entry 别名互认——key/body 与 id/promptText 同批解析', () {
      // 独立复核裁定（docs/expert-pack-format.md §2）：app/legacy 拼写与
      // core 主拼写必须在两条解析路径里认出同一批专家，否则同一份远端包
      // 会在一边全量跳过。
      final r = PackCodec.parse(jsonEncode({
        'format': 'jev-expert-pack/1',
        'pack': {'id': 'mixed', 'version': '1.0.0'},
        'experts': [
          {'id': 'a', 'promptText': '正文甲'},
          {'key': 'b', 'body': '正文乙'},
          {'id': 'c', 'body': '正文丙'},
          {'key': 'd', 'promptText': '正文丁'},
        ],
      }));
      expect(r.ok, isTrue, reason: r.problem);
      expect(r.pack!.experts.map((e) => e.key).toList(), ['a', 'b', 'c', 'd']);
      expect(r.pack!.experts.map((e) => e.promptText).toList(),
          ['正文甲', '正文乙', '正文丙', '正文丁']);
      expect(r.problem, '');
    });

    test('PackCodec：experts[] 超上限 → 上限内解析、其余计数跳过', () {
      final experts = <Object?>[
        for (var i = 0; i < PackCodec.maxExpertsPerPack + 5; i++)
          {'id': 'k$i', 'promptText': '正文 $i'},
      ];
      final r = PackCodec.parse(jsonEncode({
        'format': 'jev-expert-pack/1',
        'pack': {'id': 'big', 'version': '1.0.0'},
        'experts': experts,
      }));
      expect(r.ok, isTrue);
      expect(r.pack!.experts, hasLength(PackCodec.maxExpertsPerPack));
      expect(r.skipped, 5);
      expect(r.problem, contains('5 条'));
    });

    test('PackCodec：单条 promptText 超 64KiB 护栏 → 按坏条目跳过', () {
      final r = PackCodec.parse(jsonEncode({
        'format': 'jev-expert-pack/1',
        'pack': {'id': 'big-body', 'version': '1.0.0'},
        'experts': [
          {'id': 'ok', 'promptText': '正文'},
          {'id': 'huge', 'promptText': 'a' * (expertPromptTextMaxBytes + 1)},
        ],
      }));
      expect(r.ok, isTrue, reason: r.problem);
      expect(r.pack!.experts, hasLength(1));
      expect(r.pack!.experts.single.key, 'ok');
      expect(r.problem, contains('1 条'));
    });

    test('PackCodec.compareVersions：点分段数字比较（比较器错了会静默降级）', () {
      expect(PackCodec.compareVersions('1.2.10', '1.2.9'), greaterThan(0));
      expect(PackCodec.compareVersions('1.0', '1.0.0'), 0);
      expect(PackCodec.compareVersions('2.0', '1.9.9'), greaterThan(0));
      expect(PackCodec.compareVersions('0.9', '1.0'), lessThan(0));
      expect(PackCodec.compareVersions('1.0.0', '1.0.0'), 0);
    });
  });

  // ======================================================================
  // 3. 搜索（领域 / 标签 / 关键词）
  // ======================================================================
  group('搜索', () {
    final experts =
        ExpertCatalog.loadBuiltin(readAsset: (_) => rawCatalog).experts;

    test('domains：五类按固定序出现，自定义领域排后、未分类殿后', () {
      expect(
          ExpertCatalog.domains(experts), ['情感', '销售', '职场', '客服', '日常']);
      expect(ExpertCatalog.domains([...experts, ...extraShelf()]),
          ['情感', '销售', '职场', '客服', '日常', '投放广告', '未分类']);
    });

    test('filter：按领域筛；「全部」与缺省不筛', () {
      expect(
        ExpertCatalog.filter(experts, domain: '销售').map((e) => e.key),
        ['sales.followup'],
      );
      expect(ExpertCatalog.filter(experts, domain: '全部'), hasLength(5));
      expect(ExpertCatalog.filter(experts), hasLength(5));
      // 自定义领域包里那位没写 domain 的，用「未分类」能筛出来。
      expect(ExpertCatalog.filter(extraShelf(), domain: '未分类').map((e) => e.key),
          ['b']);
    });

    test('filter：按标签精确筛（不是 contains）', () {
      expect(
        ExpertCatalog.filter(experts, tag: '跟单').map((e) => e.key),
        ['sales.followup'],
      );
      expect(ExpertCatalog.filter(experts, tag: '跟'), isEmpty);
    });

    test('matches：名字/简介/标签/正文都算，大小写不敏感', () {
      final sales = builtinExpert('sales.followup');
      expect(ExpertCatalog.matches(sales, '跟单'), isTrue, reason: '名字');
      expect(ExpertCatalog.matches(sales, '不催不捧'), isTrue, reason: '简介');
      expect(ExpertCatalog.matches(sales, '稳赚'), isTrue, reason: '正文（避谈词）');
      expect(ExpertCatalog.matches(sales, ''), isTrue, reason: '空 = 不筛');
      final work = builtinExpert('work.report');
      expect(ExpertCatalog.matches(work, 'x 总'), isTrue, reason: '大小写');
      expect(ExpertCatalog.matches(sales, '不存在的东西'), isFalse);
    });

    test('browse：筛选 + 排序的组合动作，交集语义', () {
      expect(ExpertCatalog.browse(experts, query: '客户').map((e) => e.key),
          contains('service.complaint'));
      final one = ExpertCatalog.browse(experts, domain: '客服', query: '客户');
      expect(one.map((e) => e.key), ['service.complaint']);
    });

    test('tags：按出现次数多在前（同次数按名字）', () {
      const src = ExpertSource(packId: 'p', packVersion: '1');
      final e1 = Expert(
        id: 'pack:p/a', key: 'a', name: 'A', domain: '', promptText: 'x',
        tags: const ['热词', '冷词'], source: src,
      );
      final e2 = Expert(
        id: 'pack:p/b', key: 'b', name: 'B', domain: '', promptText: 'x',
        tags: const ['热词'], source: src,
      );
      expect(ExpertCatalog.tags([e1, e2]), ['热词', '冷词']);
    });
  });

  // ======================================================================
  // 4. 排序与评分（usage 由 app 层注入的钩子位）
  // ======================================================================
  group('排序与评分', () {
    const builtinSrc =
        ExpertSource(packId: 'builtin', packVersion: '1.0.0', origin: ExpertOrigin.builtin);
    const remoteSrc = ExpertSource(packId: 'rp', packVersion: '1.0.0');
    const a = Expert(
        id: 'pack:builtin/a', key: 'a', name: '甲', domain: '日常',
        promptText: '甲', source: builtinSrc);
    const b = Expert(
        id: 'pack:rp/b', key: 'b', name: '乙', domain: '销售',
        promptText: '乙', source: remoteSrc);
    const c = Expert(
        id: 'pack:rp/c', key: 'c', name: '丙', domain: '销售',
        promptText: '丙', source: remoteSrc);

    test('score：一次套用顶 3 分，内置 +2', () {
      expect(ExpertCatalog.score(a, {}), 2);
      expect(ExpertCatalog.score(b, {}), 0);
      expect(ExpertCatalog.score(b, {b.id: 1}), 3);
      expect(ExpertCatalog.score(b, {b.id: 2}), 6);
      // 负数计数按 0（外部数据不可信）。
      expect(ExpertCatalog.score(b, {b.id: -5}), 0);
    });

    test('comprehensive：内置占先，但用得多能顶上来（legacy 的规则）', () {
      final tied = ExpertCatalog.sort([a, b], usage: {a.id: 1, b.id: 1});
      expect(tied.first.id, a.id, reason: '5 > 3：用一次的远端包专家占先前先输给内置');
      final overtaken = ExpertCatalog.sort([a, b], usage: {a.id: 1, b.id: 2});
      expect(overtaken.first.id, b.id, reason: '6 > 5：再用一次就反超');
    });

    test('hottest：只看使用次数', () {
      final out =
          ExpertCatalog.sort([a, b], mode: ExpertSort.hottest, usage: {b.id: 1});
      expect(out.first.id, b.id);
    });

    test('副键统一名字：同分结果确定可比', () {
      // 名字按 UTF-16 码元升序：'丙'(U+4E19) 在 '乙'(U+4E59) 前。
      final out = ExpertCatalog.sort([b, c], usage: const {});
      expect(out.map((e) => e.name), ['丙', '乙']);
    });

    test('ofLabel：界面字面量反查，认不出退回综合', () {
      expect(ExpertSort.ofLabel('综合'), ExpertSort.comprehensive);
      expect(ExpertSort.ofLabel(' 最热 '), ExpertSort.hottest);
      expect(ExpertSort.ofLabel('不存在'), ExpertSort.comprehensive);
    });
  });

  // ======================================================================
  // 5. 资产包：安装 / 卸载 / 升级 / 降级
  // ======================================================================
  group('资产包安装卸载', () {
    test('内置包永远在场、不可卸载；安装内置保留 id 被拒', () {
      final m = ExpertPackManager(MemoryPackStore(), builtinJson: rawCatalog);
      final snap = m.installed();
      expect(snap.healthy, isTrue, reason: snap.problems.join('；'));
      expect(snap.packs.first.meta.id, 'builtin');
      expect(m.allExperts(), hasLength(5));
      expect(m.findExpert('pack:builtin/daily.friend'), isNotNull);
      expect(m.findExpert('pack:builtin/不存在'), isNull);

      final u = m.uninstall('builtin');
      expect(u.ok, isFalse);
      expect(u.problem, contains('不可卸载'));
      expect(m.allExperts(), hasLength(5), reason: '卸载被拒，货架没变');

      final r = m.install(packJson(pack: {'id': 'builtin', 'version': '9.9.9'}));
      expect(r.ok, isFalse);
      expect(r.problem, contains('保留 id'));
    });

    test('新装 → 升级替换 → 拒绝降级 → force 降级 → 幂等', () {
      final m = ExpertPackManager(MemoryPackStore(), builtinJson: rawCatalog);

      final i1 = m.install(packJson(
        pack: {'id': 'sales-pro', 'version': '1.0.0'},
        experts: [
          {'id': 'e1', 'promptText': '正文一'},
        ],
      ));
      expect(i1.ok, isTrue, reason: i1.problem);
      expect(i1.action, InstallAction.installed);
      expect(m.expertsOf('sales-pro'), hasLength(1));

      final i2 = m.install(packJson(
        pack: {'id': 'sales-pro', 'version': '1.2.0'},
        experts: [
          {'id': 'e1', 'promptText': '正文一'},
          {'id': 'e2', 'promptText': '正文二'},
        ],
      ));
      expect(i2.action, InstallAction.upgraded);
      expect(m.expertsOf('sales-pro'), hasLength(2), reason: '升级整体替换');

      final down = m.install(packJson(
        pack: {'id': 'sales-pro', 'version': '1.0.0'},
        experts: [
          {'id': 'e1', 'promptText': '正文一'},
        ],
      ));
      expect(down.ok, isFalse);
      expect(down.problem, contains('拒绝降级'));
      expect(m.expertsOf('sales-pro'), hasLength(2), reason: '降级被拒，没动');

      final forced = m.install(
        packJson(
          pack: {'id': 'sales-pro', 'version': '1.0.0'},
          experts: [
            {'id': 'e1', 'promptText': '正文一'},
          ],
        ),
        force: true,
      );
      expect(forced.ok, isTrue, reason: forced.problem);
      expect(m.expertsOf('sales-pro'), hasLength(1));

      final same = m.install(packJson(
        pack: {'id': 'sales-pro', 'version': '1.0.0'},
        experts: [
          {'id': 'e1', 'promptText': '正文一'},
        ],
      ));
      expect(same.ok, isTrue);
      expect(same.action, InstallAction.alreadyCurrent);
      expect(same.problem, '');
      expect(same.warning, contains('同版本'));
    });

    test('卸载：卸掉的是装的包；没装过报「没有安装过」', () {
      final m = ExpertPackManager(MemoryPackStore(), builtinJson: rawCatalog);
      m.install(packJson(pack: {'id': 'tmp', 'version': '1.0.0'}));
      expect(m.uninstall('tmp').ok, isTrue);
      expect(m.expertsOf('tmp'), isEmpty);
      final miss = m.uninstall('tmp');
      expect(miss.ok, isFalse);
      expect(miss.problem, contains('没有安装过'));
    });

    test('安装清单校验失败：不写入，存储不变', () {
      final store = MemoryPackStore();
      final m = ExpertPackManager(store, builtinJson: rawCatalog);
      final r = m.install('这不是json');
      expect(r.ok, isFalse);
      expect(r.problem, contains('不是合法 JSON'));
      expect(store.loadAll(), isEmpty);
    });
  });

  // ======================================================================
  // 6. 已安装集合的坏包容错
  // ======================================================================
  group('坏包容错', () {
    test('存储里的坏包被忽略并如实报告，其余包照常可用；可显式清理', () {
      final store = MemoryPackStore();
      store.save('junk', '{not json');
      store.save('good', packJson(pack: {'id': 'good', 'version': '1.0.0'}));
      final m = ExpertPackManager(store, builtinJson: rawCatalog);

      final snap = m.installed();
      expect(snap.packs.map((p) => p.meta.id), ['builtin', 'good'],
          reason: '坏包被忽略，好的照常');
      expect(snap.problems, hasLength(1));
      expect(snap.problems.first, contains('junk'));

      // 显式清理路径：卸载不校验内容，直接删。
      expect(m.uninstall('junk').ok, isTrue);
      expect(m.installed().healthy, isTrue);
    });

    test('内置包清单损坏也只报问题，不吞掉已安装的包', () {
      final m = ExpertPackManager(MemoryPackStore(), builtinJson: '不是json');
      m.install(packJson(pack: {'id': 'x', 'version': '1.0.0'}));
      final snap = m.installed();
      expect(snap.problems.first, contains('内置包'));
      expect(m.expertsOf('x'), hasLength(1));
    });
  });

  // ======================================================================
  // 7. 远端资产包清单（URL 由 app 层配置，core 只解析与对照）
  // ======================================================================
  group('远端清单', () {
    String manifestJson(List<Map<String, Object?>> entries) => jsonEncode(
        {'format': 'jev-expert-remote-manifest/1', 'packs': entries});

    Map<String, Object?> entry(String id, String version) =>
        {'id': id, 'version': version, 'url': 'https://example.com/$id-$version.json'};

    test('解析：格式/结构级损坏拒绝；坏条目跳过并计数；重复 id 跳过后者', () {
      final broken = <String>[
        '',
        'nope',
        jsonEncode({'format': 'wrong', 'packs': <Object>[]}),
        jsonEncode({'format': 'jev-expert-remote-manifest/1'}),
        jsonEncode({
          'format': 'jev-expert-remote-manifest/1',
          'packs': '不是数组',
        }),
      ];
      for (final raw in broken) {
        final r = RemoteManifestCodec.parse(raw);
        expect(r.ok, isFalse, reason: raw);
        expect(r.problem, isNotEmpty);
      }
      final r = RemoteManifestCodec.parse(manifestJson([
        {'id': '', 'version': '1', 'url': 'x'},
        {'id': 'a', 'version': '', 'url': 'x'},
        {'id': 'a', 'version': '1.0', 'url': 'x'},
        entry('a', '1.0.0'),
        entry('b', '2.0.0'),
      ]));
      expect(r.entries.map((e) => e.id), ['a', 'b']);
      // 坏条目是前两个（空 id / 空 version）与第 4 条（与第 3 条 id 重复）——
      // 第 3 条（id:'a'，version:'1.0'）本身合法，是先到的那个 'a'。
      expect(r.skipped, 3);
      expect(r.problem, contains('3 条'));
    });

    test('diff：可新装 / 可升级 / 已最新 / 非法条目四类', () {
      final m = ExpertPackManager(MemoryPackStore(), builtinJson: rawCatalog);
      m.install(packJson(pack: {'id': 'installed', 'version': '1.0.0'}));
      // 注意：清单里同 id 条目会被解析器去重（后者跳过），所以「已最新」
      // 得用一个独立 id 的已装包来测，不能复用 'installed'。
      m.install(packJson(pack: {'id': 'steady', 'version': '2.0.0'}));
      final diff = RemoteManifestCodec.diff(
        RemoteManifestCodec.parse(manifestJson([
          entry('newbie', '1.0.0'),
          entry('installed', '1.1.0'),
          entry('steady', '2.0.0'),
          entry('builtin', '9.9.9'),
        ])),
        m,
      );
      expect(diff.installable.map((e) => e.id), ['newbie']);
      expect(diff.upgrades.map((e) => e.id), ['installed']);
      expect(diff.upgrades.first.version, '1.1.0');
      expect(diff.upToDate.map((e) => e.id), ['steady']);
      expect(diff.problems, hasLength(1));
      expect(diff.problems.first, contains('builtin'));
    });

    test('diff：存量坏包按「可安装」对待——重装就是修复', () {
      final store = MemoryPackStore();
      store.save('broken', '{');
      final m = ExpertPackManager(store, builtinJson: rawCatalog);
      final diff = RemoteManifestCodec.diff(
        RemoteManifestCodec.parse(manifestJson([entry('broken', '1.0.0')])),
        m,
      );
      expect(diff.installable.map((e) => e.id), ['broken']);
    });
  });

  // ======================================================================
  // 8. 套用：联系人直写（无冲突）
  // ======================================================================
  group('套用：联系人', () {
    test('没有专用人设 → 直写，逐字不 trim，其它字段原样保留', () {
      final expert = builtinExpert('sales.followup');
      final apply = ExpertApply(sink: MemSink('全局旧文'));
      final r = apply.applyToContact(expert, contactNoPersona);
      expect(r.ok, isTrue, reason: r.problem);
      expect(r.needsChoice, isFalse);
      expect(r.contact!.persona, expert.promptText, reason: '逐字写入');
      expect(r.contact!.name, '王总');
      expect(r.contact!.relationship, '客户');
      expect(r.contact!.notes, '在跟单');
      expect(r.contact!.id, 'c1');
      expect(r.appliedText, expert.promptText);
      expect(r.previousContact, isNull);
      // 复用 StyleSource.resolve 验证优先级事实：这个聊天现在生效的是联系人。
      final res = StyleSource.resolve('全局旧文', r.contact!.persona);
      expect(res.from, StyleSourceFrom.contact);
      expect(res.shadowed, isTrue);
    });

    test('promptText 逐字保存：尾随空格不许被悄悄 trim', () {
      const expert = Expert(
        id: 'pack:p/k', key: 'k', name: 'K', domain: '', promptText: '称呼：您 ',
        source: ExpertSource(packId: 'p', packVersion: '1'),
      );
      final r = ExpertApply().applyToContact(expert, contactNoPersona);
      expect(r.contact!.persona, '称呼：您 ');
    });

    test('空正文绝不套用（那等于清空用户的人设）', () {
      const expert = Expert(
        id: 'pack:p/k', key: 'k', name: '空卡', domain: '', promptText: '   ',
        source: ExpertSource(packId: 'p', packVersion: '1'),
      );
      final r = ExpertApply().applyToContact(expert, contactNoPersona);
      expect(r.ok, isFalse);
      expect(r.problem, contains('没有正文'));
      expect(r.contact, isNull);
    });
  });

  // ======================================================================
  // 9. 套用冲突：已有专用人设 → 覆盖 / 并存
  // ======================================================================
  group('套用冲突：覆盖/并存', () {
    final expert = builtinExpert('love.coldwar');

    test('未选择时：needsChoice，两个目标一个字节都不动', () {
      final sink = MemSink('全局旧文');
      final apply = ExpertApply(sink: sink);
      final r = apply.applyToContact(expert, contactWithPersona);
      expect(r.ok, isFalse);
      expect(r.needsChoice, isTrue);
      expect(r.contact, isNull, reason: '还没写');
      expect(sink.style, '全局旧文', reason: '全局也没动');
      expect(r.note, contains('覆盖'));
      expect(r.note, contains('并存'));
      expect(r.note, contains('李姐'));
    });

    test('选覆盖：专用人设换成专家正文，原句留在 previousContact 供撤销', () {
      final apply = ExpertApply(sink: MemSink('全局旧文'));
      final r = apply.applyToContact(expert, contactWithPersona,
          choice: ConflictChoice.overwrite);
      expect(r.ok, isTrue, reason: r.problem);
      expect(r.needsChoice, isFalse);
      expect(r.contact!.persona, expert.promptText);
      expect(r.previousContact!.persona, '称呼：李姐\n语气：客气但直接');
      expect(r.previousContact!.id, 'c2');
      // 覆盖后的优先级事实（StyleSource.resolve 语义）：专用人设继续压全局。
      final res = StyleSource.resolve('全局旧文', r.contact!.persona);
      expect(res.from, StyleSourceFrom.contact);
    });

    test('选并存：专用人设不动，专家进全局 style；提示说清本聊天仍用人设', () {
      final sink = MemSink('全局旧文');
      final apply = ExpertApply(sink: sink);
      final r = apply.applyToContact(expert, contactWithPersona,
          choice: ConflictChoice.coexist);
      expect(r.ok, isTrue, reason: r.problem);
      expect(r.wroteGlobalStyle, isTrue);
      expect(sink.style, expert.promptText, reason: '全局换成专家正文');
      expect(r.contact, isNull, reason: '联系人没动');
      expect(r.note, contains('专用人设没动'));
      expect(r.note, contains('其余没有专用人设的聊天'));
      // 并存后的优先级事实：本聊天仍被专用人设盖住。
      final res = StyleSource.resolve(sink.style, contactWithPersona.persona);
      expect(res.shadowed, isTrue);
    });

    test('并存但没有 sink：如实报错，什么都不写', () {
      final apply = ExpertApply();
      final r = apply.applyToContact(expert, contactWithPersona,
          choice: ConflictChoice.coexist);
      expect(r.ok, isFalse);
      expect(r.problem, contains('sink'));
      expect(r.wroteGlobalStyle, isFalse);
    });

    test('冲突检测复用 resolve 的语义：专用人设只剩空白时不算冲突', () {
      // resolve 对空白专用人设回落到全局——所以这里不该弹选择框。
      const blankish = Contact(id: 'c3', name: '路人', persona: '   ');
      final r =
          ExpertApply(sink: MemSink('全局旧文')).applyToContact(expert, blankish);
      expect(r.needsChoice, isFalse);
      expect(r.ok, isTrue);
    });
  });

  // ======================================================================
  // 10. 套用：全局 style + 盖不住谁的并存提示
  // ======================================================================
  group('套用：全局', () {
    final expert = builtinExpert('work.report');

    test('写入全局逐字；带专用人设的联系人被列进 shadowedContacts', () {
      final sink = MemSink('全局旧文');
      final apply = ExpertApply(sink: sink);
      final r =
          apply.applyToGlobal(expert, contacts: [contactNoPersona, contactWithPersona]);
      expect(r.ok, isTrue, reason: r.problem);
      expect(sink.style, expert.promptText);
      expect(r.appliedText, expert.promptText);
      expect(r.shadowedContacts.map((s) => s.id), ['c2'],
          reason: '只有带专用人设的盖不住');
      expect(r.note, contains('1 个联系人'));
      expect(r.note, contains('并存'));
    });

    test('没有人带专用人设时没有多余提示', () {
      final r = ExpertApply(sink: MemSink(''))
          .applyToGlobal(expert, contacts: [contactNoPersona]);
      expect(r.ok, isTrue);
      expect(r.shadowedContacts, isEmpty);
      expect(r.note, '');
    });

    test('没有 sink / 空正文：如实报错', () {
      expect(ExpertApply().applyToGlobal(expert).ok, isFalse);
      expect(ExpertApply(sink: MemSink()).applyToGlobal(expert).ok, isTrue);
      const blank = Expert(
        id: 'pack:p/k', key: 'k', name: '空卡', domain: '', promptText: '',
        source: ExpertSource(packId: 'p', packVersion: '1'),
      );
      final r = ExpertApply(sink: MemSink('旧')).applyToGlobal(blank);
      expect(r.ok, isFalse);
      expect(r.problem, contains('没有正文'));
    });

    test('写失败：回滚到原来那句，重试可成功（半截状态不存在）', () {
      final sink = FlakySink('全局旧文', failures: 1);
      final r = ExpertApply(sink: sink).applyToGlobal(expert);
      expect(r.ok, isFalse);
      expect(r.problem, contains('磁盘满了'));
      expect(r.problem, contains('还原'));
      expect(sink.style, '全局旧文', reason: '回滚真的执行了');
      // 同一个 sink 重试（失败额度用完）：套用成功。
      final retry = ExpertApply(sink: sink).applyToGlobal(expert);
      expect(retry.ok, isTrue, reason: retry.problem);
      expect(sink.style, expert.promptText);
    });

    test('并存路径写失败：联系人人设与全局都保持原样', () {
      final sink = FlakySink('全局旧文', failures: 1);
      final r = ExpertApply(sink: sink).applyToContact(
          builtinExpert('love.coldwar'), contactWithPersona,
          choice: ConflictChoice.coexist);
      expect(r.ok, isFalse);
      expect(r.problem, contains('专用人设没动'));
      expect(sink.style, '全局旧文');
    });
  });

  // ======================================================================
  // 11. 评测钩子（用户校准：命中评测钩子）
  // ======================================================================
  group('评测钩子', () {
    test('套用成功回调一次，载荷说清目标与正文', () {
      final events = <AppliedEvent>[];
      final apply = ExpertApply(sink: MemSink('旧'), onApplied: events.add);
      final expert = builtinExpert('daily.friend');
      apply.applyToContact(expert, contactNoPersona);
      expect(events, hasLength(1));
      expect(events[0].toContact, isTrue);
      expect(events[0].coexist, isFalse);
      expect(events[0].contactId, 'c1');
      expect(events[0].promptText, expert.promptText);

      apply.applyToGlobal(expert);
      expect(events, hasLength(2));
      expect(events[1].toContact, isFalse);

      // 并存路径 coexist=true。
      apply.applyToContact(expert, contactWithPersona,
          choice: ConflictChoice.coexist);
      expect(events, hasLength(3));
      expect(events[2].coexist, isTrue);
    });

    test('冲突待选与失败不回调', () {
      var calls = 0;
      final apply = ExpertApply(sink: MemSink('旧'), onApplied: (_) => calls++);
      apply.applyToContact(builtinExpert('love.coldwar'), contactWithPersona);
      const blank = Expert(
        id: 'pack:p/k', key: 'k', name: '空卡', domain: '', promptText: ' ',
        source: ExpertSource(packId: 'p', packVersion: '1'),
      );
      apply.applyToContact(blank, contactNoPersona);
      expect(calls, 0);
    });

    test('钩子抛异常只降级成 warning，套用照样成功', () {
      final apply = ExpertApply(
        sink: MemSink('旧'),
        onApplied: (_) => throw StateError('统计坏了'),
      );
      final r =
          apply.applyToContact(builtinExpert('daily.friend'), contactNoPersona);
      expect(r.ok, isTrue, reason: '观测坏了不能把套用变成失败');
      expect(r.warning, contains('钩子'));
      expect(r.warning, contains('统计坏了'));
    });
  });

  // ======================================================================
  // 12. 正文兼容：promptText 可被 PersonaCard 解析（Character Card V2 兼容）
  // ======================================================================
  group('正文与 PersonaCard 兼容', () {
    test('内置 5 张卡全部解析成结构化卡，键位认得出来', () {
      final experts =
          ExpertCatalog.loadBuiltin(readAsset: (_) => rawCatalog).experts;
      for (final e in experts) {
        final card = PersonaCard.parse(e.promptText);
        expect(card.structured, isTrue,
            reason: '${e.id}：认不出键会静默退回自由文本，'
                '用户看到的是「填了人设但回复没变」');
        expect(card.topic, isNotEmpty, reason: e.id);
        expect(card.examples, isNotEmpty, reason: e.id);
      }
    });

    test('避谈键拆进 avoid、不进 boundaries（legacy PersonaPresets.kt 的教训）', () {
      final sales = builtinExpert('sales.followup');
      final card = PersonaCard.parse(sales.promptText);
      expect(card.avoid, contains('稳赚'), reason: '避谈只约束我方措辞');
      expect(card.boundaries, isEmpty,
          reason: '写成硬边界会在客户问「能稳赚吗」那一轮掐掉全部候选');
    });
  });
}

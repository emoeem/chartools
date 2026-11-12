// 专家库控制器的单测：目录解析容错、货架合并、浏览层纯函数、套用三步语义
// （install → touch → 换正文，要么全成要么不留半截）、资产包安装去重与持久化。
//
// fake 注入：StyleSink / ContactPersonaSink 用内存实现（experts_controller
// 定义接口的理由就是让套用语义能在纯 Dart 单测里逼出失败路径，参考 legacy
// ExpertApply.kt:13 的 StyleSink 设计）；持久化用
// SharedPreferences.setMockInitialValues 提供内存存档（与
// contact_store_test.dart 同一口径）——套用会真的落盘，所以每个测试前都重置。
import 'dart:convert';

import 'package:chartools_app/application/experts_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内存 StyleSink：可注入写失败（第 3 步回滚路径的靶子）。
class _MemoryStyleSink implements StyleSink {
  @override
  String style = '';
  bool failWrite = false;

  @override
  Future<void> setStyle(String value) async {
    if (failWrite) throw StateError('写盘失败');
    style = value;
  }
}

/// 内存 ContactPersonaSink：可注入写失败；persona 写入就地更新快照。
class _MemoryContactSink implements ContactPersonaSink {
  _MemoryContactSink(this._targets);

  final List<ContactTarget> _targets;
  bool failWrite = false;

  @override
  List<ContactTarget> get targets => _targets;

  @override
  Future<void> writePersona(String contactId, String persona) async {
    if (failWrite) throw StateError('写失败');
    final i = _targets.indexWhere((t) => t.id == contactId);
    if (i < 0) throw StateError('联系人不存在');
    _targets[i] = ContactTarget(
        id: contactId, displayName: _targets[i].displayName, persona: persona);
  }
}

ExpertsController _newController({
  _MemoryStyleSink? sink,
  _MemoryContactSink? contactSink,
}) =>
    ExpertsController(
      styleSink: sink ?? _MemoryStyleSink(),
      contactSink: contactSink ??
          _MemoryContactSink([
            const ContactTarget(id: 'c1', displayName: '小测', persona: '旧人设'),
          ]),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 套用路径会写盘：每个测试都从空存档开始，互不串档。
    SharedPreferences.setMockInitialValues({});
  });

  group('ExpertPack.parse（资产包容错解析）', () {
    test('正常包：元信息与专家都读出来', () {
      final pack = ExpertPack.parse(jsonEncode({
        'name': '测试包',
        'source': 'https://example.test/pack',
        'sourceCommit': 'abc123',
        'contentHash': 'h1',
        'experts': [
          {
            'key': 'a.b',
            'name': '专家A',
            'body': '称呼：你',
            'category': '日常',
            'tags': ['t1', ' t2 '],
            'description': '简介',
            'emoji': '🌳',
          },
          {
            'key': 'c.d',
            'name': '',
            'body': '称呼：我',
          },
        ],
      }));
      expect(pack.ok, isTrue);
      expect(pack.problem, isEmpty);
      expect(pack.presets, hasLength(2));
      expect(pack.presets[0].packName, '测试包');
      expect(pack.presets[0].tags, ['t1', 't2']);
      // name 空落回 key（legacy ExpertPack.kt:114 同口径）。
      expect(pack.presets[1].name, 'c.d');
      expect(pack.meta.hash, 'h1');
      expect(pack.meta.expertCount, 2);
    });

    test('坏包不外抛：非法 JSON / 缺 experts 数组 / 逐条跳过', () {
      expect(ExpertPack.parse('not json').ok, isFalse);
      expect(ExpertPack.parse('{"name":"x"}').problem, contains('experts'));
      // 一条 body 为空只跳过那一条，不整包放弃。
      final pack = ExpertPack.parse(jsonEncode({
        'name': 'x',
        'experts': [
          {'key': 'ok.1', 'name': '好的', 'body': '称呼：你'},
          {'key': 'bad.1', 'name': '没正文', 'body': '   '},
          {'key': '', 'name': '没键', 'body': '称呼：你'},
          'not-an-object',
        ],
      }));
      expect(pack.ok, isTrue);
      expect(pack.presets, hasLength(1));
      expect(pack.problem, contains('跳过 3 条'));
    });

    test('别名互认：core 形状（format+pack+id/promptText/domain）照常出货架', () {
      // 独立复核裁定（docs/expert-pack-format.md §2）：同一份远端包不能在
      // app 解析器这边全量跳过——app 是宽容路径，core 主拼写与 legacy 别名
      // 都认；包级元数据落到 pack 对象里时回退读它。
      final pack = ExpertPack.parse(jsonEncode({
        'format': 'jev-expert-pack/1',
        'pack': {
          'id': 'sales-pro',
          'version': '1.2.0',
          'name': '销售话术包',
          'contentHash': 'abc123',
        },
        'experts': [
          {'id': 'followup', 'name': '跟单', 'promptText': '称呼：您\n主题：跟进',
            'domain': '销售', 'tags': ['跟进']},
          {'key': 'legacy', 'body': '称呼：您'},
        ],
      }));
      expect(pack.ok, isTrue, reason: pack.problem);
      expect(pack.meta.name, '销售话术包'); // 顶层缺席 → 回退读 pack 对象
      expect(pack.meta.hash, 'abc123');
      expect(pack.presets, hasLength(2));
      expect(pack.presets[0].key, 'followup');
      expect(pack.presets[0].body, '称呼：您\n主题：跟进');
      expect(pack.presets[0].category, '销售'); // domain 别名
      expect(pack.presets[1].key, 'legacy'); // legacy 拼写同批解析
      expect(pack.presets[1].body, '称呼：您');
    });
  });

  test('内置种子包可解析且键不重复（正文全非空，种子与外部包走同一解析路径）', () {
    final pack = ExpertPack.parse(seedPackJson);
    expect(pack.ok, isTrue);
    expect(pack.meta.name, '内置种子目录');
    final keys = pack.presets.map((e) => e.key).toList();
    expect(keys, everyElement(isNotEmpty));
    expect(keys.toSet().length, keys.length);
    for (final p in pack.presets) {
      expect(p.body.trim(), isNotEmpty, reason: '${p.key} 的正文为空');
    }
  });

  group('货架合并与浏览层', () {
    test('同 presetKey：我的条目盖过目录样品（目录是样品不是真源）', () async {
      final c = _newController();
      final ghost =
          c.shelfUnfiltered.firstWhere((i) => i.presetKey == 'daily.friend');
      expect(ghost.inLibrary, isFalse);
      expect(ghost.sourceRef, 'pack:内置种子目录');

      await c.applyAsGlobalStyle(ghost);
      final shelf = c.shelfUnfiltered
          .where((i) => i.presetKey == 'daily.friend')
          .toList();
      expect(shelf, hasLength(1));
      expect(shelf.single.inLibrary, isTrue);
      expect(shelf.single.usedCount, 1);
      // 来源追踪跟着落库走：入库后仍能回答「从哪来」。
      expect(shelf.single.sourceRef, 'pack:内置种子目录');
    });

    test('搜索命中正文（用户记得的是卡上那句话，legacy ExpertCatalog 口径）', () {
      final c = _newController();
      expect(c.shelf(query: '稳赚').map((i) => i.name), ['销售跟进']);
      expect(c.shelf(query: '稳赚').any((i) => i.name == '日常闲聊'), isFalse);
    });

    test('分类与标签筛选；分类顺序按 categoryOrder 的固定前缀', () {
      final c = _newController();
      expect(c.categories().first, '情感');
      expect(c.categories(), containsAll(['销售', '日常', '研究']));
      expect(c.shelf(category: '销售').map((i) => i.name), ['销售跟进']);
      expect(c.shelf(tag: '倾听').map((i) => i.name), ['情绪陪伴']);
    });

    test('综合排序：usedCount*3 + builtin?2——用一次的自建压过没用过的目录条目', () {
      // 分值规则本身（legacy ExpertCatalog.kt:111，规则写死就是为了能断言）。
      final unused = const ExpertShelfItem.ghost(
          ExpertPreset(key: 'g.1', name: '样品', body: '称呼：你'));
      final once = ExpertShelfItem.mine(const ExpertProfile(
        id: 'x1',
        name: '用过一次',
        body: '称呼：你',
        builtin: false,
        usedCount: 1,
      ));
      expect(ExpertCatalog.score(unused), 2); // 目录条目 +2
      expect(ExpertCatalog.score(once), 3); // 一次套用 = 3 分，刚好反超
      expect(ExpertCatalog.sort([unused, once]).first.id, 'x1');

      // 「最热」只看次数；「最新」只看 updatedAt——主键不同，副键统一兜底。
      final hotter = ExpertShelfItem.mine(const ExpertProfile(
        id: 'x2',
        name: '用过两次',
        body: '称呼：你',
        usedCount: 2,
      ));
      expect(
          ExpertCatalog.sort([once, hotter], mode: ExpertSort.hottest).first.id,
          'x2');
      final newer = ExpertShelfItem.mine(const ExpertProfile(
        id: 'x3',
        name: '刚改过',
        body: '称呼：你',
        usedCount: 0,
        updatedAt: 999,
      ));
      expect(
          ExpertCatalog.sort([once, newer], mode: ExpertSort.newest).first.id,
          'x3');
    });
  });

  group('套用语义（legacy ExpertApply 三步）', () {
    test('成功路径：style 换成正文原样 + 落库 + 热度+1', () async {
      final sink = _MemoryStyleSink();
      final c = ExpertsController(
          styleSink: sink,
          contactSink: _MemoryContactSink([
            const ContactTarget(id: 'c1', displayName: '小测', persona: ''),
          ]));
      final item =
          c.shelfUnfiltered.firstWhere((i) => i.presetKey == 'daily.friend');
      final r = await c.applyAsGlobalStyle(item);
      expect(r.ok, isTrue);
      expect(r.warning, isEmpty);
      expect(r.problem, isEmpty);
      // 正文原样（不 trim）——「套用 → 保存 → 再套用」不允许悄悄变形。
      expect(sink.style, item.body);
      expect(c.installed.value, hasLength(1));
      expect(c.installed.value.first.usedCount, 1);
      expect(c.installed.value.first.builtin, isTrue);
      // StyleSource 优先级提示的数据源：有没有联系人写了专用人设。
      expect(c.anyContactHasPersona, isFalse);
    });

    test('空正文直接拒绝：style 与库都不动（第 0 步）', () async {
      final sink = _MemoryStyleSink();
      sink.style = '原来的话';
      final c = ExpertsController(styleSink: sink);
      final r = await c.applyAsGlobalStyle(const ExpertShelfItem.ghost(
        ExpertPreset(key: 'x.y', name: '空壳', body: '   '),
      ));
      expect(r.ok, isFalse);
      expect(r.problem, contains('没有正文'));
      expect(sink.style, '原来的话');
      expect(c.installed.value, isEmpty);
    });

    test('第 3 步写失败：回滚 style、库里那条保留（不是二次破坏的对象）', () async {
      final sink = _MemoryStyleSink();
      sink.style = '原来的话';
      final c = ExpertsController(styleSink: sink);
      final item =
          c.shelfUnfiltered.firstWhere((i) => i.presetKey == 'daily.friend');
      sink.failWrite = true; // 落库（第 1 步）之后、换 style 之前失败
      final r = await c.applyAsGlobalStyle(item);
      expect(r.ok, isFalse);
      expect(r.problem, contains('还原成原来那句'));
      expect(r.profile, isNotNull);
      expect(sink.style, '原来的话');
      expect(c.installed.value, hasLength(1));
    });

    test('套用为联系人人设：写入 persona；写失败时原 persona 不动', () async {
      final contactSink = _MemoryContactSink([
        const ContactTarget(id: 'c1', displayName: '小测', persona: '旧人设'),
      ]);
      final c = ExpertsController(
          styleSink: _MemoryStyleSink(), contactSink: contactSink);
      expect(c.anyContactHasPersona, isTrue);
      final item = c.shelfUnfiltered
          .firstWhere((i) => i.presetKey == 'emotion.companion');

      final r = await c.applyToContact(item, contactSink.targets.first);
      expect(r.ok, isTrue);
      expect(contactSink.targets.first.persona, item.body);

      // 写路径失败：原句不动（上一轮写入保留），problem 说明给了界面显示。
      contactSink.failWrite = true;
      final r2 = await c.applyToContact(item, contactSink.targets.first);
      expect(r2.ok, isFalse);
      expect(r2.problem, contains('没写成'));
      expect(contactSink.targets.first.persona, item.body);
    });

    test('未接线时如实报「未接线」，不假装成功（#13）', () async {
      final c = ExpertsController(); // 两个 sink 都不接
      final item =
          c.shelfUnfiltered.firstWhere((i) => i.presetKey == 'daily.friend');
      expect(c.hasStyleSink, isFalse);
      expect(c.hasContactSink, isFalse);
      expect(c.contactTargets, isEmpty);
      final r = await c.applyAsGlobalStyle(item);
      expect(r.ok, isFalse);
      expect(r.problem, contains('未接线'));
    });
  });

  group('资产包安装', () {
    test('安装与同 name+hash 重装=替换', () async {
      final c = _newController();
      expect(c.packs, hasLength(1)); // 种子包
      final pack = await c.installPackJson(jsonEncode({
        'name': '外部包',
        'source': ' somewhere ',
        'contentHash': 'v1',
        'experts': [
          {'key': 'e.1', 'name': '外部专家', 'body': '称呼：你'},
        ],
      }));
      expect(pack.ok, isTrue);
      expect(c.packs, hasLength(2));
      expect(c.shelfUnfiltered.any((i) => i.name == '外部专家'), isTrue);

      // 同 name+hash 再装（内容微调）：替换而不是追加。
      await c.installPackJson(jsonEncode({
        'name': '外部包',
        'source': ' somewhere ',
        'contentHash': 'v1',
        'experts': [
          {'key': 'e.1', 'name': '外部专家二', 'body': '称呼：你\n语气：短句'},
        ],
      }));
      expect(c.packs, hasLength(2));
      expect(c.packs.last.meta.expertCount, 1);
      expect(
          c.shelfUnfiltered.where((i) => i.presetKey == 'e.1'), hasLength(1));
      // 换 hash 则是第二个包。
      await c.installPackJson(jsonEncode({
        'name': '外部包',
        'contentHash': 'v2',
        'experts': [
          {'key': 'e.2', 'name': '另一位', 'body': '称呼：我'},
        ],
      }));
      expect(c.packs, hasLength(3));
    });

    test('坏包抛 FormatException 且不留半装的包', () async {
      final c = _newController();
      await expectLater(c.installPackJson('not json'), throwsFormatException);
      expect(c.packs, hasLength(1));
    });
  });

  test('持久化：套用落盘后，新控制器 load 能还原我的库与货架合并', () async {
    final c3 = _newController();
    final item2 = c3.shelfUnfiltered
        .firstWhere((i) => i.presetKey == 'emotion.companion');
    await c3.applyAsGlobalStyle(item2);

    final c4 = ExpertsController();
    await c4.load();
    expect(c4.installed.value, hasLength(1));
    expect(c4.installed.value.first.presetKey, 'emotion.companion');
    expect(c4.installed.value.first.usedCount, 1);
    // 货架合并：已入库的不再出样品。
    expect(
        c4.shelfUnfiltered
            .where((i) => i.presetKey == 'emotion.companion')
            .length,
        1);

    // 移出我的库落盘后，load 仍是空的；目录样品回来了（货架不受影响）。
    await c3.removeFromLibrary(c3.installed.value.first.id);
    final c5 = ExpertsController();
    await c5.load();
    expect(c5.installed.value, isEmpty);
    expect(
        c5.shelfUnfiltered
            .where((i) => i.presetKey == 'emotion.companion')
            .single
            .inLibrary,
        isFalse);
  });
}

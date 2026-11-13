// 专家库控制器的单测（#13 收敛版）：包解析/校验/安装/卸载/降级拒装全部断言
// core 语义（PackCodec + ExpertPackManager，规则唯一出处）；套用断言
// needsChoice/覆盖/并存（core ExpertApply）；货架合并与浏览层沿用原意图
// （正文搜索、领域/标签筛选、综合分、最新档）；另加「旧持久化键数据读入」
// 的兼容组（别名互认、失败计数、写不回退旧键）。
//
// fake 注入：StyleSinkPort / ContactPersonaSink 用内存实现（StyleSinkPort 在
// core 同步 StyleSink 之上加 flush——core ExpertApply 的回滚判在同步 setter
// 上，盘上成败由 flush 上交，控制器兜底）；持久化用
// SharedPreferences.setMockInitialValues 提供内存存档（与
// contact_store_test.dart 同一口径）——套用会真的落盘，所以每个测试前都重置。
// 内置包：控制器构造期走 core 磁盘探测，读的是 packages/core 真文件。
import 'dart:convert';

import 'package:chartools_app/application/experts_controller.dart';
import 'package:chartools_core/chartools_core.dart' as kb;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内存 StyleSinkPort：可注入写失败（core 同步回滚路径的靶子）与
/// flush 失败（异步落盘回滚路径的靶子）。
class _MemoryStyleSink implements StyleSinkPort {
  String _style = '';
  bool failWrite = false;
  bool failFlush = false;

  @override
  String get style => _style;

  @override
  set style(String value) {
    if (failWrite) throw StateError('写盘失败');
    _style = value;
  }

  @override
  Future<void> flush() async {
    if (failFlush) throw StateError('落盘失败');
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

int _usedCountOf(ExpertsController c, String id) =>
    c.shelfUnfiltered.firstWhere((i) => i.id == id).usedCount;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 套用路径会写盘：每个测试都从空存档开始，互不串档。
    SharedPreferences.setMockInitialValues({});
  });

  group('core 收敛：内置包来自 core 磁盘探测（builtin@1.0.0）', () {
    test('内置包可解析：5 位示例专家，键不重复、正文全非空、领域都在 5 固定领域内', () async {
      final c = _newController();
      await c.load();
      expect(c.packs, isNotEmpty);
      final builtin = c.packs.first;
      expect(builtin.meta.id, 'builtin');
      expect(builtin.meta.version, '1.0.0');
      expect(builtin.meta.name, '内置示例专家');
      final experts = builtin.experts;
      expect(experts, hasLength(5));
      final keys = experts.map((e) => e.key).toList();
      expect(keys, everyElement(isNotEmpty));
      expect(keys.toSet().length, keys.length);
      for (final e in experts) {
        expect(e.promptText.trim(), isNotEmpty, reason: '${e.key} 的正文为空');
        expect(kb.ExpertCatalog.knownDomains, contains(e.domain));
        expect(e.isBuiltin, isTrue);
      }
      // 货架合并：内置条目全部以样品出现（库里还没有东西）。
      expect(
          c.shelfUnfiltered.where((i) => i.builtin).length, experts.length);
    });
  });

  group('core 收敛：包安装/升级/降级拒装/卸载（PackCodec + ExpertPackManager）', () {
    String packJson({String version = '1.2.0', int experts = 1}) =>
        jsonEncode({
          'format': 'jev-expert-pack/1',
          'pack': {'id': 'sales-pro', 'version': version, 'name': '销售话术包'},
          'experts': [
            for (var i = 0; i < experts; i++)
              {
                'id': 'followup.$i',
                'name': '跟单$i',
                'promptText': '称呼：您\n主题：跟进',
                'domain': '销售',
                'tags': ['跟进'],
              },
          ],
        });

    test('正常包安装成功：货架出现新专家，来源追踪指向包 id', () async {
      final c = _newController();
      await c.load();
      expect(c.packs, hasLength(1)); // 内置包
      final r = await c.installPackJson(packJson());
      expect(r.ok, isTrue);
      expect(r.action, kb.InstallAction.installed);
      expect(r.problem, isEmpty);
      expect(c.packs, hasLength(2));
      final item = c.shelfUnfiltered.firstWhere((i) => i.presetKey == 'followup.0');
      expect(item.name, '跟单0');
      expect(item.category, '销售');
      expect(item.sourceRef, 'pack:sales-pro');
      expect(c.shelf(category: '销售').map((i) => i.name), contains('跟单0'));
    });

    test('清单级严格校验：缺 format / 缺 pack.id / 缺 version 都拒装，不留半装的包',
        () async {
      final c = _newController();
      await c.load();
      Map<String, dynamic> raw = jsonDecode(packJson()) as Map<String, dynamic>;
      // 缺 format（app 形状的历史包必须补 format+pack 才能走安装路径，docs §2）。
      final noFormat = Map<String, dynamic>.of(raw)..remove('format');
      await expectLater(
          c.installPackJson(jsonEncode(noFormat)), throwsFormatException);
      // 缺 pack 对象。
      final noPack = Map<String, dynamic>.of(raw)..remove('pack');
      await expectLater(
          c.installPackJson(jsonEncode(noPack)), throwsFormatException);
      // 缺 version。
      final noVersion = Map<String, dynamic>.of(raw);
      (noVersion['pack'] as Map<String, dynamic>).remove('version');
      await expectLater(
          c.installPackJson(jsonEncode(noVersion)), throwsFormatException);
      expect(c.packs, hasLength(1)); // 只有内置包
    });

    test('别名互认：legacy 条目形状（key/body/category）经条目级补齐照常出货架',
        () async {
      final c = _newController();
      await c.load();
      final r = await c.installPackJson(jsonEncode({
        'format': 'jev-expert-pack/1',
        'pack': {'id': 'legacy-shape', 'version': '1.0.0', 'name': '旧形状包'},
        'experts': [
          {'key': 'legacy', 'name': '旧拼写专家', 'body': '称呼：您', 'category': '日常'},
          {'id': 'main', 'name': '主拼写专家', 'promptText': '称呼：我', 'domain': '销售'},
        ],
      }));
      expect(r.ok, isTrue, reason: r.problem);
      final legacy = c.shelfUnfiltered.firstWhere((i) => i.presetKey == 'legacy');
      expect(legacy.body, '称呼：您'); // body → promptText 互认
      expect(legacy.category, '日常'); // category → domain 互认（core 解码只读
      // domain，app 安装入口补齐主拼写，见 experts_controller._normalizePackJson）
      expect(c.shelf(category: '日常').map((i) => i.name), contains('旧拼写专家'));
    });

    test('同版本幂等 / 更高版本升级替换 / 更低版本拒装（core 版本仲裁）', () async {
      final c = _newController();
      await c.load();
      // 首装：新装。
      final first = await c.installPackJson(packJson());
      expect(first.action, kb.InstallAction.installed);
      // 同版本再装：alreadyCurrent，不重复写。
      final again = await c.installPackJson(packJson());
      expect(again.action, kb.InstallAction.alreadyCurrent);
      expect(c.packs, hasLength(2));
      expect(c.packs.last.meta.version, '1.2.0');
      expect(c.packs.last.expertCount, 1);
      // 更高版本：升级替换（整体作废旧内容）。
      final up = await c.installPackJson(packJson(version: '1.3.0', experts: 2));
      expect(up.action, kb.InstallAction.upgraded);
      expect(c.packs, hasLength(2));
      expect(c.packs.last.meta.version, '1.3.0');
      expect(c.packs.last.expertCount, 2);
      // 更低版本：core 拒绝降级——界面不会想装旧版，装了多半是缓存坏了。
      await expectLater(
        c.installPackJson(packJson(version: '1.0.0')),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('拒绝降级'))),
      );
      expect(c.packs.last.meta.version, '1.3.0');
    });

    test('内置保留 id 拒装；卸载语义（内置不可卸/没装过报错/坏包也可显式清理）',
        () async {
      final c = _newController();
      await c.load();
      await expectLater(
        c.installPackJson(jsonEncode({
          'format': 'jev-expert-pack/1',
          'pack': {'id': 'builtin', 'version': '9.9.9'},
          'experts': [
            {'id': 'x', 'promptText': '称呼：你'},
          ],
        })),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('保留 id'))),
      );
      // 正常卸载。
      await c.installPackJson(packJson());
      final r = await c.uninstallPack('sales-pro');
      expect(r.ok, isTrue);
      expect(c.packs, hasLength(1));
      expect(c.shelfUnfiltered.any((i) => i.presetKey == 'followup.0'), isFalse);
      // 内置包不可卸载（货架底座）。
      final rb = await c.uninstallPack('builtin');
      expect(rb.ok, isFalse);
      expect(rb.problem, contains('不可卸载'));
      // 没装过的包。
      final rn = await c.uninstallPack('never-installed');
      expect(rn.ok, isFalse);
      expect(rn.problem, contains('没有安装过'));
    });
  });

  group('货架合并与浏览层（意图沿旧，数据源换 core）', () {
    test('同 id/同名：我的条目盖过目录样品（目录是样品不是真源）', () async {
      final c = _newController();
      await c.load();
      final ghost = c.shelfUnfiltered
          .firstWhere((i) => i.presetKey == 'daily.friend');
      expect(ghost.inLibrary, isFalse);
      expect(ghost.sourceRef, 'seed:builtin'); // 内置包样品的来源追踪

      await c.applyAsGlobalStyle(ghost);
      final shelf = c.shelfUnfiltered
          .where((i) => i.presetKey == 'daily.friend')
          .toList();
      expect(shelf, hasLength(1));
      expect(shelf.single.inLibrary, isTrue);
      expect(shelf.single.usedCount, 1);
      // 来源追踪跟着落库走：入库后仍能回答「从哪来」。
      expect(shelf.single.sourceRef, 'seed:builtin');
    });

    test('搜索命中正文（用户记得的是卡上那句话）', () async {
      final c = _newController();
      await c.load();
      expect(c.shelf(query: '稳赚').map((i) => i.name), ['销售·跟单']);
      expect(c.shelf(query: '稳赚').any((i) => i.name == '日常闲聊'), isFalse);
    });

    test('领域分组与标签筛选（core 5 领域 + tags 的展示组合）', () async {
      final c = _newController();
      await c.load();
      // 领域 chips 按 core knownDomains 固定前缀排序，只列在场的。
      expect(c.categories().first, '情感');
      expect(c.categories(), containsAll(['销售', '职场', '客服', '日常']));
      expect(c.shelf(category: '销售').map((i) => i.name), ['销售·跟单']);
      expect(c.shelf(tag: '先接情绪').map((i) => i.name), ['客服·投诉安抚']);
    });

    test('综合分沿用 core 规则：used*3 + builtin?2——用一次的自建压过没用过的目录条目',
        () async {
      // 分值规则唯一出处是 core ExpertCatalog.score（usage 由 app 注入）。
      final builtinExpert = kb.Expert(
        id: 'pack:t/x',
        key: 'x',
        name: '样品',
        domain: '',
        promptText: '称呼：你',
        source: const kb.ExpertSource(
            packId: 't', packVersion: '1', origin: kb.ExpertOrigin.builtin),
      );
      final mineExpert = kb.Expert(
        id: 'x1',
        key: 'x1',
        name: '用过一次',
        domain: '',
        promptText: '称呼：你',
        source: const kb.ExpertSource(packId: '', packVersion: ''),
      );
      expect(kb.ExpertCatalog.score(builtinExpert, const {}), 2); // 目录条目 +2
      expect(kb.ExpertCatalog.score(mineExpert, {'x1': 1}), 3); // 一次套用 = 3 分
      final sorted = kb.ExpertCatalog.sort(
          [builtinExpert, mineExpert], usage: {'x1': 1});
      expect(sorted.first.id, 'x1');
      // 「最热」只看次数（core 语义）。
      final hotter = kb.Expert(
        id: 'x2',
        key: 'x2',
        name: '用过两次',
        domain: '',
        promptText: '称呼：你',
        source: const kb.ExpertSource(packId: '', packVersion: ''),
      );
      final hottest = kb.ExpertCatalog.sort([mineExpert, hotter],
          mode: kb.ExpertSort.hottest, usage: {'x1': 1, 'x2': 2});
      expect(hottest.first.id, 'x2');
    });

    test('最新档（展示层）：包 importedAt 支撑目录样品，我的条目 updatedAt 浮顶',
        () async {
      final c = _newController();
      await c.load();
      await c.installPackJson(jsonEncode({
        'format': 'jev-expert-pack/1',
        'pack': {'id': 'fresh', 'version': '1.0.0', 'name': '新装包'},
        'experts': [
          {'id': 'fresh.1', 'name': '新装专家', 'promptText': '称呼：你'},
        ],
      }));
      // 刚装的包：importedAt > 0，其样品浮在 builtin 样品（importedAt=0，沉底）之上。
      expect(c.shelf(sort: ExpertSort.newest).first.name, '新装专家');
      // 套用内置条目落库（updatedAt 前进）后浮到最顶。
      final ghost = c.shelfUnfiltered
          .firstWhere((i) => i.presetKey == 'daily.friend');
      await c.applyAsGlobalStyle(ghost);
      expect(
          c.shelf(sort: ExpertSort.newest).first.presetKey, 'daily.friend');
    });
  });

  group('套用语义（core ExpertApply 收敛）', () {
    test('成功路径：style 换成正文原样 + 落库 + 热度+1', () async {
      final sink = _MemoryStyleSink();
      final c = ExpertsController(
          styleSink: sink,
          contactSink: _MemoryContactSink([
            const ContactTarget(id: 'c1', displayName: '小测', persona: ''),
          ]));
      await c.load();
      final item =
          c.shelfUnfiltered.firstWhere((i) => i.presetKey == 'daily.friend');
      final r = await c.applyAsGlobalStyle(item);
      expect(r.ok, isTrue);
      expect(r.warning, isEmpty);
      expect(r.problem, isEmpty);
      // 正文原样（不 trim）——「套用 → 保存 → 再套用」不允许悄悄变形。
      expect(sink.style, item.body);
      expect(c.installed.value, hasLength(1));
      expect(_usedCountOf(c, item.id), 1);
      expect(c.installed.value.first.isBuiltin, isTrue);
      // StyleSource 优先级提示的数据源：有没有联系人写了专用人设。
      expect(c.anyContactHasPersona, isFalse);
    });

    test('空正文直接拒绝：style 与库都不动（第 0 步，与 core 同判定）', () async {
      final sink = _MemoryStyleSink();
      sink.style = '原来的话';
      final c = ExpertsController(styleSink: sink);
      await c.load();
      const emptyExpert = kb.Expert(
        id: 'pack:x/empty',
        key: 'empty',
        name: '空壳',
        domain: '',
        promptText: '   ',
        source: kb.ExpertSource(packId: 'x', packVersion: '1'),
      );
      final r = await c.applyAsGlobalStyle(ExpertShelfItem.ghost(emptyExpert));
      expect(r.ok, isFalse);
      expect(r.problem, contains('没有正文'));
      expect(sink.style, '原来的话');
      expect(c.installed.value, isEmpty);
    });

    test('同步写失败：core 回滚 style，库里那条保留（不是二次破坏的对象）', () async {
      final sink = _MemoryStyleSink();
      sink.style = '原来的话';
      final c = ExpertsController(styleSink: sink);
      await c.load();
      final item =
          c.shelfUnfiltered.firstWhere((i) => i.presetKey == 'daily.friend');
      sink.failWrite = true; // core _write 抛异常 → core 自己回滚
      final r = await c.applyAsGlobalStyle(item);
      expect(r.ok, isFalse);
      expect(r.problem, contains('还原成原来那句'));
      expect(r.profile, isNotNull);
      expect(sink.style, '原来的话');
      expect(c.installed.value, hasLength(1));
    });

    test('异步落盘失败：内存回滚 + 如实报错（StyleSinkPort.flush 兜底）', () async {
      final sink = _MemoryStyleSink();
      sink.style = '原来的话';
      final c = ExpertsController(styleSink: sink);
      await c.load();
      final item =
          c.shelfUnfiltered.firstWhere((i) => i.presetKey == 'daily.friend');
      sink.failFlush = true; // 内存写入成功、盘上没写成
      final r = await c.applyAsGlobalStyle(item);
      expect(r.ok, isFalse);
      expect(r.problem, contains('还原成原来那句'));
      // 内存已回滚到进来时的那句。
      expect(sink.style, '原来的话');
      expect(c.installed.value, hasLength(1));
    });

    test('套用为联系人人设（无冲突直写）：写入 persona；写失败时原 persona 不动',
        () async {
      final contactSink = _MemoryContactSink([
        const ContactTarget(id: 'c1', displayName: '小测', persona: ''),
      ]);
      final sink = _MemoryStyleSink();
      final c = ExpertsController(styleSink: sink, contactSink: contactSink);
      await c.load();
      expect(c.anyContactHasPersona, isFalse);
      final item = c.shelfUnfiltered
          .firstWhere((i) => i.presetKey == 'love.coldwar');

      final r = await c.applyToContact(item, contactSink.targets.first);
      expect(r.ok, isTrue);
      expect(contactSink.targets.first.persona, item.body);
      expect(_usedCountOf(c, item.id), 1);

      // 写路径失败：原句不动（上一轮写入保留），problem 说明给了界面显示。
      contactSink.failWrite = true;
      final r2 = await c.applyToContact(item, contactSink.targets.first,
          choice: kb.ConflictChoice.overwrite);
      expect(r2.ok, isFalse);
      expect(r2.problem, contains('没写成'));
      expect(contactSink.targets.first.persona, item.body);
      expect(r2.profile, isNotNull);
    });

    test('已有专用人设：首调 needsChoice 两个目标都不动；覆盖后 persona 换新',
        () async {
      final contactSink = _MemoryContactSink([
        const ContactTarget(id: 'c1', displayName: '小测', persona: '旧人设'),
      ]);
      final sink = _MemoryStyleSink();
      final c = ExpertsController(styleSink: sink, contactSink: contactSink);
      await c.load();
      expect(c.anyContactHasPersona, isTrue);
      // 页面的「已有专用人设」判定与 core 是同一处（StyleSource.resolve）。
      expect(ExpertsController.contactHasPersona(contactSink.targets.first),
          isTrue);
      final item = c.shelfUnfiltered
          .firstWhere((i) => i.presetKey == 'love.coldwar');

      // 首调（不带 choice）：core 判定冲突 → needsChoice，什么都不写。
      final r1 = await c.applyToContact(item, contactSink.targets.first);
      expect(r1.ok, isFalse);
      expect(r1.needsChoice, isTrue);
      expect(r1.note, isNotEmpty);
      expect(contactSink.targets.first.persona, '旧人设'); // persona 没动
      expect(sink.style, ''); // style 没动
      // 条目已落库（收藏），但热度未记——touch 只发生在真正落笔之后。
      expect(c.installed.value, hasLength(1));
      expect(_usedCountOf(c, item.id), 0);

      // 用户选覆盖：persona 换成专家正文，热度+1。
      final r2 = await c.applyToContact(item, contactSink.targets.first,
          choice: kb.ConflictChoice.overwrite);
      expect(r2.ok, isTrue);
      expect(contactSink.targets.first.persona, item.body);
      expect(_usedCountOf(c, item.id), 1);
    });

    test('已有专用人设 + 并存：只写全局风格，专用人设保留并继续压全局', () async {
      final contactSink = _MemoryContactSink([
        const ContactTarget(id: 'c1', displayName: '小测', persona: '旧人设'),
      ]);
      final sink = _MemoryStyleSink();
      final c = ExpertsController(styleSink: sink, contactSink: contactSink);
      await c.load();
      final item = c.shelfUnfiltered
          .firstWhere((i) => i.presetKey == 'love.coldwar');

      final r = await c.applyToContact(item, contactSink.targets.first,
          choice: kb.ConflictChoice.coexist);
      expect(r.ok, isTrue);
      expect(r.note, contains('并存完成')); // core 照实说明并存事实
      // 全局风格换成专家正文……
      expect(sink.style, item.body);
      // ……而专用人设原句未动（StyleSource：TA 继续压全局）。
      expect(contactSink.targets.first.persona, '旧人设');
    });

    test('未接线时如实报「未接线」，不假装成功（#13）', () async {
      final c = ExpertsController(); // 两个 sink 都不接
      await c.load();
      final item =
          c.shelfUnfiltered.firstWhere((i) => i.presetKey == 'daily.friend');
      expect(c.hasStyleSink, isFalse);
      expect(c.hasContactSink, isFalse);
      expect(c.contactTargets, isEmpty);
      final r = await c.applyAsGlobalStyle(item);
      expect(r.ok, isFalse);
      expect(r.problem, contains('未接线'));
      final r2 = await c.applyToContact(item,
          const ContactTarget(id: 'c1', displayName: '小测', persona: ''));
      expect(r2.ok, isFalse);
      expect(r2.problem, contains('未接线'));
    });
  });

  group('我的库管理（改名/改正文）', () {
    test('改名：id/key/正文/来源不动，updatedAt 前进；空白名与缺条目报错', () async {
      final c = _newController();
      await c.load();
      final item =
          c.shelfUnfiltered.firstWhere((i) => i.presetKey == 'daily.friend');
      await c.applyAsGlobalStyle(item);
      final id = item.id;
      final renamed = await c.renameLibraryEntry(id, '  我的闲聊  ');
      expect(renamed.name, '我的闲聊'); // trim 后保存
      expect(renamed.id, id);
      expect(renamed.promptText, item.body);
      final shelfItem = c.shelfUnfiltered.firstWhere((i) => i.id == id);
      expect(shelfItem.name, '我的闲聊');
      expect(shelfItem.usedCount, 1); // 改名不动热度
      expect(shelfItem.meta!.updatedAt, greaterThan(0));

      await expectLater(c.renameLibraryEntry(id, '   '), throwsArgumentError);
      await expectLater(c.renameLibraryEntry('nope', 'x'), throwsStateError);
    });

    test('改正文：逐字保存；空正文与超 64KiB 拒绝（与包条目同一护栏）', () async {
      final c = _newController();
      await c.load();
      final item =
          c.shelfUnfiltered.firstWhere((i) => i.presetKey == 'daily.friend');
      await c.applyAsGlobalStyle(item);
      final id = item.id;
      final updated = await c.updateLibraryBody(id, '称呼：改过的正文\n语气：短句');
      expect(updated.promptText, '称呼：改过的正文\n语气：短句');
      expect(c.shelfUnfiltered.firstWhere((i) => i.id == id).body,
          '称呼：改过的正文\n语气：短句');

      await expectLater(c.updateLibraryBody(id, '   '), throwsArgumentError);
      final oversize = 'x' * (kb.expertPromptTextMaxBytes + 1);
      await expectLater(
          c.updateLibraryBody(id, oversize), throwsArgumentError);
      await expectLater(c.updateLibraryBody('nope', '称呼：你'), throwsStateError);
    });

    test('移出我的库：目录样品回来了（货架不受影响）', () async {
      final c = _newController();
      await c.load();
      final item =
          c.shelfUnfiltered.firstWhere((i) => i.presetKey == 'daily.friend');
      await c.applyAsGlobalStyle(item);
      await c.removeFromLibrary(item.id);
      final shelf = c.shelfUnfiltered
          .where((i) => i.presetKey == 'daily.friend')
          .toList();
      expect(shelf, hasLength(1));
      expect(shelf.single.inLibrary, isFalse);
    });
  });

  group('持久化与新控制器 load 还原', () {
    test('套用落盘后，新控制器 load 能还原我的库与货架合并', () async {
      final c1 = _newController();
      await c1.load();
      final item = c1.shelfUnfiltered
          .firstWhere((i) => i.presetKey == 'love.coldwar');
      await c1.applyAsGlobalStyle(item);

      final c2 = _newController();
      await c2.load();
      expect(c2.installed.value, hasLength(1));
      expect(c2.installed.value.first.key, 'love.coldwar');
      expect(c2.installed.value.first.id, 'pack:builtin/love.coldwar');
      expect(_usedCountOf(c2, item.id), 1);
      // 货架合并：已入库的不再出样品。
      expect(
          c2.shelfUnfiltered
              .where((i) => i.presetKey == 'love.coldwar')
              .length,
          1);

      // 移出我的库落盘后，load 仍是空的；目录样品回来了（货架不受影响）。
      await c1.removeFromLibrary(item.id);
      final c3 = _newController();
      await c3.load();
      expect(c3.installed.value, isEmpty);
      expect(
          c3.shelfUnfiltered
              .where((i) => i.presetKey == 'love.coldwar')
              .single
              .inLibrary,
          isFalse);
    });

    test('#13 接线守护：dispose 先于 load() 续体，notifier 写入安全跳过', () async {
      // main.dart 的 _PageHost 是「push 构造 + ..load()、pop 即 dispose」——
      // 用户在 shared_preferences 返回前 pop 掉页面，load 的续体会撞已
      // dispose 的 ValueNotifier（_PageHost 文档注释的已知微风险）。守卫
      // 让续体变成静默 no-op，本测试钉死这个契约。
      final c = _newController();
      await c.load();
      final item = c.shelfUnfiltered
          .firstWhere((i) => i.presetKey == 'daily.friend');
      await c.applyAsGlobalStyle(item); // 盘上有 v2 存档，load 续体有东西可写

      final c2 = _newController();
      final pending = c2.load(); // 模拟 push
      c2.dispose(); // 模拟用户立刻 pop：dispose 先于续体
      await expectLater(pending, completes);
    });
  });

  group('旧持久化键数据读入（兼容：别名互认 + 失败计数 + 写不回退旧键）', () {
    test('我的库旧键：body→promptText、category→domain、usedCount/sourceRef 保留',
        () async {
      final oldEntry = <String, dynamic>{
        'id': 'x_old1',
        'name': '旧专家',
        'body': '称呼：您\n关系：旧存档', // 旧拼写（别名）
        'builtin': true,
        'avatar': '🧪',
        'description': '旧简介',
        'tags': ['旧'],
        'category': '销售', // 旧拼写（别名）
        'usedCount': 3,
        'presetKey': 'old.pack',
        'sourceRef': 'pack:旧种子包',
        'updatedAt': 1234567,
      };
      final original = jsonEncode({'version': 1, 'experts': [oldEntry]});
      SharedPreferences.setMockInitialValues({'experts': original});

      final c = _newController();
      await c.load();
      expect(c.installed.value, hasLength(1));
      final e = c.installed.value.first;
      expect(e.id, 'x_old1'); // 旧 id 原样保留（不重排成全局 id）
      expect(e.promptText, '称呼：您\n关系：旧存档'); // body 别名互认
      expect(e.domain, '销售'); // category 别名互认
      expect(e.emoji, '🧪'); // avatar 别名互认
      expect(e.key, 'old.pack'); // presetKey → key
      expect(e.isBuiltin, isTrue); // builtin 标记 → origin builtin（综合分 +2 口径不变）
      final item = c.shelfUnfiltered.first;
      expect(item.usedCount, 3);
      expect(item.meta!.updatedAt, 1234567); // 旧 updatedAt 保留（最新档数据源）
      expect(item.sourceRef, 'pack:旧种子包'); // 来源展示串原样保留
      expect(c.loadProblems, isEmpty);
      expect(c.loadNotes.join(' '), contains('迁移'));
      // 写新键（主拼写）、不回写旧键。
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('experts'), original); // 旧键原样
      final v2Raw = prefs.getString('experts_v2');
      expect(v2Raw, isNotNull);
      final v2 = jsonDecode(v2Raw!) as Map<String, dynamic>;
      final entryJson = (v2['entries'][0] as Map)['expert'] as Map;
      expect(entryJson.containsKey('promptText'), isTrue); // 主拼写
      expect(entryJson.containsKey('body'), isFalse);
    });

    test('旧我的库坏条目：计数进 loadProblems，不静默丢', () async {
      SharedPreferences.setMockInitialValues({
        'experts': jsonEncode({
          'version': 1,
          'experts': [
            {
              'id': 'x_good',
              'name': '好条目',
              'body': '称呼：您',
              'presetKey': 'good.1',
            },
            {
              'id': 'x_bad',
              'name': '坏条目',
              'body': '   ', // 空正文：转换失败
            },
          ],
        }),
      });
      final c = _newController();
      await c.load();
      expect(c.installed.value, hasLength(1)); // 好条目照常迁入
      expect(c.installed.value.first.id, 'x_good');
      expect(c.loadProblems, hasLength(1));
      expect(c.loadProblems.single, contains('转换失败'));
      expect(c.loadProblems.single, contains('x_bad'));
    });

    test('资产包旧键：legacy 形状（无 format）包装升级到 jev-expert-pack/1 后经 core 校验安装',
        () async {
      final legacyPackRaw = jsonEncode({
        'name': '旧包',
        'source': '旧仓库导出',
        'contentHash': 'h1',
        'experts': [
          {
            'key': 'old.1',
            'name': '旧专家',
            'body': '称呼：您', // 旧拼写
            'category': '销售', // 旧拼写
            'tags': ['旧'],
            'description': '简介',
            'emoji': '🧪',
          },
        ],
      });
      final originalPacks = jsonEncode({'version': 1, 'packs': [legacyPackRaw]});
      SharedPreferences.setMockInitialValues({'expert_packs': originalPacks});

      final c = _newController();
      await c.load();
      final migrated = c.packs.where((p) => p.meta.id == '旧包').toList();
      expect(migrated, hasLength(1));
      expect(migrated.single.meta.version, '0.0.0'); // 旧包置最低版本，正式版可升级
      expect(migrated.single.meta.name, '旧包');
      expect(migrated.single.expertCount, 1);
      final item = c.shelfUnfiltered.firstWhere((i) => i.presetKey == 'old.1');
      expect(item.body, '称呼：您'); // body 别名互认
      expect(item.category, '销售'); // category 别名不丢分组
      expect(item.sourceRef, 'pack:旧包');
      // 新键写入（KV 原文），旧键原样（写不回退键）。
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('expert_packs'), originalPacks);
      final v2Raw = prefs.getString('expert_packs_v2');
      expect(v2Raw, isNotNull);
      expect((jsonDecode(v2Raw!) as Map).containsKey('旧包'), isTrue);
      // 迁移后的包经得起 core 严格解析（安装路径同一校验）。
      final stored = jsonDecode(v2Raw) as Map<String, dynamic>;
      expect(
          kb.PackCodec.parse(stored['旧包'] as String).ok, isTrue);
      // 导入时间存活（独立复核修复：load 的旧值 clear 不再吃掉迁移时间戳），
      // 且已并入 experts_v2 存档——重启后 v2 包键已在盘、迁移不重走，时间戳
      // 只能靠存档活下来。
      final libRaw = prefs.getString('experts_v2');
      expect(libRaw, isNotNull);
      final stamp =
          (jsonDecode(libRaw!) as Map)['packImportedAt']?['旧包'] as int?;
      expect(stamp, isNotNull, reason: '迁移包的导入时间必须进存档');
      expect(stamp!, greaterThan(0));
      // 「最新」档：迁移包的目录样品（importedAt > 0）浮到内置样品（0，沉底）
      // 之前——文件头「目录样品按所在包 importedAt 排」的落地断言。
      expect(c.shelf(sort: ExpertSort.newest).first.presetKey, 'old.1');
    });

    test('旧包迁移幂等：重复 load 不重复安装', () async {
      final legacyPackRaw = jsonEncode({
        'name': '旧包',
        'experts': [
          {'key': 'old.1', 'body': '称呼：您'},
        ],
      });
      SharedPreferences.setMockInitialValues({
        'expert_packs': jsonEncode({'version': 1, 'packs': [legacyPackRaw]}),
      });
      final c = _newController();
      await c.load();
      expect(c.packs, hasLength(2)); // builtin + 旧包
      await c.load(); // 第二次：v2 键已在，不重走旧键
      expect(c.packs, hasLength(2));
    });

    test('同名旧包：不同内容都保留（id 加后缀），同内容按去重计数', () async {
      final packA = jsonEncode({
        'name': '旧包',
        'contentHash': 'h1',
        'experts': [
          {'key': 'a.1', 'body': '称呼：甲'},
        ],
      });
      final packB = jsonEncode({
        'name': '旧包',
        'contentHash': 'h2',
        'experts': [
          {'key': 'b.1', 'body': '称呼：乙'},
        ],
      });
      final packADup = jsonEncode({
        'name': '旧包',
        'contentHash': 'h1',
        'experts': [
          {'key': 'a.1', 'body': '称呼：甲'},
        ],
      });
      SharedPreferences.setMockInitialValues({
        'expert_packs': jsonEncode({'version': 1, 'packs': [packA, packB]}),
      });
      final c = _newController();
      await c.load();
      // 两个不同内容的同名包都迁进来（不静默丢），第二个 id 加后缀。
      expect(c.packs, hasLength(3)); // builtin + 旧包 + 旧包-2
      expect(c.packs.map((p) => p.meta.id), containsAll(['旧包', '旧包-2']));
      expect(c.shelfUnfiltered.any((i) => i.presetKey == 'a.1'), isTrue);
      expect(c.shelfUnfiltered.any((i) => i.presetKey == 'b.1'), isTrue);

      // 同名同内容的第三份：按去重跳过且计数可见。
      SharedPreferences.setMockInitialValues({
        'expert_packs': jsonEncode({
          'version': 1,
          'packs': [packA, packADup],
        }),
      });
      final c3 = _newController();
      await c3.load();
      expect(c3.packs, hasLength(2)); // builtin + 旧包（重复份去重）
      expect(c3.loadProblems, hasLength(1));
      expect(c3.loadProblems.single, contains('同名同内容'));
    });
  });
}

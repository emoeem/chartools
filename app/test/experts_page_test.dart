// 专家库页的 widget 测试（#13 收敛版 + #15 扩展）：目录浏览/搜索/标签、详情
// promptText 预览、「套用为全局风格」的 StyleSource 确认弹窗、「套用为联系人
// 人设」的 needsChoice 覆盖/并存二选一（core ExpertApply 语义）、资产包管理
// 区（粘贴安装走 core PackCodec 严格校验 + 卸载）。
//
// #15 我的自建专家：新建/编辑同一表单（字段 → PersonaCard 卡片键原文的拼装
// 含硬边界/避谈数组）、网格来源徽章 mine/seed/pack +「我的库」快筛、详情页/
// 长按菜单的编辑删除入口、改名改正文的落盘往返（重开控制器 load 验证）。
//
// #15 资产包三入口：粘贴安装（原链路）+「从文件导入」（假选择器注入，断言
// installPackFromFile 收到路径与错误展示）+「从 URL 安装」（假 controller
// 断言 manifest 地址/packId 传参、进度禁止重复点击、RemoteInstallReport
// .problem 展示）——网络层与文件读取本身归控制器（W2）测试。
//
// fake 注入：StyleSinkPort / ContactPersonaSink 用内存实现（experts_controller
// 的接口就是为此定义的），持久化用 SharedPreferences.setMockInitialValues，
// 文件选择器经 ExpertsPage.packFilePicker 注入。页面接线留 #13——这里直接
// pump 页面本体，不经过 main.dart。
// 内置包：控制器构造期走 core 磁盘探测（读 packages/core 真文件），load 前
// 页面即有货架。
import 'dart:async';
import 'dart:convert';

import 'package:chartools_app/application/experts_controller.dart';
import 'package:chartools_app/ui/experts_page.dart';
import 'package:chartools_core/chartools_core.dart' as kb;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryStyleSink implements StyleSinkPort {
  String _style = '';

  @override
  String get style => _style;

  @override
  set style(String value) => _style = value;

  @override
  Future<void> flush() async {}
}

class _MemoryContactSink implements ContactPersonaSink {
  _MemoryContactSink(this._targets);

  final List<ContactTarget> _targets;

  @override
  List<ContactTarget> get targets => _targets;

  @override
  Future<void> writePersona(String contactId, String persona) async {
    final i = _targets.indexWhere((t) => t.id == contactId);
    if (i < 0) throw StateError('联系人不存在');
    _targets[i] = ContactTarget(
        id: contactId, displayName: _targets[i].displayName, persona: persona);
  }
}

/// 「从文件导入 / 从 URL 安装」的假控制器：只重写这两个契约方法，记录调用
/// 参数并返回注入的结果（或抛出注入的异常对象）。其余方法走真实现——内置
/// 货架照常可浏览。RemoteInstallReport 的形状按契约字段
/// （ok/packId/version/expertsInstalled/problem，problem 用户可读中文）。
class _InstallFakeController extends ExpertsController {
  /// installPackFromFile 的注入结果：kb.InstallResult 或要抛的异常对象。
  Object? fileResult;

  /// installFromRemote 的注入结果：RemoteInstallReport 或要抛的异常对象。
  Object? remoteResult;

  /// 注入后 installFromRemote 挂起等 completer（测「拉取中禁止重复点击」）。
  Completer<RemoteInstallReport>? holdRemote;

  String? pickedFilePath;
  final List<({String url, String? packId})> remoteCalls = [];

  @override
  Future<kb.InstallResult> installPackFromFile(String filePath) async {
    pickedFilePath = filePath;
    final r = fileResult;
    if (r is! kb.InstallResult) throw r!; // 注入异常时原样抛出
    return r;
  }

  @override
  Future<RemoteInstallReport> installFromRemote(String manifestUrl,
      {String? packId}) async {
    remoteCalls.add((url: manifestUrl, packId: packId));
    final h = holdRemote;
    if (h != null) return h.future;
    final r = remoteResult;
    if (r is! RemoteInstallReport) throw r!; // 注入异常时原样抛出
    return r;
  }
}

/// 一份 core 形状的好包（经 PackCodec 严格校验解析出 ExpertPackData），
/// 给假控制器当「从文件导入」的成功返回。
const String _filePackJson =
    '{"format":"jev-expert-pack/1",'
    '"pack":{"id":"file-pack","version":"1.0.0","name":"文件包"},'
    '"experts":[{"id":"f.1","name":"文件专家","promptText":"称呼：你"}]}';

kb.InstallResult _okFileResult() {
  final parsed = kb.PackCodec.parse(_filePackJson);
  expect(parsed.ok, isTrue);
  return kb.InstallResult(
      ok: true, action: kb.InstallAction.installed, pack: parsed.pack);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MemoryStyleSink sink;
  late _MemoryContactSink contactSink;
  late ExpertsController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sink = _MemoryStyleSink();
    // 一位已写专用人设的联系人：触发 StyleSource 优先级的确认弹窗（core
    // ExpertApply 的 needsChoice 判定）。
    contactSink = _MemoryContactSink([
      const ContactTarget(id: 'c1', displayName: '小测', persona: '旧人设'),
    ]);
    controller = ExpertsController(styleSink: sink, contactSink: contactSink);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ExpertsPage(controller: controller))));
    await tester.pumpAndSettle();
  }

  testWidgets('目录浏览：搜索命中正文，标签筛选生效', (tester) async {
    await pumpPage(tester);

    // 内置示例包整架在列（按名字序，断言两位代表即可）。
    expect(find.text('日常闲聊'), findsOneWidget);
    expect(find.text('销售·跟单'), findsOneWidget);

    // 搜索命中正文里的「避谈：稳赚」——用户记得的是卡上那句话。
    await tester.enterText(find.byKey(const Key('experts_search')), '稳赚');
    await tester.pumpAndSettle();
    expect(find.text('日常闲聊'), findsNothing);
    expect(find.text('销售·跟单'), findsOneWidget);

    // 清空搜索，改走标签筛选：#先接情绪 只留客服·投诉安抚。
    await tester.enterText(find.byKey(const Key('experts_search')), '');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('#先接情绪'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#先接情绪'));
    await tester.pumpAndSettle();
    expect(find.text('客服·投诉安抚'), findsOneWidget);
    expect(find.text('日常闲聊'), findsNothing);
  });

  testWidgets('详情：promptText 预览 + 套用为全局风格（StyleSource 确认后生效）', (tester) async {
    await pumpPage(tester);
    final item = controller.shelfUnfiltered
        .firstWhere((i) => i.presetKey == 'daily.friend');

    await tester.tap(find.text('日常闲聊'));
    await tester.pumpAndSettle();

    // 预览与真实进提示词的东西同一条路径（PersonaCard.promptText）。
    expect(find.textContaining('<persona_card>'), findsOneWidget);
    expect(find.textContaining('称呼：用平时的叫法'), findsOneWidget);
    // 来源追踪：内置包样品标明来自哪个包（core 来源：builtin@1.0.0）。
    expect(find.textContaining('来源：seed:builtin'), findsOneWidget);

    // 联系人已有专用人设 → StyleSource 优先级提示弹窗，确认才套用。
    await tester.ensureVisible(find.byKey(const Key('experts_apply_global')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('experts_apply_global')));
    await tester.pumpAndSettle();
    expect(find.text('部分联系人不会生效'), findsOneWidget);
    expect(find.textContaining('专用人设优先于全局风格'), findsOneWidget);

    await tester.tap(find.byKey(const Key('experts_confirm_shadowed')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已套用为全局风格'), findsOneWidget);
    // 全局风格正文 = 专家正文原样。
    expect(sink.style, item.body);
    // 套用同时落库（我的专家库有了这条，货架不再出样品）。
    expect(controller.installed.value, hasLength(1));
    expect(controller.installed.value.first.key, 'daily.friend');
  });

  testWidgets('套用为联系人人设：needsChoice → 覆盖确认 → 写入 persona', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('恋爱·冷战破冰'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('experts_apply_contact')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('experts_apply_contact')));
    await tester.pumpAndSettle();

    // 目标列表标出「已有专用人设（套用将覆盖）」。
    expect(find.text('小测'), findsOneWidget);
    expect(find.text('已有专用人设（套用将覆盖）'), findsOneWidget);
    await tester.tap(find.text('小测'));
    await tester.pumpAndSettle();

    // core ExpertApply 判定冲突（needsChoice）→ 弹覆盖/并存二选一。
    expect(find.text('覆盖「小测」的专用人设？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('experts_confirm_overwrite')));
    await tester.pumpAndSettle();

    expect(find.textContaining('已套用为「小测」的专用人设'), findsOneWidget);
    expect(
        contactSink.targets.first.persona,
        controller.shelfUnfiltered
            .firstWhere((i) => i.presetKey == 'love.coldwar')
            .body);
  });

  testWidgets('套用为联系人人设：并存套用 → 只写全局风格，专用人设保留', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('恋爱·冷战破冰'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('experts_apply_contact')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('experts_apply_contact')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('小测'));
    await tester.pumpAndSettle();

    // 冲突选择收敛到 core ExpertApply 的 needsChoice 语义：除覆盖外还要提供
    // 并存（只写全局风格，专用人设保留并继续压全局）。
    expect(find.text('覆盖「小测」的专用人设？'), findsOneWidget);
    await tester.tap(find.text('并存套用'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已并存套用'), findsOneWidget);
    // 全局风格换成专家正文……
    expect(
        sink.style,
        controller.shelfUnfiltered
            .firstWhere((i) => i.presetKey == 'love.coldwar')
            .body);
    // ……而专用人设原句未动（StyleSource：TA 继续压全局）。
    expect(contactSink.targets.first.persona, '旧人设');
  });

  testWidgets('资产包管理区：已安装列表 + 粘贴安装（坏包如实报错、好包走 core 校验、卸载）',
      (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byTooltip('资产包'));
    await tester.pumpAndSettle();
    expect(find.text('内置示例专家'), findsOneWidget);
    expect(find.textContaining('5 位专家'), findsOneWidget);
    // 安装三入口（#15）：粘贴 / 从文件导入 / 从 URL 安装。
    expect(find.byKey(const Key('experts_install_pack')), findsOneWidget);
    expect(find.byKey(const Key('experts_install_from_file')), findsOneWidget);
    expect(find.byKey(const Key('experts_install_from_url')), findsOneWidget);
    // 内置包是货架底座：不给卸载按钮（core 也会拒绝，双保险）。
    expect(find.byIcon(Icons.delete_outline), findsNothing);

    // 安装入口一（粘贴 JSON）：坏包报错不留半装的包。
    await tester.tap(find.byKey(const Key('experts_install_pack')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('experts_pack_json')), 'not-json');
    await tester.tap(find.byKey(const Key('experts_pack_install_confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('安装失败'), findsOneWidget);
    expect(controller.packs, hasLength(1));

    // 等失败 SnackBar 走完（默认 4s），避免它盖住 sheet 里的安装按钮。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // 好包（core 形状）：重开安装弹层，粘贴安装成功，货架出现新专家，
    // 出现卸载按钮。
    await tester.tap(find.byKey(const Key('experts_install_pack')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('experts_pack_json')),
      '{"format":"jev-expert-pack/1",'
      '"pack":{"id":"external","version":"1.0.0","name":"外部包"},'
      '"experts":[{"id":"ext.1","name":"外部专家","promptText":"称呼：你","domain":"日常"}]}',
    );
    await tester.tap(find.byKey(const Key('experts_pack_install_confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已安装「外部包」'), findsOneWidget);
    expect(controller.packs, hasLength(2));
    expect(
        controller.shelfUnfiltered.any((i) => i.presetKey == 'ext.1'), isTrue);

    // 等成功 SnackBar 走完（默认 4s，与上方失败 SnackBar 的处理同一招）：
    // SnackBar 是排队的——「已安装」还挂着时卸载提示只能进队列，而排队不
    // 调度帧，pumpAndSettle 的静帧窗口里它永远不会进树，find 就扑空。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // 卸载外部包：core uninstall 语义。
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.textContaining('已卸载「外部包」'), findsOneWidget);
    expect(controller.packs, hasLength(1));
    expect(
        controller.shelfUnfiltered.any((i) => i.presetKey == 'ext.1'), isFalse);
  });

  // ------------------------------------------------- 我的自建专家（mine）

  testWidgets('新建 mine 专家：网格出现 + mine 来源徽章 +「我的库」快筛 + 存档往返',
      (tester) async {
    // 表单比默认测试视口（800x600）高：把表面加高到 900，让整张表单免滚动，
    // 保存键必在视口内（默认视口下测试绑定里的滚动会被 onChanged 重排/焦点
    // 拉扯打断，保存键中心会落在视口外，tap 打空）。addTearDown 恢复，不串
    // 到别的测试。
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('experts_mine_new')));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const Key('experts_mine_name')), '我的测试专家');
    await tester.enterText(
        find.byKey(const Key('experts_mine_address')), '叫我小测');
    await tester.enterText(
        find.byKey(const Key('experts_mine_relation')), '朋友');
    await tester.enterText(find.byKey(const Key('experts_mine_tone')), '口语、松弛');
    await tester.enterText(find.byKey(const Key('experts_mine_scene')), '深夜聊天');
    await tester.enterText(
        find.byKey(const Key('experts_mine_boundaries')), '家人、前任');
    await tester.enterText(find.byKey(const Key('experts_mine_safeword')), '红灯');
    await tester.enterText(find.byKey(const Key('experts_mine_avoid')), '稳赚、保证收益');

    await tester.ensureVisible(find.byKey(const Key('experts_mine_save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('experts_mine_save')));
    await tester.pumpAndSettle();

    expect(find.textContaining('已新建「我的测试专家」'), findsOneWidget);
    final list = controller.installed.value;
    expect(list, hasLength(1));
    // 契约：mine 来源专家 id 形如 mine:<时间戳或uuid>。
    expect(list.first.id, startsWith('mine:'));
    // 对话框字段 → promptText 的拼装：PersonaCard 卡片键原文，
    // 硬边界/避谈数组用顿号连接（与对话框原词一一对应）。
    expect(list.first.promptText, contains('称呼：叫我小测'));
    expect(list.first.promptText, contains('关系：朋友'));
    expect(list.first.promptText, contains('语气：口语、松弛'));
    expect(list.first.promptText, contains('情境：深夜聊天'));
    expect(list.first.promptText, contains('硬边界：家人、前任'));
    expect(list.first.promptText, contains('安全词：红灯'));
    expect(list.first.promptText, contains('避谈：稳赚、保证收益'));

    // 落盘：experts_v2 存档里有这条，meta 来源标 mine。
    final prefs = await SharedPreferences.getInstance();
    final decoded =
        jsonDecode(prefs.getString(ExpertsController.libraryKeyV2)!) as Map;
    final entry = (decoded['entries'] as List).single as Map;
    expect((entry['expert'] as Map)['id'] as String, startsWith('mine:'));
    expect((entry['meta'] as Map)['sourceRef'] as String, 'mine');

    // 「我的库」快筛：网格里只剩这条，来源徽章 mine；目录样品被滤掉。
    await tester.tap(find.byKey(const Key('experts_filter_mine')));
    await tester.pumpAndSettle();
    expect(find.text('我的测试专家'), findsOneWidget);
    expect(find.text('mine'), findsOneWidget);
    expect(find.text('日常闲聊'), findsNothing);
  });

  testWidgets('编辑 mine 专家：表单预填原卡原词；改名改正文落盘往返（重开控制器验证）',
      (tester) async {
    // 表面加高到 900 让表单免滚动（理由同上）。
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final created = await controller.createMineExpert(
        name: '编辑前', promptText: '称呼：旧称呼\n硬边界：不要熬夜');

    await pumpPage(tester);
    await tester.ensureVisible(find.text('编辑前'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑前'));
    await tester.pumpAndSettle();

    // 详情页有 mine 管理行（编辑/删除），进编辑器。
    await tester.ensureVisible(find.byKey(const Key('experts_mine_edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('experts_mine_edit')));
    await tester.pumpAndSettle();

    // 预填：名称/称呼来自原卡；硬边界取原文行的原词——不是 PersonaCard.parse
    // 展开后的关键词集合（那会把「不要熬夜」补成「熬夜」等变体，越滚越多）。
    String textOf(String key) => tester
        .widget<TextFormField>(find.byKey(Key(key)))
        .controller!
        .text;
    expect(textOf('experts_mine_name'), '编辑前');
    expect(textOf('experts_mine_address'), '旧称呼');
    expect(textOf('experts_mine_boundaries'), '不要熬夜');

    await tester.enterText(find.byKey(const Key('experts_mine_name')), '编辑后');
    await tester.enterText(find.byKey(const Key('experts_mine_address')), '新称呼');

    await tester.ensureVisible(find.byKey(const Key('experts_mine_save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('experts_mine_save')));
    await tester.pumpAndSettle();

    expect(find.textContaining('已保存「编辑后」'), findsOneWidget);
    final edited =
        controller.installed.value.firstWhere((e) => e.id == created.id);
    expect(edited.name, '编辑后');
    expect(edited.promptText, contains('称呼：新称呼'));
    // 没进本次编辑的字段从原卡保留（硬边界原词不丢）。
    expect(edited.promptText, contains('硬边界：不要熬夜'));
    // 契约：仅 mine 条目可改——id/来源不动。
    expect(edited.id, startsWith('mine:'));

    // 落盘往返：重开控制器 load 后，名字与正文都是改后的。
    final reloaded = ExpertsController(styleSink: sink, contactSink: contactSink);
    await reloaded.load();
    final fromDisk =
        reloaded.installed.value.firstWhere((e) => e.id == created.id);
    expect(fromDisk.name, '编辑后');
    expect(fromDisk.promptText, contains('称呼：新称呼'));
    expect(fromDisk.promptText, contains('硬边界：不要熬夜'));
  });

  testWidgets('删除 mine 专家：确认后从我的库与存档消失', (tester) async {
    final created = await controller.createMineExpert(
        name: '待删除', promptText: '称呼：你');
    expect(created.id, startsWith('mine:'));

    await pumpPage(tester);
    await tester.ensureVisible(find.text('待删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('待删除'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('experts_mine_delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('experts_mine_delete')));
    await tester.pumpAndSettle();

    // 确认弹窗（personas 删除同款文案）。
    expect(find.text('删除「待删除」？'), findsOneWidget);
    expect(find.text('删除后不可恢复。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('experts_mine_delete_confirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('已删除「待删除」'), findsOneWidget);
    expect(controller.installed.value, isEmpty);
    expect(find.text('待删除'), findsNothing);

    // 存档：entries 清空（persist 写的是整库）。
    final prefs = await SharedPreferences.getInstance();
    final decoded =
        jsonDecode(prefs.getString(ExpertsController.libraryKeyV2)!) as Map;
    expect(decoded['entries'] as List, isEmpty);
  });

  testWidgets('契约护栏：seed 来源的入库条目不给编辑/删除入口；update/delete 拒改非 mine',
      (tester) async {
    await pumpPage(tester);
    // 把一个内置样品落库（来源 seed:builtin）——套用链路的既有行为。
    final seedItem = controller.shelfUnfiltered
        .firstWhere((i) => i.presetKey == 'daily.friend');
    final applied = await controller.applyAsGlobalStyle(seedItem);
    expect(applied.ok, isTrue);

    // 入库条目的详情页：没有 mine 编辑/删除入口（不给会失败的入口）。
    await tester.tap(find.text('日常闲聊'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('experts_mine_edit')), findsNothing);
    expect(find.byKey(const Key('experts_mine_delete')), findsNothing);

    // 契约：updateMineExpert / deleteMineExpert 对非 mine 来源抛 ArgumentError。
    final libId = controller.installed.value.single.id;
    await expectLater(
        controller.updateMineExpert(libId, name: '改名'), throwsArgumentError);
    await expectLater(
        controller.deleteMineExpert(libId), throwsArgumentError);
  });

  // ------------------------------------ 对话框字段 → promptText 拼装（纯函数）

  group('对话框字段 → promptText 拼装（ExpertPromptCard 纯函数）', () {
    test('七字段拼装：硬边界/避谈数组用顿号连接，顺序即表单顺序', () {
      expect(
          ExpertPromptCard.assemble(
            address: '你',
            relation: '朋友',
            tone: '口语、松弛',
            scene: '深夜聊天',
            boundaries: ['家人', '前任'],
            safeword: '红灯',
            avoid: ['稳赚', '保证收益'],
          ),
          '称呼：你\n关系：朋友\n语气：口语、松弛\n情境：深夜聊天\n'
          '硬边界：家人、前任\n安全词：红灯\n避谈：稳赚、保证收益');
    });

    test('没进表单的卡内容（主题/黄灯/语域/示例/未识别行）从原卡保留', () {
      final base = kb.PersonaCard.parse(
          '主题：销售\n语域：开\n黄灯：缓一缓\n示例：\n我：王总\n对方：嗯\n随口一句');
      final out = ExpertPromptCard.assemble(
          base: base, address: '王总', boundaries: ['稳赚']);
      expect(out, contains('称呼：王总'));
      expect(out, contains('主题：销售'));
      expect(out, contains('语域：开'));
      expect(out, contains('黄灯：缓一缓'));
      expect(out, contains('硬边界：稳赚'));
      expect(out, contains('示例：\n我：王总\n对方：嗯'));
      expect(out, contains('随口一句'));
    });

    test('splitList 与 rawListText：预填取原文行的原词，不取解析展开的关键词', () {
      expect(ExpertPromptCard.splitList('家人、前任,稳赚；x/y'),
          ['家人', '前任', '稳赚', 'x', 'y']);
      const raw = '硬边界：不要提家人\n避谈：稳赚、保证收益\n示例：\n我：hi';
      expect(ExpertPromptCard.rawListText(raw, ExpertPromptCard.boundaryKeys),
          '不要提家人');
      expect(ExpertPromptCard.rawListText(raw, ExpertPromptCard.avoidKeys),
          '稳赚、保证收益');
      // 对照：parse 的展开集合确实含变体（这正是预填走原文行的原因）。
      expect(kb.PersonaCard.parse(raw).boundaries,
          containsAll(['不要提家人', '提家人', '家人']));
    });
  });

  // --------------------------------------------- 资产包：从文件导入（假选择器）

  testWidgets('从文件导入：路径传给 installPackFromFile，成功提示导入结果', (tester) async {
    final fake = _InstallFakeController()..fileResult = _okFileResult();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ExpertsPage(
          controller: fake,
          packFilePicker: () async => XFile('C:/tmp/file-pack.json'),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('资产包'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('experts_install_from_file')));
    await tester.pumpAndSettle();

    // 契约调用：installPackFromFile 收到选择器给的路径。
    expect(fake.pickedFilePath, 'C:/tmp/file-pack.json');
    expect(find.textContaining('已从文件导入「文件包」'), findsOneWidget);
  });

  testWidgets('从文件导入：取消选择不调用控制器；不可读文件按契约报可读错误', (tester) async {
    final fake = _InstallFakeController();
    XFile? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ExpertsPage(controller: fake, packFilePicker: () async => picked),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('资产包'));
    await tester.pumpAndSettle();

    // 用户取消：控制器没被调用、没有错误提示。
    await tester.tap(find.byKey(const Key('experts_install_from_file')));
    await tester.pumpAndSettle();
    expect(fake.pickedFilePath, isNull);

    // 文件读不了（契约：非 UTF-8 报可读错误——控制器以 FormatException 抛出）。
    picked = XFile('C:/tmp/broken.json');
    fake.fileResult = const FormatException('文件不是 UTF-8，读不了');
    await tester.tap(find.byKey(const Key('experts_install_from_file')));
    await tester.pumpAndSettle();
    expect(fake.pickedFilePath, 'C:/tmp/broken.json');
    expect(find.textContaining('导入失败：文件不是 UTF-8'), findsOneWidget);

    // 失败以报告返回的形状（InstallResult.ok=false）也要照实展示 problem。
    await tester.pump(const Duration(seconds: 5)); // 上一条 SnackBar 走完（排队）
    await tester.pumpAndSettle();
    picked = XFile('C:/tmp/missing.json');
    fake.fileResult = kb.InstallResult(ok: false, problem: '文件不存在');
    await tester.tap(find.byKey(const Key('experts_install_from_file')));
    await tester.pumpAndSettle();
    expect(fake.pickedFilePath, 'C:/tmp/missing.json');
    expect(find.text('文件不存在'), findsOneWidget);
  });

  // ------------------------------------------- 资产包：从 URL 安装（假控制器）

  testWidgets('从 URL 安装：manifest 地址与可选 packId 传给控制器，成功提示报告', (tester) async {
    final fake = _InstallFakeController()
      ..remoteResult = RemoteInstallReport(
          ok: true,
          packId: 'demo-pack',
          version: '1.2.0',
          expertsInstalled: 2,
          problem: '');
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ExpertsPage(controller: fake))));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('资产包'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('experts_install_from_url')));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const Key('experts_remote_url')),
        'https://example.com/experts-manifest.json');
    await tester.enterText(
        find.byKey(const Key('experts_remote_pack_id')), 'demo-pack');
    await tester.tap(find.byKey(const Key('experts_remote_confirm')));
    await tester.pumpAndSettle();

    // 契约调用：manifestUrl 逐字、packId 高级框可选传入。
    expect(fake.remoteCalls, hasLength(1));
    expect(fake.remoteCalls.single.url,
        'https://example.com/experts-manifest.json');
    expect(fake.remoteCalls.single.packId, 'demo-pack');
    // 成功提示来自 RemoteInstallReport 的字段。
    expect(find.textContaining('已安装资产包「demo-pack」v1.2.0：2 位专家'),
        findsOneWidget);
  });

  testWidgets('从 URL 安装：失败把 RemoteInstallReport.problem 留在弹层里，可重试',
      (tester) async {
    final fake = _InstallFakeController()
      ..remoteResult = RemoteInstallReport(
          ok: false,
          packId: '',
          version: '',
          expertsInstalled: 0,
          problem: '清单拉取失败：404');
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ExpertsPage(controller: fake))));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('资产包'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('experts_install_from_url')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('experts_remote_url')),
        'https://example.com/experts-manifest.json');
    await tester.tap(find.byKey(const Key('experts_remote_confirm')));
    await tester.pumpAndSettle();

    // packId 留空 = null（契约：装清单里的最新/第一个）。
    expect(fake.remoteCalls.single.packId, isNull);
    // 失败：弹层不关，problem 原样展示（用户可改地址重试）。
    expect(find.text('清单拉取失败：404'), findsOneWidget);
    expect(find.byKey(const Key('experts_remote_confirm')), findsOneWidget);

    // 改后重试成功。
    fake.remoteResult = RemoteInstallReport(
        ok: true,
        packId: 'demo-pack',
        version: '1.0.0',
        expertsInstalled: 1,
        problem: '');
    await tester.tap(find.byKey(const Key('experts_remote_confirm')));
    await tester.pumpAndSettle();
    expect(fake.remoteCalls, hasLength(2));
    expect(find.textContaining('已安装资产包「demo-pack」'), findsOneWidget);
  });

  testWidgets('从 URL 安装：拉取中显示进度并禁止重复点击', (tester) async {
    final fake = _InstallFakeController();
    final gate = Completer<RemoteInstallReport>();
    fake.holdRemote = gate;
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ExpertsPage(controller: fake))));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('资产包'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('experts_install_from_url')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('experts_remote_url')),
        'https://example.com/experts-manifest.json');

    await tester.tap(find.byKey(const Key('experts_remote_confirm')));
    // 进行中：进度文案出现（转圈动画永不 settle，定帧 pump）。
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('正在拉取清单并安装…'), findsOneWidget);
    // 禁止重复点击：确认键已禁用，再点不产生第二次调用。
    await tester.tap(find.byKey(const Key('experts_remote_confirm')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(fake.remoteCalls, hasLength(1));

    gate.complete(RemoteInstallReport(
        ok: true,
        packId: 'demo-pack',
        version: '1.0.0',
        expertsInstalled: 3,
        problem: ''));
    await tester.pumpAndSettle();
    expect(find.textContaining('已安装资产包「demo-pack」'), findsOneWidget);
  });
}

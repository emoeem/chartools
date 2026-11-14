/// 专家库的应用层 —— #13 收敛后的唯一实现：**一切包语义走 core 三件套**。
///
/// 独立复核裁定（#12 复核 high，docs/expert-pack-format.md 头部）：app 自有的
/// `ExpertPreset/ExpertPack/ExpertCatalog/ExpertSort/StyleSink` 与 core 三件套
/// 平行不兼容——同一份远端包两套解析器必有一边全量跳过。本版按裁定收敛：
///
/// ┌─────────────────── 数据流（收敛后） ───────────────────┐
///  远端包 JSON → [_normalizePackJson]（条目级别名补齐，清单级结构不动）
///             → kb.ExpertPackManager.install（core：清单级严格校验 / 版本
///               仲裁 / 降级拒装 / builtin 保留 id，expert_pack.dart:313）
///             → PrefsPackStore（新键 expert_packs_v2，KV 原文单键存储）
///  货架        → kb.ExpertPackManager.installed（内置包 + 已装包合并）
///             → kb.ExpertCatalog.filter/sort（浏览层纯函数，规则唯一出处）
///  套用        → kb.ExpertApply（needsChoice / 覆盖 / 并存 / 回滚唯一判定处）
///  持久化      → 旧键 experts / expert_packs **只读迁移**（别名互认，失败
///               计数进 loadProblems，绝不静默丢）；新键 experts_v2 /
///               expert_packs_v2 写 core 主拼写 promptText/domain，写永不回退旧键
/// └──────────────────────────────────────────────────────┘
///
/// 两条铁律沿袭 legacy PersonaProfile / core Expert 文档，收敛后不变：
/// 1. **浏览层 ≠ 提示词正文**：[ExpertShelfItem.description] / [tags] /
///    [category]（core 的 domain）/ [avatar]（core 的 emoji）只给人看；进
///    提示词的只有 [ExpertShelfItem.body]（core 的 promptText），页面的
///    promptText 预览仍经 `PersonaCard.parse(body).promptText()` 现算。
/// 2. **持久化只用 shared_preferences JSON**（p0-plan F2 边界不变：只有
///    API Key 走 secure storage）。与 ContactStore 的 `contacts` 键、
///    SettingsStore 的 `settings` 键互不相干。
///
/// UI 能力清单（对照 #12 版本逐项核对，不许变浅）：
/// - 领域分组/搜索/标签：领域 chips 走 core `ExpertCatalog.domains`（5 固定
///   领域在前、自定义领域按名跟后、未分类殿后）；搜索命中名字/简介/标签/**正文**
///   （core `ExpertCatalog.matches`）；标签行走 core `ExpertCatalog.tags`。
///   旧版 25 条 categoryOrder 清单是展示层概念：5 条固定领域由 core 接管，
///   其余 20 条本就只是「排后面」的顺序种子——现在由 core 的「自定义领域按名
///   排后 + tags 行」组合承接；旧数据迁移时 category 原样映射进 domain，
///   用户已有的分组 chip 一个都不会消失。
/// - 我的库：改名 / 改正文走 [renameLibraryEntry] / [updateLibraryBody]
///   （core Expert 不可变 → 造新实例，id 与来源不动）；自建（mine）条目的
///   新建/编辑/删除走 [createMineExpert] / [updateMineExpert] /
///   [deleteMineExpert]（id 形如 `mine:<时间戳>`，持久化并入我的库同一存档
///   键）；远端清单导入走 [installFromRemote]、本地文件导入走
///   [installPackFromFile]——两条导入最终都汇入 [installPackJson] 这一条
///   安装路径（校验/版本仲裁/落盘事务只在那一处）。
/// - 排序：综合/最热两档直接交给 core `ExpertCatalog.sort`（usage 由本层注入
///   ——core 不存使用计数，expert_catalog.dart:411 的评测钩子位）；**最新**
///   档是 app 展示层概念（货架条目没有编辑时间），按我的条目 updatedAt、
///   目录样品按所在包 importedAt 排，core 数据（来源 + 导入时间）支撑它。
library;

import 'dart:convert';
import 'dart:io' show File;

import 'package:chartools_core/chartools_core.dart' as kb;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import 'contact_store.dart';
import 'pack_fetch_service.dart';
import 'settings_store.dart';

// ---------------------------------------------------------------------------
// 数据模型
// ---------------------------------------------------------------------------

/// 「我的专家库」条目的 app 侧元数据。**条目本体是 core `kb.Expert`**（收敛后
/// 不再有 app 自有 ExpertProfile）；这里只存 core 模型装不下的三样东西：
/// 套用计数（最热/综合排序数据源）、最近编辑时间（最新档展示排序数据源）、
/// 来源展示串（旧存档 sourceRef 原样保留——迁移数据在 UI 上一个字都不变）。
class ExpertEntryMeta {
  const ExpertEntryMeta({
    this.usedCount = 0,
    this.updatedAt = 0,
    this.sourceRef = '',
  });

  /// 被套用次数（「最热」排序与综合分的数据源）。
  final int usedCount;

  /// 最近一次修改的毫秒时间戳（「最新」档展示排序的数据源）。
  final int updatedAt;

  /// **来源追踪**：这条专家从哪来。旧键迁移时原样保留（`pack:<包名>` /
  /// `seed:<包名>` / `mine`），新入库条目按 core 来源现算。
  final String sourceRef;

  ExpertEntryMeta copyWith({int? usedCount, int? updatedAt, String? sourceRef}) =>
      ExpertEntryMeta(
        usedCount: usedCount ?? this.usedCount,
        updatedAt: updatedAt ?? this.updatedAt,
        sourceRef: sourceRef ?? this.sourceRef,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'usedCount': usedCount,
        'updatedAt': updatedAt,
        'sourceRef': sourceRef,
      };

  /// 容错解析：类型不对的项落默认值，绝不抛（坏存档不挡启动）。
  factory ExpertEntryMeta.fromJson(Map<String, dynamic> j) => ExpertEntryMeta(
        usedCount: j['usedCount'] is int ? j['usedCount'] as int : 0,
        updatedAt: j['updatedAt'] is int ? j['updatedAt'] as int : 0,
        sourceRef: j['sourceRef'] is String ? j['sourceRef'] as String : '',
      );
}

/// 货架上的一条：**我的条目优先**（同 id 或同名时目录样品让位——legacy
/// ExpertShelf.kt 的双重判断，收敛后语义不变）。包装的是 core `kb.Expert`；
/// [body]/[category] 等页面字段名保持 #12 版本的词汇，页面只换数据来源不换话。
class ExpertShelfItem {
  const ExpertShelfItem.mine(this.expert, this.meta) : inLibrary = true;

  const ExpertShelfItem.ghost(this.expert)
      : meta = null,
        inLibrary = false;

  final kb.Expert expert;

  /// 我的库元数据；目录样品为 null。
  final ExpertEntryMeta? meta;

  /// 我的库里已有这一条。
  final bool inLibrary;

  /// 全局稳定 id（`pack:<packId>/<key>`；自建条目是 `x_` 开头的旧形状）。
  String get id => expert.id;

  String get name => expert.name;

  /// 唯一进提示词的正文（core Expert.promptText）。
  String get body => expert.promptText;

  /// 浏览层领域（core 主拼写 domain；旧页面叫「分类」，字段名保留）。
  String get category => expert.domain;
  List<String> get tags => expert.tags;
  String get description => expert.description;

  /// 浏览层 emoji（core 默认占位 🧩）。
  String get avatar => expert.emoji;
  int get usedCount => meta?.usedCount ?? 0;
  bool get builtin => expert.isBuiltin;

  /// 包内稳定键（旧 presetKey 的对应物）。
  String get presetKey => expert.key;

  /// 来源追踪展示串：已入库的显示落库时记下的 sourceRef；样品按 core 来源
  /// 现算（内置包 `seed:<id>`、远端包 `pack:<id>`、自建 `mine`）。
  String get sourceRef {
    final sr = meta?.sourceRef ?? '';
    return sr.isEmpty ? _sourceRefOf(expert) : sr;
  }

  static String _sourceRefOf(kb.Expert e) {
    final packId = e.source.packId;
    if (packId.isEmpty) return 'mine';
    return e.isBuiltin ? 'seed:$packId' : 'pack:$packId';
  }
}

/// 展示层排序：综合/最热两档直接交给 core `ExpertCatalog.sort`（规则唯一
/// 出处）；[newest] 是 app 展示层概念（core ExpertSort 没有也不该有——货架
/// 条目没有编辑时间），由控制器按 meta.updatedAt / 包 importedAt 排。
enum ExpertSort {
  comprehensive('综合'),
  hottest('最热'),
  newest('最新');

  const ExpertSort(this.label);

  /// 界面 tab 的字面量，改它等于改 UI 契约。
  final String label;
}

// ---------------------------------------------------------------------------
// 套用通道（sink 适配）
// ---------------------------------------------------------------------------

/// 全局风格写入口（app 侧端口）。core 的 StyleSink（expert_apply.dart:44）是
/// **同步**接口——ExpertApply 的「写失败回滚」在同步 setter 上判定；盘上的
/// 成败由 [flush] 上交，控制器在套用成功后 await 它并兜底回滚（内存+盘一起
/// 要么成、要么还原），保证「要么全成、要么不留半截」覆盖到落盘。
abstract class StyleSinkPort implements kb.StyleSink {
  /// 把内存态落盘；失败抛出（调用方负责回滚与报错）。
  Future<void> flush();
}

/// [StyleSinkPort] 的 SettingsStore 适配器：同步改内存 `config.style`，
/// 异步整包落盘。settings_store.dart 不由本工作流改动，只 import 消费。
class SettingsStyleSink implements StyleSinkPort {
  SettingsStyleSink(this.store);

  final SettingsStore store;

  /// 最近一次 setter 触发的落盘任务；flush 等的就是它（连写多次取最后一次）。
  Future<void>? _pending;

  @override
  String get style => store.config.value.style;

  @override
  set style(String value) {
    store.config.value = store.config.value.copyWith(style: value);
    _pending = store.save();
  }

  @override
  Future<void> flush() => _pending ?? Future<void>.value();
}

/// 联系人档案对套用动作暴露的最小面：目标快照 + 覆写专用人设。接口隔离，
/// 测试用内存实现，接线用 [ContactStorePersonaSink]。
abstract class ContactPersonaSink {
  /// 当前全部联系人（页面选套用目标用；[ContactTarget.persona] 供页面标注
  /// 「已有专用人设」——判定走 [ExpertsController.contactHasPersona]）。
  List<ContactTarget> get targets;

  /// 覆写联系人的专用人设正文。目标不存在时抛 StateError（与
  /// ContactStore.update 对缺失 id 的行为一致）。
  Future<void> writePersona(String contactId, String persona);
}

/// 联系人目标快照：套用确认弹窗需要「有没有专用人设」这个当下事实。
class ContactTarget {
  const ContactTarget({
    required this.id,
    required this.displayName,
    required this.persona,
  });

  final String id;
  final String displayName;
  final String persona;
}

/// [ContactPersonaSink] 的 ContactStore 适配器（contact_store.dart 只读不写，
/// 本工作流不碰它）。
class ContactStorePersonaSink implements ContactPersonaSink {
  ContactStorePersonaSink(this.store);

  final ContactStore store;

  @override
  List<ContactTarget> get targets => <ContactTarget>[
        for (final c in store.contacts.value)
          ContactTarget(
              id: c.id, displayName: c.displayName, persona: c.persona),
      ];

  @override
  Future<void> writePersona(String contactId, String persona) async {
    final c = store.byId(contactId);
    if (c == null) {
      throw StateError('ContactStorePersonaSink.writePersona: '
          '联系人不存在（$contactId）');
    }
    await store.update(c.copyWith(persona: persona));
  }
}

/// 一次套用的结果。[needsChoice] 为 true 时**什么都没写**——core
/// ExpertApply 检测到「专用人设压全局」的冲突，等界面问完用户（覆盖/并存）
/// 再带 `kb.ConflictChoice` 调一次。[profile] 非空表示库里那条已就位（失败
/// 路径也保留——它是完整的合法条目，删才是二次破坏）。
class ExpertApplyResult {
  const ExpertApplyResult({
    required this.ok,
    this.needsChoice = false,
    this.profile,
    this.warning = '',
    this.problem = '',
    this.note = '',
  });

  final bool ok;
  final bool needsChoice;
  final kb.Expert? profile;

  /// 降级说明（热度没记上一类），不影响使用。
  final String warning;

  /// 失败原因，给界面直接显示。
  final String problem;

  /// core 的冲突/优先级提示文案（needsChoice 与并存路径都有，界面照实念）。
  final String note;
}

/// 一次远端安装的结果（[ExpertsController.installFromRemote] 的返回）。
/// ok=false 时 [problem] 给界面直接显示（用户可读中文，含失败在哪一步）；
/// 成功时 packId / version / expertsInstalled 描述装到了什么
/// （expertsInstalled 是该包在货架上的可用专家条数——幂等安装返回的是
/// 已装那份的条数）。
class RemoteInstallReport {
  const RemoteInstallReport({
    required this.ok,
    this.packId = '',
    this.version = '',
    this.expertsInstalled = 0,
    this.problem = '',
  });

  final bool ok;
  final String packId;
  final String version;
  final int expertsInstalled;

  /// 失败/拒绝原因，给界面直接显示。
  final String problem;
}

// ---------------------------------------------------------------------------
// 包持久化（PackStore 的 SharedPreferences 实现）
// ---------------------------------------------------------------------------

/// `kb.PackStore` 的 SharedPreferences 实现。**单键存整包映射**：packId 只作
/// JSON 键（纯数据），绝不拼平台键名/文件路径——core 对 packId 只拦 `/`，
/// `..\`、控制字符等由实现方拒绝；KV 原文存储是 expert_pack.dart:156 建议
/// 的最稳做法（与 MemoryPackStore 同款思路）。存的是「收到的原文 + 条目级
/// 别名补齐主拼写」的归一化形（见 [ExpertsController._normalizePackJson]：
/// format/pack/experts 结构与语义不动）。
class PrefsPackStore implements kb.PackStore {
  /// 新键：packId → 包清单原文（JSON map 单键存储）。
  static const String storageKey = 'expert_packs_v2';

  final Map<String, String> _mem = <String, String>{};

  /// 读盘灌内存。返回 true = 新键在盘上且可解析（迁移已完成，不重走旧键）；
  /// false = 新键缺席/损坏 → 调用方走旧键迁移。平台通道不可用时也返回 true
  /// （走内存模式，别再触发迁移写盘）。
  Future<bool> hydrate(List<String> problems) async {
    _mem.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null) return false; // 没迁移过
      if (raw.isEmpty) return true;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((k, v) {
          if (v is String && v.isNotEmpty) _mem[k as String] = v;
        });
        return true;
      }
      problems.add('资产包存档（$storageKey）形状不对，按旧键重新迁移');
      return false;
    } on FormatException {
      problems.add('资产包存档（$storageKey）不是合法 JSON，按旧键重新迁移');
      return false;
    } catch (e) {
      problems.add('资产包存档读取失败（$e），本次会话改动不会持久化');
      return true;
    }
  }

  @override
  Map<String, String> loadAll() => Map.of(_mem);

  @override
  void save(String packId, String rawJson) => _mem[packId] = rawJson;

  @override
  void remove(String packId) => _mem.remove(packId);

  /// 安装/卸载落盘失败时的回滚：整包映射还原成进来时的快照。
  void restoreSnapshot(Map<String, String> snapshot) {
    _mem
      ..clear()
      ..addAll(snapshot);
  }

  /// 内存态写盘。失败原样上抛——调用方（控制器）负责回滚与报错。
  Future<void> flush() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(_mem));
  }
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

/// 专家库控制器：内置包 + 已装资产包（core ExpertPackManager）+ 我的库
/// （core Expert + 本层元数据）+ 套用（core ExpertApply）。
///
/// 页面接线留 **#13**：main.dart 不由本工作流改动；接线时构造
/// `ExpertsController(styleSink: SettingsStyleSink(settings), contactSink:
/// ContactStorePersonaSink(contacts))` 并调 [load]。
class ExpertsController {
  ExpertsController({
    StyleSinkPort? styleSink,
    ContactPersonaSink? contactSink,
    PrefsPackStore? packStore,
    PackFetchService? fetchService,
  })  : _styleSink = styleSink,
        _contactSink = contactSink,
        _packStore = packStore ?? PrefsPackStore(),
        _fetchService = fetchService ?? const PackFetchService() {
    // 内置包：构造期先做一次**同步磁盘探测**（VM / 测试 / 桌面开发路径能直接
    // 找到 packages/core/assets/experts/catalog.json）——页面在 load() 之前也
    // 有货架可看；load() 会用 rootBundle/磁盘/内嵌镜像三层的最终结果重建。
    _manager = kb.ExpertPackManager(
        _packStore, builtinJson: kb.readBuiltinCatalogJson());
    _apply = kb.ExpertApply(sink: _styleSink);
    _refreshPacks();
  }

  /// 旧 shared_preferences 键（**只读兼容**；写永不回退到这两个键）：
  /// - `$legacyLibraryKey`：旧 ExpertProfile 整包（body/presetKey/sourceRef…）；
  /// - `$legacyPacksKey`：旧 ExpertPack 原文列表（无 format、无 pack 对象）。
  static const String legacyLibraryKey = 'experts';
  static const String legacyPacksKey = 'expert_packs';

  /// 新键：我的库整包（条目 + 元数据 + 包导入时间），写 core 主拼写
  /// promptText/domain（读取时仍按别名互认，docs/expert-pack-format.md §2）。
  static const String libraryKeyV2 = 'experts_v2';

  /// 内置包保留 id（core ExpertPackManager.builtinPackId 的透传）——页面据此
  /// 隐藏内置包的卸载按钮（core 也会拒绝，双保险）。
  static const String builtinPackId = kb.ExpertPackManager.builtinPackId;

  final StyleSinkPort? _styleSink;
  final ContactPersonaSink? _contactSink;
  final PrefsPackStore _packStore;

  /// 远端清单/包体拉取（HTTP 细节在 core HttpJson.get，解析校验在 core
  /// 两个 Codec——本类只用它的结果，见 pack_fetch_service.dart）。
  final PackFetchService _fetchService;

  late kb.ExpertPackManager _manager;
  late kb.ExpertApply _apply;

  /// 我的专家库（存档顺序即展示顺序；写回永远换新 List，ValueNotifier 按
  /// identical 判定——与 ContactStore.contacts 同一纪律）。
  final ValueNotifier<List<kb.Expert>> installed =
      ValueNotifier(const <kb.Expert>[]);

  /// 已装载的资产包：第 0 位恒为内置包，其余按 pack.id 字典序（core 快照语义）。
  final ValueNotifier<List<kb.ExpertPackData>> _packs =
      ValueNotifier(const <kb.ExpertPackData>[]);

  /// 已装包快照里的坏包消息（core：坏包被忽略而不是被删除，照实说）。
  final ValueNotifier<List<String>> packProblems =
      ValueNotifier(const <String>[]);

  final List<kb.Expert> _library = <kb.Expert>[];
  final Map<String, ExpertEntryMeta> _meta = <String, ExpertEntryMeta>{};

  /// packId → 导入时间（「最新」档对目录样品的数据源；挂在我的库存档里持久化）。
  final Map<String, int> _packImportedAt = <String, int>{};

  List<String> _loadProblems = const <String>[];
  List<String> _loadNotes = const <String>[];
  int _lastStamp = 0;

  /// dispose 之后的 notifier 写入守卫。#13 接线（main.dart 的 _PageHost）是
  /// 「push 构造 + ..load()、pop 即 dispose」——load 的续体在
  /// shared_preferences 返回后才走，用户在那一刻之前 pop 掉页面，续体就会
  /// 往已 dispose 的 ValueNotifier 写值（debug 断言崩）。守卫让这些续体变成
  /// 静默 no-op：盘上状态已由 persist 落好，内存态随实例一起销毁，无须补救。
  bool _disposed = false;

  /// 只读视图（页面监听用）。
  Listenable get packsListenable => _packs;
  List<kb.ExpertPackData> get packs => _packs.value;

  /// load() 之后的迁移/读取问题清单（失败计数，非空即有东西被跳过）。
  List<String> get loadProblems => _loadProblems;

  /// load() 之后的迁移说明（成功计数、去重说明等信息级消息）。
  List<String> get loadNotes => _loadNotes;

  /// 全局风格写入口是否已接线（未接线时页面禁用「套用为全局风格」并提示）。
  bool get hasStyleSink => _styleSink != null;

  /// 联系人写入口是否已接线（#13 接线后才有值）。
  bool get hasContactSink => _contactSink != null;

  /// 当前联系人目标快照（页面选套用目标、判断「已有专用人设」用）。
  List<ContactTarget> get contactTargets => _contactSink?.targets ?? const [];

  /// 「这位联系人是否写了专用人设」的**唯一判定处**：复用 core
  /// StyleSource.resolve（style_source.dart:29——专用人设压全局的既定优先级）。
  /// 独立复核要求：优先级规则将来若改，判定只改这一处，页面与提示不得各自
  /// 手写 trim 判空漂移。
  static bool contactHasPersona(ContactTarget target) =>
      kb.StyleSource.resolve('', target.persona).from ==
      kb.StyleSourceFrom.contact;

  /// 是否存在写了专用人设的联系人（套用为全局风格时的 StyleSource 提示条件）。
  bool get anyContactHasPersona => contactTargets.any(contactHasPersona);

  // ------------------------------------------------------------------ 货架

  /// 货架：我的条目在前 + 尚未入库的目录样品（同 id 或同名让位——legacy
  /// ExpertShelf.kt:179 的双重判断：用户改过名的条目也是「他的东西」）。
  List<ExpertShelfItem> get shelfUnfiltered {
    final items = <ExpertShelfItem>[];
    final mineIds = <String>{};
    final mineNames = <String>{};
    for (final e in _library) {
      items.add(ExpertShelfItem.mine(
        e,
        _meta[e.id] ??
            ExpertEntryMeta(sourceRef: ExpertShelfItem._sourceRefOf(e)),
      ));
      mineIds.add(e.id);
      mineNames.add(e.name);
    }
    // core 口径：allExperts() 已经把所有已装包（含内置）的专家合并成一张
    // List<Expert>（expert_pack.dart:286-287）——直接逐个过筛即可。
    for (final e in _manager.allExperts()) {
      if (mineIds.contains(e.id) || mineNames.contains(e.name)) continue;
      items.add(ExpertShelfItem.ghost(e));
    }
    return items;
  }

  /// 按 id 找货架条目（详情页返回列表项后重查最新状态用）。
  ExpertShelfItem? shelfItemById(String id) {
    for (final i in shelfUnfiltered) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// 货架上真实存在的领域（页面分组 chips）：core 5 固定领域在前（只列在场
  /// 的），自定义领域按名排后，未分类殿后——25 条旧分类清单的承接见文件头注释。
  List<String> categories() => kb.ExpertCatalog.domains(_shelfExperts);

  /// 货架上的标签按出现次数降序（页面标签筛选行），最多 [limit] 个。
  List<String> topTags({int limit = 24}) =>
      kb.ExpertCatalog.tags(_shelfExperts).take(limit).toList();

  List<kb.Expert> get _shelfExperts => <kb.Expert>[
        for (final i in shelfUnfiltered) i.expert,
      ];

  /// 界面用的组合动作：先筛（core ExpertCatalog.filter：领域+标签+关键词，
  /// 关键词命中名字/简介/标签/正文）后排。
  List<ExpertShelfItem> shelf({
    String? category,
    String tag = '',
    String query = '',
    ExpertSort sort = ExpertSort.comprehensive,
  }) {
    final items = shelfUnfiltered;
    final experts = <kb.Expert>[for (final i in items) i.expert];
    final keep = kb.ExpertCatalog
        .filter(experts, domain: category, tag: tag, query: query)
        .map((e) => e.id)
        .toSet();
    final filtered = <ExpertShelfItem>[
      for (final i in items)
        if (keep.contains(i.id)) i,
    ];
    return _sortItems(filtered, sort);
  }

  /// 展示层排序（见 [ExpertSort] 文档）：综合/最热委托 core，最新本层排。
  List<ExpertShelfItem> _sortItems(
      List<ExpertShelfItem> items, ExpertSort mode) {
    switch (mode) {
      case ExpertSort.comprehensive:
      case ExpertSort.hottest:
        final experts = <kb.Expert>[for (final i in items) i.expert];
        final ordered = kb.ExpertCatalog.sort(
          experts,
          mode: mode == ExpertSort.hottest
              ? kb.ExpertSort.hottest
              : kb.ExpertSort.comprehensive,
          usage: _usageMap(),
        );
        // 条目与专家是同一批实例（Expert 按 id 判等，货架内 id 无重复）。
        final byExpert = Map<kb.Expert, ExpertShelfItem>.fromIterables(
            experts, items);
        return <ExpertShelfItem>[for (final e in ordered) byExpert[e]!];
      case ExpertSort.newest:
        // 我的条目看 updatedAt；目录样品看所在包的 importedAt（没装过的
        // 内置包为 0，沉底——样品不是用户动过的东西）。
        int recency(ExpertShelfItem i) =>
            i.meta?.updatedAt ?? _packImportedAt[i.expert.source.packId] ?? 0;
        final list = [...items]..sort((a, b) {
            final r = recency(b).compareTo(recency(a));
            if (r != 0) return r;
            return a.name.compareTo(b.name);
          });
        return list;
    }
  }

  /// core 排序的 usage 注入（core 不存使用计数——命中/使用评测的钩子位）。
  Map<String, int> _usageMap() => <String, int>{
        for (final e in _meta.entries) e.key: e.value.usedCount,
      };

  // ------------------------------------------------------------------ 套用

  /// 「套用为全局风格」。判定与落笔唯一出处是 core ExpertApply.applyToGlobal
  /// （expert_apply.dart:231）：正文空拒绝、写失败回滚、shadowed 提示都在那。
  /// 本层保留三件事：接线检查（#13）、**空正文预检 + 先落库再套用**（第 1 步
  /// 失败目标一个字节不动）、异步落盘 flush 的成败兜底（core 的 sink 是同步
  /// 接口，盘上成败由 StyleSinkPort.flush 上交，失败在这里回滚内存并如实报错）。
  Future<ExpertApplyResult> applyAsGlobalStyle(ExpertShelfItem item) async {
    final sink = _styleSink;
    if (sink == null) {
      return const ExpertApplyResult(
          ok: false, problem: '全局风格未接线（#13），暂时不能套用');
    }
    // 0) 正文是唯一进提示词的东西；空正文套上去等于把人设清空（与 core 同一
    //    判定，提前在这里拦是为了别把空条目先落了库）。
    if (item.expert.promptText.trim().isEmpty) {
      return ExpertApplyResult(
          ok: false, problem: '「${item.name}」没有正文，没套用');
    }
    // 1) 落库。失败 → 目标正文一个字节都不动（本类最要紧的一条不变量）。
    kb.Expert entry;
    try {
      entry = await _installIntoLibrary(item.expert);
    } catch (e) {
      return ExpertApplyResult(
          ok: false,
          problem: '没能把「${item.name}」存进我的专家库（$e），目标未改动');
    }
    // 3) core 落笔（写失败 core 自己回滚并给 problem）。
    final previous = sink.style; // flush 失败要原样退回去
    final r = _apply.applyToGlobal(item.expert, contacts: _coreContacts());
    if (!r.ok) {
      return ExpertApplyResult(ok: false, problem: r.problem, profile: entry);
    }
    // 4) 落盘兜底：内存已成、盘上没成 → 整体按失败处理并还原。
    try {
      await sink.flush();
    } catch (e) {
      sink.style = previous;
      try {
        await sink.flush();
      } catch (_) {
        // 回滚也失败：problem 里照实说，不假装成功。
      }
      return ExpertApplyResult(
        ok: false,
        problem: '设置里那句人设没写成（$e），已经还原成原来那句；'
            '「${item.name}」还在我的专家库里',
        profile: entry,
      );
    }
    // 5) 记热度。失败降级成 warning，不阻塞套用。
    var warning = '';
    try {
      entry = await _touch(entry.id);
    } catch (_) {
      warning = '热度没记上，不影响使用';
    }
    return ExpertApplyResult(
        ok: true, profile: entry, warning: warning, note: r.note);
  }

  /// 「套用为联系人人设」。冲突判定（专用人设压全局）唯一出处是 core
  /// StyleSource.resolve——[kb.ExpertApply.applyToContact] 检测到冲突时返回
  /// needsChoice 且**两个目标都不动**，界面问完用户（覆盖/并存）带
  /// [kb.ConflictChoice] 再调一次。并存路径 core 写全局 sink、盘上成败由
  /// flush 兜底；覆盖路径 core 返回新 persona，联系人落盘走 ContactPersonaSink。
  Future<ExpertApplyResult> applyToContact(
    ExpertShelfItem item,
    ContactTarget target, {
    kb.ConflictChoice? choice,
  }) async {
    final contactSink = _contactSink;
    if (contactSink == null) {
      return const ExpertApplyResult(
          ok: false, problem: '联系人档案未接线（#13），暂时不能套用');
    }
    if (item.expert.promptText.trim().isEmpty) {
      return ExpertApplyResult(
          ok: false, problem: '「${item.name}」没有正文，没套用');
    }
    kb.Expert entry;
    try {
      entry = await _installIntoLibrary(item.expert);
    } catch (e) {
      return ExpertApplyResult(
          ok: false,
          problem: '没能把「${item.name}」存进我的专家库（$e），目标未改动');
    }
    final styleBefore = _styleSink?.style ?? ''; // 并存要写全局，失败得还原
    final r = _apply.applyToContact(
        item.expert, _coreContactOf(target), choice: choice);
    // 冲突待裁决：core 保证两个目标都没写——界面弹「覆盖/并存」后再调。
    if (r.needsChoice) {
      return ExpertApplyResult(
          ok: false, needsChoice: true, note: r.note, profile: entry);
    }
    if (!r.ok) {
      return ExpertApplyResult(ok: false, problem: r.problem, profile: entry);
    }
    if (r.wroteGlobalStyle) {
      // 并存：专家正文已由 core 写进全局 sink，联系人专用人设没动。
      final sink = _styleSink;
      if (sink == null) {
        // entry 是运行期对象，不能进 const 构造——去掉 const（invalid_constant）。
        return ExpertApplyResult(
            ok: false,
            problem: '并存需要全局风格通道：控制器未接线 styleSink',
            profile: entry);
      }
      try {
        await sink.flush();
      } catch (e) {
        sink.style = styleBefore;
        try {
          await sink.flush();
        } catch (_) {
          // 回滚也失败：problem 里照实说。
        }
        return ExpertApplyResult(
          ok: false,
          problem: '全局风格没写成（$e），已经还原；'
              '「${target.displayName}」的专用人设没动',
          profile: entry,
        );
      }
      final touched = await _touchOrWarn(entry.id);
      return ExpertApplyResult(
          ok: true, profile: touched.entry, warning: touched.warning, note: r.note);
    }
    // 覆盖/直写：把 core 给的 persona 落到联系人档案（app 层落盘）。写失败
    // 不回滚第 1 步（库里那条保留），如实报 problem。
    try {
      await contactSink.writePersona(target.id, r.appliedText);
    } catch (e) {
      return ExpertApplyResult(
        ok: false,
        problem: '「${target.displayName}」的专用人设没写成（$e），原句未改动；'
            '「${item.name}」还在我的专家库里',
        profile: entry,
      );
    }
    final touched = await _touchOrWarn(entry.id);
    return ExpertApplyResult(
        ok: true, profile: touched.entry, warning: touched.warning, note: r.note);
  }

  kb.Contact _coreContactOf(ContactTarget t) =>
      kb.Contact(id: t.id, name: t.displayName, persona: t.persona);

  List<kb.Contact> _coreContacts() => <kb.Contact>[
        for (final t in contactTargets) _coreContactOf(t),
      ];

  // ---------------------------------------------------------- 我的库管理

  /// 自建（mine）专家入库：id 形如 `mine:<严格递增毫秒时间戳>`（[_nextStamp]，
  /// 同一毫秒连续创建也能分先后），source 置 packId 空——货架的来源串现算
  /// 就是 'mine'（[ExpertShelfItem._sourceRefOf] 的既定口径），origin 走
  /// remote（core ExpertOrigin 只有 builtin/remote 两档，mine 的判定靠
  /// packId 空，见 ExpertShelfItem.sourceRef）。持久化并入我的库同一存档键
  /// （experts_v2），写盘事务与 [renameLibraryEntry] 同风格：内存先落、盘上
  /// 失败回滚内存并上抛，不留半截。
  ///
  /// 校验：名字空白拒绝；正文空白/超 64KiB 拒绝（与包条目同一护栏
  /// kb.expertPromptTextMaxBytes——空正文套用等于清空人设）。
  Future<kb.Expert> createMineExpert({
    required String name,
    required String promptText,
    String? domain,
    List<String> tags = const [],
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) throw ArgumentError('专家名字不能为空');
    if (promptText.trim().isEmpty) {
      throw ArgumentError('正文不能为空（套用空正文等于清空人设）');
    }
    if (utf8.encode(promptText).length > kb.expertPromptTextMaxBytes) {
      throw ArgumentError('正文超过 ${kb.expertPromptTextMaxBytes} 字节上限');
    }
    final stamp = _nextStamp();
    final expert = kb.Expert(
      id: 'mine:$stamp',
      key: 'mine:$stamp',
      name: trimmedName,
      domain: domain?.trim() ?? '',
      promptText: promptText, // 逐字保存，不 trim（与包条目同一口径）
      tags: <String>[
        for (final t in tags)
          if (t.trim().isNotEmpty) t.trim(),
      ],
      description: '',
      emoji: '🧩',
      source: const kb.ExpertSource(packId: '', packVersion: ''),
    );
    final meta = ExpertEntryMeta(
      usedCount: 0,
      updatedAt: stamp,
      sourceRef: ExpertShelfItem._sourceRefOf(expert), // 'mine'
    );
    _library.add(expert);
    _meta[expert.id] = meta;
    _notifyLibrary();
    try {
      await _persistLibrary();
    } catch (_) {
      _library.remove(expert);
      _meta.remove(expert.id);
      _notifyLibrary();
      rethrow;
    }
    return expert;
  }

  /// 仅自建（mine）条目可改。seed:/pack: 来源的条目拒改并抛 ArgumentError
  /// ——包条目是上游内容的镜像，逐条改了会跟上游漂移（mine 判定与来源串
  /// 现算同一口径：source.packId 非空即包/内置，空即自建）。name/promptText
  /// 同时缺省抛 ArgumentError（没有要改的字段不算一次编辑）；给出的字段按
  /// [renameLibraryEntry] / [updateLibraryBody] 同一校验。写盘事务同风格：
  /// 失败回滚内存并上抛。
  Future<kb.Expert> updateMineExpert(
    String id, {
    String? name,
    String? promptText,
  }) async {
    if (name == null && promptText == null) {
      throw ArgumentError('没有要修改的字段（name/promptText 都未提供）');
    }
    final idx = _library.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw StateError('ExpertsController.updateMineExpert: 条目不存在（$id）');
    }
    final prev = _library[idx];
    if (prev.source.packId.isNotEmpty) {
      throw ArgumentError('「${prev.name}」来自包/内置（seed:/pack: 来源），'
          '只能修改自建（mine）专家');
    }
    if (name != null && name.trim().isEmpty) {
      throw ArgumentError('新名字不能为空');
    }
    if (promptText != null && promptText.trim().isEmpty) {
      throw ArgumentError('正文不能为空（套用空正文等于清空人设）');
    }
    if (promptText != null &&
        utf8.encode(promptText).length > kb.expertPromptTextMaxBytes) {
      throw ArgumentError('正文超过 ${kb.expertPromptTextMaxBytes} 字节上限');
    }
    final prevMeta = _meta[id] ??
        ExpertEntryMeta(sourceRef: ExpertShelfItem._sourceRefOf(prev));
    final next = kb.Expert(
      id: prev.id,
      key: prev.key,
      name: name != null ? name.trim() : prev.name,
      domain: prev.domain,
      promptText: promptText ?? prev.promptText,
      tags: List.of(prev.tags),
      description: prev.description,
      emoji: prev.emoji,
      source: prev.source,
    );
    final nextMeta = prevMeta.copyWith(updatedAt: _nextStamp());
    _library[idx] = next;
    _meta[id] = nextMeta;
    _notifyLibrary();
    try {
      await _persistLibrary();
    } catch (_) {
      _library[idx] = prev;
      _meta[id] = prevMeta;
      _notifyLibrary();
      rethrow;
    }
    return next;
  }

  /// 仅自建（mine）条目可删，成功返回被删的那条（界面要 toast 名字）。
  /// seed:/pack: 来源拒删抛 ArgumentError——包条目整包管理走
  /// [uninstallPack]，不逐条删；缺失条目抛 StateError（与 update/rename
  /// 同口径）。写盘事务同风格：失败回滚内存并上抛。
  Future<kb.Expert> deleteMineExpert(String id) async {
    final idx = _library.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw StateError('ExpertsController.deleteMineExpert: 条目不存在（$id）');
    }
    final removed = _library[idx];
    if (removed.source.packId.isNotEmpty) {
      throw ArgumentError('「${removed.name}」来自包/内置（seed:/pack: 来源），'
          '只能删除自建（mine）专家');
    }
    final prevMeta = _meta[id];
    _library.removeAt(idx);
    _meta.remove(id);
    _notifyLibrary();
    try {
      await _persistLibrary();
    } catch (_) {
      _library.insert(idx, removed);
      if (prevMeta != null) _meta[id] = prevMeta;
      _notifyLibrary();
      rethrow;
    }
    return removed;
  }

  /// 我的库条目改名（core Expert 不可变 → 造新实例；id/key/正文/来源都不动，
  /// updatedAt 前进——「最新」档随之浮上来）。名字空白拒绝；条目不存在抛
  /// StateError。失败回滚内存（写盘失败不产生半截改名）。
  Future<kb.Expert> renameLibraryEntry(String id, String newName) async {
    final name = newName.trim();
    if (name.isEmpty) throw ArgumentError('新名字不能为空');
    final idx = _library.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw StateError('ExpertsController.renameLibraryEntry: 条目不存在（$id）');
    }
    final prev = _library[idx];
    final prevMeta =
        _meta[id] ?? ExpertEntryMeta(sourceRef: ExpertShelfItem._sourceRefOf(prev));
    final next = kb.Expert(
      id: prev.id,
      key: prev.key,
      name: name,
      domain: prev.domain,
      promptText: prev.promptText,
      tags: List.of(prev.tags),
      description: prev.description,
      emoji: prev.emoji,
      source: prev.source,
    );
    final nextMeta = prevMeta.copyWith(updatedAt: _nextStamp());
    _library[idx] = next;
    _meta[id] = nextMeta;
    _notifyLibrary();
    try {
      await _persistLibrary();
    } catch (_) {
      _library[idx] = prev;
      _meta[id] = prevMeta;
      _notifyLibrary();
      rethrow;
    }
    return next;
  }

  /// 我的库条目改正文（promptText 逐字保存，不 trim）。空正文拒绝——套用空
  /// 正文等于清空人设；超 64KiB 拒绝——与包条目同一尺寸护栏
  /// （kb.expertPromptTextMaxBytes）。条目不存在抛 StateError。
  Future<kb.Expert> updateLibraryBody(String id, String promptText) async {
    if (promptText.trim().isEmpty) {
      throw ArgumentError('正文不能为空（套用空正文等于清空人设）');
    }
    if (utf8.encode(promptText).length > kb.expertPromptTextMaxBytes) {
      throw ArgumentError(
          '正文超过 ${kb.expertPromptTextMaxBytes} 字节上限');
    }
    final idx = _library.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw StateError('ExpertsController.updateLibraryBody: 条目不存在（$id）');
    }
    final prev = _library[idx];
    final prevMeta =
        _meta[id] ?? ExpertEntryMeta(sourceRef: ExpertShelfItem._sourceRefOf(prev));
    final next = kb.Expert(
      id: prev.id,
      key: prev.key,
      name: prev.name,
      domain: prev.domain,
      promptText: promptText,
      tags: List.of(prev.tags),
      description: prev.description,
      emoji: prev.emoji,
      source: prev.source,
    );
    final nextMeta = prevMeta.copyWith(updatedAt: _nextStamp());
    _library[idx] = next;
    _meta[id] = nextMeta;
    _notifyLibrary();
    try {
      await _persistLibrary();
    } catch (_) {
      _library[idx] = prev;
      _meta[id] = prevMeta;
      _notifyLibrary();
      rethrow;
    }
    return next;
  }

  /// 从我的库移除一条（幂等）。目录样品不受影响——它本来就不在库里；失败
  /// 回滚内存。
  Future<void> removeFromLibrary(String id) async {
    final idx = _library.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final prevExpert = _library[idx];
    final prevMeta = _meta[id];
    _library.removeAt(idx);
    _meta.remove(id);
    _notifyLibrary();
    try {
      await _persistLibrary();
    } catch (_) {
      _library.insert(idx, prevExpert);
      if (prevMeta != null) _meta[id] = prevMeta;
      _notifyLibrary();
      rethrow;
    }
  }

  /// 目录条目落库（幂等：同 id 已有原样返回，保住用户的改名改文），来源串
  /// 按 core 来源现算。写盘失败回滚内存并上抛（调用方转为 problem）。
  Future<kb.Expert> _installIntoLibrary(kb.Expert expert) async {
    for (final e in _library) {
      if (e.id == expert.id) return e;
    }
    final meta = ExpertEntryMeta(
      usedCount: 0,
      updatedAt: _nextStamp(),
      sourceRef: ExpertShelfItem._sourceRefOf(expert),
    );
    _library.add(expert);
    _meta[expert.id] = meta;
    _notifyLibrary();
    try {
      await _persistLibrary();
    } catch (e) {
      // 落库是「要么全成要么不留半截」的第 1 步：写盘失败回滚内存，让第 1 步
      // 整体失败（上层会返回 problem 且不动目标正文）。
      _library.remove(expert);
      _meta.remove(expert.id);
      _notifyLibrary();
      rethrow;
    }
    return expert;
  }

  /// 记热度：usedCount+1 并落盘；失败上抛（调用方降级成 warning）。
  Future<kb.Expert> _touch(String id) async {
    final prev = _meta[id];
    if (prev == null || !_library.any((e) => e.id == id)) {
      throw StateError('ExpertsController._touch: 条目不存在（$id）');
    }
    final updated = prev.copyWith(
        usedCount: prev.usedCount + 1, updatedAt: _nextStamp());
    _meta[id] = updated;
    _notifyLibrary();
    try {
      await _persistLibrary();
    } catch (_) {
      // 热度是计数器：落盘失败就把内存也退回去，保持「盘上没有 = 没发生」。
      _meta[id] = prev;
      _notifyLibrary();
      rethrow;
    }
    return _library.firstWhere((e) => e.id == id);
  }

  /// 套用成功后的记热度：失败降级成 warning（热度是观测数据，不该让一次
  /// 计数写盘失败把「已生效」报成失败）。
  Future<({kb.Expert entry, String warning})> _touchOrWarn(String id) async {
    try {
      return (entry: await _touch(id), warning: '');
    } catch (_) {
      final e = _library.firstWhere((x) => x.id == id);
      return (entry: e, warning: '热度没记上，不影响使用');
    }
  }

  // ---------------------------------------------------------- 资产包管理

  /// 安装一份资产包清单。清单级校验/版本仲裁/降级拒装全在 core
  /// （ExpertPackManager.install：未装新装、同版本幂等、低版本拒装、高版本
  /// 升级替换、坏包重装即修复）。入口先做**条目级**别名补齐
  /// （[_normalizePackJson]：key/body/category → id/promptText/domain，
  /// docs/expert-pack-format.md §2；清单级 format/pack 结构不碰——严格校验
  /// 归 core PackCodec，app 形状的历史包必须自带 format+pack 才能走安装路径）。
  /// 校验拒绝抛 FormatException（problem 在消息里）；落盘失败抛 StateError
  /// 并回滚内存。
  Future<kb.InstallResult> installPackJson(String json) async {
    final before = _packStore.loadAll();
    final beforeImported = Map.of(_packImportedAt);
    final normalized = _normalizePackJson(json);
    final r = _manager.install(normalized);
    if (!r.ok) {
      throw FormatException(r.problem.isEmpty ? '资产包安装失败' : r.problem);
    }
    if (r.pack != null && r.action != kb.InstallAction.alreadyCurrent) {
      _packImportedAt[r.pack!.meta.id] = _nextStamp();
    }
    try {
      await _packStore.flush();
      await _persistLibrary(); // packImportedAt 挂在我的库存档里持久化
    } catch (e) {
      _packStore.restoreSnapshot(before);
      _packImportedAt
        ..clear()
        ..addAll(beforeImported);
      try {
        await _packStore.flush();
      } catch (_) {
        // 回滚也失败：异常照抛，不假装成功。
      }
      _refreshPacks();
      throw StateError('资产包落盘失败（$e），本次没有安装');
    }
    _refreshPacks();
    return r;
  }

  /// 本地文件导入的单文件尺寸护栏——与远端下载同一护栏（core
  /// HttpJson.maxDownloadBytes 的 2MB）：本地文件与远端包体同为「一份包
  /// 清单」，超限一律拒绝导入，不假装读得动。
  static const int packFileMaxBytes = kb.HttpJson.maxDownloadBytes;

  /// 从本地文件安装资产包（file_selector 选出的路径）。读文件（utf8）→
  /// 复用 [installPackJson]——归一化、core 严格校验、版本仲裁、落盘事务
  /// 全在那条路径上，本方法只负责把文件变成字符串再交给它。返回的
  /// PackInstallReport 即 installPackJson 的返回类型 kb.InstallResult
  /// （沿用不重造）。文件不存在 / 不是 UTF-8 / 超过 2MB 都抛
  /// FormatException（message 用户可读）。
  Future<kb.InstallResult> installPackFromFile(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FormatException('文件不存在：$filePath');
    }
    final int bytesLen;
    try {
      bytesLen = file.lengthSync();
    } catch (e) {
      throw FormatException('文件读取失败：$e');
    }
    if (bytesLen > packFileMaxBytes) {
      throw FormatException('文件超过 '
          '${(packFileMaxBytes / 1024 / 1024).toStringAsFixed(0)}MB 上限'
          '（$bytesLen 字节），没有导入');
    }
    final String raw;
    try {
      // 先读字节再显式 utf8.decode：readAsString 对解码失败抛的是
      // FileSystemException（语义混淆，本机实测）；显式 decode 让「不是
      // UTF-8」以 FormatException 出现，文案可读。
      raw = utf8.decode(file.readAsBytesSync());
    } on FormatException {
      throw FormatException('文件不是合法 UTF-8 文本，没有导入');
    } catch (e) {
      throw FormatException('文件读取失败：$e');
    }
    return installPackJson(raw);
  }

  /// 从远端清单安装资产包：拉清单（core RemoteManifestCodec 解析，清单级
  /// 校验失败即拒）→ 选包 → 拉包体（[PackFetchService.fetchPack]：先过
  /// core PackCodec 严格校验，**校验不过不落盘**）→ 复用 [installPackJson]
  /// 安装。任何一步失败都返回 ok=false 且 problem 用户可读——**不抛**
  /// （与 [uninstallPack] 同风格，结果直接给界面展示）。
  ///
  /// 选包规则：[packId] 指定则精确匹配（清单里没有该 id 报可读错误，附上
  /// 清单里现有哪些包）；缺省（null 或空白）取版本最高的条目（并列取清单
  /// 顺序靠前的——清单作者通常把最新的写在最前面；版本比较是 core
  /// PackCodec.compareVersions 的唯一口径）。
  Future<RemoteInstallReport> installFromRemote(
    String manifestUrl, {
    String? packId,
  }) async {
    // 1) 清单。
    List<kb.RemotePackEntry> entries;
    try {
      entries = await _fetchService.fetchRemoteManifest(manifestUrl);
    } on FormatException catch (e) {
      return RemoteInstallReport(ok: false, problem: e.message);
    } catch (e) {
      return RemoteInstallReport(ok: false, problem: '清单拉取失败：$e');
    }
    // 2) 选包。
    final kb.RemotePackEntry chosen;
    if (packId != null && packId.trim().isNotEmpty) {
      final wanted = packId.trim();
      final hit = entries.where((e) => e.id == wanted).toList();
      if (hit.isEmpty) {
        return RemoteInstallReport(
          ok: false,
          problem: '清单里没有这个包：$wanted'
              '（清单共有 ${entries.length} 个包：${entries.map((e) => e.id).join('、')}）',
        );
      }
      chosen = hit.first;
    } else {
      chosen = entries.reduce((a, b) =>
          kb.PackCodec.compareVersions(b.version, a.version) > 0 ? b : a);
    }
    // 3) 包体：fetchPack 内已过 core 严格校验，到这里的一定是合法清单原文。
    final String raw;
    try {
      raw = await _fetchService.fetchPack(chosen.url);
    } on FormatException catch (e) {
      return RemoteInstallReport(
          ok: false,
          packId: chosen.id,
          version: chosen.version,
          problem: e.message);
    } catch (e) {
      return RemoteInstallReport(
          ok: false,
          packId: chosen.id,
          version: chosen.version,
          problem: '包体下载失败：$e');
    }
    // 4) 安装（归一化 → core 校验/版本仲裁 → 落盘事务）。
    try {
      final r = await installPackJson(raw);
      return RemoteInstallReport(
        ok: true,
        packId: r.pack?.meta.id ?? chosen.id,
        version: r.pack?.meta.version ?? chosen.version,
        expertsInstalled: r.pack?.expertCount ?? 0,
        problem: r.problem,
      );
    } on FormatException catch (e) {
      return RemoteInstallReport(
          ok: false,
          packId: chosen.id,
          version: chosen.version,
          problem: e.message);
    } catch (e) {
      return RemoteInstallReport(
          ok: false,
          packId: chosen.id,
          version: chosen.version,
          problem: '安装失败：$e');
    }
  }

  /// 卸载一个资产包（走 core ExpertPackManager.uninstall：内置包不可卸载、
  /// 没装过报「没有安装过」、坏包也允许卸——显式清理路径）。落盘失败还原并
  /// 返回 ok=false（不抛，卸载的结果直接给界面展示）。
  Future<kb.UninstallResult> uninstallPack(String packId) async {
    final before = _packStore.loadAll();
    final beforeImported = Map.of(_packImportedAt);
    final r = _manager.uninstall(packId);
    if (!r.ok) return r;
    _packImportedAt.remove(packId);
    try {
      await _packStore.flush();
      await _persistLibrary();
    } catch (e) {
      _packStore.restoreSnapshot(before);
      _packImportedAt
        ..clear()
        ..addAll(beforeImported);
      try {
        await _packStore.flush();
      } catch (_) {
        // 回滚也失败：结果里照实说。
      }
      _refreshPacks();
      return kb.UninstallResult(ok: false, problem: '卸载没写盘成功（$e），已还原');
    }
    _refreshPacks();
    return r;
  }

  /// 条目级别名互认（docs/expert-pack-format.md §2）：`key`→`id`、`body`→
  /// `promptText`、`category`→`domain` **只补不删**——原文与别名都保留，
  /// 清单级 format/pack/experts 结构不动（严格校验归 core PackCodec）。core
  /// decodeExpertEntry 对 domain 别名不回落 category（expert_catalog.dart:248
  /// 只读 `domain`），这步补齐保证 legacy 形状条目不丢分组。非 JSON/非对象
  /// 原样返回（交给 PackCodec 拒）。
  static String _normalizePackJson(String raw) {
    Object? root;
    try {
      root = jsonDecode(raw);
    } catch (_) {
      return raw;
    }
    if (root is! Map) return raw;
    final list = root['experts'];
    if (list is! List) return raw;
    var changed = false;
    String? str(Object? v) {
      final s = v?.toString().trim() ?? '';
      return s.isEmpty ? null : s;
    }

    final out = <Object?>[];
    for (final e in list) {
      if (e is! Map) {
        out.add(e);
        continue;
      }
      final m = Map<String, dynamic>.from(e);
      final id = str(m['id']);
      final key = str(m['key']);
      if (id == null && key != null) {
        m['id'] = key;
        changed = true;
      }
      if (m['promptText'] == null && m['body'] != null) {
        m['promptText'] = m['body'];
        changed = true;
      }
      final domain = str(m['domain']);
      final category = str(m['category']);
      if (domain == null && category != null) {
        m['domain'] = category;
        changed = true;
      }
      out.add(m);
    }
    if (!changed) return raw;
    root['experts'] = out;
    try {
      return jsonEncode(root);
    } catch (_) {
      return raw;
    }
  }

  // ------------------------------------------------------------------ 存取

  /// 启动时调用：读内置清单 + 新键存档 + 旧键迁移（别名互认；失败计数进
  /// [loadProblems]，绝不静默丢）。可重复调用（以盘上为准重建内存态）。
  Future<void> load() async {
    final problems = <String>[];
    final notes = <String>[];

    // 内置清单三层兜底（见 [_resolveBuiltinJson] 注释）。
    final builtin = await _resolveBuiltinJson();
    if (builtin != null) {
      _manager = kb.ExpertPackManager(_packStore, builtinJson: builtin);
    } else {
      problems.add('读不到内置目录 JSON（rootBundle/磁盘/内嵌镜像都失败）——内置货架为空');
    }

    final v2Packs = await _packStore.hydrate(problems);

    // 内存态重建前的旧值清理。clear 必须在 [_migrateLegacyPacks] **之前**：
    // 迁移会往 _packImportedAt 写刚迁包的导入时间（「最新」档的排序数据源），
    // 若像旧顺序那样先迁移再 clear，时间戳当场被吃掉——迁移包的目录样品在
    // 「最新」档恒按 0 沉底，导入时间也落不了盘（独立复核发现）。
    _packImportedAt.clear();
    _library.clear();
    _meta.clear();
    final v2Lib = await _loadLibraryV2(problems);
    if (!v2Lib) await _migrateLegacyLibrary(problems, notes);
    // 包迁移挪到我的库读入之后：迁移完要把导入时间经 [_persistLibrary] 并进
    // experts_v2 存档，而 persist 写的是「当前整库」——库还没读入就 persist
    // 会把既有 entries 用空库覆盖。
    if (!v2Packs) await _migrateLegacyPacks(problems, notes);

    _notifyLibrary();
    _refreshPacks();
    _loadProblems = List.unmodifiable(problems);
    _loadNotes = List.unmodifiable(notes);
  }

  /// 内置包清单原文的三层兜底：
  /// 1. rootBundle 读 `packages/chartools_core/<builtinCatalogAssetPath>`
  ///    （资产键，若未来 pubspec 声明了 core assets 即自动生效）；
  /// 2. core 的磁盘探测（VM / 测试 / 桌面开发路径——测试读的是真文件，杜绝
  ///    镜像漂移）；
  /// 3. 内嵌镜像 [_builtinCatalogMirror]（发布包兜底——beta.6 的 core pubspec
  ///    没有 flutter assets 段，rootBundle 读不到，磁盘上也找不到）。
  Future<String?> _resolveBuiltinJson() async {
    try {
      return await rootBundle
          .loadString('packages/chartools_core/${kb.builtinCatalogAssetPath}');
    } catch (_) {
      // 资产未随包声明（beta.6）→ 下一层。
    }
    final disk = kb.readBuiltinCatalogJson();
    if (disk != null) return disk;
    return _builtinCatalogMirror;
  }

  /// 旧键资产包迁移：legacy 形状（无 format / 无 pack 对象）包装升级到
  /// `jev-expert-pack/1` 后经 core 校验安装（docs/expert-pack-format.md §2：
  /// app 形状的历史包走 core 安装路径必须补 format 与 pack{id,version}）。
  /// 失败逐条计数进 [problems]，不静默丢。
  Future<void> _migrateLegacyPacks(
      List<String> problems, List<String> notes) async {
    final String raw;
    try {
      final prefs = await SharedPreferences.getInstance();
      final r = prefs.getString(legacyPacksKey);
      if (r == null || r.isEmpty) return;
      raw = r;
    } catch (e) {
      problems.add('旧资产包存档（$legacyPacksKey）读取失败（$e），按没存过处理');
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      problems.add('旧资产包存档（$legacyPacksKey）不是合法 JSON，按没存过处理');
      return;
    }
    if (decoded is! Map || decoded['packs'] is! List) {
      problems.add('旧资产包存档（$legacyPacksKey）形状不对，按没存过处理');
      return;
    }
    final packs = decoded['packs'] as List;
    final usedIds = <String, String>{};
    var migrated = 0;
    var failed = 0;
    for (var i = 0; i < packs.length; i++) {
      final rawPack = packs[i];
      if (rawPack is! String || rawPack.isEmpty) {
        failed++;
        problems.add('旧资产包第 ${i + 1} 条不是字符串清单，已跳过');
        continue;
      }
      final (wrapped, id, why) = _wrapLegacyPack(rawPack, usedIds);
      if (wrapped == null) {
        failed++;
        problems.add('旧资产包「$id」迁移失败：$why');
        continue;
      }
      final r = _manager.install(wrapped);
      if (!r.ok) {
        failed++;
        problems.add('旧资产包「$id」迁移被 core 校验拒绝：${r.problem}');
        continue;
      }
      if (r.action == kb.InstallAction.alreadyCurrent) {
        notes.add('旧资产包「$id」与已装包同 id 同版本，按去重跳过');
        continue;
      }
      _packImportedAt[id] = _nextStamp();
      migrated++;
    }
    if (migrated > 0) {
      notes.add('已从旧键 $legacyPacksKey 迁移 $migrated 个资产包到新键 '
          '${PrefsPackStore.storageKey}（旧键只读不写）');
      // 导入时间挂在我的库存档（experts_v2 的 packImportedAt）里持久化——
      // 只 flush 包键不够：重启后 v2 包键已在盘、迁移不再重走，时间戳就永久
      // 丢了（迁移包的目录样品在「最新」档沉底）。此刻我的库已读入（load
      // 的顺序保证），persist 写整库不会覆盖既有 entries。
      try {
        await _persistLibrary();
      } catch (e) {
        problems.add('迁移包的导入时间没写成（$e）：本次会话内存有效，'
            '下次迁移重走时自动补');
      }
    }
    if (failed > 0) {
      notes.add('旧资产包迁移失败 $failed 个（明细见 loadProblems，未静默丢弃）');
    }
    try {
      await _packStore.flush();
    } catch (e) {
      problems.add('迁移后的资产包没写成（$e）：本次会话内存有效，下次启动自动重试迁移');
    }
  }

  /// 一份 legacy 包原文 → 包装升级后的 core 形状 JSON。返回
  /// (包装 JSON, 包 id, 失败原因)。id 取自旧包 name（`/` 换 `_`、撞内置保留
  /// id 换 `imported_builtin`）；同名不同内容加 `-2` 后缀防覆盖，同名同内容
  /// 按去重跳过。条目按别名互认归一成主拼写（key/body/category →
  /// id/promptText/domain），坏条目跳过计数。
  (String?, String, String?) _wrapLegacyPack(
      String raw, Map<String, String> usedIds) {
    Object? root;
    try {
      root = jsonDecode(raw);
    } catch (_) {
      return (null, '', '不是合法 JSON');
    }
    if (root is! Map) return (null, '', '顶层不是 JSON 对象');
    String str(Object? v) {
      final s = v?.toString().trim() ?? '';
      return s;
    }

    final name = str(root['name']);
    var id = name.replaceAll('/', '_');
    if (id.isEmpty) id = 'imported';
    if (id == kb.ExpertPackManager.builtinPackId) id = 'imported_builtin';
    final list = root['experts'];
    if (list is! List) return (null, id, '缺少 experts 数组');
    var skipped = 0;
    final entries = <Map<String, dynamic>>[];
    for (final e in list) {
      if (e is! Map) {
        skipped++;
        continue;
      }
      final m = Map<String, dynamic>.from(e);
      final key = str(m['key']).isNotEmpty ? str(m['key']) : str(m['id']);
      final bodyRaw = m['body'] ?? m['promptText'];
      final body = bodyRaw?.toString() ?? '';
      // key 与 body 是「这条专家能不能用」的下限（legacy ExpertPack.kt:98 同口径）。
      if (key.isEmpty || body.trim().isEmpty) {
        skipped++;
        continue;
      }
      entries.add(<String, dynamic>{
        'id': key,
        'name': str(m['name']).isNotEmpty ? str(m['name']) : key,
        'promptText': body, // 逐字保存，不 trim
        'domain': str(m['category']).isNotEmpty
            ? str(m['category'])
            : str(m['domain']),
        'tags': <String>[
          if (m['tags'] is List)
            for (final t in (m['tags'] as List))
              if (t is String && t.trim().isNotEmpty) t.trim(),
        ],
        'description': str(m['description']),
        'emoji': str(m['emoji']),
      });
    }
    if (entries.isEmpty) {
      return (null, id, '没有可用专家（跳过 $skipped 条）');
    }
    // 同名不同内容 → id 加后缀防覆盖（不静默丢第二个包）；同名同内容 → 去重。
    final marker = '${str(root['contentHash'])}:${entries.length}';
    var candidate = id;
    var suffix = 2;
    while (usedIds.containsKey(candidate)) {
      if (usedIds[candidate] == marker) {
        return (null, candidate, '与已迁移包同名同内容，按去重跳过');
      }
      candidate = '$id-${suffix++}';
    }
    id = candidate;
    usedIds[id] = marker;
    final wrapped = jsonEncode(<String, dynamic>{
      'format': kb.PackCodec.format,
      'pack': <String, dynamic>{
        'id': id,
        'version': '0.0.0', // 旧包没有版本：置最低，任何正式版本都可升级
        if (name.isNotEmpty) 'name': name,
        'origin': kb.ExpertOrigin.remote.wire,
        if (str(root['source']).isNotEmpty) 'source': str(root['source']),
        if (str(root['sourceCommit']).isNotEmpty)
          'sourceCommit': str(root['sourceCommit']),
        if (str(root['contentHash']).isNotEmpty)
          'contentHash': str(root['contentHash']),
      },
      'experts': entries,
    });
    final check = kb.PackCodec.parse(wrapped);
    if (!check.ok) {
      return (null, id, '补 format 后仍被 core 校验拒绝：${check.problem}');
    }
    return (wrapped, id, null);
  }

  /// 新键（experts_v2）读入我的库。返回 true = 新键在盘上（含空库）；false =
  /// 缺席/损坏 → 调用方走旧键迁移。逐条容错 + 别名互认，失败计数进 problems。
  Future<bool> _loadLibraryV2(List<String> problems) async {
    final String? raw;
    try {
      final prefs = await SharedPreferences.getInstance();
      raw = prefs.getString(libraryKeyV2);
    } catch (e) {
      problems.add('我的库存档（$libraryKeyV2）读取失败（$e），本次会话改动不会持久化');
      return true; // 平台通道问题：走内存模式，不触发迁移写盘
    }
    if (raw == null) return false; // 没迁移过
    if (raw.isEmpty) return true;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      problems.add('我的库存档（$libraryKeyV2）不是合法 JSON，按旧键重新迁移');
      return false;
    }
    if (decoded is! Map) {
      problems.add('我的库存档（$libraryKeyV2）形状不对，按旧键重新迁移');
      return false;
    }
    final imported = decoded['packImportedAt'];
    if (imported is Map) {
      imported.forEach((k, v) {
        if (v is int) _packImportedAt[k as String] = v;
      });
    }
    final entries = decoded['entries'];
    if (entries is! List) return true; // 空库存
    var failed = 0;
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (e is! Map) {
        failed++;
        problems.add('我的库第 ${i + 1} 条不是对象，已跳过');
        continue;
      }
      final expertRaw = e['expert'];
      if (expertRaw is! Map) {
        failed++;
        problems.add('我的库第 ${i + 1} 条缺 expert 对象，已跳过');
        continue;
      }
      final (expert, why) =
          _expertFromWire(Map<String, dynamic>.from(expertRaw));
      if (expert == null) {
        failed++;
        problems.add('我的库第 ${i + 1} 条读取失败：$why');
        continue;
      }
      final metaRaw = e['meta'];
      var meta = metaRaw is Map
          ? ExpertEntryMeta.fromJson(Map<String, dynamic>.from(metaRaw))
          : const ExpertEntryMeta();
      if (meta.sourceRef.isEmpty) {
        meta = ExpertEntryMeta(
          usedCount: meta.usedCount,
          updatedAt: meta.updatedAt,
          sourceRef: ExpertShelfItem._sourceRefOf(expert),
        );
      }
      _library.add(expert);
      _meta[expert.id] = meta;
    }
    if (failed > 0) {
      problems.add('我的库有 $failed 条读取失败（明细见上，未静默丢弃）');
    }
    return true;
  }

  /// 旧键（experts）迁移我的库：旧 ExpertProfile 存档 → (core Expert, 元数据,
  /// 失败原因)。别名互认：body|promptText → promptText、category|domain →
  /// domain、avatar|emoji → emoji、presetKey → key；builtin 标记 / `seed:`
  /// 前缀 → origin builtin（综合分 +2 的口径与旧版一致）；sourceRef 原样保留。
  (kb.Expert?, ExpertEntryMeta?, String?) _legacyLibraryEntry(
      Map<String, dynamic> j) {
    String str(Object? v) {
      final s = v?.toString().trim() ?? '';
      return s;
    }

    final presetKey = str(j['presetKey']);
    var id = str(j['id']);
    if (id.isEmpty) id = presetKey; // 旧存档总有 id；这里兜底
    if (id.isEmpty) return (null, null, '缺 id（且无 presetKey 可推导）');
    final ptRaw = j['body'] ?? j['promptText'];
    final promptText = ptRaw?.toString() ?? '';
    if (promptText.trim().isEmpty) {
      return (null, null, '「$id」正文为空（body/promptText 都没有可用内容）');
    }
    if (utf8.encode(promptText).length > kb.expertPromptTextMaxBytes) {
      return (null, null, '「$id」正文超过 64KiB 上限');
    }
    final domain =
        str(j['category']).isNotEmpty ? str(j['category']) : str(j['domain']);
    final emoji =
        str(j['avatar']).isNotEmpty ? str(j['avatar']) : str(j['emoji']);
    final sourceRef = str(j['sourceRef']);
    final builtinFlag = j['builtin'] == true;
    final origin = builtinFlag || sourceRef.startsWith('seed:')
        ? kb.ExpertOrigin.builtin
        : kb.ExpertOrigin.remote;
    var packId = '';
    for (final p in const ['seed:', 'pack:']) {
      if (sourceRef.startsWith(p)) {
        packId = sourceRef.substring(p.length);
        break;
      }
    }
    final key = presetKey.isNotEmpty
        ? presetKey
        : (id.contains('/') ? id.substring(id.lastIndexOf('/') + 1) : id);
    final expert = kb.Expert(
      id: id,
      key: key,
      name: str(j['name']).isEmpty ? key : str(j['name']),
      domain: domain,
      promptText: promptText,
      tags: <String>[
        if (j['tags'] is List)
          for (final t in (j['tags'] as List))
            if (t is String && t.trim().isNotEmpty) t.trim(),
      ],
      description: str(j['description']),
      emoji: emoji.isEmpty ? '🧩' : emoji,
      source: kb.ExpertSource(packId: packId, packVersion: '', origin: origin),
    );
    final meta = ExpertEntryMeta(
      usedCount: j['usedCount'] is int ? j['usedCount'] as int : 0,
      updatedAt: j['updatedAt'] is int ? j['updatedAt'] as int : 0,
      sourceRef: sourceRef,
    );
    return (expert, meta, null);
  }

  Future<void> _migrateLegacyLibrary(
      List<String> problems, List<String> notes) async {
    final String raw;
    try {
      final prefs = await SharedPreferences.getInstance();
      final r = prefs.getString(legacyLibraryKey);
      if (r == null || r.isEmpty) return;
      raw = r;
    } catch (e) {
      problems.add('旧我的库存档（$legacyLibraryKey）读取失败（$e），按没存过处理');
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      problems.add('旧我的库存档（$legacyLibraryKey）不是合法 JSON，按没存过处理');
      return;
    }
    if (decoded is! Map || decoded['experts'] is! List) {
      problems.add('旧我的库存档（$legacyLibraryKey）形状不对，按没存过处理');
      return;
    }
    final list = decoded['experts'] as List;
    var converted = 0;
    var failed = 0;
    for (var i = 0; i < list.length; i++) {
      final e = list[i];
      if (e is! Map<String, dynamic>) {
        failed++;
        problems.add('旧我的库第 ${i + 1} 条不是对象，已跳过');
        continue;
      }
      final (expert, meta, why) = _legacyLibraryEntry(e);
      if (expert == null || meta == null) {
        failed++;
        problems.add('旧我的库第 ${i + 1} 条转换失败：$why（已计数，未静默丢弃）');
        continue;
      }
      _library.add(expert);
      _meta[expert.id] = meta;
      converted++;
    }
    if (converted > 0) {
      notes.add('已从旧键 $legacyLibraryKey 迁移 $converted 条到新键 '
          '$libraryKeyV2（别名互认：body→promptText、category→domain；旧键只读不写）');
    }
    if (failed > 0) {
      notes.add('旧我的库迁移失败 $failed 条（明细见 loadProblems）');
    }
    try {
      await _persistLibrary();
    } catch (e) {
      problems.add('迁移后的我的库没写成（$e）：本次会话内存有效，下次启动自动重试迁移');
    }
  }

  /// 新键条目解码：**别名互认**（promptText|body、domain|category、emoji|avatar）
  /// + 逐条容错。id 必须可用、正文必须非空且 ≤64KiB（docs/expert-pack-format.md
  /// §2/§3 的条目级护栏）——失败返回原因，由调用方计数。
  (kb.Expert?, String?) _expertFromWire(Map<String, dynamic> m) {
    String str(Object? v) {
      final s = v?.toString().trim() ?? '';
      return s;
    }

    var id = str(m['id']);
    final keyWire = str(m['key']);
    if (id.isEmpty) id = keyWire;
    if (id.isEmpty) return (null, '缺 id/key');
    final key = keyWire.isNotEmpty
        ? keyWire
        : (id.contains('/') ? id.substring(id.lastIndexOf('/') + 1) : id);
    final ptRaw = m['promptText'] ?? m['body'];
    final promptText = ptRaw?.toString() ?? '';
    if (promptText.trim().isEmpty) return (null, '「$id」正文为空');
    if (utf8.encode(promptText).length > kb.expertPromptTextMaxBytes) {
      return (null, '「$id」正文超过 64KiB 上限');
    }
    final domain =
        str(m['domain']).isNotEmpty ? str(m['domain']) : str(m['category']);
    final emoji =
        str(m['emoji']).isNotEmpty ? str(m['emoji']) : str(m['avatar']);
    final sourceRaw = m['source'];
    final source = sourceRaw is Map
        ? kb.ExpertSource.fromJson(Map<String, dynamic>.from(sourceRaw))
        : kb.ExpertSource(
            packId: str(m['packId']),
            packVersion: str(m['packVersion']),
            origin: kb.ExpertOrigin.tryParse(str(m['origin'])),
          );
    return (
      kb.Expert(
        id: id,
        key: key,
        name: str(m['name']).isEmpty ? key : str(m['name']),
        domain: domain,
        promptText: promptText,
        tags: <String>[
          if (m['tags'] is List)
            for (final t in (m['tags'] as List))
              if (t is String && t.trim().isNotEmpty) t.trim(),
        ],
        description: str(m['description']),
        emoji: emoji.isEmpty ? '🧩' : emoji,
        source: source,
      ),
      null,
    );
  }

  /// 新键条目序列化：写 core 主拼写（promptText/domain/emoji），source 走
  /// core ExpertSource.toJson。
  Map<String, dynamic> _expertToJson(kb.Expert e) => <String, dynamic>{
        'id': e.id,
        'key': e.key,
        'name': e.name,
        'domain': e.domain,
        'promptText': e.promptText,
        'tags': List<String>.of(e.tags),
        'description': e.description,
        'emoji': e.emoji,
        'source': e.source.toJson(),
      };

  Future<void> _persistLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      libraryKeyV2,
      jsonEncode(<String, dynamic>{
        'version': 2,
        'entries': <Map<String, dynamic>>[
          for (final e in _library)
            <String, dynamic>{
              'expert': _expertToJson(e),
              'meta': (_meta[e.id] ?? const ExpertEntryMeta()).toJson(),
            },
        ],
        'packImportedAt': Map<String, int>.of(_packImportedAt),
      }),
    );
  }

  void _notifyLibrary() {
    if (_disposed) return; // 页面已退场：盘上状态已落好，内存态随实例销毁
    installed.value = List.of(_library);
  }

  void _refreshPacks() {
    if (_disposed) return; // 同 _notifyLibrary
    final snap = _manager.installed();
    _packs.value = snap.packs;
    packProblems.value = List.unmodifiable(snap.problems);
  }

  /// 严格递增的毫秒时间戳（同一毫秒内连续两次变更也要能分先后，否则
  /// ValueNotifier/排序都可能停在旧值上——与 ContactStore.update 同一教训）。
  int _nextStamp() {
    final n = DateTime.now().millisecondsSinceEpoch;
    if (n > _lastStamp) {
      _lastStamp = n;
      return n;
    }
    _lastStamp += 1;
    return _lastStamp;
  }

  void dispose() {
    _disposed = true;
    installed.dispose();
    _packs.dispose();
    packProblems.dispose();
  }
}

// ---------------------------------------------------------------------------
// 内置清单的发布包兜底镜像
// ---------------------------------------------------------------------------

/// 内置目录 JSON 的**逐字镜像**（beta.6，git 652a78c 时的
/// `packages/core/assets/experts/catalog.json`）。
///
/// 为什么 app 里要有这份拷贝：beta.6 的 `packages/core/pubspec.yaml` 没有
/// `flutter:` assets 段（本会话已核对全文），core 包 assets 不是 Flutter 资产，
/// rootBundle 在发布运行时读不到 `packages/chartools_core/assets/experts/
/// catalog.json`；磁盘探测（[kb.readBuiltinCatalogJson]）在发布包里同样找不到
/// 工作区文件。没有这层兜底，发布包的内置货架是空的——浏览能力直接变浅。
/// 取用顺序见 [ExpertsController._resolveBuiltinJson]：rootBundle → 磁盘探测
/// → 这份镜像；测试与桌面开发走前两层（读真文件），镜像只在发布运行时生效。
///
/// **同步义务**：core 目录演进时必须刷新这份镜像（加载顺序保证 dev/测试环境
/// 立刻暴露偏差——测试断言的是 core 真文件的内容，镜像过期会在测试里显形）。
const String _builtinCatalogMirror = r'''
{
  "format": "jev-expert-pack/1",
  "pack": {
    "id": "builtin",
    "version": "1.0.0",
    "name": "内置示例专家",
    "origin": "builtin",
    "source": "骨架示例包：正文取自旧仓库 PersonaPresets.kt 的五类示范卡（超越 legacy 的全量内嵌——完整 331 位专家目录按需经远端资产包安装，清单 URL 由 app 层配置）"
  },
  "experts": [
    {
      "id": "daily.friend",
      "name": "日常闲聊",
      "domain": "日常",
      "tags": ["朋友", "口语", "松弛"],
      "description": "日常闲聊：用平时的叫法，口语松弛，不端着",
      "emoji": "🌿",
      "promptText": "称呼：用平时的叫法\n关系：朋友\n语气：口语、松弛，别端着\n主题：日常\n示例：\n我：在忙吗\n我：晚饭吃了吗"
    },
    {
      "id": "love.coldwar",
      "name": "恋爱·冷战破冰",
      "domain": "情感",
      "tags": ["冷战", "破冰", "不翻旧账"],
      "description": "冷了两天要开口：认自己那部分，不翻旧账，约一个具体时间",
      "emoji": "🧊",
      "promptText": "称呼：还是平时的叫法，别突然改口\n关系：情侣，正在闹别扭\n语气：平静、直接，不翻旧账，不阴阳\n主题：恋爱\n情境：冷了两天，我决定先开口\n避谈：分手、随便你\n示例：\n我：这两天我说话冲了，是我不对\n我：我想把这事说清楚，不是要吵\n我：你什么时候方便，我们聊十分钟"
    },
    {
      "id": "sales.followup",
      "name": "销售·跟单",
      "domain": "销售",
      "tags": ["跟单", "方案", "不催"],
      "description": "销售跟单：先结论后理由，不催不捧，不替客户许诺",
      "emoji": "📈",
      "promptText": "称呼：按对方名片上的称呼，姓＋总或姓＋老师\n关系：销售和客户，我给方案，他做决定\n语气：短句、具体，先给结论再给理由，不催不捧\n主题：销售\n情境：微信或电话跟单，隔着屏幕\n避谈：稳赚、保证收益\n示例：\n我：王总，方案按您上次说的改完了，您看哪天方便过一遍\n我：这个折扣我申请不下来，先如实跟您说\n我：不急，您先忙，我明天上午再跟您确认"
    },
    {
      "id": "work.report",
      "name": "职场·向上汇报",
      "domain": "职场",
      "tags": ["汇报", "结论先行", "要拍板"],
      "description": "给上级汇报：一句话结论 + 一个要他拍的决定",
      "emoji": "📊",
      "promptText": "称呼：X 总 / X 老师\n关系：下属和上级\n语气：结论先行，一句话说完再展开\n主题：职场\n情境：周会或群里汇报进度\n避谈：我觉得、可能吧\n示例：\n我：X 总，A 项目按期，本周三上线，风险只有一个：测试环境排期\n我：需要您拍一下：先上 80% 功能，还是整体延两天\n我：两条路的影响我写成两行，您看哪个"
    },
    {
      "id": "service.complaint",
      "name": "客服·投诉安抚",
      "domain": "客服",
      "tags": ["投诉", "先接情绪", "不辩解"],
      "description": "客户在群里发火：先认下我们的问题，再给动作和时间",
      "emoji": "🫱",
      "promptText": "称呼：您\n关系：客服和不满的客户\n语气：先接住情绪，再给动作，不辩解\n主题：客服\n情境：客户在群里发火\n避谈：按规定、没办法\n示例：\n我：这事是我们没做好，先跟您说声抱歉\n我：我现在就查，十分钟内给您准信\n我：补偿方案我按最高一档给您申请"
    }
  ]
}
''';

/// 专家库的应用层：目录（ExpertPack 资产包）+ 我的专家库 + 套用语义。
///
/// 对应旧仓库 `core/kb/` 的四个纯 Kotlin 件的职责移植（legacy 是思路库，
/// 不是逐行复刻——本层按「按需资产包」重新设计）：
/// - `ExpertPack.kt` → [ExpertPack]：目录 JSON 的容错解析 + 资产包元信息
///   （来源追踪，用户校准项）。
/// - `ExpertCatalog.kt` → [ExpertCatalog]：分类/搜索/标签/排序的纯函数浏览层。
/// - `ExpertShelf.kt` → [ExpertShelfItem]：目录样品与我的条目拼一张货架，
///   同 presetKey 我的优先。
/// - `ExpertApply.kt` → [ExpertsController.applyAsGlobalStyle] /
///   [ExpertsController.applyToContact]：install → touch → 换正文的三步
///   套用语义，要么全成、要么不留半截。
///
/// 两条铁律（沿袭 legacy PersonaProfile 的设计约束）：
/// 1. **浏览层 ≠ 提示词正文**：[ExpertPreset.description] / [tags] /
///    [category] / [avatar] 只给人看；进提示词的只有 [ExpertShelfItem.body]，
///    页面的 promptText 预览经 `PersonaCard.parse(body).promptText()` 现算。
/// 2. **持久化只用 shared_preferences JSON**（p0-plan F2 的边界不变：只有
///    API Key 走 secure storage）。专家/资产包都是非敏感字段，键为
///    [_libraryKey] / [_packsKey]，与 ContactStore 的 `contacts` 键、
///    SettingsStore 的 `settings` 键互不相干。
library;

import 'dart:convert';

import 'package:chartools_core/chartools_core.dart' show StyleSource, StyleSourceFrom;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'contact_store.dart';
import 'settings_store.dart';

// ---------------------------------------------------------------------------
// 数据模型
// ---------------------------------------------------------------------------

/// 目录里的一位专家（资产包内的一条）。[body] 是唯一进提示词的字段；
/// 其余全是浏览层（展示 / 检索 / 排序），一个字节都不进提示词。
class ExpertPreset {
  const ExpertPreset({
    required this.key,
    required this.name,
    required this.body,
    this.category = '',
    this.tags = const [],
    this.description = '',
    this.avatar = '',
    this.packName = '',
  });

  /// 包内稳定标识（用户改名不变；与 legacy PersonaPreset.key 同语义）。
  final String key;
  final String name;

  /// 人设正文，逐字保存（不 trim、不规范化——「套用 → 保存 → 再套用」
  /// 不允许悄悄变形，见 legacy StyleSource.kt:24 的注释）。
  final String body;

  /// 以下均为浏览层字段，**永不进提示词**。
  final String category;
  final List<String> tags;
  final String description;

  /// 一个 emoji；空串由 [ExpertShelfItem.avatar] 落回占位符。
  final String avatar;

  /// 来源包名（来源追踪）：种子包填种子包名，导入的资产包填其 meta.name。
  final String packName;
}

/// 资产包元信息：**来源追踪**（用户校准项「知识库要有来源追踪」在专家侧
/// 的落点）。每个安装进来的目录都要能回答「这些专家是谁、从哪来、哪个版本」。
class ExpertPackMeta {
  const ExpertPackMeta({
    required this.name,
    this.source = '',
    this.commit = '',
    this.hash = '',
    this.expertCount = 0,
    this.installedAt = 0,
  });

  /// 包名：展示用，也是与 [hash] 一起做「重复安装去重」的键。
  final String name;

  /// 出处（URL 或说明），页面照实显示，不参与逻辑。
  final String source;
  final String commit;

  /// 内容指纹：同 name+hash 视为同一个包（重复安装=刷新而不是追加）。
  final String hash;

  /// 包内可用专家数（解析通过的那部分）。
  final int expertCount;

  /// 安装时间的毫秒时间戳；0 = 内置种子包（不持久化，每次启动重建）。
  final int installedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'source': source,
        'commit': commit,
        'hash': hash,
        'expertCount': expertCount,
        'installedAt': installedAt,
      };

  /// 容错解析：缺字段落默认值（与 ContactProfile.fromJson 同一口径）。
  factory ExpertPackMeta.fromJson(Map<String, dynamic> j) => ExpertPackMeta(
        name: j['name'] is String ? j['name'] as String : '',
        source: j['source'] is String ? j['source'] as String : '',
        commit: j['commit'] is String ? j['commit'] as String : '',
        hash: j['hash'] is String ? j['hash'] as String : '',
        expertCount: j['expertCount'] is int ? j['expertCount'] as int : 0,
        installedAt: j['installedAt'] is int ? j['installedAt'] as int : 0,
      );
}

/// [ExpertPack.parse] 的结果：解析失败收敛成 [problem]，绝不外抛——
/// 目录坏了只该退化成「没有货架」，不能把专家页带崩（legacy ExpertPack
/// 的既定态度）。
class ExpertPack {
  const ExpertPack({
    required this.meta,
    this.presets = const [],
    this.problem = '',
  });

  final ExpertPackMeta meta;
  final List<ExpertPreset> presets;

  /// 解析说明；空串 = 正常。逐条容错时这里给「跳过了几条」的汇总。
  final String problem;

  bool get ok => presets.isNotEmpty;

  /// 解析资产包 JSON。任何异常都收敛成 [problem]；**逐条容错而不是整包
  /// 放弃**——一条 body 写坏，不该让其余专家一起消失。
  ///
  /// 认的形状（宽松）：`{name?, source?, sourceCommit?, contentHash?,
  /// experts: [{key, name, body, category?, tags?, description?, emoji?}]}`
  /// ——与 legacy ExpertPack.kt:79 的字段名一致，外加可选的 `name` 包名。
  ///
  /// **字段别名互认**（统一包格式见 docs/expert-pack-format.md；core 严格
  /// 路径认 `id`/`promptText`，这里是宽容路径，两套拼写都认，同一份远端包
  /// 不至于在某一边全量跳过）：entry 级 `id`↔`key`、`promptText`↔`body`、
  /// `domain`↔`category`；包级认 `format`（只容忍不校验，严格校验归 core
  /// PackCodec）与 `pack` 对象（name/source/sourceCommit/contentHash 落不到
  /// 包级时回退读它）。
  static ExpertPack parse(String json, {int installedAt = 0}) {
    if (json.trim().isEmpty) {
      return ExpertPack(
          meta: ExpertPackMeta(name: '', installedAt: installedAt),
          problem: '资产包为空');
    }
    final Object? root;
    try {
      root = jsonDecode(json);
    } on FormatException catch (e) {
      return ExpertPack(
          meta: ExpertPackMeta(name: '', installedAt: installedAt),
          problem: '资产包不是合法 JSON：${e.message}');
    }
    if (root is! Map<String, dynamic>) {
      return ExpertPack(
          meta: ExpertPackMeta(name: '', installedAt: installedAt),
          problem: '资产包根节点必须是对象');
    }
    String str(Object? v) => v is String ? v.trim() : '';
    // 包级元数据回退：core 形状的元数据在 `pack` 对象里（id/version/...）。
    final Map<String, dynamic> rootMap = root; // 闭包内不继承 is! 提升，落回本地
    final packRaw = rootMap['pack'] is Map<String, dynamic>
        ? rootMap['pack'] as Map<String, dynamic>
        : const <String, dynamic>{};
    String packField(String key, String fallback) {
      final top = str(rootMap[key]);
      if (top.isNotEmpty) return top;
      final nested = str(packRaw[key]);
      return nested.isNotEmpty ? nested : fallback;
    }

    final meta = ExpertPackMeta(
      name: packField('name', str(packRaw['id'])),
      source: packField('source', ''),
      commit: packField('sourceCommit', ''),
      hash: packField('contentHash', ''),
      installedAt: installedAt,
    );
    final list = root['experts'];
    if (list is! List) {
      return ExpertPack(meta: meta, problem: '资产包缺少 experts 数组');
    }
    final out = <ExpertPreset>[];
    var skipped = 0;
    for (final e in list) {
      if (e is! Map<String, dynamic>) {
        skipped++;
        continue;
      }
      // 别名互认：key↔id、body↔promptText、category↔domain（主拼写在前）。
      final key = str(e['key']).isNotEmpty ? str(e['key']) : str(e['id']);
      final name = str(e['name']).isEmpty ? key : str(e['name']);
      final bodyRaw = e['body'] ?? e['promptText'];
      final body = bodyRaw is String ? bodyRaw : '';
      // key 与 body 是「这条专家能不能用」的下限：key 空则货架去重失灵，
      // body 空则套用等于清空人设——都跳过（legacy ExpertPack.kt:98 同口径）。
      if (key.isEmpty || body.trim().isEmpty) {
        skipped++;
        continue;
      }
      out.add(ExpertPreset(
        key: key,
        name: name,
        body: body,
        category: str(e['category']).isNotEmpty
            ? str(e['category'])
            : str(e['domain']),
        tags: [
          if (e['tags'] is List)
            for (final t in e['tags'] as List)
              if (t is String) t.trim()
        ].where((t) => t.isNotEmpty).toList(),
        description: str(e['description']),
        avatar: str(e['emoji']),
        packName: meta.name,
      ));
    }
    final problem = switch ((out.isEmpty, skipped > 0)) {
      (true, _) => '资产包里没有可用专家（跳过 $skipped 条）',
      (false, true) => '资产包有解析失败的条目，跳过 $skipped 条',
      (false, false) => '',
    };
    return ExpertPack(
      meta: ExpertPackMeta(
        name: meta.name,
        source: meta.source,
        commit: meta.commit,
        hash: meta.hash,
        expertCount: out.length,
        installedAt: installedAt,
      ),
      presets: out,
      problem: problem,
    );
  }
}

/// 「我的专家库」里的一条：装进来的目录专家（可改名改正文）或用户自建的。
/// 与 legacy PersonaProfile.kt 同构：body 行为层，其余浏览层。
class ExpertProfile {
  const ExpertProfile({
    required this.id,
    required this.name,
    required this.body,
    this.builtin = false,
    this.avatar = '',
    this.description = '',
    this.tags = const [],
    this.category = '',
    this.usedCount = 0,
    this.presetKey = '',
    this.sourceRef = '',
    this.updatedAt = 0,
  });

  final String id;
  final String name;
  final String body;
  final bool builtin;

  // —— 以下浏览层，永不进提示词 ——
  final String avatar;
  final String description;
  final List<String> tags;
  final String category;

  /// 被套用次数（「最热」排序与综合分的数据源）。
  final int usedCount;

  /// 目录来源的稳定标识（`daily.friend` 一类）；自建/复制为空串。
  final String presetKey;

  /// **来源追踪**：这条专家从哪来（`pack:<包名>` / `seed:<包名>` / `mine`）。
  final String sourceRef;
  final int updatedAt;

  ExpertProfile copyWith({
    String? id,
    String? name,
    String? body,
    bool? builtin,
    String? avatar,
    String? description,
    List<String>? tags,
    String? category,
    int? usedCount,
    String? presetKey,
    String? sourceRef,
    int? updatedAt,
  }) =>
      ExpertProfile(
        id: id ?? this.id,
        name: name ?? this.name,
        body: body ?? this.body,
        builtin: builtin ?? this.builtin,
        avatar: avatar ?? this.avatar,
        description: description ?? this.description,
        tags: tags ?? this.tags,
        category: category ?? this.category,
        usedCount: usedCount ?? this.usedCount,
        presetKey: presetKey ?? this.presetKey,
        sourceRef: sourceRef ?? this.sourceRef,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'body': body,
        'builtin': builtin,
        'avatar': avatar,
        'description': description,
        'tags': List<String>.of(tags),
        'category': category,
        'usedCount': usedCount,
        'presetKey': presetKey,
        'sourceRef': sourceRef,
        'updatedAt': updatedAt,
      };

  /// 容错解析：类型不对的项落默认值，绝不抛（坏存档不挡启动）。
  factory ExpertProfile.fromJson(Map<String, dynamic> j) => ExpertProfile(
        id: j['id'] is String ? j['id'] as String : '',
        name: j['name'] is String ? j['name'] as String : '',
        body: j['body'] is String ? j['body'] as String : '',
        builtin: j['builtin'] is bool ? j['builtin'] as bool : false,
        avatar: j['avatar'] is String ? j['avatar'] as String : '',
        description:
            j['description'] is String ? j['description'] as String : '',
        tags: _stringListOf(j['tags']),
        category: j['category'] is String ? j['category'] as String : '',
        usedCount: j['usedCount'] is int ? j['usedCount'] as int : 0,
        presetKey: j['presetKey'] is String ? j['presetKey'] as String : '',
        sourceRef: j['sourceRef'] is String ? j['sourceRef'] as String : '',
        updatedAt: j['updatedAt'] is int ? j['updatedAt'] as int : 0,
      );

  static List<String> _stringListOf(Object? raw) => [
        if (raw is List)
          for (final v in raw)
            if (v is String) v,
      ];
}

/// 货架上的一条：**我的条目优先**（同 presetKey 或同名时目录样品让位）。
/// legacy ExpertShelf.kt:162 的对应物——目录是货架上的样品，用户改过的
/// 那份才是他的东西；拼的时候丢掉用户改过的内容是这类功能最隐蔽的错。
class ExpertShelfItem {
  const ExpertShelfItem.mine(this.profile) : preset = null;
  const ExpertShelfItem.ghost(this.preset) : profile = null;

  final ExpertProfile? profile;
  final ExpertPreset? preset;

  /// 我的库里已有这一条。
  bool get inLibrary => profile != null;

  /// 目录样品的稳定 id（`pack:<key>`，与库内自增 id 形状不同，无歧义）。
  String get id => profile?.id ?? 'pack:${preset?.key ?? ''}';

  String get name => profile?.name ?? preset?.name ?? '';
  String get body => profile?.body ?? preset?.body ?? '';
  String get category => (profile?.category ?? preset?.category ?? '').trim();
  List<String> get tags => profile?.tags ?? preset?.tags ?? const [];
  String get description => profile?.description ?? preset?.description ?? '';
  int get usedCount => profile?.usedCount ?? 0;
  bool get builtin => profile?.builtin ?? true;
  String get presetKey => profile?.presetKey ?? preset?.key ?? '';

  /// 来源追踪：样品显示包名；已入库的显示落库时记下的 sourceRef。
  String get sourceRef =>
      profile?.sourceRef ?? 'pack:${preset?.packName ?? ''}';

  /// 头像：没设时落占位 emoji（legacy ExpertCard.kt:35 的 FALLBACK_AVATAR）。
  String get avatar {
    final a = (profile?.avatar ?? preset?.avatar ?? '').trim();
    return a.isEmpty ? '🧩' : a;
  }
}

// ---------------------------------------------------------------------------
// 浏览层（纯函数）
// ---------------------------------------------------------------------------

/// 排序方式：综合 / 最热 / 最新（legacy ExpertCatalog.kt:9 的三个 tab）。
enum ExpertSort {
  /// 综合分排序：`usedCount * 3 + (builtin ? 2 : 0)`。
  comprehensive('综合'),

  /// 只看套用次数。
  hottest('最热'),

  /// 只看最近编辑时间。
  newest('最新');

  const ExpertSort(this.label);
  final String label;
}

/// 专家浏览的纯函数层：分类、搜索、标签、排序。全部不改入参、返回新列表，
/// 让「综合排序凭什么这个顺序」「搜『稳赚』能不能搜到销售跟进」这类问题
/// 能被单测钉死（与 legacy ExpertCatalog.kt:26 同一理由）。
abstract final class ExpertCatalog {
  /// 内置分类的固定顺序（分组 chips 的顺序）；不在表里的自定义分类按名字
  /// 排在后面。沿用 legacy ExpertPack.kt:46 的清单，保证老用户换过来时
  /// 分组顺序的眼熟感。
  static const List<String> categoryOrder = <String>[
    '情感',
    '销售',
    '职场',
    '客服',
    '日常',
    '学术研究',
    '企业战略',
    '设计',
    '技术工程',
    '金融财务',
    '游戏开发',
    '地理信息',
    '医疗健康',
    '人力组织',
    '法务合规',
    '市场营销',
    '投放广告',
    '产品',
    '项目管理',
    '研究',
    '安全',
    '空间计算',
    '垂直专业',
    '供应链',
    '质量测试',
  ];

  /// 没有分类的条目归到这里（只在真有这种条目时出现）。
  static const String uncategorized = '未分类';

  /// 「全部」不是分类，是「不筛」。
  static const String all = '全部';

  /// 当前货架真实存在的分类，按 [categoryOrder] 排；自定义分类按名字跟在
  /// 后面；有未分类条目时最后追加 [uncategorized]。刻意不返回空分类。
  static List<String> categories(List<ExpertShelfItem> items) {
    final present = {
      for (final i in items)
        if (i.category.isNotEmpty) i.category
    };
    final out = <String>[
      for (final c in categoryOrder)
        if (present.contains(c)) c,
      ...present.where((c) => !categoryOrder.contains(c)).toList()..sort(),
    ];
    if (items.any((i) => i.category.isEmpty)) out.add(uncategorized);
    return out;
  }

  /// 综合分（规则写死在这里，是为了能被断言）：一次套用值 3 分，内置目录
  /// 条目额外 2 分——「用了一次的自建专家」和「没被用过的目录条目」打平，
  /// 再用一次就反超（legacy ExpertCatalog.kt:111 的规则原样保留）。
  /// （int.clamp 返回 num，手动钳负值保持 int 返回类型。）
  static int score(ExpertShelfItem item) {
    final used = item.usedCount < 0 ? 0 : item.usedCount;
    return used * 3 + (item.builtin ? 2 : 0);
  }

  /// 单条是否命中关键词：名字、简介、标签、正文（正文也算——用户往往记得
  /// 的是「那张写着某句话的卡」，legacy ExpertCatalog.kt:77 同口径）。
  static bool matches(ExpertShelfItem item, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (item.name.toLowerCase().contains(q)) return true;
    if (item.description.toLowerCase().contains(q)) return true;
    if (item.tags.any((t) => t.toLowerCase().contains(q))) return true;
    return item.body.toLowerCase().contains(q);
  }

  /// 按分类 + 标签 + 关键词筛。[category] 传 null / [all] 都表示不筛；
  /// [uncategorized] 筛没有分类的条目；[tag] 空串 = 不筛。
  static List<ExpertShelfItem> filter(
    List<ExpertShelfItem> items, {
    String? category,
    String tag = '',
    String query = '',
  }) {
    final cat = (category ?? '').trim();
    final t = tag.trim();
    return items.where((i) {
      final catOk = switch (cat) {
        '' || all => true,
        uncategorized => i.category.isEmpty,
        _ => i.category.toLowerCase() == cat.toLowerCase(),
      };
      final tagOk = t.isEmpty || i.tags.contains(t);
      return catOk && tagOk && matches(i, query);
    }).toList();
  }

  /// 排序。三种模式的主键不同，副键统一（最近编辑 → 名字），保证结果确定
  /// 可比（legacy ExpertCatalog.kt:114 同口径）。
  static List<ExpertShelfItem> sort(
    List<ExpertShelfItem> items, {
    ExpertSort mode = ExpertSort.comprehensive,
  }) {
    int byRecent(ExpertShelfItem i) => i.profile?.updatedAt ?? 0;
    int byUsage(ExpertShelfItem i) => i.usedCount;
    final list = [...items];
    list.sort((a, b) {
      switch (mode) {
        case ExpertSort.comprehensive:
          final s = score(b).compareTo(score(a));
          if (s != 0) return s;
        case ExpertSort.hottest:
          final s = byUsage(b).compareTo(byUsage(a));
          if (s != 0) return s;
        case ExpertSort.newest:
          final s = byRecent(b).compareTo(byRecent(a));
          if (s != 0) return s;
      }
      final r = byRecent(b).compareTo(byRecent(a));
      if (r != 0) return r;
      return a.name.compareTo(b.name);
    });
    return list;
  }

  /// 界面用的组合动作：先筛后排（顺序固定，分开调两次没有意义）。
  static List<ExpertShelfItem> browse(
    List<ExpertShelfItem> items, {
    String? category,
    String tag = '',
    String query = '',
    ExpertSort mode = ExpertSort.comprehensive,
  }) =>
      sort(
        filter(items, category: category, tag: tag, query: query),
        mode: mode,
      );
}

// ---------------------------------------------------------------------------
// 套用语义
// ---------------------------------------------------------------------------

/// 一次套用的结果。[ok=false] 时 [profile] 也可能非空——落库成功但换正文
/// 失败时，库里那条要保留（legacy ExpertApply.kt:39 的「负向的第 3 步失败」）。
class ExpertApplyResult {
  const ExpertApplyResult({
    required this.ok,
    this.profile,
    this.warning = '',
    this.problem = '',
  });

  final bool ok;
  final ExpertProfile? profile;

  /// 降级说明（热度没记上一类），不影响使用。
  final String warning;

  /// 失败原因，给界面直接显示。
  final String problem;
}

/// 全局风格正文的写入口。接口而不是直接依赖 SettingsStore，理由与 legacy
/// ExpertApply.kt:13（StyleSink）一致：保持套用语义可在纯 Dart 单测里逼出
/// 失败路径。接线时用 [SettingsStyleSink]。
abstract class StyleSink {
  String get style;
  Future<void> setStyle(String value);
}

/// [StyleSink] 的 SettingsStore 适配器：写 `config.style` 并整包落盘。
/// settings_store.dart 不由本工作流改动，只 import 消费（页面的接线留 #13）。
class SettingsStyleSink implements StyleSink {
  SettingsStyleSink(this.store);

  final SettingsStore store;

  @override
  String get style => store.config.value.style;

  @override
  Future<void> setStyle(String value) async {
    store.config.value = store.config.value.copyWith(style: value);
    await store.save();
  }
}

/// 联系人档案对套用动作暴露的最小面：选目标 + 覆写专用人设。与 [StyleSink]
/// 同一思路——接口隔离，测试用内存实现，接线用 [ContactStorePersonaSink]。
abstract class ContactPersonaSink {
  /// 当前全部联系人（页面选套用目标用；[ContactTarget.persona] 供页面判断
  /// 「已有专用人设 → 弹确认」的 StyleSource 优先级提示）。
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
/// 本工作流不碰它；接线留 #13）。
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

// ---------------------------------------------------------------------------
// 内置种子目录
// ---------------------------------------------------------------------------

/// 内置种子资产包：随代码内置的一小批示范专家（**思路源自 legacy
/// PersonaPresets.kt，内容按本仓库场景重写**——它是「长成什么样才对」的
/// 示范，不是唯一选项）。走 [ExpertPack.parse] 同一条解析路径，保证种子与
/// 外部资产包的解析行为一致。正文一律写 PersonaCard 的**键**而不是散文
/// ——键才会被拆进提示词/闸门/语域开关（legacy PersonaPresets.kt:38 的教训）。
const String seedPackJson = '''
{
  "name": "内置种子目录",
  "source": "chartools-next 内置（思路源自 legacy PersonaPresets，内容重写）",
  "contentHash": "seed-v1",
  "experts": [
    {
      "key": "daily.friend",
      "name": "日常闲聊",
      "category": "日常",
      "tags": ["朋友", "口语", "松弛"],
      "description": "日常闲聊：用平时的叫法，口语松弛，不端着",
      "emoji": "🌿",
      "body": "称呼：用平时的叫法\\n关系：朋友\\n语气：口语、松弛，不端着\\n情境：日常闲聊\\n硬边界：借钱、隐私\\n避谈：鸡汤\\n示例：\\n我：在干嘛\\n对方：刚吃完饭，瘫着\\n我：出来走走？"
    },
    {
      "key": "emotion.companion",
      "name": "情绪陪伴",
      "category": "情感",
      "tags": ["深夜", "倾听", "不建议"],
      "description": "亲密朋友的深夜聊天：先接情绪，给陪伴不给说教",
      "emoji": "🌙",
      "body": "称呼：用平时的昵称\\n关系：亲密朋友\\n语气：温和、接住情绪，不急着给建议\\n主题：情绪陪伴\\n情境：深夜私聊\\n硬边界：评判、说教\\n避谈：想开点、多喝热水\\n安全词：暂停\\n示例：\\n我：今天好累\\n对方：那就先歇着，我陪你待会儿"
    },
    {
      "key": "sales.followup",
      "name": "销售跟进",
      "category": "销售",
      "tags": ["跟进", "克制", "不夸大"],
      "description": "客户跟进：先回应再推进，不替产品许诺",
      "emoji": "🤝",
      "body": "称呼：称对方「您」\\n关系：销售与客户，跟进阶段\\n语气：热情但克制，短句，先回应再推进\\n主题：产品跟进\\n情境：微信文字沟通\\n硬边界：虚假承诺、贬低竞品\\n避谈：稳赚、保证收益、最低价\\n示例：\\n我：上次说的方案您看了吗\\n对方：还没细看\\n我：不急，需要我挑两页重点发您吗"
    },
    {
      "key": "workplace.report",
      "name": "职场汇报",
      "category": "职场",
      "tags": ["汇报", "结论先行", "结构化"],
      "description": "对上级汇报：先结论后细节，不甩锅不越级",
      "emoji": "📋",
      "body": "称呼：称职务或「老师」\\n关系：下属向直属上级汇报\\n语气：结构化、先结论后细节，不用感叹号\\n情境：周会与周报\\n硬边界：甩锅、越级\\n避谈：大概、可能吧\\n示例：\\n我：本周进展两个：A 已上线，B 卡在审批\\n我：B 需要您帮忙推一下审批"
    },
    {
      "key": "service.complaint",
      "name": "客诉安抚",
      "category": "客服",
      "tags": ["客诉", "先接情绪", "不辩解"],
      "description": "客诉处理：先接情绪再处理问题，不辩解不推诿",
      "emoji": "🎧",
      "body": "称呼：称「您」\\n关系：客服与不满中的用户\\n语气：先接情绪再处理，短句，不辩解\\n主题：客诉处理\\n硬边界：推诿、私自承诺赔偿\\n避谈：这是规定\\n示例：\\n我：非常抱歉让您跑了三趟\\n我：这次我来跟进到底，处理完第一时间告诉您"
    },
    {
      "key": "research.literature",
      "name": "文献速读",
      "category": "研究",
      "tags": ["文献", "来源", "不编造"],
      "description": "文献梳理：给结论先给来源，不编造不脑补",
      "emoji": "📚",
      "body": "称呼：直呼「你」\\n关系：研究助理与研究者\\n语气：精确、克制，先给来源再给结论\\n主题：文献梳理\\n硬边界：编造文献、伪造数据\\n避谈：众所周知\\n示例：\\n我：这个问题有三条线：Chen 2021、Dupont 2022、以及综述里的一句带过"
    },
    {
      "key": "tech.code-review",
      "name": "代码评审",
      "category": "技术工程",
      "tags": ["评审", "就事论事"],
      "description": "同事代码评审：就事论事，先结论再理由，附改法",
      "emoji": "🛠",
      "body": "称呼：直接用 ID\\n关系：同事之间的代码评审\\n语气：就事论事，先结论再理由，附修改建议\\n情境：PR 评论\\n硬边界：人身评价\\n避谈：重构一切\\n示例：\\n我：这里先别缓存：键没含租户 ID，会串数据；改成传参就行"
    },
    {
      "key": "product.prd",
      "name": "需求梳理",
      "category": "产品",
      "tags": ["需求", "用户故事"],
      "description": "产品与研发对齐需求：用户故事先行，边界写清楚",
      "emoji": "🧭",
      "body": "称呼：称「你」\\n关系：产品与研发对齐需求\\n语气：结构化，用户故事先行\\n主题：需求评审\\n硬边界：拍脑袋排期\\n避谈：对标大厂\\n示例：\\n我：这个故事是：运营在活动前能自己改文案，不用找研发"
    }
  ]
}
''';

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

/// 专家库控制器：持目录（[ExpertPack] 列表）+ 我的库（[ExpertProfile] 列表）
/// 与本地持久化；套用动作实现 legacy ExpertApply 的三步语义。
///
/// 页面接线留 **#13**：main.dart 不由本工作流改动；接线时构造
/// `ExpertsController(styleSink: SettingsStyleSink(settings), contactSink:
/// ContactStorePersonaSink(contacts))` 并调 [load]。
class ExpertsController {
  ExpertsController({StyleSink? styleSink, ContactPersonaSink? contactSink})
      : _styleSink = styleSink,
        _contactSink = contactSink {
    // 种子包不持久化：每次启动重建（内容随代码走，不该被旧盘上的快照钉死）。
    _packs.value = [ExpertPack.parse(seedPackJson)];
  }

  /// shared_preferences 键：我的专家库整包 JSON。
  static const String _libraryKey = 'experts';

  /// shared_preferences 键：已安装资产包的原始 JSON 列表（重装/去重的依据）。
  static const String _packsKey = 'expert_packs';

  final StyleSink? _styleSink;
  final ContactPersonaSink? _contactSink;

  /// 我的专家库（存档顺序即展示顺序；写回永远换新 List，ValueNotifier 按
  /// identical 判定——与 ContactStore.contacts 同一纪律）。
  final ValueNotifier<List<ExpertProfile>> installed =
      ValueNotifier(const <ExpertProfile>[]);

  /// 已装载的资产包：第 0 位恒为种子包，其后是安装进来的。
  final ValueNotifier<List<ExpertPack>> _packs = ValueNotifier(<ExpertPack>[]);

  /// 只读视图（页面监听用）。
  Listenable get packsListenable => _packs;

  List<ExpertPack> get packs => _packs.value;

  /// 全局风格写入口是否已接线（未接线时页面禁用「套用为全局风格」并提示）。
  bool get hasStyleSink => _styleSink != null;

  /// 联系人写入口是否已接线（#13 接线后才有值）。
  bool get hasContactSink => _contactSink != null;

  /// 当前联系人目标快照（页面选套用目标、判断「已有专用人设」用）。
  List<ContactTarget> get contactTargets => _contactSink?.targets ?? const [];

  /// 「这位联系人是否写了专用人设」的**唯一判定处**：复用 core
  /// [StyleSource.resolve]（style_source.dart:27——专用人设压全局的既定
  /// 优先级）。独立复核要求：优先级规则将来若改，判定只改这一处，页面与
  /// 提示不得各自手写 trim 判空漂移。
  static bool contactHasPersona(ContactTarget target) =>
      StyleSource.resolve('', target.persona).from == StyleSourceFrom.contact;

  /// 是否存在写了专用人设的联系人（套用为全局风格时的 StyleSource 提示条件）。
  bool get anyContactHasPersona =>
      contactTargets.any((t) => contactHasPersona(t));

  // ------------------------------------------------------------------ 货架

  /// 货架：我的条目在前 + 尚未入库的目录样品（legacy ExpertShelf.merge 的
  /// 语义），再按浏览条件筛排。
  List<ExpertShelfItem> shelf({
    String? category,
    String tag = '',
    String query = '',
    ExpertSort sort = ExpertSort.comprehensive,
  }) =>
      ExpertCatalog.browse(shelfUnfiltered,
          category: category, tag: tag, query: query, mode: sort);

  /// 未筛排的整张货架（详情页按 id 反查用）。
  List<ExpertShelfItem> get shelfUnfiltered {
    final mine = <ExpertShelfItem>[
      for (final p in installed.value) ExpertShelfItem.mine(p),
    ];
    final mineKeys = {
      for (final p in installed.value)
        if (p.presetKey.isNotEmpty) p.presetKey,
    };
    final mineNames = {for (final p in installed.value) p.name};
    final ghosts = <ExpertShelfItem>[];
    for (final pack in _packs.value) {
      for (final preset in pack.presets) {
        // 同 presetKey **或同名**都让位：目录里的 key 是稳定标识，但用户
        // 完全可能把改名后的条目当「自己的」——两种都算已入库（legacy
        // ExpertShelf.kt:179 的双重判断）。
        if (mineKeys.contains(preset.key) || mineNames.contains(preset.name)) {
          continue;
        }
        ghosts.add(ExpertShelfItem.ghost(preset));
      }
    }
    return [...mine, ...ghosts];
  }

  /// 按 id 找货架条目（详情页返回列表项后重查最新状态用）。
  ExpertShelfItem? shelfItemById(String id) {
    for (final i in shelfUnfiltered) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// 货架上真实存在的分类（页面分组 chips）。
  List<String> categories() => ExpertCatalog.categories(shelfUnfiltered);

  /// 货架上的标签按出现次数降序（页面标签筛选行），最多 [limit] 个。
  List<String> topTags({int limit = 24}) {
    final count = <String, int>{};
    for (final i in shelfUnfiltered) {
      for (final t in i.tags) {
        if (t.trim().isEmpty) continue;
        count[t] = (count[t] ?? 0) + 1;
      }
    }
    final tags = count.keys.toList()
      ..sort((a, b) => (count[b] ?? 0).compareTo(count[a] ?? 0));
    return tags.take(limit).toList();
  }

  // ------------------------------------------------------------------ 套用

  /// 「套用为全局风格」：install → touch → 换 `config.style`，要么全成、
  /// 要么不留半截（legacy ExpertApply.kt:47 的语义移植）。
  ///
  /// 1. 落库失败 → 立刻返回，style 一个字节不动；
  /// 2. 记热度失败 → 降级 [ExpertApplyResult.warning]，不阻塞；
  /// 3. 换 style 失败 → 回滚到进来时的那句；库里那条**不删**（它是完整的
  ///    合法条目，删才是二次破坏）。
  ///
  /// StyleSource 优先级（style_source.dart:27 的既定事实）：联系人专用人设
  /// 压过全局风格——「已有专用人设时弹确认」的判断在页面层用
  /// [anyContactHasPersona] 做，本方法只管写。
  Future<ExpertApplyResult> applyAsGlobalStyle(ExpertShelfItem item) async {
    final sink = _styleSink;
    if (sink == null) {
      return const ExpertApplyResult(ok: false, problem: '全局风格未接线（#13），暂时不能套用');
    }
    return _apply(item, (name) async {
      // 进来时的那句：第 3 步失败要原样退回去。
      final before = sink.style;
      try {
        await sink.setStyle(item.body);
      } catch (e) {
        try {
          await sink.setStyle(before);
        } catch (_) {
          // 回滚也失败：只能如实上报，不能假装成功。
        }
        return '设置里那句人设没写成（$e），已经还原成原来那句；'
            '「$name」还在我的专家库里';
      }
      return null;
    });
  }

  /// 「套用为联系人人设」：install → touch → 覆写该联系人的 persona，三步
  /// 语义与 [applyAsGlobalStyle] 相同。目标联系人的 persona 非空时页面先弹
  /// 确认（StyleSource 优先级：专用人设一旦写入就会压过全局风格）。
  Future<ExpertApplyResult> applyToContact(
    ExpertShelfItem item,
    ContactTarget target,
  ) async {
    final sink = _contactSink;
    if (sink == null) {
      return const ExpertApplyResult(
          ok: false, problem: '联系人档案未接线（#13），暂时不能套用');
    }
    return _apply(item, (_) async {
      try {
        await sink.writePersona(target.id, item.body);
      } catch (e) {
        return '「${target.displayName}」的专用人设没写成（$e），原句未改动；'
            '「${item.name}」还在我的专家库里';
      }
      return null;
    });
  }

  /// 三步套用的公共骨架：0 校验正文 → 1 落库 → 2 记热度 → 3 换目标正文
  /// （[swap] 返回非 null = 第 3 步失败的 problem 文案）。
  Future<ExpertApplyResult> _apply(
    ExpertShelfItem item,
    Future<String?> Function(String name) swap,
  ) async {
    final name = item.name;
    // 0) 正文是唯一进提示词的东西；空正文套上去等于把人设清空。
    if (item.body.trim().isEmpty) {
      return ExpertApplyResult(ok: false, problem: '「$name」没有正文，没套用');
    }

    // 1) 落库。失败 → 目标正文一个字节都不动（本类最要紧的一条不变量）。
    ExpertProfile? entry;
    try {
      entry = await _installShelfItem(item);
    } catch (e) {
      return ExpertApplyResult(
          ok: false, problem: '没能把「$name」存进我的专家库（$e），目标未改动');
    }

    // 2) 记热度。失败降级成 warning，不阻塞套用。
    var warning = '';
    try {
      entry = await _touch(entry.id);
    } catch (_) {
      warning = '热度没记上，不影响使用';
    }

    // 3) 换目标正文。失败不回滚第 1 步（库里那条保留），如实报 problem。
    final problem = await swap(name);
    if (problem != null) {
      return ExpertApplyResult(
          ok: false, profile: entry, warning: warning, problem: problem);
    }
    return ExpertApplyResult(ok: true, profile: entry, warning: warning);
  }

  /// 目录条目落库（幂等）：同 presetKey 或同名的已有条目原样返回（保住用户
  /// 的改名改文），没有才新建——builtin=true、sourceRef 记来源包。
  Future<ExpertProfile> _installShelfItem(ExpertShelfItem item) async {
    final existing = installed.value
        .where((p) =>
            (item.presetKey.isNotEmpty && p.presetKey == item.presetKey) ||
            p.name == item.name)
        .toList();
    if (existing.isNotEmpty) return existing.first;
    final profile = ExpertProfile(
      id: 'x_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      name: item.name,
      body: item.body,
      builtin: true,
      avatar: item.avatar == '🧩' ? '' : item.avatar,
      description: item.description,
      tags: List<String>.of(item.tags),
      category: item.category,
      presetKey: item.presetKey,
      // 来源追踪：从哪个包装进来的（样品路径）
      sourceRef: item.sourceRef,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    installed.value = [...installed.value, profile];
    try {
      await _persistLibrary();
    } catch (_) {
      // 落库是「要么全成要么不留半截」的第 1 步：写盘失败就回滚内存，
      // 让第 1 步整体失败（上层会返回 problem 且不动目标正文）。
      installed.value = [
        for (final p in installed.value)
          if (p.id != profile.id) p,
      ];
      rethrow;
    }
    return profile;
  }

  /// 记热度：usedCount+1 并落盘；失败上抛（调用方降级成 warning）。
  Future<ExpertProfile> _touch(String id) async {
    final prev = installed.value.where((p) => p.id == id).toList();
    if (prev.isEmpty) {
      throw StateError('ExpertsController._touch: 条目不存在（$id）');
    }
    final updated = prev.first.copyWith(usedCount: prev.first.usedCount + 1);
    installed.value = [
      for (final p in installed.value)
        if (p.id == id) updated else p,
    ];
    try {
      await _persistLibrary();
    } catch (_) {
      // 热度是计数器：落盘失败就把内存也退回去，保持「盘上没有 = 没发生」。
      installed.value = [
        for (final p in installed.value)
          if (p.id == id) prev.first else p,
      ];
      rethrow;
    }
    return updated;
  }

  // ------------------------------------------------------------ 我的库管理

  /// 从我的库移除一条（幂等）。目录样品不受影响——它本来就不在库里。
  Future<void> removeFromLibrary(String id) async {
    final next = <ExpertProfile>[
      for (final p in installed.value)
        if (p.id != id) p,
    ];
    if (next.length == installed.value.length) return;
    final prev = installed.value;
    installed.value = next;
    try {
      await _persistLibrary();
    } catch (e) {
      installed.value = prev;
      rethrow;
    }
  }

  // ---------------------------------------------------------- 资产包管理

  /// 安装一个资产包（页面「安装入口」的后端；文件选择器接线留 #13，当前
  /// 以粘贴 JSON 的方式进来）。同 name+hash 视为同一个包：替换而不是追加
  /// （重复安装=刷新）。解析失败（pack.ok=false）抛 FormatException，problem
  /// 在异常消息里——页面据此提示，不产生半装的包。
  Future<ExpertPack> installPackJson(String json) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final pack = ExpertPack.parse(json, installedAt: now);
    if (!pack.ok) {
      throw FormatException(pack.problem.isEmpty ? '资产包解析失败' : pack.problem);
    }
    final prev = _packs.value;
    final dedup = prev.indexWhere((p) =>
        p.meta.name == pack.meta.name &&
        p.meta.hash == pack.meta.hash &&
        p.meta.installedAt != 0);
    _packs.value = [
      if (dedup >= 0) ...[
        for (var i = 0; i < prev.length; i++)
          if (i == dedup) pack else prev[i],
      ] else
        ...prev,
      if (dedup < 0) pack,
    ];
    try {
      await _persistPacks();
    } catch (e) {
      _packs.value = prev;
      throw StateError('资产包落盘失败（$e），本次没有安装');
    }
    return pack;
  }

  // ------------------------------------------------------------------ 存取

  /// 启动时调用：读我的库与已安装资产包。坏存档/平台通道不可用按空清单
  /// 继续（与 ContactStore.load / SettingsStore.load 同一口径）。
  Future<void> load() async {
    final seed = ExpertPack.parse(seedPackJson);
    final packs = <ExpertPack>[seed];
    try {
      final prefs = await SharedPreferences.getInstance();

      final libRaw = prefs.getString(_libraryKey);
      if (libRaw != null && libRaw.isNotEmpty) {
        try {
          final decoded = jsonDecode(libRaw);
          if (decoded is Map<String, dynamic> && decoded['experts'] is List) {
            installed.value = <ExpertProfile>[
              for (final e in decoded['experts'] as List)
                if (e is Map<String, dynamic>) ExpertProfile.fromJson(e),
            ];
          }
        } on FormatException {
          // 整包 JSON 损坏：按没存过处理。
        }
      }

      final packsRaw = prefs.getString(_packsKey);
      if (packsRaw != null && packsRaw.isNotEmpty) {
        try {
          final decoded = jsonDecode(packsRaw);
          if (decoded is Map<String, dynamic> && decoded['packs'] is List) {
            for (final raw in decoded['packs'] as List) {
              if (raw is! String || raw.isEmpty) continue;
              final pack = ExpertPack.parse(raw);
              // 种子包不落盘也不认盘上的同名快照：内容随代码走。
              if (pack.ok && pack.meta.name != seed.meta.name) {
                packs.add(pack);
              }
            }
          }
        } on FormatException {
          // 资产包存档损坏：丢弃，种子包仍在。
        }
      }
    } catch (_) {
      // shared_preferences 不可用（平台通道缺失等）：保持内存空清单。
    }
    _packs.value = packs;
  }

  Future<void> _persistLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _libraryKey,
      jsonEncode(<String, dynamic>{
        'version': 1,
        'experts': <Map<String, dynamic>>[
          for (final p in installed.value) p.toJson(),
        ],
      }),
    );
  }

  Future<void> _persistPacks() async {
    // 存原始 JSON 而不是元信息：重装/去重要靠原文重解析，元信息不够还原。
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _packsKey,
      jsonEncode(<String, dynamic>{
        'version': 1,
        'packs': <String>[
          for (final p in _packs.value)
            if (p.meta.installedAt != 0)
              jsonEncode(<String, dynamic>{
                'name': p.meta.name,
                'source': p.meta.source,
                'sourceCommit': p.meta.commit,
                'contentHash': p.meta.hash,
                'experts': <Map<String, dynamic>>[
                  for (final e in p.presets)
                    <String, dynamic>{
                      'key': e.key,
                      'name': e.name,
                      'body': e.body,
                      'category': e.category,
                      'tags': e.tags,
                      'description': e.description,
                      'emoji': e.avatar,
                    },
                ],
              }),
        ],
      }),
    );
  }

  void dispose() {
    installed.dispose();
    _packs.dispose();
  }
}

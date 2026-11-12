/// 专家目录的**货架层**：数据模型 + 解析 + 检索/排序。
///
/// 对应旧仓库 `core/kb/ExpertCatalog.kt`（浏览/搜索/排序）与
/// `ExpertPack.kt` 的解析职责。与 legacy 的三点不同（超越而非复刻）：
///
/// 1. **按需资产包**：legacy 把 331 位专家全量编进 APK（`ExpertPack.ASSET`），
///    更新一次目录就要发一版；这里内置包只带 3-5 位示例
///    （`assets/experts/catalog.json`），完整目录由 expert_pack.dart 的
///    远端资产包按需安装，URL 由 app 层配置。
/// 2. **来源追踪**：每个条目带 [ExpertSource]（包 id + 版本 + 来源）——货架上的
///    东西说得清出处（用户校准：知识库要有来源追踪）。
/// 3. **两层容忍度是刻意的，不是疏忽**：
///    - 本文件的 [ExpertCatalog.parseShelf] / [ExpertCatalog.loadBuiltin]
///      （浏览与预览路径）：尽力而为，一条坏只跳一条，绝不抛——货架坏一角
///      不该把页面带崩（legacy ExpertPack.parse 的态度，原样保留）；
///    - `PackCodec.parse`（expert_pack.dart，安装路径）：清单级字段严格校验，
///      format / pack.id / pack.version 缺一即拒——装进本地的包必须说得清自己
///      是谁。
///
/// 正文兼容说明：`promptText` 写的是 PersonaCard 卡片键的原文（称呼/关系/语气/
/// 主题/情境/避谈/示例），`PersonaCard.parse` 直接可解析——与 legacy 的
/// 「只有 body 进提示词」同一条铁律，tags/description/emoji 全是浏览层。
library;

import 'dart:convert';
import 'dart:io' show Directory, File;

/// 内置目录在包内的路径。Flutter 应用通过 rootBundle 注入时的资源键是
/// `packages/chartools_core/$builtinCatalogAssetPath`。
const String builtinCatalogAssetPath = 'assets/experts/catalog.json';

/// 目录条目全局 id 的前缀：`pack:<packId>/<条目id>`。稳定、可预测，且与 app 侧
/// 自生成 id 形状不同（沿用旧仓库 `ExpertShelf.PACK_ID_PREFIX` 的做法——
/// 「这条是不是货架样品」判断起来没有歧义）。
const String expertPackIdPrefix = 'pack:';

/// 由包 id + 包内 id 拼出全局稳定 id。
String globalExpertId(String packId, String key) =>
    '$expertPackIdPrefix$packId/$key';

/// 专家条目的来源。
enum ExpertOrigin {
  /// 随包内置的骨架包（assets/experts/catalog.json）。
  builtin,

  /// 远端资产包安装而来。
  remote;

  /// 持久化 wire 名：改它等于改 JSON 契约。
  String get wire => name;

  /// 容错反查：不认识的一律当 remote——手工文件里的来历不明的东西，
  /// 按外来物处理最稳。
  static ExpertOrigin tryParse(String wire) =>
      wire == 'builtin' ? ExpertOrigin.builtin : ExpertOrigin.remote;
}

/// JSON 值 → 去首尾空白的字符串（null / 数字都兜住；清单是外部输入，不抛）。
String _str(Object? v) => v == null ? '' : v.toString().trim();

/// JSON 值 → 非空字符串列表（去重保序；不是数组就当空——导入半截文件不抛）。
List<String> _strList(Object? v) {
  if (v is! List) return const [];
  final out = <String>[];
  for (final e in v) {
    final s = _str(e);
    if (s.isNotEmpty && !out.contains(s)) out.add(s);
  }
  return out;
}

/// 资产包清单的 `pack` 对象：包是谁、哪个版本、从哪来。
/// 解析全容错（缺字段给默认值），**严格校验在 PackCodec**（expert_pack.dart）
/// ——浏览路径宽容、安装路径严格是本设计的刻意分工。
class PackMeta {
  const PackMeta({
    required this.id,
    this.version = '',
    this.name = '',
    this.origin = ExpertOrigin.remote,
    this.source = '',
    this.sourceCommit = '',
    this.contentHash = '',
    this.url = '',
  });

  final String id;
  final String version;
  final String name;

  /// 出处说明（上游仓库、生成脚本等），只用于展示，不参与任何逻辑。
  final String source;
  final ExpertOrigin origin;

  /// 上游 commit。
  final String sourceCommit;

  /// 上游内容指纹，**只透传不校验**：core 零第三方依赖没有 SHA-256，
  /// 校验交给 app 层。不假装验证过——诚实声明比假的「已校验」值钱。
  final String contentHash;

  /// 该包的来源 URL（远端包才有；内置包为空）。
  final String url;

  factory PackMeta.fromJson(Map<String, dynamic> j) => PackMeta(
        id: _str(j['id']),
        version: _str(j['version']),
        name: _str(j['name']),
        origin: ExpertOrigin.tryParse(_str(j['origin'])),
        source: _str(j['source']),
        sourceCommit: _str(j['sourceCommit']),
        contentHash: _str(j['contentHash']),
        url: _str(j['url']),
      );
}

/// 一条专家的出处（来源追踪的落点）。随 Expert 一起可序列化，让
/// 「这条建议是谁给的、哪个版本给的」在日志与 UI 里都说得清。
class ExpertSource {
  const ExpertSource({
    required this.packId,
    required this.packVersion,
    this.origin = ExpertOrigin.remote,
    this.url = '',
  });

  final String packId;
  final String packVersion;
  final ExpertOrigin origin;
  final String url;

  /// 展示用一句话：`内置 builtin@1.0.0` / `资产包 sales-pro@2.1.0`。
  String get label =>
      '${origin == ExpertOrigin.builtin ? '内置' : '资产包'} $packId@$packVersion';

  factory ExpertSource.fromMeta(PackMeta meta) => ExpertSource(
        packId: meta.id,
        packVersion: meta.version,
        origin: meta.origin,
        url: meta.url,
      );

  Map<String, dynamic> toJson() => {
        'packId': packId,
        'packVersion': packVersion,
        'origin': origin.wire,
        'url': url,
      };

  factory ExpertSource.fromJson(Map<String, dynamic> j) => ExpertSource(
        packId: _str(j['packId']),
        packVersion: _str(j['packVersion']),
        origin: ExpertOrigin.tryParse(_str(j['origin'])),
        url: _str(j['url']),
      );
}

/// 货架上的一位专家。与旧仓库 PersonaPreset 的字段一一对应：
/// `key→id`（包内）、`body→promptText`、`category→domain`；浏览层的
/// description / emoji 原样保留。
///
/// **只有 [promptText] 进提示词**（expert_apply.dart 只写它），其余字段全部是
/// 浏览层——这条铁律沿用 legacy（PersonaProfile.kt 的「两组字段」）：如果简介
/// 混进提示词，用户改一句简介就会改变回复风格，而那没有任何报错可查。
class Expert {
  const Expert({
    required this.id,
    required this.key,
    required this.name,
    required this.domain,
    required this.promptText,
    this.tags = const [],
    this.description = '',
    this.emoji = '🧩',
    required this.source,
  });

  /// 全局稳定 id：`pack:<packId>/<key>`。
  final String id;

  /// 包内 id（清单 experts[] 里的 `id` 字段原样），包内唯一、包外不保证。
  final String key;
  final String name;

  /// 领域（legacy 的 category）：浏览层抽屉，空 = 未分类。**不进提示词。**
  final String domain;

  /// 唯一进提示词的正文（PersonaCard 卡片键原文，逐字保存、不 trim）。
  final String promptText;

  /// 浏览层：检索标签。**不进提示词。**
  final List<String> tags;

  /// 浏览层：一句话简介。**不进提示词。**
  final String description;

  /// 浏览层：一个 emoji（默认占位 🧩）。**不进提示词。**
  final String emoji;
  final ExpertSource source;

  /// 内置示例包的条目（排序时 +2 的那批）。
  bool get isBuiltin => source.origin == ExpertOrigin.builtin;

  @override
  bool operator ==(Object other) => other is Expert && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Expert($id, $name)';
}

/// 单条专家正文（promptText）的 utf8 字节上限——不可信远端清单的尺寸护栏
/// （legacy 对文档导入有 MAX_CHUNKS=2000，包体系同类护栏的条目级对应物）。
/// 超限按坏条目跳过、由调用方计数进 problem；正常专家正文是 PersonaCard
/// 卡片键原文，量级在 KB 内，64KB 已是百倍余量。
const int expertPromptTextMaxBytes = 64 * 1024;

/// 清单 experts[] 里的一个条目 → [Expert]。任何不合法返回 null
/// （调用方计数并跳过——一条 emoji 写坏了，不该让另外 330 位专家消失）。
///
/// [source] 由调用方（包解析器）构造：条目自己不知道包是谁。
///
/// 字段别名（统一包格式的一部分，见 docs/expert-pack-format.md）：
/// `id`（本格式主键）↔ `key`（app/legacy 形状）、`promptText`（主键）↔
/// `body`（app/legacy 形状）——两套解析器（core 严格路径 / app 宽容路径）
/// 对同一份远端包必须认得出同一批专家，不能一边全量跳过。
Expert? decodeExpertEntry(Object? raw, ExpertSource source) {
  if (raw is! Map) return null;
  var key = _str(raw['id']);
  if (key.isEmpty) key = _str(raw['key']);
  // id 带「/」会破坏全局 id 的 `pack:<packId>/<key>` 形状——直接判坏条目。
  if (key.isEmpty || key.contains('/')) return null;
  // promptText 逐字保存（不 trim）：「套用 → 保存 → 回头再套用」不该悄悄变形。
  final ptRaw = raw['promptText'] ?? raw['body'];
  final promptText = ptRaw == null ? '' : ptRaw.toString();
  if (promptText.trim().isEmpty) return null;
  if (utf8.encode(promptText).length > expertPromptTextMaxBytes) {
    return null; // 尺寸护栏：超大条目按坏条目跳过（不炸内存）
  }
  final name = _str(raw['name']);
  return Expert(
    id: globalExpertId(source.packId, key),
    key: key,
    // 名字缺省回退到 id（legacy：optString("name").ifBlank { optString("key") }）。
    name: name.isEmpty ? key : name,
    domain: _str(raw['domain']),
    promptText: promptText,
    tags: _strList(raw['tags']),
    description: _str(raw['description']),
    emoji: _str(raw['emoji']).isEmpty ? '🧩' : _str(raw['emoji']),
    source: source,
  );
}

/// 逐条容错地解码整个 experts 数组，包内 id 重复的条目按坏条目跳过
/// （后者不覆盖前者）。返回（可用条目，跳过条数）。
(List<Expert>, int) decodeExpertEntries(List rawList, ExpertSource source) {
  final out = <Expert>[];
  final seen = <String>{};
  var skipped = 0;
  for (final raw in rawList) {
    final e = decodeExpertEntry(raw, source);
    if (e == null || !seen.add(e.key)) {
      skipped++;
      continue;
    }
    out.add(e);
  }
  return (out, skipped);
}

/// 货架层解析结果：能用的专家 + 坏消息。永不抛。
class ShelfParse {
  const ShelfParse({
    this.experts = const [],
    this.meta,
    this.problem = '',
    this.skipped = 0,
    this.rawJson = '',
  });

  final List<Expert> experts;
  final PackMeta? meta;

  /// 空 = 完全正常；非空 = 有跳过条目或结构异常（专家可能仍然可用）。
  final String problem;
  final int skipped;
  final String rawJson;

  /// 货架上有没有东西（有 problem 不代表空货架）。
  bool get ok => experts.isNotEmpty;
}

/// 货架的排序方式。legacy `ExpertSort` 的子集——「最新」没有移植：货架条目
/// 没有编辑时间（那是用户自建库的概念，专家库目录是只读货架）。
enum ExpertSort {
  /// 精选优先，但**用得多能顶上来**：`usage * 3 + (内置 ? 2 : 0)`。
  comprehensive('综合'),

  /// 只看套用次数。
  hottest('最热');

  const ExpertSort(this.label);

  /// 界面 tab 的字面量，改它等于改 UI 契约。
  final String label;

  /// 按标签反查；认不出退回综合（legacy 同款兜底）。
  static ExpertSort ofLabel(String label) {
    for (final v in values) {
      if (v.label == label.trim()) return v;
    }
    return comprehensive;
  }
}

/// 专家目录的纯函数浏览层：领域、搜索、排序。
///
/// 为什么是 `abstract final class` 而不是实例：这三件事全是
/// `List<Expert> → List<Expert>` 的纯函数（沿用 legacy ExpertCatalog 的
/// 论证——留在界面层就只能靠「跑起来看一眼」验证，独立出来才能用单测钉死）。
abstract final class ExpertCatalog {
  /// 没有领域的条目归到这里（只在真有这种条目时出现）。
  static const String uncategorized = '未分类';

  /// 「全部」不是领域，是「不筛」——单独给常量避免各处写字面量写错。
  static const String all = '全部';

  /// 固定领域顺序的种子（与 legacy 五类一致）：目录里的自定义领域排后面。
  /// 顺序错了不会报错，只会让 chips 顺序莫名其妙——所以写死在这里被单测钉住。
  static const List<String> knownDomains = ['情感', '销售', '职场', '客服', '日常'];

  /// 当前货架上真实存在的领域：[knownDomains] 的顺序在前，其余按名字排后，
  /// 没有领域的条目归入 [uncategorized] 殿后。刻意**不返回空领域**：
  /// 点开一个 0 条的抽屉只会让用户以为页面坏了。
  static List<String> domains(List<Expert> experts) {
    final present = experts.map((e) => e.domain.trim()).toSet();
    final out = <String>[];
    for (final d in knownDomains) {
      if (present.contains(d)) out.add(d);
    }
    final custom = present
        .where((d) => d.isNotEmpty && !knownDomains.contains(d))
        .toList()
      ..sort();
    out.addAll(custom);
    if (present.contains('')) out.add(uncategorized);
    return out;
  }

  /// 当前货架上出现过的标签：出现次数多在前，同次数按名字排（确定性）。
  /// 空白标签不算。
  static List<String> tags(List<Expert> experts) {
    final count = <String, int>{};
    for (final e in experts) {
      for (final t in e.tags) {
        final s = t.trim();
        if (s.isEmpty) continue;
        count[s] = (count[s] ?? 0) + 1;
      }
    }
    final list = count.keys.toList()
      ..sort((a, b) {
        final c = count[b]!.compareTo(count[a]!);
        return c != 0 ? c : a.compareTo(b);
      });
    return list;
  }

  /// 关键词命中：名字、简介、标签、**正文**。正文也算——用户往往记得的是
  /// 「那张写着『跪好，等我』的卡」（legacy 的教训，原样保留）。
  /// 大小写不敏感。
  static bool matches(Expert e, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (e.name.toLowerCase().contains(q)) return true;
    if (e.description.toLowerCase().contains(q)) return true;
    for (final t in e.tags) {
      if (t.toLowerCase().contains(q)) return true;
    }
    return e.promptText.toLowerCase().contains(q);
  }

  /// 领域 + 标签 + 关键词筛选。
  ///
  /// [domain] 传 [all] / null / 空串 = 不筛；传 [uncategorized] 筛没有领域的
  /// 条目。[tag] 精确匹配（去空白后相等）。[query] 走 [matches]。
  static List<Expert> filter(
    List<Expert> experts, {
    String? domain,
    String? tag,
    String query = '',
  }) {
    final d = domain?.trim() ?? '';
    final t = tag?.trim() ?? '';
    return experts.where((e) {
      final domainOk = d.isEmpty ||
          d == all ||
          (d == uncategorized ? e.domain.trim().isEmpty : e.domain.trim() == d);
      final tagOk = t.isEmpty || e.tags.any((x) => x.trim() == t);
      return domainOk && tagOk && matches(e, query);
    }).toList();
  }

  /// 综合分：一次套用顶 3 分，内置示例 +2（legacy `ExpertCatalog.score` 的
  /// 规则，单测钉死：「用了一次的自建专家」会和「从没被用过的内置」打平、
  /// 再用一次就反超）。[usage] 由 app 层注入（core 不存使用计数）——这就是
  /// 命中/使用评测的钩子位。负数计数按 0 处理（外部数据不可信）。
  static int score(Expert e, Map<String, int> usage) {
    final used = usage[e.id] ?? 0;
    final n = used < 0 ? 0 : used;
    return n * 3 + (e.isBuiltin ? 2 : 0);
  }

  /// 排序。副键统一名字升序，保证结果确定可比（legacy 的做法）。
  static List<Expert> sort(
    List<Expert> experts, {
    ExpertSort mode = ExpertSort.comprehensive,
    Map<String, int> usage = const {},
  }) {
    int usageOf(Expert e) {
      final v = usage[e.id] ?? 0;
      return v < 0 ? 0 : v;
    }

    int cmp(Expert a, Expert b) {
      final int primary;
      switch (mode) {
        case ExpertSort.comprehensive:
          primary = score(b, usage).compareTo(score(a, usage));
        case ExpertSort.hottest:
          primary = usageOf(b).compareTo(usageOf(a));
      }
      if (primary != 0) return primary;
      return a.name.compareTo(b.name);
    }

    return List.of(experts)..sort(cmp);
  }

  /// 界面用的组合动作：先筛后排。分开调用也行，但界面上永远是这个顺序。
  static List<Expert> browse(
    List<Expert> experts, {
    String? domain,
    String? tag,
    String query = '',
    ExpertSort mode = ExpertSort.comprehensive,
    Map<String, int> usage = const {},
  }) =>
      sort(
        filter(experts, domain: domain, tag: tag, query: query),
        mode: mode,
        usage: usage,
      );

  /// 按全局 id 反查；没有返回 null。
  static Expert? findById(List<Expert> experts, String id) {
    for (final e in experts) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 宽松解析一段目录 JSON（内置目录与**远端包预览**共用）。
  ///
  /// 预览在装之前：用户要先看货，所以坏一条跳一条、绝不抛；结构级损坏
  /// （顶层不是对象 / 没有 experts 数组）返回空货架 + problem。装的时候
  /// 会再用 PackCodec 严格校验一遍——浏览宽容、安装严格，两层是刻意的。
  static ShelfParse parseShelf(String raw) {
    if (raw.trim().isEmpty) return const ShelfParse(problem: '目录为空');
    Object? root;
    try {
      root = jsonDecode(raw);
    } catch (e) {
      return ShelfParse(problem: '目录不是合法 JSON：$e');
    }
    if (root is! Map) {
      return const ShelfParse(problem: '目录顶层必须是 JSON 对象');
    }
    final packRaw = root['pack'];
    final meta = packRaw is Map
        ? PackMeta.fromJson(Map<String, dynamic>.from(packRaw))
        : null;
    final list = root['experts'];
    if (list is! List) {
      return ShelfParse(meta: meta, problem: '目录缺少 experts 数组');
    }
    final source = meta == null
        // 没有 pack 元数据时给空来源——货架还能看，出处显示成缺省。
        ? const ExpertSource(packId: '', packVersion: '')
        : ExpertSource.fromMeta(meta);
    final (experts, skipped) = decodeExpertEntries(list, source);
    var problem = experts.isEmpty
        ? '目录里没有可用专家（跳过 $skipped 条）'
        : (skipped > 0 ? '目录有 $skipped 条解析失败，已跳过' : '');
    if (meta == null && experts.isNotEmpty) {
      problem = problem.isEmpty
          ? '目录缺少 pack 对象（来源信息缺失）'
          : '$problem；目录缺少 pack 对象（来源信息缺失）';
    }
    return ShelfParse(
      experts: experts,
      meta: meta,
      problem: problem,
      skipped: skipped,
      rawJson: raw,
    );
  }

  /// 加载内置目录。
  ///
  /// - 传 [readAsset] 时直接用它（Flutter 应用包一层
  ///   `rootBundle.loadString('packages/chartools_core/$builtinCatalogAssetPath')`）；
  /// - 不传时走 dart:io 在磁盘上找（VM / 测试 / 桌面工具路径）：从当前目录
  ///   沿父目录向上最多 6 层，依次尝试 [assetPath] 与 `packages/core/` +
  ///   [assetPath]，覆盖「从 packages/core 跑测试」与「从工作区根跑」两种 cwd。
  /// 找不到返回空货架 + problem，**绝不抛**——货架读不到不该带崩调用方。
  static ShelfParse loadBuiltin({
    String Function(String path)? readAsset,
    String assetPath = builtinCatalogAssetPath,
  }) {
    final raw = readBuiltinCatalogJson(readAsset: readAsset, assetPath: assetPath);
    if (raw == null) {
      return ShelfParse(
        problem: '读不到内置目录 JSON（$assetPath）。'
            'Flutter 应用请用 rootBundle.loadString 注入 readAsset。',
      );
    }
    return parseShelf(raw);
  }
}

/// 读取内置目录 JSON 的磁盘/注入实现。返回 null = 读不到（不抛）。
String? readBuiltinCatalogJson({
  String Function(String path)? readAsset,
  String assetPath = builtinCatalogAssetPath,
}) {
  if (readAsset != null) {
    try {
      return readAsset(assetPath);
    } catch (_) {
      return null;
    }
  }
  try {
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      for (final rel in <String>[assetPath, 'packages/core/$assetPath']) {
        final f = File('${dir.path}/$rel');
        if (f.existsSync()) return f.readAsStringSync();
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  } catch (_) {
    // 磁盘探测是尽力而为：读不到交给调用方的 problem，不往上抛。
  }
  return null;
}

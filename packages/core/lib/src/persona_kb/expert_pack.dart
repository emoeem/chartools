/// 专家**按需资产包**：清单解析/校验 + 本地安装集合管理 + 远端清单。
///
/// 超越 legacy 的地方：legacy 把 331 位专家全量编进 APK
/// （`ExpertPack.ASSET = kb/experts.json`），更新一次目录就要发一版。
/// 这里把「目录」拆成**包**，包是清单（manifest）：
///
/// ```json
/// {
///   "format": "jev-expert-pack/1",
///   "pack":   { "id": "sales-pro", "version": "1.2.0", "origin": "remote" },
///   "experts": [ { "id": "...", "promptText": "..." } ]
/// }
/// ```
///
/// - **内置包（builtin）**只带 3-5 位示例，永远在场、不可卸载——货架不能空；
///   `builtin` 是保留 id，远端包不许占用。
/// - **完整目录**（331 位等）是远端包：清单 URL 与包体下载都由 app 层负责
///   （core 不发请求，URL 由 app 层配置——用户校准）；本文件给
///   [RemoteManifestCodec] 解析清单、对照已装集合算出该装/该升哪些。
/// - **存储不落盘**（与 kb_models.dart 同一约定）：[PackStore] 由 app 层注入，
///   core 只认「存过 = 已安装」——没有第二份安装索引就不会漂移（legacy
///   PersonaStore 类注释里的教训：两边各存一份必然漂移，漂移的表现是
///   「界面说生效的是 A，实际发出去的是 B」）。
///
/// 与浏览层（expert_catalog.dart）的容忍度分工：本文件的
/// [PackCodec.parse] 是**安装路径**，清单级字段严格校验——format / pack.id /
/// pack.version / experts 数组缺一即拒；单条专家仍然逐条容错（一条坏的
/// 不该毁掉整个包）。
///
/// **本文件（连同 expert_catalog.dart / expert_apply.dart）是专家库的
/// 预留权威 API**（独立复核裁定，见 docs/expert-pack-format.md）：包格式
/// `jev-expert-pack/1` 是唯一格式，entry 字段 `id`/`promptText` 是主拼写
/// （`key`/`body` 是 app/legacy 别名，解码互认）。app 层当前并行着一套
/// legacy 形状的自有实现（experts_controller.dart），#13 接线时必须收敛到
/// 本套——在那之前 app 解析器也认别名（互认，同一份远端包两边都能出货架），
/// 但格式演进以这里为准。
library;

import 'dart:convert';

import 'expert_catalog.dart';

/// 一个资产包的解析产物：pack = {id, version, experts[]}（任务规格的字段形状）。
class ExpertPackData {
  const ExpertPackData({required this.meta, required this.experts});

  final PackMeta meta;
  final List<Expert> experts;

  int get expertCount => experts.length;
}

/// 清单解析结果。`pack == null` = 致命失败（清单级校验没过，一个包都给不出）；
/// `pack != null` 且 problem 非空 = 可用但有跳过条目（警告，照实说）。
class PackParseResult {
  const PackParseResult({this.pack, this.problem = '', this.skipped = 0});

  final ExpertPackData? pack;

  /// 致命失败时是原因；可用时是「跳过条目」的警告。
  final String problem;
  final int skipped;

  bool get ok => pack != null;
}

/// 清单校验与解析（安装路径，严格）。
abstract final class PackCodec {
  /// 清单格式版本。写进每个包 JSON 的 `format` 字段；升级格式时旧解析器
  /// **必须拒绝**而不是猜着解析——猜错的解析会把不可信文件当货架卖。
  /// 统一包格式与字段别名表见 docs/expert-pack-format.md。
  static const String format = 'jev-expert-pack/1';

  /// 单包 experts[] 条数上限——不可信远端清单的尺寸护栏（对应 legacy 文档
  /// 导入的 MAX_CHUNKS=2000，DocImport.kt:53）。超限条目跳过并计数进
  /// problem，与逐条容错的风格一致；正常目录量级是几百条，2000 已是余量。
  static const int maxExpertsPerPack = 2000;

  /// 远端清单 packs[] 条数上限（同一护栏的清单级对应物）。
  static const int maxPacksPerManifest = 2000;

  /// 严格解析一份包清单。永不抛（外部输入），但清单级字段缺一即拒。
  static PackParseResult parse(String json) {
    if (json.trim().isEmpty) return const PackParseResult(problem: '清单是空的');
    Object? root;
    try {
      root = jsonDecode(json);
    } catch (e) {
      return PackParseResult(problem: '清单不是合法 JSON：$e');
    }
    if (root is! Map) return const PackParseResult(problem: '清单顶层必须是 JSON 对象');

    // 第一道：format。宁可拒绝，也不猜格式。
    final f = root['format'];
    if (f == null) return const PackParseResult(problem: '清单缺少 format 字段');
    if (f is! String || f.trim() != format) {
      return PackParseResult(problem: '清单格式不支持：$f（本版本支持 $format）');
    }

    final packRaw = root['pack'];
    if (packRaw is! Map) return const PackParseResult(problem: '清单缺少 pack 对象');
    final meta = PackMeta.fromJson(Map<String, dynamic>.from(packRaw));
    if (meta.id.isEmpty) return const PackParseResult(problem: '清单缺少 pack.id');
    // id 带「/」会破坏专家全局 id 的 `pack:<packId>/<key>` 形状。
    if (meta.id.contains('/')) {
      return const PackParseResult(
          problem: 'pack.id 不能包含「/」（会破坏专家全局 id 的 pack:<id>/<key> 形状）');
    }
    if (meta.version.isEmpty) {
      return const PackParseResult(problem: '清单缺少 pack.version');
    }

    final list = root['experts'];
    if (list is! List) return const PackParseResult(problem: '清单缺少 experts 数组');

    // 尺寸护栏：超出上限的条目直接计入跳过（不进解码，防超大包打爆内存）。
    final overflow = list.length > maxExpertsPerPack
        ? list.length - maxExpertsPerPack
        : 0;
    final effective = overflow > 0 ? list.take(maxExpertsPerPack).toList() : list;

    final (experts, skipped0) =
        decodeExpertEntries(effective, ExpertSource.fromMeta(meta));
    final skipped = skipped0 + overflow;
    if (experts.isEmpty) {
      return PackParseResult(problem: '清单里没有可用专家（跳过 $skipped 条）');
    }
    return PackParseResult(
      pack: ExpertPackData(meta: meta, experts: experts),
      problem: skipped > 0 ? '清单有 $skipped 条解析失败，已跳过' : '',
      skipped: skipped,
    );
  }

  /// 版本比较（点分段数字）：`1.2.10 > 1.2.9`、`1.0 == 1.0.0`、`2.0 > 1.9.9`。
  /// 缺段补 0，非数字段当 0。安装时的升级/降级判定全靠它——写死在这里
  /// 是为了能被单测钉住：比较器错了不会报错，只会让用户装不上新版或被
  /// 静默降级。
  static int compareVersions(String a, String b) {
    final sa = a.split('.');
    final sb = b.split('.');
    final n = sa.length > sb.length ? sa.length : sb.length;
    for (var i = 0; i < n; i++) {
      final x = i < sa.length ? int.tryParse(sa[i].trim()) ?? 0 : 0;
      final y = i < sb.length ? int.tryParse(sb[i].trim()) ?? 0 : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }
}

/// 包持久化的最小接口。core 不落盘（与 kb_models.dart 同一约定）：
/// app 层注入文件 / SharedPreferences 实现；测试用 [MemoryPackStore]。
/// 只认「存过 = 已安装」——安装索引单独存一份必然漂移，所以不存在索引。
///
/// **实现要求（安全键）**：[save]/[remove]/[loadAll] 的 `packId` 必须只作
/// 键名/键值使用，**绝不直接拼进文件路径**——远端包 id 是不可信数据（core
/// 只在清单级拦 `/`，`..\`、控制字符等由实现方拒绝；最稳的做法是按
/// [MemoryPackStore] 同款用 KV 存原文，文件名用固定名或自造 id）。
abstract class PackStore {
  /// 全部已安装包的原始 JSON：pack.id → 内容。返回副本，调用方改动不影响存储。
  Map<String, String> loadAll();

  /// 写入/覆盖一个包（存**收到的原文**，不重排——升级替换时旧内容整体作废）。
  void save(String packId, String rawJson);

  /// 删除一个包。
  void remove(String packId);
}

/// [PackStore] 的内存实现：测试用；app 开发期 / 无持久化场景也能用。
class MemoryPackStore implements PackStore {
  final Map<String, String> _data = {};

  @override
  Map<String, String> loadAll() => Map.of(_data);

  @override
  void save(String packId, String rawJson) => _data[packId] = rawJson;

  @override
  void remove(String packId) => _data.remove(packId);
}

/// 安装动作（让界面能区分「新装/升级/幂等」三种提示）。
enum InstallAction {
  /// 之前没装过，新装。
  installed,

  /// 已有旧版本，本次升级替换。
  upgraded,

  /// 同版本已装，幂等：什么都没写（[InstallResult.pack] 返回的是已装的那份）。
  alreadyCurrent,
}

class InstallResult {
  const InstallResult({
    required this.ok,
    this.pack,
    this.action,
    this.problem = '',
    this.warning = '',
  });

  /// 包已就位（新装/升级/幂等都算成功）。
  final bool ok;
  final ExpertPackData? pack;
  final InstallAction? action;

  /// 失败/拒绝原因（ok=false 时给界面直接显示）。
  final String problem;

  /// 非致命警告（跳过条目、幂等说明）。
  final String warning;
}

class UninstallResult {
  const UninstallResult({required this.ok, this.problem = ''});
  final bool ok;
  final String problem;
}

/// 一次「已安装集合」读出的快照：能用的包 + 每个坏包一条坏消息。
/// 坏包**被忽略而不是被删除**——那可能是磁盘读坏了一半，删掉才是二次破坏；
/// 用户可以随时对它调 [ExpertPackManager.uninstall] 显式清理（卸载不校验内容）。
class InstalledSnapshot {
  const InstalledSnapshot({required this.packs, required this.problems});

  /// 可用包，**内置包固定第一**，其余按 pack.id 字典序（确定性）。
  final List<ExpertPackData> packs;
  final List<String> problems;

  bool get healthy => problems.isEmpty;
}

/// 本地已安装资产包集合的管理：安装 / 卸载 / 枚举 / 按需合并货架。
///
/// 单写者约定与 legacy PersonaStore 一致：所有变更走 [PackStore] 即时落盘，
/// 每次读都重新解析（内置包 5 条 + 远端包几百条，重解析的开销可忽略；
/// 换来的好处是 store 被外部改坏时这里不会拿陈旧缓存装没事）。
class ExpertPackManager {
  /// [builtinJson]：内置包清单原文。app 层注入（rootBundle 读出来）；
  /// 不注入时走磁盘探测（VM / 测试可用，Flutter 运行时读不到——快照里
  /// 会如实报告，不会静默装没事）。
  ExpertPackManager(this.store, {this.builtinJson});

  final PackStore store;
  final String? builtinJson;

  /// 内置包保留 id。远端包占用它会被安装拒绝；它不可卸载——货架不能空。
  static const String builtinPackId = 'builtin';

  /// 当前已安装集合（含内置包）。坏包逐条进 [InstalledSnapshot.problems]。
  InstalledSnapshot installed() {
    final packs = <ExpertPackData>[];
    final problems = <String>[];

    final raw = builtinJson ?? readBuiltinCatalogJson();
    if (raw == null) {
      // 货架底座读不到是坏消息，不是空集合：照实说，别让用户以为只有他装的包。
      problems.add('读不到内置目录 JSON（Flutter 运行时请注入 builtinJson）');
    } else {
      final r = PackCodec.parse(raw);
      if (r.ok) {
        packs.add(r.pack!);
      } else {
        problems.add('内置包清单校验失败：${r.problem}');
      }
    }

    final stored = store.loadAll();
    final ids = stored.keys.toList()..sort();
    for (final id in ids) {
      final r = PackCodec.parse(stored[id]!);
      if (r.ok) {
        packs.add(r.pack!);
      } else {
        problems.add('已安装包「$id」清单校验失败，已忽略：${r.problem}');
      }
    }
    return InstalledSnapshot(packs: packs, problems: problems);
  }

  /// 全部已装包的专家合并成一张货架（内置在前、按包 id 排序，结果稳定）。
  List<Expert> allExperts() =>
      installed().packs.expand((p) => p.experts).toList();

  /// 按全局 id 反查；没有返回 null。
  Expert? findExpert(String globalId) {
    for (final e in allExperts()) {
      if (e.id == globalId) return e;
    }
    return null;
  }

  /// 某个包的专家；包不存在（或校验失败被忽略）返回空列表。
  List<Expert> expertsOf(String packId) => installed()
      .packs
      .where((p) => p.meta.id == packId)
      .expand((p) => p.experts)
      .toList();

  /// 安装一份包清单（原文落盘，不重排）。
  ///
  /// 严格校验（[PackCodec.parse]）→ 保留 id 检查 → 版本仲裁：
  /// - 未装过 → 新装；
  /// - 同版本 → 幂等成功，不重复写（alreadyCurrent）；
  /// - 更低版本 → 拒绝降级（界面不会想装旧版，装了多半是缓存坏了；确要
  ///   降级传 [force]）；
  /// - 更高版本 → 升级替换；
  /// - 存量清单解析失败（坏包）→ 本次写入视为修复，直接覆盖。
  InstallResult install(String rawJson, {bool force = false}) {
    final r = PackCodec.parse(rawJson);
    if (!r.ok) return InstallResult(ok: false, problem: r.problem);
    final p = r.pack!;
    if (p.meta.id == builtinPackId) {
      return InstallResult(
          ok: false, problem: '「$builtinPackId」是内置包保留 id，远端包请换一个 id');
    }

    ExpertPackData? existing;
    final existingRaw = store.loadAll()[p.meta.id];
    if (existingRaw != null) {
      final er = PackCodec.parse(existingRaw);
      existing = er.ok ? er.pack : null;
    }

    if (existing != null) {
      final cmp = PackCodec.compareVersions(p.meta.version, existing.meta.version);
      if (cmp == 0 && !force) {
        return InstallResult(
          ok: true,
          pack: existing,
          action: InstallAction.alreadyCurrent,
          warning: r.problem.isEmpty ? '同版本已安装，未重复写入' : r.problem,
        );
      }
      if (cmp < 0 && !force) {
        return InstallResult(
          ok: false,
          problem: '已安装更高版本 ${existing.meta.version}，'
              '拒绝降级到 ${p.meta.version}（确要降级传 force=true）',
        );
      }
    }

    store.save(p.meta.id, rawJson);
    return InstallResult(
      ok: true,
      pack: p,
      action: existing == null ? InstallAction.installed : InstallAction.upgraded,
      warning: r.problem,
    );
  }

  /// 卸载一个包。内置包不可卸载（货架底座）；没装过报「没有安装过」；
  /// 存储里的坏包也允许卸——这是坏包的显式清理路径（不校验内容，直接删）。
  UninstallResult uninstall(String packId) {
    if (packId == builtinPackId) {
      return const UninstallResult(ok: false, problem: '内置包不可卸载（它是货架的底座）');
    }
    if (!store.loadAll().containsKey(packId)) {
      return UninstallResult(ok: false, problem: '没有安装过这个包：$packId');
    }
    store.remove(packId);
    return const UninstallResult(ok: true);
  }
}

/// 远端清单里的一条：一个**可下载的资产包**的描述。
class RemotePackEntry {
  const RemotePackEntry({
    required this.id,
    required this.version,
    required this.url,
    this.name = '',
    this.sizeBytes = 0,
    this.sha256 = '',
  });

  final String id;
  final String version;

  /// 包 JSON 的下载地址。清单 URL 与包体下载都由 app 层做（core 不发请求）。
  final String url;
  final String name;

  /// 预估体积（字节，展示用）。
  final int sizeBytes;

  /// 包体指纹，**只透传**：core 零第三方依赖没有 SHA-256，校验由 app 层负责。
  final String sha256;

  /// 容错解码：不是对象 / 缺 id / 缺 version / 缺 url 返回 null。
  static RemotePackEntry? decode(Object? raw) {
    if (raw is! Map) return null;
    final id = _s(raw['id']);
    final version = _s(raw['version']);
    final url = _s(raw['url']);
    if (id.isEmpty || version.isEmpty || url.isEmpty) return null;
    return RemotePackEntry(
      id: id,
      version: version,
      url: url,
      name: _s(raw['name']),
      sizeBytes: raw['sizeBytes'] is int ? raw['sizeBytes'] as int : 0,
      sha256: _s(raw['sha256']),
    );
  }

  static String _s(Object? v) => v == null ? '' : v.toString().trim();
}

/// 远端清单解析结果。
class RemoteManifestParse {
  const RemoteManifestParse({this.entries = const [], this.problem = '', this.skipped = 0});

  final List<RemotePackEntry> entries;

  /// 致戴失败（清单级）时的原因；entries 可用时是「跳过条目」警告。
  final String problem;
  final int skipped;

  bool get ok => entries.isNotEmpty;
}

/// 远端清单与本地差异的对照结果——设置页「可安装 / 可升级」两栏的数据源。
class RemoteManifestDiff {
  const RemoteManifestDiff({
    required this.installable,
    required this.upgrades,
    required this.upToDate,
    required this.problems,
  });

  /// 本地没装过的包。
  final List<RemotePackEntry> installable;

  /// 已装且远端版本更高。
  final List<RemotePackEntry> upgrades;

  /// 已装且不落后。
  final List<RemotePackEntry> upToDate;

  /// 非法条目的说明（保留 id 等）。
  final List<String> problems;
}

/// 远端资产包清单的解析与对照。
///
/// 清单形状：`{"format": "...", "packs": [{"id","version","url",...}]}`。
/// 它是「货架目录的目录」：app 层持有清单 URL（用户校准：URL 由 app 层配置），
/// 拉下来交给 [parse]，再对照 [ExpertPackManager.installed] 决定装什么、升什么。
abstract final class RemoteManifestCodec {
  static const String format = 'jev-expert-remote-manifest/1';

  /// 严格解析远端清单（与 PackCodec 同一态度：清单级字段缺一即拒，
  /// 条目逐条容错）。
  static RemoteManifestParse parse(String json) {
    if (json.trim().isEmpty) return const RemoteManifestParse(problem: '清单是空的');
    Object? root;
    try {
      root = jsonDecode(json);
    } catch (e) {
      return RemoteManifestParse(problem: '清单不是合法 JSON：$e');
    }
    if (root is! Map) return const RemoteManifestParse(problem: '清单顶层必须是 JSON 对象');
    final f = root['format'];
    if (f == null) return const RemoteManifestParse(problem: '清单缺少 format 字段');
    if (f is! String || f.trim() != format) {
      return RemoteManifestParse(problem: '清单格式不支持：$f（本版本支持 $format）');
    }
    final packs = root['packs'];
    if (packs is! List) return const RemoteManifestParse(problem: '清单缺少 packs 数组');

    final out = <RemotePackEntry>[];
    final seen = <String>{};
    var skipped = 0;
    for (final raw in packs) {
      // 尺寸护栏：超出 [PackCodec.maxPacksPerManifest] 的条目计数跳过。
      if (out.length >= PackCodec.maxPacksPerManifest) {
        skipped++;
        continue;
      }
      final e = RemotePackEntry.decode(raw);
      // 同 id 重复条目跳过后者（与包内专家的重复规则一致）。
      if (e == null || !seen.add(e.id)) {
        skipped++;
        continue;
      }
      out.add(e);
    }
    if (out.isEmpty) {
      return RemoteManifestParse(problem: '清单里没有可用条目（跳过 $skipped 条）', skipped: skipped);
    }
    return RemoteManifestParse(
      entries: out,
      problem: skipped > 0 ? '清单有 $skipped 条解析失败，已跳过' : '',
      skipped: skipped,
    );
  }

  /// 对照本地已装集合：算出可新装 / 可升级 / 已是最新 / 非法四类。
  /// 存量清单解析失败的坏包按「可安装」对待——重装就是修复路径。
  static RemoteManifestDiff diff(RemoteManifestParse manifest, ExpertPackManager manager) {
    final installable = <RemotePackEntry>[];
    final upgrades = <RemotePackEntry>[];
    final upToDate = <RemotePackEntry>[];
    final problems = <String>[];

    final stored = manager.store.loadAll();
    for (final e in manifest.entries) {
      if (e.id == ExpertPackManager.builtinPackId) {
        problems.add('「${ExpertPackManager.builtinPackId}」是内置保留 id，清单条目非法：${e.url}');
        continue;
      }
      final raw = stored[e.id];
      if (raw == null) {
        installable.add(e);
        continue;
      }
      final parsed = PackCodec.parse(raw);
      if (!parsed.ok) {
        installable.add(e);
        continue;
      }
      final cmp = PackCodec.compareVersions(e.version, parsed.pack!.meta.version);
      if (cmp > 0) {
        upgrades.add(e);
      } else {
        upToDate.add(e);
      }
    }
    return RemoteManifestDiff(
      installable: installable,
      upgrades: upgrades,
      upToDate: upToDate,
      problems: problems,
    );
  }
}

/// legacy 数据迁移导入器（设计见 `docs/migration-design.md`，W6）。
///
/// 旧版 `com.jev.probe` 与新版 `dev.chartools.chartools_app` 的数据目录被
/// Android 沙箱隔离，互不可读；转移只能靠「旧版导出 ZIP → 新版导入」这一座桥。
/// 本文件是桥的新版这一半：**纯 Dart、零第三方依赖**（JSON 用 dart:convert，
/// hash 用本文件内置的 SHA-256 实现），ZIP 解包与文件读取留给 app 层——
/// core 只吃解出来的 JSON 字符串。
///
/// 与 legacy 实现的关系（只读参考 `_reference/chartools/cn/app/.../core/kb/`）：
///
/// - `KbStore.kt:414-428`  notes.json 字段结构（裸数组，id/title/content/tags/
///   alwaysOn/enabled/updatedAt/type）；
/// - `KbStore.kt:430-452`  contacts.json 字段结构（id/name/aliases/apps/
///   relationship/notes/persona/autoSummary/updatedAt）；
/// - `PersonaStore.kt:608-641`  personas.json 解码（v2 为
///   `{version,seeded,removed,items}` 对象，v1 为裸数组；body 为空即跳过）；
/// - `PersonaStore.kt:362-418`  legacy 自己的 importJson 的容错姿态——「浏览层
///   字段有就带上，没有就空着」，本导入器沿用并加强（见下）。
///
/// 三条导入铁律（都从 legacy 的教训里来，见 PersonaStore.kt 类注释）：
///
/// 1. **不连坐**：字段缺失/类型不符退默认值继续；一条坏了只记一条
///    [MigrationProblem]，同文件其余条目照常导入。目录级损坏（整包不是 JSON）
///    也只影响该文件，另两个文件不受牵连。
/// 2. **绝不静默覆盖**：与已有数据内容相同 → 判重复跳过；同键不同内容 → 判
///    冲突，进预览等用户裁决（思路同 legacy PersonaStore.kt:399-413 的
///    「同名不同文改名新增」，但新版把决定权交给用户而不是自动改名）。
/// 3. **G8 确认后入库**：本文件只产出 [MigrationPreview]，**没有任何落盘通路**；
///    落盘契约在 [MigrationSink]，由 app 层实现，且必须发生在用户确认预览之后。
///
/// 挂载说明：按包约定「新增文件必须挂进 barrel」（chartools_core.dart 头注释），
/// 但 barrel 不在本工作流的文件清单里，故由 barrel 所有者挂载；本文件当前
/// 仅供测试以 `package:chartools_core/src/migration/legacy_importer.dart` 直引。
library;

import 'dart:convert';

import '../persona_kb/kb_models.dart';
import '../persona_kb/persona_card.dart';

// ---------------------------------------------------------------------------
// 迁移包 manifest（ZIP 层的格式校验，校验逻辑在 core、解包在 app 层）
// ---------------------------------------------------------------------------

/// 迁移包 manifest 的识别串。app 层拿到 ZIP 后先读 `manifest.json`，
/// kind 对不上就整包拒绝——防止把随手压的 ZIP 当迁移包导进一半。
const String legacyManifestKind = 'chartools-legacy-export';

/// 当前支持的 manifest 版本。更高版本 → 提示先升级新版，绝不「大概能导」。
const int legacyManifestVersion = 1;

/// manifest.json 的结构（`docs/migration-design.md` §4）。
class LegacyManifest {
  const LegacyManifest({
    required this.kind,
    required this.version,
    required this.fromPackage,
    required this.exportedAt,
    required this.fileHashes,
    required this.counts,
  });

  final String kind;
  final int version;

  /// 导出方包名，现状只可能是 `com.jev.probe`；字段留着是为下一个 legacy 包名
  /// 留位（出海版 global/ 的包名不同，PersonaProfile.kt:8-16 拆分的动机）。
  final String fromPackage;
  final int exportedAt;

  /// 文件名 → 该文件内容的 SHA-256（十六进制小写）。app 层解包后逐个对拍，
  /// 传输损坏在进解析器之前就会被抓住。
  final Map<String, String> fileHashes;

  /// 各文件条目数（导出时的快照），仅用于核对展示，不做强校验。
  final Map<String, int> counts;

  /// 文件在不在 manifest 的清单里（未知文件一律不导入，防夹带）。
  bool declares(String fileName) => fileHashes.containsKey(fileName);
}

/// manifest 解析结果：`ok == true` 时 manifest 可用，否则 [problem] 说明原因。
class LegacyManifestCheck {
  const LegacyManifestCheck(this.manifest, this.problem)
      : ok = manifest != null && problem == null;

  final LegacyManifest? manifest;
  final String? problem;
  final bool ok;
}

/// 解析 manifest.json。任何异常收敛成 problem，绝不外抛。
LegacyManifestCheck parseLegacyManifestJson(String raw) {
  if (raw.trim().isEmpty) {
    return LegacyManifestCheck(null, 'manifest.json 是空的');
  }
  final dynamic decoded;
  try {
    decoded = json.decode(raw);
  } on FormatException catch (e) {
    return LegacyManifestCheck(null, 'manifest.json 不是合法 JSON：${e.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    return LegacyManifestCheck(null, 'manifest.json 顶层必须是对象');
  }
  final kind = _coerceString(decoded['kind']);
  if (kind != legacyManifestKind) {
    return LegacyManifestCheck(null, '不是 chartools 迁移包（kind=$kind）');
  }
  final version = _coerceInt(decoded['version'], -1);
  if (version < 1) {
    return LegacyManifestCheck(null, 'manifest 缺少有效 version 字段');
  }
  if (version > legacyManifestVersion) {
    return LegacyManifestCheck(
        null, '迁移包版本 $version 比当前支持的 $legacyManifestVersion 新，请先升级新版应用');
  }
  final hashes = <String, String>{};
  final rawHashes = decoded['files'];
  if (rawHashes is Map<String, dynamic>) {
    rawHashes.forEach((name, hash) {
      final h = _coerceString(hash);
      // forEach 的 name 已是 Map<String, _> 的键类型（String），无需再判。
      if (name.isNotEmpty && h.isNotEmpty) hashes[name] = h;
    });
  }
  final counts = <String, int>{};
  final rawCounts = decoded['counts'];
  if (rawCounts is Map<String, dynamic>) {
    rawCounts.forEach((name, n) {
      // 同上：name 已是 String，类型检查恒真（unnecessary_type_check）。
      if (name.isNotEmpty) counts[name] = _coerceInt(n, 0);
    });
  }
  return LegacyManifestCheck(
    LegacyManifest(
      kind: kind,
      version: version,
      fromPackage: _coerceString(decoded['fromPackage']),
      exportedAt: _coerceInt(decoded['exportedAt'], 0),
      fileHashes: hashes,
      counts: counts,
    ),
    null,
  );
}

/// 对拍一个文件内容的 SHA-256 与 manifest 里登记的值。
/// 大小写不敏感；expected 为空视为「manifest 没登记」，不在这里拦（由调用方决定）。
bool verifyLegacyFileHash(String content, String expectedSha256) {
  final e = expectedSha256.trim().toLowerCase();
  if (e.isEmpty || e.length != 64) return false;
  return sha256HexOfUtf8(content) == e;
}

// ---------------------------------------------------------------------------
// 逐条解析：容错 + 新版模型
// ---------------------------------------------------------------------------

/// 一条「成功解析出来的条目 + 它在源文件里的下标」。
/// 下标随条目一起走，是为了冲突/重复明细能指回源文件的第几条。
class ParsedEntry<T> {
  const ParsedEntry(this.entity, this.index);

  final T entity;
  final int index;
}

/// 一个文件的解析段：条目 + 问题明细 + 整包是否可解码。
class ParsedSection<T> {
  const ParsedSection(this.entries, this.problems, {required this.parsed});

  /// 解析成功的条目（保持源文件顺序）。
  final List<ParsedEntry<T>> entries;

  /// 条目级/整包级问题明细；每条都能直接展示给用户。
  final List<MigrationProblem> problems;

  /// 整包 JSON 是否成功解码。false 时 entries 必为空（文件级损坏）。
  final bool parsed;

  /// 新版模型列表（ask 里的「输出新版模型列表」就是这个）。
  List<T> get items => List<T>.unmodifiable(entries.map((e) => e.entity));

  bool get isEmpty => entries.isEmpty;
}

/// 一条问题明细。`index < 0` 表示文件级问题（不是某一条坏了）。
class MigrationProblem {
  const MigrationProblem({
    required this.file,
    required this.index,
    required this.reason,
  });

  final String file;
  final int index;
  final String reason;

  @override
  String toString() =>
      index < 0 ? '$file：$reason' : '$file 第 ${index + 1} 条：$reason';
}

/// **legacy notes.json → 新版 [Note]**。
///
/// 容错规则（对应 KbStore.kt:414-428 的读取面，字段名逐字一致）：
/// - 元素不是对象（裸字符串/数字）→ 记 problem，跳过该条，不连坐；
/// - 字段缺失 → 新版默认值；类型不符 → 能收就收（数字标题收成 `"123"`），
///   收不了（如 tags 不是数组）→ 退默认值；
/// - title 与 content **同时**为空 → 这条笔记什么都不携带，记 problem 跳过。
ParsedSection<Note> parseLegacyNotesJson(String raw, {String file = 'notes.json'}) {
  return _parseLegacyArray<Note>(
    raw,
    file: file,
    wrapperKeys: const ['items', 'notes'],
    hashOf: noteContentHash,
    convert: (o, hash) {
      final type = _coerceString(o['type']).trim();
      return Note(
        // id 空缺时用内容 hash 合成：同一段内容重新导出/重导，得到同一个 id，
        // 幂等性从这里来（legacy 是随手 newId，重导会生出重复条目）。
        id: _coerceString(o['id']).isNotEmpty
            ? _coerceString(o['id'])
            : 'imp-n-${hash.substring(0, 10)}',
        title: _coerceString(o['title']),
        content: _coerceString(o['content']),
        tags: _coerceStringList(o['tags']),
        alwaysOn: _coerceBool(o['alwaysOn'], false),
        enabled: _coerceBool(o['enabled'], true),
        updatedAt: _clampNonNeg(_coerceInt(o['updatedAt'], 0), _maxStamp),
        type: type.isEmpty ? 'note' : type,
      );
    },
    // 内容判空在 convert 之后做（坏类型 coerce 之后可能从有变无）。
    isBlank: (n) => n.title.trim().isEmpty && n.content.trim().isEmpty,
    blankReason: (n) => '笔记没有标题也没有正文，跳过',
  );
}

/// **legacy contacts.json → 新版 [Contact]**。
///
/// 容错规则（对应 KbStore.kt:430-452）：字符串/字符串数组/布尔字段全部走
/// coerce 兜底；name 为空 → 这条联系人匹配不到任何会话（legacy
/// `findContact` 对空名直接返回 null，KbStore.kt:191-200），记 problem 跳过。
ParsedSection<Contact> parseLegacyContactsJson(String raw,
    {String file = 'contacts.json'}) {
  return _parseLegacyArray<Contact>(
    raw,
    file: file,
    wrapperKeys: const ['items', 'contacts'],
    hashOf: contactContentHash,
    convert: (o, hash) {
      return Contact(
        id: _coerceString(o['id']).isNotEmpty
            ? _coerceString(o['id'])
            : 'imp-c-${hash.substring(0, 10)}',
        name: _coerceString(o['name']),
        aliases: _coerceStringList(o['aliases']),
        apps: _coerceStringList(o['apps']),
        relationship: _coerceString(o['relationship']),
        notes: _coerceString(o['notes']),
        persona: _coerceString(o['persona']),
        autoSummary: _coerceString(o['autoSummary']),
        updatedAt: _clampNonNeg(_coerceInt(o['updatedAt'], 0), _maxStamp),
      );
    },
    isBlank: (c) => c.name.trim().isEmpty,
    blankReason: (c) => '联系人没有名字，跳过（没有名字匹配不到会话）',
  );
}

/// **legacy personas.json → 新版 [ImportedPersona]**。
///
/// 同时接受两种形态（PersonaStore.kt:608-641 的 decode 语义）：
/// - v2：`{"version":2,"seeded":[...],"removed":[...],"items":[...]}`；
/// - v1：裸数组 `[{"name":...,"body":...}]`。
///
/// `seeded`/`removed` 两个台账**不迁移**：它们绑定 legacy 自己的预设 key，
/// 新版预设体系不同，搬过去只会让新版「补缺预设」的判断失真。
/// body 为空 → 记 problem 跳过（与 legacy importJson 同语义，PersonaStore.kt:374）。
ParsedSection<ImportedPersona> parseLegacyPersonasJson(String raw,
    {String file = 'personas.json'}) {
  return _parseLegacyArray<ImportedPersona>(
    raw,
    file: file,
    wrapperKeys: const ['items'],
    hashOf: personaContentHash,
    convert: (o, hash) {
      final name = _coerceString(o['name']).trim();
      // Kotlin trimEnd() 的 Dart 对应物是 trimRight()（同样只去尾部空白）。
      final body = _coerceString(o['body']).trimRight();
      return ImportedPersona(
        id: _coerceString(o['id']).isNotEmpty
            ? _coerceString(o['id'])
            : 'imp-p-${hash.substring(0, 10)}',
        name: name.isEmpty ? '导入的人设' : name,
        body: body,
        avatar: _optText(o['avatar']),
        description: _optText(o['description']),
        tags: _coerceStringList(o['tags']),
        category: _optText(o['category']),
        usedCount: _clampNonNeg(_coerceInt(o['usedCount'], 0), _maxCount),
        presetKey: _coerceString(o['presetKey']).trim(),
        skillRefs: _coerceStringList(o['skillRefs']),
        appPkgs: _coerceStringList(o['appPkgs']),
        builtin: _coerceBool(o['builtin'], false),
        updatedAt: _clampNonNeg(_coerceInt(o['updatedAt'], 0), _maxStamp),
      );
    },
    isBlank: (p) => p.body.trim().isEmpty,
    blankReason: (p) => '「${p.name}」正文为空，跳过',
  );
}

/// 三类解析共用的容错骨架：解码 → 逐条转换 → 逐条记错。
/// T 的差异全部收敛进 hashOf/convert/isBlank/blankReason 四个回调。
///
/// hash 的口径由构造保证：先以占位 hash 建草稿实体，用**同一个** hashOf
/// （即下面三个 contentHash 函数）算出正式 hash，再重建实体——合成 id 与
/// 去重判定永远对得上，不存在「parse 期一套口径、去重时另一套」的漂移。
ParsedSection<T> _parseLegacyArray<T>(
  String raw, {
  required String file,
  required List<String> wrapperKeys,
  required String Function(T entity) hashOf,
  required T Function(Map<String, dynamic> o, String contentHash) convert,
  required bool Function(T entity) isBlank,
  required String Function(T entity) blankReason,
}) {
  if (raw.trim().isEmpty) {
    return ParsedSection<T>(const [], [
      MigrationProblem(file: file, index: -1, reason: '文件内容为空'),
    ], parsed: false);
  }
  final dynamic decoded;
  try {
    decoded = json.decode(raw);
  } on FormatException catch (e) {
    return ParsedSection<T>(const [], [
      MigrationProblem(file: file, index: -1, reason: '不是合法 JSON：${e.message}'),
    ], parsed: false);
  }
  final array = _extractArray(decoded, wrapperKeys);
  if (array == null) {
    return ParsedSection<T>(const [], [
      MigrationProblem(
          file: file, index: -1, reason: '顶层既不是数组也没有可识别的条目数组'),
    ], parsed: true);
  }
  final entries = <ParsedEntry<T>>[];
  final problems = <MigrationProblem>[];
  for (var i = 0; i < array.length; i++) {
    final element = array[i];
    if (element is! Map<String, dynamic>) {
      problems.add(MigrationProblem(
        file: file,
        index: i,
        reason: '不是对象（${_typeName(element)}），跳过这一条，其余照常',
      ));
      continue;
    }
    // 两段式构造：先建草稿（占位 hash）算内容 hash，再用正式 hash 重建，
    // 让「合成 id」与「去重判定」用同一个 hash 口径。
    final draft = convert(element, '0' * 64);
    final hash = hashOf(draft);
    final entity = convert(element, hash);
    if (isBlank(entity)) {
      problems.add(MigrationProblem(file: file, index: i, reason: blankReason(entity)));
      continue;
    }
    entries.add(ParsedEntry<T>(entity, i));
  }
  return ParsedSection<T>(entries, problems, parsed: true);
}

/// 抽出条目数组：裸数组直接用；对象则按 wrapperKeys 找（v2 personas 用
/// `items`；导出工具若包了一层 `notes`/`contacts` 也收）。找不到 → null。
List<dynamic>? _extractArray(dynamic decoded, List<String> wrapperKeys) {
  if (decoded is List) return decoded;
  if (decoded is Map<String, dynamic>) {
    for (final key in wrapperKeys) {
      final v = decoded[key];
      if (v is List) return v;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// 字段 coerce：类型不符退默认值，绝不抛（「不连坐」的落实点）
// ---------------------------------------------------------------------------

/// 字符串字段：String 原样；num/bool（字段值写串了）收成文本；其余结构类型
/// （List/Map/null/缺）退 [fallback]。与 legacy `optString` 的语义对齐但更宽。
String _coerceString(dynamic v, [String fallback = '']) {
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  return fallback;
}

/// 字符串数组：不是 List → 空表（legacy `stringList` 同语义，PersonaStore.kt:720）；
/// List 内元素逐个收文本、去空白、去重，嵌套结构跳过。
List<String> _coerceStringList(dynamic v) {
  if (v is! List) return const [];
  final out = <String>[];
  for (final e in v) {
    if (e == null || e is Map || e is List) continue;
    final s = e.toString().trim();
    if (s.isNotEmpty && !out.contains(s)) out.add(s);
  }
  return out;
}

/// 布尔字段：与 legacy `optBoolean(key, fallback)` 同宽——只认 bool 与
/// `"true"/"false"` 字串；数字等其他类型一律退 fallback（`alwaysOn: 3` 不该被
/// 读成 true）。org.json 的 optBoolean 就是这个行为（KbStore.kt:419-420）。
bool _coerceBool(dynamic v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is String) {
    switch (v.trim().toLowerCase()) {
      case 'true':
        return true;
      case 'false':
        return false;
    }
  }
  return fallback;
}

/// 整数字段：int 原样；double（时间戳被写成 1.7e12）取整；字符串可解析则收；
/// 其余退 fallback。与 legacy `optLong` 的字符串兼容行为一致。
int _coerceInt(dynamic v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is double) return v.toInt();
  if (v is String) {
    final p = int.tryParse(v.trim());
    if (p != null) return p;
    final d = double.tryParse(v.trim());
    if (d != null) return d.toInt();
  }
  return fallback;
}

/// 缺失/null/空白 → null 的可选文本（legacy `optText` 同语义，PersonaStore.kt:716）。
String? _optText(dynamic v) {
  final s = _coerceString(v).trim();
  return s.isEmpty ? null : s;
}

/// 夹回非负区间。legacy 对 usedCount 有 `coerceAtLeast(0)`（PersonaStore.kt:628）；
/// 时间戳/计数被写成负数一律当 0，上限拦手滑的天文数字。不用 `int.clamp`
/// 是因为它的静态类型在 num/int 之间有过历史反复，显式分支没有歧义。
const int _maxStamp = 1 << 62;
const int _maxCount = 1 << 30;

int _clampNonNeg(int v, int max) => v < 0 ? 0 : (v > max ? max : v);

/// 归一化文本：去零宽字符（legacy KbStore.kt:618 的 ZERO_WIDTH 集合）、trim、
/// 连续空白折叠。内容 hash 只对归一化结果算——「同一段话多打两个空格」不该
/// 变成两条数据。
String _normText(String s) => s
    .replaceAll(RegExp('[\u200B-\u200D\uFEFF]'), '')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

/// 名字键：归一化再 lowercase，用于联系人/人设的重名判定
///（legacy normalizeName 的思路，KbStore.kt:639-643）。
String _normName(String s) => _normText(s).toLowerCase();

String _typeName(dynamic v) {
  if (v == null) return 'null';
  if (v is String) return '字符串';
  if (v is num) return '数字';
  if (v is bool) return '布尔';
  if (v is List) return '数组';
  if (v is Map) return '对象';
  return v.runtimeType.toString();
}

// ---------------------------------------------------------------------------
// 内容 hash：内置 SHA-256（core 零第三方依赖，crypto 用不得）
// ---------------------------------------------------------------------------

const List<int> _sha256K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr32(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

/// UTF-8 字符串的 SHA-256（十六进制小写）。内置实现的理由只有一个：core 零
/// 第三方依赖，而「内容 hash」要经得起对拍——测试里钉了空串与 `"abc"` 两个
/// FIPS 校准向量。
String sha256HexOfUtf8(String input) {
  final bytes = utf8.encode(input);
  // final：h 之后只做元素赋值（h[0] = ...），引用本身不再变。
  final h = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  final bitLen = bytes.length * 8;
  final data = List<int>.of(bytes)..add(0x80);
  while (data.length % 64 != 56) {
    data.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    data.add((bitLen >> (8 * i)) & 0xFF);
  }
  final w = List<int>.filled(64, 0);
  for (var block = 0; block < data.length; block += 64) {
    for (var t = 0; t < 16; t++) {
      final b = block + t * 4;
      w[t] = (data[b] << 24) |
          (data[b + 1] << 16) |
          (data[b + 2] << 8) |
          data[b + 3];
    }
    for (var t = 16; t < 64; t++) {
      final s0 =
          _rotr32(w[t - 15], 7) ^ _rotr32(w[t - 15], 18) ^ (w[t - 15] >> 3);
      final s1 = _rotr32(w[t - 2], 17) ^ _rotr32(w[t - 2], 19) ^ (w[t - 2] >> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xFFFFFFFF;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var t = 0; t < 64; t++) {
      final bigS1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final t1 = (hh + bigS1 + ch + _sha256K[t] + w[t]) & 0xFFFFFFFF;
      final bigS0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (bigS0 + maj) & 0xFFFFFFFF;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }
    h[0] = (h[0] + a) & 0xFFFFFFFF;
    h[1] = (h[1] + b) & 0xFFFFFFFF;
    h[2] = (h[2] + c) & 0xFFFFFFFF;
    h[3] = (h[3] + d) & 0xFFFFFFFF;
    h[4] = (h[4] + e) & 0xFFFFFFFF;
    h[5] = (h[5] + f) & 0xFFFFFFFF;
    h[6] = (h[6] + g) & 0xFFFFFFFF;
    h[7] = (h[7] + hh) & 0xFFFFFFFF;
  }
  return h.map((x) => x.toRadixString(16).padLeft(8, '0')).join();
}

// ---------------------------------------------------------------------------
// 新版实体的人设契约记录（Character Card V2 兼容钩子在这里）
// ---------------------------------------------------------------------------

/// 一条有名的人设/专家——legacy `PersonaProfile` 的无损搬运记录。
///
/// 新版 core 尚无正式的专家库模型（专家库按「按需资产包」设计，另工作流交付），
/// 这里先立一份**迁移契约**：字段与 legacy PersonaProfile.kt:31-66 逐一对齐，
/// 一个都不丢；app 层把正式模型定稿后，从这份记录一一映射即可，不需要回头
/// 重解析 ZIP。两组字段的铁律同 legacy：
///
/// - 行为层 [body]：唯一进提示词的东西（经 [card] 解析）；
/// - 其余全部是浏览层/装配层，一个字节都不进提示词（PersonaProfile.kt 铁律）。
class ImportedPersona {
  const ImportedPersona({
    required this.id,
    required this.name,
    required this.body,
    this.avatar,
    this.description,
    this.tags = const [],
    this.category,
    this.usedCount = 0,
    this.presetKey = '',
    this.skillRefs = const [],
    this.appPkgs = const [],
    this.builtin = false,
    this.updatedAt = 0,
  });

  final String id;
  final String name;

  /// 人设原文，逐字保存（含换行），中间不做规范化——「套用 → 保存 → 再套用」
  /// 不能悄悄变形（PersonaProfile.kt 对 body 的原话）。
  final String body;
  final String? avatar;
  final String? description;
  final List<String> tags;
  final String? category;
  final int usedCount;

  /// legacy 内置预设的稳定标识（如 `daily.friend`）；用户自建为空串。
  /// 只作来源登记，新版不应拿它参与新预设的播种/删除台账。
  final String presetKey;
  final List<String> skillRefs;
  final List<String> appPkgs;
  final bool builtin;
  final int updatedAt;

  /// 现算结构化卡：认得出键 → 结构化（Character Card V2 风格的键
  /// `description`/`scenario`/`{{user}}`/`{{char}}` 都被 PersonaCard 接受）；
  /// 认不出 → 自由文本原样。人设兼容性由 PersonaCard 统一兜底。
  PersonaCard card() => PersonaCard.parse(body);
}

// ---------------------------------------------------------------------------
// 重复检测 + 迁移预览（G8：预览先行，确认后才落盘）
// ---------------------------------------------------------------------------

/// 单条迁移明细的三种去向。
enum MigrationStatus {
  /// 内容全新 → 将导入（N）。
  insert,

  /// 内容 hash 与已有数据/包内前文相同 → 无损跳过（M）。
  duplicate,

  /// 同键（同 id / 同名）但内容不同 → 待用户裁决（K）。
  conflict,
}

extension MigrationStatusLabel on MigrationStatus {
  /// UI 直接可用的中文标签。
  String get label => switch (this) {
        MigrationStatus.insert => '将导入',
        MigrationStatus.duplicate => '重复跳过',
        MigrationStatus.conflict => '冲突待确认',
      };
}

/// 预览里的一条明细：解析出的实体 + 来源 + hash + 去向。
class MigrationItem<T> {
  const MigrationItem({
    required this.entity,
    required this.file,
    required this.index,
    required this.contentHash,
    required this.status,
    required this.detail,
  });

  final T entity;
  final String file;
  final int index;
  final String contentHash;
  final MigrationStatus status;
  final String detail;

  @override
  String toString() =>
      '$file#${index + 1} ${status.label}：${detail.isEmpty ? entity.runtimeType : detail}';
}

/// 新版库里已有数据的检索索引——重复/冲突判定的「既有侧」。
///
/// 由 app 层在导入前用当前库构建（core 不读任何存储，存储注入原则同
/// kb_models.dart 头注释）。空的索引 = 只做包内去重（全新装机场景）。
class LegacyExistingIndex {
  const LegacyExistingIndex({
    this.noteHashes = const {},
    this.noteIds = const {},
    this.contactHashes = const {},
    this.contactNames = const {},
    this.personaHashes = const {},
    this.personaNames = const {},
  });

  final Set<String> noteHashes;
  final Set<String> noteIds;
  final Set<String> contactHashes;
  final Set<String> contactNames;
  final Set<String> personaHashes;
  final Set<String> personaNames;

  factory LegacyExistingIndex.fromData({
    List<Note> notes = const [],
    List<Contact> contacts = const [],
    List<ImportedPersona> personas = const [],
  }) {
    return LegacyExistingIndex(
      noteHashes: {for (final n in notes) noteContentHash(n)},
      noteIds: {for (final n in notes) if (!n.id.startsWith('imp-')) n.id},
      contactHashes: {for (final c in contacts) contactContentHash(c)},
      contactNames: {for (final c in contacts) _normName(c.name)},
      personaHashes: {for (final p in personas) personaContentHash(p)},
      personaNames: {for (final p in personas) _normName(p.name)},
    );
  }
}

/// 三个文件的解析结果合成的「待迁移包」。
class LegacyBundle {
  const LegacyBundle({
    required this.notes,
    required this.contacts,
    required this.personas,
  });

  final ParsedSection<Note> notes;
  final ParsedSection<Contact> contacts;
  final ParsedSection<ImportedPersona> personas;
}

/// 一次性的拼包入口：app 层把 ZIP 里解出的三段 JSON 文本喂进来。
/// 某个文件缺失/为 null → 视为该文件不存在，给文件级 problem，其余照常。
LegacyBundle collectLegacyBundle({
  String? notesJson,
  String? contactsJson,
  String? personasJson,
}) {
  return LegacyBundle(
    notes: notesJson == null
        ? ParsedSection<Note>(const [], [
            MigrationProblem(file: 'notes.json', index: -1, reason: '迁移包里没有这个文件'),
          ], parsed: false)
        : parseLegacyNotesJson(notesJson),
    contacts: contactsJson == null
        ? ParsedSection<Contact>(const [], [
            MigrationProblem(file: 'contacts.json', index: -1, reason: '迁移包里没有这个文件'),
          ], parsed: false)
        : parseLegacyContactsJson(contactsJson),
    personas: personasJson == null
        ? ParsedSection<ImportedPersona>(const [], [
            MigrationProblem(file: 'personas.json', index: -1, reason: '迁移包里没有这个文件'),
          ], parsed: false)
        : parseLegacyPersonasJson(personasJson),
  );
}

/// 新版 [Note] 的内容 hash：type + 标题 + 正文（tags/开关是元数据，不参与）。
String noteContentHash(Note n) => sha256HexOfUtf8(
    ['note', _normText(n.type), _normText(n.title), _normText(n.content)]
        .join('\x00'));

/// 新版 [Contact] 的内容 hash：名字 + 别名集合 + app 集合 + 关系 + 备注
///（列表排序后参与，因此 [a,b] 与 [b,a] 算同一段内容）。
String contactContentHash(Contact c) {
  final aliases = c.aliases.map(_normName).toList()..sort();
  final apps = c.apps.toList()..sort();
  return sha256HexOfUtf8([
    'contact',
    _normName(c.name),
    aliases.join('\u001f'),
    apps.join('\u001f'),
    _normText(c.relationship),
    _normText(c.notes),
  ].join('\x00'));
}

/// [ImportedPersona] 的内容 hash：名字 + 正文。头像/简介/标签/分类是浏览层
///（PersonaProfile.kt 铁律），不参与「是不是同一个人设」的判定。
String personaContentHash(ImportedPersona p) =>
    sha256HexOfUtf8(['persona', _normName(p.name), _normText(p.body)].join('\x00'));

/// **迁移预览**——导入器的唯一产出。N/M/K 三个计数 + 全部明细 + 问题清单。
///
/// G8 确认后入库：本对象只是「快把什么搬进来」的账单；确认动作在 app 层，
/// 落盘契约在 [MigrationSink]。core 里不存在任何从预览直接写存储的路径。
class MigrationPreview {
  const MigrationPreview({
    required this.notes,
    required this.contacts,
    required this.personas,
    required this.problems,
  });

  final List<MigrationItem<Note>> notes;
  final List<MigrationItem<Contact>> contacts;
  final List<MigrationItem<ImportedPersona>> personas;

  /// 全部问题明细（条目级 + 文件级）。有它，「部分失败」是可核对的事实
  /// 而不是一句「导入完成」。
  final List<MigrationProblem> problems;

  /// 将导入 N 条。
  int get importCount => _countStatus(MigrationStatus.insert);

  /// 跳过 M 条（重复）。
  int get duplicateCount => _countStatus(MigrationStatus.duplicate);

  /// 冲突 K 条（待用户裁决）。
  int get conflictCount => _countStatus(MigrationStatus.conflict);

  int get totalCount => notes.length + contacts.length + personas.length;

  bool get isEmpty => totalCount == 0;

  /// 用户确认后默认入库的集合：**只含 insert 状态**。冲突项要入库必须由
  /// 用户在 UI 上逐条点名（或整体选择「仍导入」），app 层从 [notes]/
  /// [contacts]/[personas] 明细里自己挑——预览不替用户做决定。
  List<Note> get confirmedNotes =>
      [for (final i in notes) if (i.status == MigrationStatus.insert) i.entity];

  List<Contact> get confirmedContacts => [
        for (final i in contacts)
          if (i.status == MigrationStatus.insert) i.entity
      ];

  List<ImportedPersona> get confirmedPersonas => [
        for (final i in personas)
          if (i.status == MigrationStatus.insert) i.entity
      ];

  /// 一句话摘要，措辞沿用 legacy PersonaImport.describe 的风格
  ///（PersonaStore.kt:18-26）：数字在前，口径说清。
  String describe() {
    if (isEmpty && problems.isEmpty) return '迁移包里没有可导入的数据。';
    final sb = StringBuffer('将导入 $importCount 条');
    if (duplicateCount > 0) sb.write('，跳过 $duplicateCount 条重复');
    if (conflictCount > 0) sb.write('，$conflictCount 条冲突待确认');
    if (problems.isNotEmpty) sb.write('，另有 ${problems.length} 条问题已记录');
    sb.write('。');
    return sb.toString();
  }

  int _countStatus(MigrationStatus s) =>
      notes.where((i) => i.status == s).length +
      contacts.where((i) => i.status == s).length +
      personas.where((i) => i.status == s).length;
}

/// 组装预览：对三个段逐条判重复/冲突（先重复后冲突：内容完全相同永远算
/// 重复，哪怕名字也撞了——无损跳过优先于人工裁决）。
MigrationPreview buildMigrationPreview(
  LegacyBundle bundle, {
  LegacyExistingIndex existing = const LegacyExistingIndex(),
}) {
  return MigrationPreview(
    notes: _assignStatus<Note>(
      section: bundle.notes,
      file: 'notes.json',
      hashOf: noteContentHash,
      // 合成 id（imp- 前缀）派生自内容 hash，不构成身份键；只有 legacy 真带
      // id 的条目才用 id 查冲突。
      keyOf: (n) => n.id.startsWith('imp-') ? null : n.id,
      existingHashes: existing.noteHashes,
      existingKeys: existing.noteIds,
    ),
    contacts: _assignStatus<Contact>(
      section: bundle.contacts,
      file: 'contacts.json',
      hashOf: contactContentHash,
      keyOf: (c) => _normName(c.name),
      existingHashes: existing.contactHashes,
      existingKeys: existing.contactNames,
    ),
    personas: _assignStatus<ImportedPersona>(
      section: bundle.personas,
      file: 'personas.json',
      hashOf: personaContentHash,
      keyOf: (p) => _normName(p.name),
      existingHashes: existing.personaHashes,
      existingKeys: existing.personaNames,
    ),
    problems: [
      ...bundle.notes.problems,
      ...bundle.contacts.problems,
      ...bundle.personas.problems,
    ],
  );
}

/// 单段的状态判定。`seenHashes`/`seenKeys` 从既有索引复制起步，随包内进度
/// 增长——包内第二条撞第一条时同样能判出来。
List<MigrationItem<T>> _assignStatus<T>({
  required ParsedSection<T> section,
  required String file,
  required String Function(T) hashOf,
  required String? Function(T) keyOf,
  required Set<String> existingHashes,
  required Set<String> existingKeys,
}) {
  // hash / key → 首次出现的源下标（既有数据不知道下标，用 -1 占位）。
  // 这两张表同时承担「既有侧」与「包内前文」的去重记忆，边走边长。
  final hashFirstAt = <String, int>{
    for (final h in existingHashes) h: -1,
  };
  final keyFirstAt = <String, int>{for (final k in existingKeys) k: -1};
  final out = <MigrationItem<T>>[];
  for (final entry in section.entries) {
    final entity = entry.entity;
    final hash = hashOf(entity);
    final key = keyOf(entity);
    var status = MigrationStatus.insert;
    var detail = '';
    if (hashFirstAt.containsKey(hash)) {
      status = MigrationStatus.duplicate;
      final at = hashFirstAt[hash]!;
      detail = at < 0
          ? '内容与新版已有数据完全相同（hash 前 8 位 ${hash.substring(0, 8)}），无损跳过'
          : '与包内第 ${at + 1} 条内容相同（hash 前 8 位 ${hash.substring(0, 8)}），无损跳过';
    } else if (key != null && keyFirstAt.containsKey(key)) {
      status = MigrationStatus.conflict;
      final at = keyFirstAt[key]!;
      final where = at < 0 ? '新版已有数据' : '包内第 ${at + 1} 条';
      detail = '与$where同键（$key）但内容不同，请取舍：改名导入、覆盖或放弃这条';
    }
    hashFirstAt.putIfAbsent(hash, () => entry.index);
    if (key != null) keyFirstAt.putIfAbsent(key, () => entry.index);
    out.add(MigrationItem<T>(
      entity: entity,
      file: file,
      index: entry.index,
      contentHash: hash,
      status: status,
      detail: detail,
    ));
  }
  return out;
}

// ---------------------------------------------------------------------------
// G8 落盘契约（app 层实现；core 只定义，不实现）
// ---------------------------------------------------------------------------

/// 落盘契约——**必须**在用户对 [MigrationPreview] 明确确认之后才被调用。
///
/// 实现要求（对应 legacy writeAtomic 的教训，KbStore.kt:555-576）：
///
/// 1. 每段要么全进要么全不进：写到一半失败必须回滚该段，绝不留半截
///    （建议 temp 文件 + rename 的原子替换）；
/// 2. 返回 false 表示该段没落盘，调用方停止后续段并把失败展示给用户，
///    而不是把部分成功当整体成功报出去；
/// 3. 只接 `preview.confirmedXxx`（或用户逐条点名的明细子集），冲突/重复
///    条目不得在未经用户裁决的情况下混进来。
abstract class MigrationSink {
  /// 返回是否全部落盘成功。
  Future<bool> applyNotes(List<Note> items);

  /// 返回是否全部落盘成功。
  Future<bool> applyContacts(List<Contact> items);

  /// 返回是否全部落盘成功。
  Future<bool> applyPersonas(List<ImportedPersona> items);
}

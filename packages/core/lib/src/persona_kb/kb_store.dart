/// 知识库存储（超越版）—— 思路来自旧仓库 `core/kb/KbStore.kt`。
///
/// legacy 的形状：三份 JSON 文件（notes / contacts / logs/<contactId>.json），
/// 逐次原子写（临时文件 + rename），损坏文件先挪开再重写。
///
/// 超越版改动（每处都有注释标注意图）：
///
///  1. **单一存档文档 + schemaVersion**（K-7 开先例）：不再三份文件，而是一份
///     顶层带 `schemaVersion` 的 JSON 存档 —— 通道 schema 版本化自此有先例，
///     往后升级存档格式靠版本分支，而不是猜字段。
///  2. **来源追踪**：每条笔记带 `source`（manual / import / doc）与
///     `importedAt`，见 [TrackedNote]。出处属于创建时刻 —— 更新内容不改出身。
///  3. **命中评测钩子**：[KbStore.search] 每次检索写一条 [SearchLogEntry]
///     （query → 命中 id 列表）；事后可用 [KbStore.annotateSearch] 注入人工
///     相关性标注并算出 precision@k —— 先攒数据说话，再决定是否升级向量检索。
///  4. **导入去重**：按归一化内容的 FNV-1a 64 指纹识别重复
///     （[kbContentFingerprint]），文档导入反复灌同一段内容不再翻倍。
///
/// 持久化策略：内存状态是唯一真源，`archivePath` 非空时每次变更后同步落盘
/// 整份存档（个人库量级只有 KB 到 MB，同步写最简单也最不容易出竞态）；
/// `archivePath` 为空则纯内存（测试与上层自管持久化用）。落盘失败不回滚内存
/// 状态（与 legacy「缓存必须跟着文件走」不同：这里内存就是真源），改为在
/// [KbStore.lastFlushError] 留痕、方法返回 false —— 下次成功落盘自然追平。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'kb_models.dart';
import 'lexical_search.dart';

/// K-7：存档格式版本号。通道 schema 版本化自此开先例：顶层一个整数字段，
/// 升级格式时按版本分支解析；缺失视为 1（最早批次没有这个字段）。
const int kbArchiveSchemaVersion = 1;

/// 笔记来源。出处属于创建时刻：[KbSource.manual] 用户手写；[KbSource.import]
/// 迁移/批量导入；[KbSource.doc] 文档切块导入。
abstract final class KbSource {
  static const manual = 'manual';

  // 常量名避开内建字会误导（值就是 legacy 约定的 'import'），直接用内建字
  // 作为成员名在 Dart 里合法。
  static const import = 'import';
  static const doc = 'doc';
}

/// 笔记 + 出处。Note 本体复用 kb_models.dart（并行工作流共用模型，不在此加
/// 字段），出处作为旁挂记录随存档一起序列化。
class TrackedNote {
  const TrackedNote({
    required this.note,
    required this.source,
    required this.importedAt,
    required this.contentHash,
  });

  final Note note;

  /// 来源，取值见 [KbSource]；未知字符串原样保留（向前兼容）。
  final String source;

  /// 导入时间（毫秒）。仅 import / doc 有意义；manual 恒为 0（从未导入）。
  final int importedAt;

  /// 归一化内容指纹（见 [kbContentFingerprint]），去重快路径索引。
  final String contentHash;
}

/// 一条检索评测日志：query → 命中 id（按排名序）。[relevantIds] 与
/// [precisionAtK] 为 null 表示尚未注入人工标注 —— 评测流程是「先攒日志、
/// 事后 [KbStore.annotateSearch] 补标」，或检索时就传 relevantIds 直接入账。
class SearchLogEntry {
  const SearchLogEntry({
    required this.ts,
    required this.query,
    required this.k,
    required this.hitIds,
    this.anyTag = const [],
    this.anyType = const [],
    this.relevantIds,
    this.precisionAtK,
  });

  final int ts;
  final String query;

  /// 检索时的截断数（评测换算口径要用）。
  final int k;
  final List<String> hitIds;
  final List<String> anyTag;
  final List<String> anyType;

  /// 人工确认的相关笔记 id；null = 尚未标注。
  final List<String>? relevantIds;

  /// precision@k（分母为实际命中数，口径见 LexicalSearch 的 RetrievalEval 说明）。
  final double? precisionAtK;
}

/// 一条导入去重命中。[incoming] 是被丢弃的那条（id 已补），[keptId] 是已入库
/// 的同内容笔记。
class DuplicateHit {
  const DuplicateHit({
    required this.incoming,
    required this.keptId,
    required this.contentHash,
  });

  final Note incoming;
  final String keptId;
  final String contentHash;
}

/// [KbStore.importNotes] 的结果。[persisted] 为 false 表示变更没落盘（读
/// [KbStore.lastFlushError]）—— 内存状态仍是本次导入之后的。
class ImportReport {
  const ImportReport({
    required this.added,
    required this.updated,
    required this.duplicates,
    required this.persisted,
  });

  final List<TrackedNote> added;
  final List<TrackedNote> updated;
  final List<DuplicateHit> duplicates;
  final bool persisted;

  int get total => added.length + updated.length + duplicates.length;
}

/// 设置页要的计数（legacy KbCounts 同形）。
class KbCounts {
  const KbCounts({
    required this.notes,
    required this.contacts,
    required this.logLines,
  });

  final int notes;
  final int contacts;
  final int logLines;
}

/// 归一化内容：剔除零宽字符、折叠空白（ASCII 空白 + nbsp + 全角空格）、
/// 小写 —— 与 legacy normalizeName 同一套思路，让「看着一样」的内容算出
/// 同一个指纹。公开给导入器在入库前预估重复。
String kbNormalizeContent(String s) {
  final sb = StringBuffer();
  var pendingSpace = false;
  for (final rune in s.runes) {
    if (rune == 0x200B || rune == 0x200C || rune == 0x200D || rune == 0xFEFF) {
      continue; // 零宽字符不参与指纹
    }
    final isSpace = rune == 0x20 ||
        (rune >= 0x09 && rune <= 0x0D) ||
        rune == 0xA0 ||
        rune == 0x3000;
    if (isSpace) {
      pendingSpace = true;
      continue;
    }
    if (pendingSpace && sb.isNotEmpty) {
      sb.write(' ');
    }
    pendingSpace = false;
    sb.writeCharCode(rune);
  }
  return sb.toString().toLowerCase();
}

/// FNV-1a 64 内容指纹，前缀标明算法 —— 日后换摘要算法（如 sha）旧档不歧义。
/// 不是密码学摘要：重复判定最终以归一化字符串全等为准，指纹只是快路径索引
/// （防碰撞误杀的复核在 [KbStore.importNotes] 里）。
String kbContentFingerprint(String content) =>
    'fnv1a64:${_hex64(_fnv1a64(kbNormalizeContent(content)))}';

int _fnv1a64(String s) {
  // Dart VM 的 int 是 64 位二补数，乘法按 2^64 回绕，正是 FNV 要的模运算。
  // 本包面向 Android / Windows VM，不跑 web（web 的 JS 数字会失真），故放心用。
  var h = 0xcbf29ce484222325; // FNV offset basis
  for (final unit in s.codeUnits) {
    h ^= unit;
    h *= 0x100000001b3; // FNV prime
  }
  return h;
}

/// VM 的 int 是有符号 64 位；经 BigInt 补回无符号解释，输出定长十六进制。
String _hex64(int h) =>
    BigInt.from(h).toUnsigned(64).toRadixString(16).padLeft(16, '0');

/// 知识库存储。Note / Contact / LogEntry 三类数据的 CRUD + 单份带 schemaVersion
/// 的 JSON 存档持久化 + 检索评测钩子 + 导入去重。
class KbStore {
  KbStore({
    String? archivePath,
    this.maxLogLines = defaultMaxLogLines,
    this.maxSearchLog = defaultMaxSearchLog,
  }) : archivePath = archivePath;

  /// 每个联系人的聊天记录上限（legacy MAX_LOG 同值）。
  static const int defaultMaxLogLines = 300;

  /// 检索评测日志上限（只裁内存与存档里的最旧条目）。
  static const int defaultMaxSearchLog = 500;

  /// 非空时每次变更同步落盘整份存档；为空则纯内存。
  final String? archivePath;
  final int maxLogLines;
  final int maxSearchLog;

  final List<TrackedNote> _notes = <TrackedNote>[];
  final List<Contact> _contacts = <Contact>[];
  final Map<String, List<LogEntry>> _logs = <String, List<LogEntry>>{};
  final List<SearchLogEntry> _searchLog = <SearchLogEntry>[];

  /// 最近一次落盘失败的原因（成功后清空）。方法返回 false 时读它定位。
  String? lastFlushError;

  /// 存档实际加载到的 schemaVersion：新库 = [kbArchiveSchemaVersion]；
  /// [KbStore.fromJson] 会记住读到的版本号。向前兼容是**只读**的——比已知
  /// 新的存档 [_flush] 时拒绝降级重写（见 [archiveSchemaAhead]），否则
  /// [toJson] 恒写当前版本、未知字段（未来版本的 futureField / note.v2Field）
  /// 会在第一次落盘时静默丢失。
  int archiveSchemaVersion = kbArchiveSchemaVersion;

  /// 加载到的存档格式比当前已知的新（本进程是降级运行）。此态下 [_flush]
  /// 恒拒绝并往 [lastFlushError] 写原因——升级 app 才能恢复落盘。
  bool get archiveSchemaAhead => archiveSchemaVersion > kbArchiveSchemaVersion;

  // -------------------------------------------------------------- Note CRUD

  /// 全部笔记（带出处）。返回副本，外部改动不影响库内。
  List<TrackedNote> notes() => List.of(_notes);

  TrackedNote? note(String id) {
    for (final t in _notes) {
      if (t.note.id == id) return t;
    }
    return null;
  }

  /// 新增或按 id 更新。新建时按 [source] 记录出处（manual 的 importedAt 恒为
  /// 0；import / doc 缺省盖当前时间）；更新时**保留原出处** —— 出处属于创建
  /// 时刻，改内容不改出身。id 为空自动补。updatedAt 每次盖章（编辑时间语义，
  /// 与 legacy 一致）。返回 false 表示落盘失败。
  bool saveNote(Note note, {String source = KbSource.manual, int? importedAt}) {
    final id = note.id.isEmpty ? newId() : note.id;
    final stamped = Note(
      id: id,
      title: note.title,
      content: note.content,
      tags: List.of(note.tags),
      alwaysOn: note.alwaysOn,
      enabled: note.enabled,
      updatedAt: _now(),
      type: note.type,
    );
    final idx = _indexNote(id);
    if (idx >= 0) {
      final old = _notes[idx];
      _notes[idx] = TrackedNote(
        note: stamped,
        source: old.source,
        importedAt: old.importedAt,
        contentHash: kbContentFingerprint(stamped.content),
      );
    } else {
      _notes.add(TrackedNote(
        note: stamped,
        source: source,
        importedAt: importedAt ?? (source == KbSource.manual ? 0 : _now()),
        contentHash: kbContentFingerprint(stamped.content),
      ));
    }
    return _flush();
  }

  /// 批量导入（文档切块 / 迁移 / ZIP 导入器入口）。规则按序判定：
  ///
  ///  1. **去重优先**：归一化内容与已入库条目（含本批先到的）全等 → 计入
  ///     duplicates，不入库。指纹相同先做归一化全等复核，防御哈希碰撞误杀。
  ///  2. 内容不同但 id 已存在 → 按 id 更新（出处刷新为本次导入 —— 再导入
  ///     就是重新出处的时刻）。
  ///  3. 其余新增。
  ///
  /// 导入保真：incoming 的 updatedAt > 0 时原样保留（迁移不篡改原时间），
  /// 为 0 才盖当前时间（文档切块没有原始时间）。
  ImportReport importNotes(
    List<Note> incoming, {
    String source = KbSource.doc,
    int? importedAt,
  }) {
    final at = importedAt ?? _now();
    final added = <TrackedNote>[];
    final updated = <TrackedNote>[];
    final duplicates = <DuplicateHit>[];

    // 指纹 → 已入库条目（含本批新增），O(1) 查重快路径。
    final byHash = <String, List<TrackedNote>>{};
    for (final t in _notes) {
      byHash.putIfAbsent(t.contentHash, () => <TrackedNote>[]).add(t);
    }

    for (final raw in incoming) {
      final note = raw.id.isEmpty ? _withId(raw, newId()) : raw;
      final hash = kbContentFingerprint(note.content);
      final normalized = kbNormalizeContent(note.content);
      TrackedNote? dupOf;
      for (final cand in byHash[hash] ?? const <TrackedNote>[]) {
        if (kbNormalizeContent(cand.note.content) == normalized) {
          dupOf = cand;
          break;
        }
      }
      if (dupOf != null) {
        duplicates.add(DuplicateHit(
          incoming: note,
          keptId: dupOf.note.id,
          contentHash: hash,
        ));
        continue;
      }
      final stamped = Note(
        id: note.id,
        title: note.title,
        content: note.content,
        tags: List.of(note.tags),
        alwaysOn: note.alwaysOn,
        enabled: note.enabled,
        updatedAt: note.updatedAt > 0 ? note.updatedAt : _now(),
        type: note.type,
      );
      final tracked = TrackedNote(
        note: stamped,
        source: source,
        importedAt: at,
        contentHash: hash,
      );
      final idx = _indexNote(note.id);
      if (idx >= 0) {
        final old = _notes[idx];
        _notes[idx] = tracked;
        byHash[old.contentHash]?.remove(old); // 老指纹桶同步维护
        byHash.putIfAbsent(hash, () => <TrackedNote>[]).add(tracked);
        updated.add(tracked);
      } else {
        _notes.add(tracked);
        byHash.putIfAbsent(hash, () => <TrackedNote>[]).add(tracked);
        added.add(tracked);
      }
    }

    final changed = added.isNotEmpty || updated.isNotEmpty;
    return ImportReport(
      added: added,
      updated: updated,
      duplicates: duplicates,
      persisted: !changed || _flush(),
    );
  }

  /// 删除笔记。没删到东西也算成功（幂等，与 legacy 一致）。
  bool deleteNote(String id) {
    final before = _notes.length;
    _notes.removeWhere((t) => t.note.id == id);
    if (_notes.length == before) return true;
    return _flush();
  }

  // ----------------------------------------------------------- Contact CRUD

  List<Contact> contacts() => List.of(_contacts);

  Contact? contact(String id) {
    for (final c in _contacts) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 新增或按 id 更新；updatedAt 每次盖章（编辑时间语义，与 legacy 一致）。
  bool saveContact(Contact c) {
    final id = c.id.isEmpty ? newId() : c.id;
    final stamped = Contact(
      id: id,
      name: c.name,
      aliases: List.of(c.aliases),
      apps: List.of(c.apps),
      relationship: c.relationship,
      notes: c.notes,
      persona: c.persona,
      autoSummary: c.autoSummary,
      updatedAt: _now(),
    );
    final idx = _contacts.indexWhere((e) => e.id == id);
    if (idx >= 0) {
      _contacts[idx] = stamped;
    } else {
      _contacts.add(stamped);
    }
    return _flush();
  }

  /// 删除联系人并连带删掉其聊天记录（与 legacy clearLog 同语义：历史没了，
  /// 派生数据不留残影）。
  bool deleteContact(String id) {
    final before = _contacts.length;
    _contacts.removeWhere((c) => c.id == id);
    if (_contacts.length == before) return true;
    _logs.remove(id);
    return _flush();
  }

  // -------------------------------------------------------------- Log CRUD

  /// 追加聊天记录，超出 [maxLogLines] 从最旧一端裁剪。空文本行直接过滤
  /// （legacy 同判：空白屏面不值得记）。contactId 为空是调用方错误，返回 false。
  bool appendLog(String contactId, List<LogEntry> entries) {
    if (contactId.isEmpty) return false;
    final clean = [
      for (final e in entries)
        if (e.text.trim().isNotEmpty) e,
    ];
    if (clean.isEmpty) return true;
    final list = _logs.putIfAbsent(contactId, () => <LogEntry>[]);
    list.addAll(clean);
    if (list.length > maxLogLines) {
      list.removeRange(0, list.length - maxLogLines);
    }
    return _flush();
  }

  /// 最新的 [n] 条，旧→新排列。
  List<LogEntry> recentLog(String contactId, int n) {
    if (n <= 0) return const <LogEntry>[];
    final list = _logs[contactId];
    if (list == null || list.isEmpty) return const <LogEntry>[];
    return list.length <= n
        ? List.of(list)
        : List.of(list.sublist(list.length - n, list.length));
  }

  int logSize(String contactId) => _logs[contactId]?.length ?? 0;

  /// 删除满足条件的行，返回删除条数。超越 legacy：legacy 只能整档清空，
  /// 这里支持按行删除（隐私清理：卡号、密码之类进过历史就要能删掉）。
  int removeLogWhere(String contactId, bool Function(LogEntry entry) test) {
    final list = _logs[contactId];
    if (list == null || list.isEmpty) return 0;
    final before = list.length;
    list.removeWhere(test);
    final dropped = before - list.length;
    if (dropped > 0) _flush();
    return dropped;
  }

  /// 删除 [days] 天前的记录（ts 早于 cutoff）；[now] 可注入以便测试。
  /// 返回删除条数；有删除才落盘。
  int pruneLog(String contactId, int days, {int? now}) {
    if (days <= 0) return 0;
    final list = _logs[contactId];
    if (list == null || list.isEmpty) return 0;
    final cutoff = (now ?? _now()) - days * 86400000;
    final before = list.length;
    list.removeWhere((e) => e.ts < cutoff);
    final dropped = before - list.length;
    if (dropped > 0) _flush();
    return dropped;
  }

  /// 清空某联系人的聊天记录；没有记录也返回 true（幂等）。
  bool clearLog(String contactId) {
    if (!_logs.containsKey(contactId)) return true;
    _logs.remove(contactId);
    return _flush();
  }

  // ------------------------------------------------------ 检索 + 评测钩子

  /// 全库检索 + 评测钩子。默认只搜未禁用的笔记（与注入事实一致，
  /// [includeDisabled] 可放开）。检索文本 = 标题 + 换行 + 内容；tags / type
  /// 只做过滤不打分。
  ///
  /// [logSearch] 为 true 时写一条 [SearchLogEntry]（query → 命中 id，按排名
  /// 序），超过 [maxSearchLog] 从最旧一端裁剪；传 [relevantIds] 则
  /// precision@k 直接入账 —— 这就是「供后续评测注入有效性」的钩子本体。
  LexSearchResult search(
    String query, {
    int k = 5,
    double minScore = 0.0,
    Iterable<String>? anyTag,
    Iterable<String>? anyType,
    Iterable<String>? relevantIds,
    bool includeDisabled = false,
    bool logSearch = true,
  }) {
    final docs = <LexDoc>[];
    for (final t in _notes) {
      if (!includeDisabled && !t.note.enabled) continue;
      docs.add(LexDoc(
        id: t.note.id,
        text: '${t.note.title}\n${t.note.content}',
        tags: t.note.tags,
        type: t.note.type,
      ));
    }
    Set<String>? rel;
    if (relevantIds != null) rel = Set<String>.of(relevantIds);
    final result = LexicalSearch.search(
      query,
      docs,
      k: k,
      minScore: minScore,
      anyTag: anyTag,
      anyType: anyType,
      relevantIds: rel,
    );

    if (logSearch) {
      _searchLog.add(SearchLogEntry(
        ts: _now(),
        query: query,
        k: k,
        hitIds: [for (final h in result.hits) h.id],
        anyTag: anyTag == null ? const <String>[] : List.of(anyTag),
        anyType: anyType == null ? const <String>[] : List.of(anyType),
        relevantIds: rel == null ? null : List.of(rel),
        precisionAtK: result.eval?.precisionAtK,
      ));
      if (_searchLog.length > maxSearchLog) {
        _searchLog.removeRange(0, _searchLog.length - maxSearchLog);
      }
      _flush();
    }
    return result;
  }

  /// 评测注入：事后给第 [index] 条 searchLog 补人工相关性标注并算 precision@k
  /// （分母为该次检索的实际命中数，与 [LexicalSearch] 口径一致）。
  /// 「先攒查询日志、攒够一批再统一标注」的评测流程用。越界返回 null。
  SearchLogEntry? annotateSearch(int index, Iterable<String> relevantIds) {
    if (index < 0 || index >= _searchLog.length) return null;
    final entry = _searchLog[index];
    final rel = Set<String>.of(relevantIds);
    var inTop = 0;
    for (final id in entry.hitIds) {
      if (rel.contains(id)) inTop++;
    }
    final precision = entry.hitIds.isEmpty ? 0.0 : inTop / entry.hitIds.length;
    final annotated = SearchLogEntry(
      ts: entry.ts,
      query: entry.query,
      k: entry.k,
      hitIds: List.of(entry.hitIds),
      anyTag: List.of(entry.anyTag),
      anyType: List.of(entry.anyType),
      relevantIds: List.of(rel),
      precisionAtK: precision,
    );
    _searchLog[index] = annotated;
    _flush();
    return annotated;
  }

  /// 检索评测日志（副本，旧→新）。
  List<SearchLogEntry> searchLog() => List.of(_searchLog);

  // ------------------------------------------------------------------ admin

  KbCounts counts() {
    var lines = 0;
    for (final list in _logs.values) {
      lines += list.length;
    }
    return KbCounts(
      notes: _notes.length,
      contacts: _contacts.length,
      logLines: lines,
    );
  }

  /// 清空全部知识库。有存档文件时连文件一起删（用户语义是「抹掉」；只删
  /// 存档文件本身，不碰目录里其它东西）。删不掉则退化为清空重写 —— 文件还在
  /// 但内容已空，语义仍成立。
  bool clearAll() {
    _notes.clear();
    _contacts.clear();
    _logs.clear();
    _searchLog.clear();
    final path = archivePath;
    if (path == null) return true;
    final file = File(path);
    if (!file.existsSync()) return true;
    try {
      file.deleteSync();
      lastFlushError = null;
      return true;
    } on FileSystemException catch (e) {
      lastFlushError = e.toString();
      return _flush();
    }
  }

  // ----------------------------------------------------- 序列化与持久化

  /// 存档文档（内存形态）。顶层 [kbArchiveSchemaVersion] 即 K-7 的版本字段。
  /// 只表达**当前实现**的格式版本；加载到更新版本时靠 [_flush] 拒绝落盘防
  /// 降级（见 [archiveSchemaVersion]），不走「照抄旧版本号」的假兼容。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': kbArchiveSchemaVersion,
        'savedAt': _now(),
        'notes': [
          for (final t in _notes)
            <String, dynamic>{
              'note': _noteToJson(t.note),
              'source': t.source,
              'importedAt': t.importedAt,
              'contentHash': t.contentHash,
            },
        ],
        'contacts': [for (final c in _contacts) _contactToJson(c)],
        'logs': <String, dynamic>{
          for (final e in _logs.entries)
            e.key: [for (final l in e.value) _logToJson(l)],
        },
        'searchLog': [for (final s in _searchLog) _searchLogToJson(s)],
      };

  /// 缩进版存档文本（人类可排查；这个量级体积不是瓶颈）。
  String encodeArchive() =>
      const JsonEncoder.withIndent('  ').convert(toJson());

  /// 解析存档文本。顶层不是 JSON 对象 → FormatException（那不是我们的存档，
  /// 宁可失败不可吞数据）；其余容错见 [fromJson]。
  static KbStore decodeArchive(
    String text, {
    String? archivePath,
    int maxLogLines = defaultMaxLogLines,
    int maxSearchLog = defaultMaxSearchLog,
  }) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw FormatException('存档顶层不是 JSON 对象');
    }
    return KbStore.fromJson(
      Map<String, dynamic>.from(decoded),
      archivePath: archivePath,
      maxLogLines: maxLogLines,
      maxSearchLog: maxSearchLog,
    );
  }

  /// 从文件读存档；文件不存在 → 空库（archivePath 已挂上，后续变更照常落盘）。
  /// 文件损坏 → FormatException 抛给调用方处置（legacy 的「挪开再重写」留给
  /// 上层决定：core 不该替用户把读不回来的数据当垃圾扔了）。
  factory KbStore.loadFromFileSync(
    String path, {
    int maxLogLines = defaultMaxLogLines,
    int maxSearchLog = defaultMaxSearchLog,
  }) {
    final file = File(path);
    if (!file.existsSync()) {
      return KbStore(
        archivePath: path,
        maxLogLines: maxLogLines,
        maxSearchLog: maxSearchLog,
      );
    }
    return KbStore.decodeArchive(
      file.readAsStringSync(encoding: utf8),
      archivePath: path,
      maxLogLines: maxLogLines,
      maxSearchLog: maxSearchLog,
    );
  }

  /// 容错规则（对 [fromJson] 生效）：
  ///
  ///  - `schemaVersion` 缺失 → 视为 1；比已知新 → 尽力解析已知字段
  ///    （**只读**向前兼容），未知字段忽略，加载到的版本号记入
  ///    [KbStore.archiveSchemaVersion] —— 后续 [_flush] 拒绝降级重写；
  ///  - 单条目损坏（不是 Map）→ 跳过该条，不影响其余；
  ///  - 笔记条目同时接受包裹式 `{"note": {...}}` 与裸字段式（W6 导入器的
  ///    过渡便利）；
  ///  - contentHash 载入时重算 —— hash 算法升级后旧档自愈；
  ///  - 缺 id 自动补、缺 enabled 视为启用、缺 type 回落 'note'。
  ///
  /// 顶层缺字段 / 条目损坏都容忍；只有「顶层不是对象」「schemaVersion 不是
  /// 数字」抛 FormatException —— 后者说明根本不是本格式的存档。
  factory KbStore.fromJson(
    Map<String, dynamic> json, {
    String? archivePath,
    int maxLogLines = defaultMaxLogLines,
    int maxSearchLog = defaultMaxSearchLog,
  }) {
    final store = KbStore(
      archivePath: archivePath,
      maxLogLines: maxLogLines,
      maxSearchLog: maxSearchLog,
    );

    final rawVersion = json['schemaVersion'];
    if (rawVersion != null && rawVersion is! num) {
      throw FormatException('存档 schemaVersion 不是数字：$rawVersion');
    }
    // 记住加载到的版本号：比已知新 → 只读向前兼容（_flush 拒绝降级重写，
    // 否则未知字段会在第一次落盘时静默丢失——见 [KbStore.archiveSchemaVersion]）。
    store.archiveSchemaVersion =
        rawVersion == null ? kbArchiveSchemaVersion : (rawVersion as num).toInt();

    final rawNotes = json['notes'];
    if (rawNotes is List) {
      for (final entry in rawNotes) {
        if (entry is! Map) continue;
        final m = Map<String, dynamic>.from(entry);
        final inner = m['note'];
        // 包裹式 / 裸字段式二选一。裸字段式必须至少带 id/title/content 之一，
        // 否则按损坏条目跳过 —— 否则任意杂散对象都会变成空笔记混进库。
        final noteMap = inner is Map ? Map<String, dynamic>.from(inner) : m;
        if (inner is! Map &&
            _str(noteMap['id']).isEmpty &&
            _str(noteMap['title']).isEmpty &&
            _str(noteMap['content']).isEmpty) {
          continue;
        }
        final note = _noteFromJson(noteMap);
        final source = _str(m['source']);
        store._notes.add(TrackedNote(
          note: note,
          source: source.isEmpty ? KbSource.manual : source,
          importedAt: _int(m['importedAt']),
          contentHash: kbContentFingerprint(note.content),
        ));
      }
    }

    final rawContacts = json['contacts'];
    if (rawContacts is List) {
      for (final entry in rawContacts) {
        if (entry is! Map) continue;
        store._contacts
            .add(_contactFromJson(Map<String, dynamic>.from(entry)));
      }
    }

    final rawLogs = json['logs'];
    if (rawLogs is Map) {
      rawLogs.forEach((key, value) {
        if (value is! List) return;
        final list = <LogEntry>[];
        for (final entry in value) {
          if (entry is! Map) continue;
          list.add(_logFromJson(Map<String, dynamic>.from(entry)));
        }
        store._logs[key.toString()] = list;
      });
    }

    final rawSearchLog = json['searchLog'];
    if (rawSearchLog is List) {
      for (final entry in rawSearchLog) {
        if (entry is! Map) continue;
        final m = Map<String, dynamic>.from(entry);
        final hitIds = <String>[];
        final rawHits = m['hitIds'];
        if (rawHits is List) {
          for (final h in rawHits) {
            if (h is String) hitIds.add(h);
          }
        }
        final rawRelevant = m['relevantIds'];
        final relevant = <String>[];
        if (rawRelevant is List) {
          for (final h in rawRelevant) {
            if (h is String) relevant.add(h);
          }
        }
        final precision = m['precisionAtK'];
        store._searchLog.add(SearchLogEntry(
          ts: _int(m['ts']),
          query: _str(m['query']),
          k: _int(m['k']),
          hitIds: hitIds,
          anyTag: _strList(m['anyTag']),
          anyType: _strList(m['anyType']),
          relevantIds: rawRelevant == null ? null : relevant,
          precisionAtK: precision is num ? precision.toDouble() : null,
        ));
      }
    }

    return store;
  }

  // ------------------------------------------------------------------ 内部

  bool _flush() {
    final path = archivePath;
    if (path == null) return true;
    if (archiveSchemaAhead) {
      // 向前兼容只到这里为止：比已知新的存档**绝不降级重写**。toJson 只认
      // 当前实现的字段，重写会把未来版本的数据（未知字段）静默丢掉——宁可
      // 停笔留痕（内存状态照常，见持久化策略），等 app 升级后恢复落盘。
      lastFlushError = '存档 schemaVersion $archiveSchemaVersion 比已知 '
          '$kbArchiveSchemaVersion 新：拒绝降级重写，未知字段不落盘（请升级应用）';
      return false;
    }
    try {
      _writeArchiveFileSync(path, encodeArchive());
      lastFlushError = null;
      return true;
    } on FileSystemException catch (e) {
      lastFlushError = e.toString();
      return false;
    }
  }

  /// 临时文件 + rename，崩溃不会留下半份存档（与 legacy 同款）。Windows 下
  /// Dart 的 rename 语义替换已存在目标；万一 rename 失败（跨盘 / 占用）退化
  /// 为复制覆写 —— 牺牲原子性保可用，与 legacy 的兜底一致。
  void _writeArchiveFileSync(String path, String text) {
    final file = File(path);
    final parent = file.parent;
    if (!parent.existsSync()) parent.createSync(recursive: true);
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync(text, encoding: utf8, flush: true);
    try {
      tmp.renameSync(path);
    } on FileSystemException {
      tmp.copySync(path);
      tmp.deleteSync();
    }
  }

  int _indexNote(String id) {
    for (var i = 0; i < _notes.length; i++) {
      if (_notes[i].note.id == id) return i;
    }
    return -1;
  }

  int _now() => DateTime.now().millisecondsSinceEpoch;

  /// 时间基 36 + 6 位随机 —— 纯 dart:core/math（core 零第三方依赖），个人库
  /// 量级下与 legacy 的 UUID 前 12 位同量级。
  static String newId() {
    final sb = StringBuffer(DateTime.now().microsecondsSinceEpoch
        .toRadixString(36));
    final rnd = math.Random();
    for (var i = 0; i < 6; i++) {
      sb.write(rnd.nextInt(36).toRadixString(36));
    }
    return sb.toString();
  }

  static Note _withId(Note n, String id) => Note(
        id: id,
        title: n.title,
        content: n.content,
        tags: List.of(n.tags),
        alwaysOn: n.alwaysOn,
        enabled: n.enabled,
        updatedAt: n.updatedAt,
        type: n.type,
      );

  static Map<String, dynamic> _noteToJson(Note n) => <String, dynamic>{
        'id': n.id,
        'title': n.title,
        'content': n.content,
        'tags': List.of(n.tags),
        'alwaysOn': n.alwaysOn,
        'enabled': n.enabled,
        'updatedAt': n.updatedAt,
        'type': n.type,
      };

  static Note _noteFromJson(Map<String, dynamic> m) {
    final id = _str(m['id']);
    final type = _str(m['type']);
    return Note(
      id: id.isEmpty ? newId() : id,
      title: _str(m['title']),
      content: _str(m['content']),
      tags: _strList(m['tags']),
      alwaysOn: m['alwaysOn'] == true,
      enabled: m['enabled'] != false, // 缺省视为启用
      updatedAt: _int(m['updatedAt']),
      type: type.isEmpty ? 'note' : type,
    );
  }

  static Map<String, dynamic> _contactToJson(Contact c) => <String, dynamic>{
        'id': c.id,
        'name': c.name,
        'aliases': List.of(c.aliases),
        'apps': List.of(c.apps),
        'relationship': c.relationship,
        'notes': c.notes,
        'persona': c.persona,
        'autoSummary': c.autoSummary,
        'updatedAt': c.updatedAt,
      };

  static Contact _contactFromJson(Map<String, dynamic> m) {
    final id = _str(m['id']);
    return Contact(
      id: id.isEmpty ? newId() : id,
      name: _str(m['name']),
      aliases: _strList(m['aliases']),
      apps: _strList(m['apps']),
      relationship: _str(m['relationship']),
      notes: _str(m['notes']),
      persona: _str(m['persona']),
      autoSummary: _str(m['autoSummary']),
      updatedAt: _int(m['updatedAt']),
    );
  }

  static Map<String, dynamic> _logToJson(LogEntry e) => <String, dynamic>{
        'side': e.side,
        'text': e.text,
        'ts': e.ts,
        'app': e.app,
      };

  static LogEntry _logFromJson(Map<String, dynamic> m) => LogEntry(
        side: _str(m['side']).isEmpty ? 'other' : _str(m['side']),
        text: _str(m['text']),
        ts: _int(m['ts']),
        app: _str(m['app']),
      );

  static Map<String, dynamic> _searchLogToJson(SearchLogEntry s) =>
      <String, dynamic>{
        'ts': s.ts,
        'query': s.query,
        'k': s.k,
        'hitIds': List.of(s.hitIds),
        if (s.anyTag.isNotEmpty) 'anyTag': List.of(s.anyTag),
        if (s.anyType.isNotEmpty) 'anyType': List.of(s.anyType),
        if (s.relevantIds != null) 'relevantIds': List.of(s.relevantIds!),
        if (s.precisionAtK != null) 'precisionAtK': s.precisionAtK,
      };

  static String _str(Object? v) =>
      v is String ? v : (v == null ? '' : v.toString());

  static int _int(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : (int.tryParse(_str(v)) ?? 0));

  static List<String> _strList(Object? v) => v is List
      ? [
          for (final e in v)
            if (e is String && e.trim().isNotEmpty) e,
        ]
      : const <String>[];
}

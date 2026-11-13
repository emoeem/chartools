/// MigrationSink 的 KbStore 落盘实现（W6，G8 确认后的唯一写库通路）。
///
/// 落盘契约定义在 `legacy_importer.dart:930-949`（[MigrationSink]），三条
/// 铁律从 legacy 的教训里来（对应 `docs/migration-design.md` §4.5）：
///
/// 1. **段级全或无**：一个确认段里任何一条写失败，整段回滚——已写进内存的
///    半截逐条撤掉、被覆盖的既有条目逐字恢复，绝不留半截；
/// 2. **失败即停**：失败以「返回 false + [MigrationSegmentReport.error] 带
///    原因与条目位置」如实上交，绝不吞成「部分成功」；跨段的「停止后续段」
///    是调用方（app 层 MigrationController）的职责，契约原文如此分工；
/// 3. **只收确认集**：本类只写调用方传入的列表，不自行增删改——冲突/重复
///    条目必须在预览阶段被用户裁决，没裁决的进不来。
///
/// ### 为什么落在 core 而不是 app 层
///
/// `docs/migration-design.md` §7 原计划「MigrationSink 的具体存储实现属于
/// app 层」；但存储本体 [KbStore] 就在 core（persona_kb/kb_store.dart），
/// 本实现只调用它的公开方法，零第三方依赖、零 dart:io——放在 core 旁边
/// 让三原则直接被 core 测试钉住（packages/core/test/migration_sink_test.dart），
/// app 层只负责构造与接线。这是对设计文档落点的一处有意修正，不是复刻。
///
/// ### 「段级原子」在本实现里的准确含义
///
/// KbStore 的持久化是「每次变更整份存档重写、单次重写 temp+rename 原子」
/// （kb_store.dart `_writeArchiveFileSync`）。本实现逐条 saveNote/saveContact，
/// 一段跨多次重写；**返回失败/异常路径**由内存回滚兜住（内存即真源，回滚后
/// 下一次成功落盘自然追平）；进程级硬崩理论上可能在存档里留下段前缀——
/// 要彻底的跨段原子得给 KbStore 加批量口（笔记侧的 importNotes 就是现成的
/// 单次落盘批量口，联系人侧没有）。按 ask 契约本实现走逐条 saveNote，
/// 该边界如实记录在案，不谎称「任何情况下都原子」。
///
/// ### 时间戳语义
///
/// 走 [KbStore.saveNote] 意味着笔记 updatedAt 盖为落盘时刻（编辑时间语义，
/// kb_store.dart:249 契约）；legacy 原时间不保真——原时间保真是 importNotes
/// 批量口的语义（kb_store.dart:288-290），这里按确认集逐条忠实执行的契约
/// 取 saveNote。联系人同理（saveContact 恒盖章，kb_store.dart:385）。
library;

import '../persona_kb/kb_models.dart';
import '../persona_kb/kb_store.dart';
import 'legacy_importer.dart';

/// 一个确认段（notes / contacts / personas）的落盘对账。
///
/// 「成功 N/失败 M」的口径：N = [written]，M = [pending]；[skippedExisting]
/// 是「内容已在库里」的幂等跳过（既不算成功也不算失败——重导同一段内容
/// 第二遍时它就是全部结果）；[deferred] 是「确认了但暂无落盘通路」的条数
/// （当前只有人设段）。[error] 非空 = 该段失败即停时的原因。
class MigrationSegmentReport {
  const MigrationSegmentReport({
    required this.label,
    required this.written,
    required this.skippedExisting,
    required this.pending,
    this.deferred = 0,
    this.error,
  });

  /// 段名（与源文件同名：notes.json / contacts.json / personas.json），
  /// 对账明细与 UI 直接引用。
  final String label;

  /// 成功写入（新增或按 id 更新）的条数。段失败整段回滚后**归零**——回滚
  /// 掉的条目不算成功（失败段的口径见 [_failedReport]）。
  final int written;

  /// 同 id 同内容已在库里、按幂等跳过的条数（不重写、不重盖 updatedAt）。
  final int skippedExisting;

  /// 用户确认了但没有落盘的条数：成功段为 0；失败段 = 全部确认数减幂等
  /// 跳过（整段回滚后确实一条都没落盘）。
  final int pending;

  /// 确认了但暂无落盘通路的条数（人设段：新版正式人设/专家库未接入）。
  final int deferred;

  /// 失败原因（段内第几条 + 什么错）；null = 该段成功。
  final String? error;

  bool get ok => error == null;

  @override
  String toString() =>
      '$label：写入 $written、跳过已存在 $skippedExisting、未落盘 $pending'
      '${deferred > 0 ? '、暂无通路 $deferred' : ''}'
      '${error == null ? '' : '，失败：$error'}';
}

/// 整次确认的对账：三个段各自的 [MigrationSegmentReport] 合总。
class MigrationApplyReport {
  const MigrationApplyReport({
    required this.notes,
    required this.contacts,
    required this.personas,
  });

  final MigrationSegmentReport notes;
  final MigrationSegmentReport contacts;
  final MigrationSegmentReport personas;

  /// 全部段都成功（无 error）才算成功——部分成功不算成功（原则 2）。
  bool get ok => notes.ok && contacts.ok && personas.ok;

  int get writtenTotal => notes.written + contacts.written + personas.written;
  int get skippedTotal =>
      notes.skippedExisting + contacts.skippedExisting + personas.skippedExisting;
  int get pendingTotal => notes.pending + contacts.pending + personas.pending;
  int get deferredTotal =>
      notes.deferred + contacts.deferred + personas.deferred;

  /// 第一个失败原因（跨段按 notes → contacts → personas 顺序）。
  String? get firstError => notes.error ?? contacts.error ?? personas.error;

  /// 一句话对账（「成功 N/失败 M」口径 + 跳过/暂无通路如实另列）。
  String describe() {
    final parts = <String>['成功写入 $writtenTotal 条'];
    if (skippedTotal > 0) parts.add('跳过已存在 $skippedTotal 条');
    if (deferredTotal > 0) parts.add('暂无落盘通路 $deferredTotal 条（人设段）');
    if (pendingTotal > 0) parts.add('失败 $pendingTotal 条');
    final sb = StringBuffer(parts.join('，'));
    sb.write('。');
    if (firstError != null) sb.write('失败原因：$firstError');
    return sb.toString();
  }
}

/// 段内单条的尝试结果（内部搬运用）。[undo] 是这条的回滚闭包：成功写入的
/// 条目靠它在段尾失败时恢复写前状态；幂等跳过的条目没动过库，不需要。
typedef _SegmentAttempt = ({
  bool written,
  bool skipped,
  String? error,
  void Function()? undo,
});

/// [MigrationSink] 的 KbStore 实现：把确认集写进知识库存档。
///
/// 用法（G8 时序，缺一步都算违约）：parse → [MigrationPreview] → 用户确认
/// → 把确认集交给本类的三个 apply 方法。本类不持有也不校验「确认」这个
/// 动作本身——那是 UI/控制器的责任（见 legacy_importer.dart:930 头注释）。
class KbStoreSink implements MigrationSink {
  /// [store] 由外部注入（生产路径带 archivePath，测试注入纯内存实例）。
  KbStoreSink(this._store);

  final KbStore _store;

  // ------------------------------------------------- MigrationSink 契约

  @override
  Future<bool> applyNotes(List<Note> items) async =>
      (await applyNotesDetailed(items)).ok;

  @override
  Future<bool> applyContacts(List<Contact> items) async =>
      (await applyContactsDetailed(items)).ok;

  @override
  Future<bool> applyPersonas(List<ImportedPersona> items) async =>
      (await applyPersonasDetailed(items)).ok;

  // ------------------------------------------------------- 详细对账入口

  /// 笔记段：逐条 saveNote（source: manual → **import**，出处属于创建时刻，
  /// 迁移来源在知识库页的来源标签里如实可见）。失败整段回滚、原因带条目号。
  Future<MigrationSegmentReport> applyNotesDetailed(List<Note> items) async =>
      _applyAll('notes.json', items, _attemptNote);

  /// 联系人段：逐条 saveContact。失败整段回滚（含日志行快照回补）。
  Future<MigrationSegmentReport> applyContactsDetailed(
          List<Contact> items) async =>
      _applyAll('contacts.json', items, _attemptContact);

  /// 人设段：**暂无落盘通路**。KbStore 只有 notes/contacts/logs 三类
  /// （kb_store.dart 头注释），新版正式人设/专家库按「按需资产包」另工作流
  /// 交付；[ImportedPersona] 目前是迁移契约记录（legacy_importer.dart:577-618），
  /// 全字段无损地留在预览明细里。这里不写任何东西、也**不谎报失败**：
  /// 返回成功 + deferred 计数，对账与 UI 如实显示「暂无落盘通路」，等正式
  /// 库定稿后由新的 sink 实现接管。
  Future<MigrationSegmentReport> applyPersonasDetailed(
      List<ImportedPersona> items) async {
    return MigrationSegmentReport(
      label: 'personas.json',
      written: 0,
      skippedExisting: 0,
      pending: 0,
      deferred: items.length,
    );
  }

  // ------------------------------------------------------------- 段执行器

  /// 三原则 1/2 的机械落实：逐条尝试，任何一条报错 → 回滚已写的每一条
  /// （含出错那条已进内存的半截）→ 立即停止（后续条目不尝试）→ 带条目号
  /// 返回错误。全段走完 → 成功对账。
  MigrationSegmentReport _applyAll<T>(
    String label,
    List<T> items,
    _SegmentAttempt Function(T item, int index) attempt,
  ) {
    var written = 0;
    var skipped = 0;
    final undos = <void Function()>[];
    final rollbackNotes = <String>[];
    for (var i = 0; i < items.length; i++) {
      _SegmentAttempt a;
      try {
        a = attempt(items[i], i);
      } catch (e) {
        // attempt 自身炸了（库状态异常等）也按失败处理：此刻没有本条的 undo
        // （还没拿到尝试结果），回滚已有的已写条目，然后停。
        _runUndos(undos, rollbackNotes);
        return _failedReport(
            label, items.length, skipped, rollbackNotes, '第 ${i + 1} 条写入前检查失败：$e');
      }
      if (a.error != null) {
        // 出错那条可能已写进内存半截（saveNote 内存生效、落盘失败），它的
        // undo 一并执行；倒序回滚（后写的先撤，前写条目的恢复不受干扰）。
        if (a.undo != null) undos.add(a.undo!);
        _runUndos(undos, rollbackNotes);
        return _failedReport(
            label, items.length, skipped, rollbackNotes, '第 ${i + 1} 条：${a.error}');
      }
      if (a.skipped) skipped++;
      if (a.written) {
        written++;
        if (a.undo != null) undos.add(a.undo!);
      }
    }
    return MigrationSegmentReport(
      label: label,
      written: written,
      skippedExisting: skipped,
      pending: 0,
    );
  }

  /// 失败段的段级对账（三原则 1 的对账面）：段级全或无——回滚之后本段
  /// **没有任何一条**留在库里（幂等跳过的条目没动过库，仍按跳过计），所以
  /// written 恒 0、pending = 确认数 − 跳过数。「写过又被回滚」绝不进成功数
  /// ——对账给的是这段结束时的**事实**（库里多了什么），不是过程量；把回滚
  /// 掉的条目报成「成功写入」会让结果页谎报。
  MigrationSegmentReport _failedReport(String label, int total, int skipped,
      List<String> rollbackNotes, String error) {
    return MigrationSegmentReport(
      label: label,
      written: 0,
      skippedExisting: skipped,
      pending: total - skipped,
      error: _withRollbackNotes(error, rollbackNotes),
    );
  }

  /// 倒序执行回滚闭包。回滚自身失败不吞：原因并进段错误，绝不把「没回滚干净」
  /// 伪装成「已回滚」。
  void _runUndos(List<void Function()> undos, List<String> notes) {
    for (final undo in undos.reversed) {
      try {
        undo();
      } catch (e) {
        notes.add('回滚失败：$e');
      }
    }
    undos.clear();
  }

  String _withRollbackNotes(String error, List<String> rollbackNotes) =>
      rollbackNotes.isEmpty ? error : '$error；回滚时另有问题：${rollbackNotes.join('；')}';

  // ----------------------------------------------------------- 笔记段

  _SegmentAttempt _attemptNote(Note n, int index) {
    // 幂等重导：同 id 同内容已在库里 → 不重写、不重盖 updatedAt，记跳过。
    // （重导同一份迁移包是正常操作；再写一遍除了把 updatedAt 盘活没有收益。）
    final before = _store.note(n.id);
    if (before != null &&
        before.note.title == n.title &&
        before.note.content == n.content) {
      return (written: false, skipped: true, error: null, undo: null);
    }
    void undo() => _restoreNote(n.id, before);
    try {
      // source: manual → import：出处属于创建时刻（kb_store.dart:11-12、
      // KbSource 文档），迁移进来的笔记从这一刻起带 import 标注与 importedAt
      // 盖章——知识库页的来源标签如实显示，与手写笔记永不混淆。
      final ok = _store.saveNote(n, source: KbSource.import);
      if (!ok) {
        // saveNote 内存已生效、落盘失败：内存即真源（kb_store.dart 头注释），
        // undo 会把这条半截从内存撤掉；原因取 lastFlushError，绝不吞成成功。
        return (
          written: false,
          skipped: false,
          error: '存档落盘失败：${_store.lastFlushError ?? '原因未知'}',
          undo: undo,
        );
      }
      return (written: true, skipped: false, error: null, undo: undo);
    } catch (e) {
      return (written: false, skipped: false, error: '$e', undo: undo);
    }
  }

  /// 把 id 为 [id] 的笔记恢复到写前状态。[before] 为 null = 写前不存在，
  /// 撤掉即恢复；非 null = 写前存在（被按 id 覆盖），恢复原条目。
  void _restoreNote(String id, TrackedNote? before) {
    // 第一步无条件删：撤掉这条的半截/整条写入（deleteNote 幂等，没删到也算成功）。
    _store.deleteNote(id);
    if (before == null) return;
    // 恢复优先走 importNotes：updatedAt > 0 原样保留、source/importedAt 显式
    // 带回——逐字节回到写前状态。库里恰有**另一条**同内容笔记时 importNotes
    // 会判重拒收（导入去重语义），退回 saveNote 无条件按 id 覆写（保 source，
    // updatedAt 盖为回滚时刻——公开 API 下的既定代价，正文逐字回原）。
    final report = _store.importNotes(
      [before.note],
      source: before.source,
      importedAt: before.importedAt,
    );
    if (report.added.isEmpty && report.updated.isEmpty) {
      _store.saveNote(
        before.note,
        source: before.source,
        importedAt: before.importedAt,
      );
    }
  }

  // ----------------------------------------------------------- 联系人段

  _SegmentAttempt _attemptContact(Contact c, int index) {
    final before = _store.contact(c.id);
    // deleteContact 连带清聊天日志（kb_store.dart:407-409 契约）——回滚要把
    // 日志行也补回去，所以写前先把该 id 的日志快照下来（appendLog 最多留
    // maxLogLines 行，快照取同一上限即全量）。
    final logsBefore = _store.recentLog(c.id, _store.maxLogLines);
    // 幂等重导：同 id 同内容已在库里 → 跳过（判据与预览的内容口径一致：
    // 名字/别名/关系/备注等正文字段；apps/aliases 逐位比对）。
    if (before != null && _sameContactContent(before, c)) {
      return (written: false, skipped: true, error: null, undo: null);
    }
    void undo() => _restoreContact(c.id, before, logsBefore);
    try {
      final ok = _store.saveContact(c);
      if (!ok) {
        return (
          written: false,
          skipped: false,
          error: '存档落盘失败：${_store.lastFlushError ?? '原因未知'}',
          undo: undo,
        );
      }
      return (written: true, skipped: false, error: null, undo: undo);
    } catch (e) {
      return (written: false, skipped: false, error: '$e', undo: undo);
    }
  }

  void _restoreContact(String id, Contact? before, List<LogEntry> logsBefore) {
    _store.deleteContact(id);
    if (before != null) {
      // saveContact 恒盖 updatedAt（kb_store.dart:385 契约），联系人没有
      // importNotes 那样的保真批量口——回滚恢复的既有联系人 updatedAt 被
      // 盖为回滚时刻，这是公开 API 下的既定代价；内容/别名/关系等正文字段
      // 逐字回原。
      _store.saveContact(before);
    }
    if (logsBefore.isNotEmpty) {
      // 日志残影清零：把写前快照按原序补回（appendLog 保持旧→新排列）。
      _store.appendLog(id, logsBefore);
    }
  }

  /// 联系人「内容相同」的判据：正文字段全等。updatedAt 是编辑时间，不参与
  /// （重导同一份迁移包不该因为时间戳不同而被判成两条不同内容）。
  static bool _sameContactContent(Contact a, Contact b) =>
      a.name == b.name &&
      _stringListSame(a.aliases, b.aliases) &&
      _stringListSame(a.apps, b.apps) &&
      a.relationship == b.relationship &&
      a.notes == b.notes &&
      a.persona == b.persona &&
      a.autoSummary == b.autoSummary;

  static bool _stringListSame(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

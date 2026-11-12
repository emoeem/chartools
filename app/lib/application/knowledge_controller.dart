/// 知识库管理控制器（M2）—— KnowledgePage 的数据面，包住 core 的 [KbStore]。
///
/// 分层：KbStore（core：同步 CRUD + BM25 检索 + 评测日志 + 存档持久化）→
/// 本控制器（app：Notifier 状态面 + 浏览过滤 + UI 语义动作）→
/// KnowledgePage（ui：纯展示与交互）。
///
/// **main 接线留 #13：设置页入口 + KbStore 实例注入** —— 本类不 import
/// main.dart，也不自建 KbStore：构造注入由调用方完成（生产路径给带
/// archivePath 的 KbStore.loadFromFileSync(...)，测试注入纯内存实例
/// `KbStore()`）。联系人档案的管理 UI 归 PersonasPage（W5），本控制器只
/// 暴露其增删改查 API。
///
/// 检索命中评测数据透出（#12 超越点的 UI 落地）：
/// - [retrieve] 走 KbStore.search（LexicalSearch BM25），每次提交写一条
///   SearchLogEntry（query → 命中 id，按排名序）；
/// - [searchLog] / [searchCount] / [lastRetrieval] 三个 Notifier 把日志全量、
///   次数、最近一次命中（含 per-term 得分分解「为什么命中」）透出给 UI；
/// - [annotateRetrieval] 把人工相关性标注回写进日志并算出 precision@k ——
///   「先攒数据说话，再决定是否升级向量检索」的评测钩子从存储层一路通到页面。
library;

import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/foundation.dart';

/// 一次 BM25 检索在 UI 层的透出形态：命中列表 + 为什么命中 + 人工标注。
class RetrievalOutcome {
  const RetrievalOutcome({
    required this.logIndex,
    required this.query,
    required this.result,
    this.annotated,
  });

  /// 本次检索在检索评测日志里的下标（[KnowledgeController.annotateRetrieval]
  /// 按它定位要标注的那条）。
  final int logIndex;

  /// 检索词原样（透出回显用）。
  final String query;

  /// BM25 检索结果：hits best-first，每个 [ScoredDoc.terms] 是 per-term 得分
  /// 分解（来源追踪：这条为什么命中）。
  final LexSearchResult result;

  /// 人工标注后的日志条目（null = 还没标注过）。
  final SearchLogEntry? annotated;

  /// precision@k 当前口径：已标注用标注值（分母为实际命中数，与 LexicalSearch
  /// 的 RetrievalEval 口径一致）；未标注时若检索自带 eval（传入过 relevantIds）
  /// 用之，否则 null —— 提示用户「还没标注，不构成评测数据」。
  double? get precisionAtK =>
      annotated?.precisionAtK ?? result.eval?.precisionAtK;
}

/// 一个标签 + 全库引用计数：标签筛选 chips 与标签管理对话框的数据源。
class TagStat {
  const TagStat(this.tag, this.count);

  final String tag;
  final int count;
}

/// 知识库管理控制器。
class KnowledgeController {
  /// [store] 必须由外部构造注入（见类文档：main 接线留 #13）。
  KnowledgeController(this._store) {
    _refresh();
  }

  final KbStore _store;

  // ------------------------------------------------------------- 状态面

  /// 全部笔记（[TrackedNote] 带 source/importedAt 出处），updatedAt 新的在前。
  final ValueNotifier<List<TrackedNote>> notes =
      ValueNotifier(const <TrackedNote>[]);

  /// 全部联系人档案（core 的 Contact）。管理 UI 归 PersonasPage（W5），
  /// 这里先暴露增删改查的状态面。
  final ValueNotifier<List<Contact>> contacts =
      ValueNotifier(const <Contact>[]);

  /// 搜索框实时过滤词。**浏览过滤**，不进检索评测日志 —— 它只筛列表；
  /// 真正的 BM25 检索走 [retrieve]（提交动作），二者分工见 [retrieve] 文档。
  final ValueNotifier<String> query = ValueNotifier('');

  /// 标签筛选 chips 当前选中的标签集合（多选 OR 语义，见 [_recomputeVisible]）。
  final ValueNotifier<Set<String>> selectedTags = ValueNotifier(<String>{});

  /// 实时过滤（[query] × [selectedTags]）之后的可见笔记，列表直接消费。
  /// 被禁用的笔记**仍然可见** —— 管理页要能找回并重新启用它们。
  final ValueNotifier<List<TrackedNote>> visibleNotes =
      ValueNotifier(const <TrackedNote>[]);

  /// 全库标签统计（引用数降序、同数按名升序）：chips 行与标签管理的数据源。
  final ValueNotifier<List<TagStat>> tagStats =
      ValueNotifier(const <TagStat>[]);

  // ------------------------------------------------- 检索评测数据透出

  /// 检索评测日志全量（旧→新副本，来自 KbStore.searchLog）。
  final ValueNotifier<List<SearchLogEntry>> searchLog =
      ValueNotifier(const <SearchLogEntry>[]);

  /// 检索次数 = 评测日志条数（统计行「检索 K 次」直接读；实时过滤不计入）。
  final ValueNotifier<int> searchCount = ValueNotifier(0);

  /// 最近一次 BM25 检索的完整透出（null = 本次会话还没做过检索）。
  final ValueNotifier<RetrievalOutcome?> lastRetrieval = ValueNotifier(null);

  /// 最近一次写盘失败的原因（null = 正常）。KbStore 落盘失败不回滚内存
  /// （内存即真源），这里透出成页面顶部的一条降级提示，而不是静默。
  final ValueNotifier<String?> flushError = ValueNotifier(null);

  // ------------------------------------------------------------ 浏览过滤

  /// 搜索框实时过滤（输入即筛，不写检索日志）。命中范围：标题 + 内容 + 标签，
  /// 大小写不敏感的子串匹配 —— 浏览场景「看着像就能搜到」比 BM25 更可预期。
  void setQuery(String q) {
    query.value = q;
    _recomputeVisible();
  }

  /// 点按一个标签 chip：已选中则取消，否则加入筛选（多选 OR）。
  void toggleTagFilter(String tag) {
    final next = Set.of(selectedTags.value);
    // Set.add 对已存在元素返回 false —— 用它一步完成「加了就删、没加就加」。
    if (!next.add(tag)) next.remove(tag);
    selectedTags.value = next;
    _recomputeVisible();
  }

  /// 清空全部浏览筛选（查询词 + 标签选中）。空态页的「清除筛选」按钮用。
  void clearFilters() {
    query.value = '';
    selectedTags.value = <String>{};
    _recomputeVisible();
  }

  // ------------------------------------------------------------ 笔记 CRUD

  /// 新建手写笔记（source = manual，见 [KbSource]）。id 由控制器生成再交给
  /// saveNote —— 返回新笔记 id，让「新建后若被筛选挡住则清筛选」有据可依。
  /// 落盘失败不改变返回值（内存已生效），失败原因透出到 [flushError]。
  String createNote({
    String title = '',
    required String content,
    List<String> tags = const [],
    bool alwaysOn = false,
  }) {
    final id = KbStore.newId();
    _mutate(_store.saveNote(Note(
      id: id,
      title: title.trim(),
      content: content.trim(),
      tags: List.of(tags),
      alwaysOn: alwaysOn,
      enabled: true,
      type: 'note',
    )));
    return id;
  }

  /// 用编辑后的 [Note] 整体替换同 id 条目。出处（source/importedAt）由
  /// KbStore 保留 —— 出处属于创建时刻，改内容不改出身。
  bool updateNote(Note note) => _mutate(_store.saveNote(note));

  /// 启用/停用开关。停用的笔记不进检索与注入，但管理页仍然可见可找回。
  bool setNoteEnabled(String id, bool enabled) {
    final tracked = _store.note(id);
    if (tracked == null) return false;
    return _mutate(_store.saveNote(_copyNote(tracked.note, enabled: enabled)));
  }

  /// 删除笔记（幂等，与 legacy 同判）。
  bool deleteNote(String id) => _mutate(_store.deleteNote(id));

  /// KbStore.importNotes 的透传：文档导入（W2）与 ZIP 迁移（W6）的入库口。
  /// 来源标签 manual|import|doc 里的 import / doc 由此产生；本页 UI 不提供
  /// 导入入口，挂哪个页面由 #13 接线时决定。
  ImportReport importNotes(List<Note> incoming,
      {String source = KbSource.doc}) {
    final report = _store.importNotes(incoming, source: source);
    _refresh();
    return report;
  }

  // ------------------------------------------------------------ 标签管理

  /// 全库重命名一个标签：所有持有 [from] 的笔记换成 [to]；撞上已有标签时
  /// 合并去重（无重复 tag）。筛选态里的旧名同步跟过去。
  /// 逐条 saveNote —— 个人库量级可接受；批量改走 importNotes 的单次落盘路径。
  bool renameTag(String from, String to) {
    final f = from.trim();
    final t = to.trim();
    if (f.isEmpty || t.isEmpty || f == t) return false;
    var changed = false;
    for (final tracked in _store.notes()) {
      final tags = tracked.note.tags;
      if (!tags.contains(f)) continue;
      final next = <String>{
        for (final tag in tags) tag == f ? t : tag,
      }.toList(growable: false);
      _store.saveNote(_copyNote(tracked.note, tags: List.of(next)));
      changed = true;
    }
    if (changed) {
      _retagSelection(f, t);
      _refresh();
    }
    return changed;
  }

  /// 全库删除一个标签（所有持有它的笔记都去掉，笔记本身不动）。
  /// 标签不是内容，删了可手动重建，所以不做二次确认。
  bool removeTagEverywhere(String tag) {
    final t = tag.trim();
    if (t.isEmpty) return false;
    var changed = false;
    for (final tracked in _store.notes()) {
      if (!tracked.note.tags.contains(t)) continue;
      _store.saveNote(_copyNote(
        tracked.note,
        tags: [
          for (final tag in tracked.note.tags)
            if (tag != t) tag
        ],
      ));
      changed = true;
    }
    if (changed) {
      if (selectedTags.value.contains(t)) {
        selectedTags.value = <String>{...selectedTags.value}..remove(t);
      }
      _refresh();
    }
    return changed;
  }

  // ---------------------------------------------------------- 联系人 CRUD

  /// 新建联系人档案（core 的 Contact；字段语义见 kb_models.dart）。
  bool createContact({
    required String name,
    List<String> aliases = const [],
    List<String> apps = const [],
    String relationship = '',
    String persona = '',
    String notes = '',
  }) {
    return _mutate(_store.saveContact(Contact(
      id: '',
      name: name.trim(),
      aliases: List.of(aliases),
      apps: List.of(apps),
      relationship: relationship,
      persona: persona,
      notes: notes,
    )));
  }

  /// 用编辑后的 [Contact] 整体替换同 id 条目（updatedAt 由 KbStore 盖章）。
  bool updateContact(Contact contact) => _mutate(_store.saveContact(contact));

  /// 删除联系人（连带其聊天记录，幂等）。
  bool deleteContact(String id) => _mutate(_store.deleteContact(id));

  // ------------------------------------------------------ 检索 + 评测钩子

  /// BM25 检索（LexicalSearch，经 KbStore.search）+ 评测日志。
  ///
  /// 与 [setQuery] 的分工：**输入过程中的过滤是浏览**（子串匹配，不落日志，
  /// 次数不涨）；**回车/点放大镜的提交是检索**（BM25 打分，写一条
  /// SearchLogEntry，检索次数 +1）—— 次数统计的是「真的拿这批词去问过检索
  /// 器」的次数，浏览行为不污染评测数据。
  ///
  /// 默认只搜未禁用的笔记（与注入事实一致）；k 默认 5（与 legacy 同值）。
  RetrievalOutcome retrieve(String query, {int k = 5}) {
    final result = _store.search(query, k: k, logSearch: true);
    final outcome = RetrievalOutcome(
      // search(logSearch: true) 恰好追加一条日志，尾下标即本次。
      logIndex: _store.searchLog().length - 1,
      query: query,
      result: result,
    );
    lastRetrieval.value = outcome;
    _refresh();
    return outcome;
  }

  /// 评测标注：给某条检索日志注入人工相关 id（页面「标为相关」收敛后的
  /// 集合），KbStore 算出 precision@k 写回日志。标注空集也是有效数据
  /// （「看过这些命中，都不相关」→ precision 0）。越界返回 null。
  SearchLogEntry? annotateRetrieval(int logIndex, Set<String> relevantIds) {
    final entry = _store.annotateSearch(logIndex, relevantIds);
    if (entry == null) return null;
    final last = lastRetrieval.value;
    if (last != null && last.logIndex == logIndex) {
      // 重建透出对象：annotated 换新、命中列表原样 —— precision 从 annotated
      // 读，UI 的 ValueListenableBuilder 因此刷新。
      lastRetrieval.value = RetrievalOutcome(
        logIndex: logIndex,
        query: last.query,
        result: last.result,
        annotated: entry,
      );
    }
    _refresh();
    return entry;
  }

  /// 收起检索评测卡（页面关闭按钮）。
  void clearRetrieval() {
    lastRetrieval.value = null;
  }

  /// 检索命中卡显示用：id → 标题（查不到 = 笔记已删除，显示占位而非空串）。
  String noteTitleOf(String id) => _store.note(id)?.note.title ?? '（已删除）';

  // ------------------------------------------------------------------ 内部

  /// 所有改库动作的统一收口：同步写盘状态 + 重灌全部 Notifier。
  bool _mutate(bool ok) {
    _syncFlush(ok);
    _refresh();
    return ok;
  }

  void _syncFlush(bool ok) {
    // KbStore 落盘失败不回滚内存（内存即真源）：把 lastFlushError 透出成
    // 页面顶部的降级提示，而不是让用户带着「已保存」的错觉离开。
    flushError.value = ok ? null : (_store.lastFlushError ?? '写盘失败（原因未知）');
  }

  /// 从 KbStore 重灌全部状态面。列表按 updatedAt 降序（最近改的排最上），
  /// 同毫秒按 id 决胜保持稳定序。
  void _refresh() {
    final all = _store.notes()
      ..sort((a, b) {
        final byTime = b.note.updatedAt.compareTo(a.note.updatedAt);
        return byTime != 0 ? byTime : a.note.id.compareTo(b.note.id);
      });
    notes.value = all;
    contacts.value = _store.contacts();
    tagStats.value = _countTags(all);
    searchLog.value = _store.searchLog();
    searchCount.value = searchLog.value.length;
    _recomputeVisible();
  }

  /// 可见性 = 标签选中（OR，未选不设限）AND 查询词子串（未输入不设限）。
  void _recomputeVisible() {
    final q = query.value.trim().toLowerCase();
    final selected = selectedTags.value;
    final result = <TrackedNote>[];
    for (final tracked in notes.value) {
      final note = tracked.note;
      if (selected.isNotEmpty && !note.tags.any(selected.contains)) continue;
      if (q.isNotEmpty) {
        final haystack =
            '${note.title}\n${note.content}\n${note.tags.join('\n')}'
                .toLowerCase();
        if (!haystack.contains(q)) continue;
      }
      result.add(tracked);
    }
    visibleNotes.value = result;
  }

  List<TagStat> _countTags(List<TrackedNote> trackedNotes) {
    final counts = <String, int>{};
    for (final tracked in trackedNotes) {
      for (final tag in tracked.note.tags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    final stats = <TagStat>[
      for (final entry in counts.entries) TagStat(entry.key, entry.value),
    ];
    stats.sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0 ? byCount : a.tag.compareTo(b.tag);
    });
    return stats;
  }

  /// 筛选选中集里的旧标签名换成新名（renameTag 用；没有就不动）。
  void _retagSelection(String from, String to) {
    if (selectedTags.value.contains(from)) {
      selectedTags.value = <String>{
        for (final tag in selectedTags.value) tag == from ? to : tag,
      };
    }
  }

  /// Note 全字段拷贝。kb_models.Note.copyWith 只开放 tags（core 侧刻意收窄），
  /// 出处/启停/常驻的编辑在这里显式展开，避免「copyWith 改不动」的坑。
  static Note _copyNote(
    Note n, {
    String? title,
    String? content,
    List<String>? tags,
    bool? enabled,
    bool? alwaysOn,
    String? type,
  }) =>
      Note(
        id: n.id,
        title: title ?? n.title,
        content: content ?? n.content,
        tags: tags ?? List.of(n.tags),
        alwaysOn: alwaysOn ?? n.alwaysOn,
        enabled: enabled ?? n.enabled,
        updatedAt: n.updatedAt,
        type: type ?? n.type,
      );

  void dispose() {
    notes.dispose();
    contacts.dispose();
    query.dispose();
    selectedTags.dispose();
    visibleNotes.dispose();
    tagStats.dispose();
    searchLog.dispose();
    searchCount.dispose();
    lastRetrieval.dispose();
    flushError.dispose();
  }
}

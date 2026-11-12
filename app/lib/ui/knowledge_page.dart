/// 知识库管理页（M2）：搜索实时过滤 + 笔记列表（标题/内容预览/启用开关/
/// 来源标签 manual|import|doc）+ 新建/编辑对话框 + 标签筛选 chips +
/// 统计行（总条数/启用数/检索次数）+ 检索评测透出。
///
/// ChatGPT 报告的建议（知识库是核心入口，不该藏在模型参数里）：本页是
/// 一等页面 —— 独立入口、完整管理面，而不是模型参数里的一个子区块。
///
/// **main 接线留 #13：设置页入口 + KbStore 实例注入** —— 本文件不 import
/// main.dart，也不自建 KbStore / KnowledgeController；构造注入由 #13 完成
/// （例如 `KnowledgePage(controller: KnowledgeController(
///   KbStore.loadFromFileSync(<数据目录>/kb.json)))`）。本页是 body-only
/// 组件（无 Scaffold），方便 #13 嵌进路由、设置页或桌面助手侧栏。
///
/// 检索评测透出（#12 超越点）：搜索框**输入**做实时过滤（浏览，不落日志），
/// **提交**（回车/放大镜）触发 BM25 检索（LexicalSearch，经 KbStore.search
/// 落评测日志）→ 命中卡显示命中项与 per-term「为什么命中」分解 → 对命中项
/// 点「相关」做人工标注 → precision@k 写回检索日志。注入有效性的评测数据
/// 从存储层一路透出到页面。
library;

import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/material.dart';

import '../application/knowledge_controller.dart';

/// 知识库管理页。
class KnowledgePage extends StatefulWidget {
  const KnowledgePage({super.key, required this.controller});

  /// 控制器由外部构造注入（main 接线留 #13：设置页入口 + KbStore 实例注入）。
  final KnowledgeController controller;

  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage> {
  late final TextEditingController _searchCtrl;

  /// 当前评测卡上的人工「相关」标注集（按 [RetrievalOutcome.logIndex] 归属；
  /// 换了一次检索就清空重新标）。
  final Set<String> _relevantMarks = <String>{};
  int _relevantLogIndex = -1;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController();
    // 输入即浏览过滤：文本框是 query 的唯一书写端，直接灌进控制器。
    _searchCtrl.addListener(() => widget.controller.setQuery(_searchCtrl.text));
    // 检索透出变化时维护标注归属：换检索清空旧标注，同一检索的标注刷新
    // （annotateRetrieval 重建 outcome）不清 —— 否则刚点的「相关」会被抹掉。
    widget.controller.lastRetrieval.addListener(_onRetrievalChanged);
  }

  void _onRetrievalChanged() {
    final outcome = widget.controller.lastRetrieval.value;
    if (outcome == null || outcome.logIndex != _relevantLogIndex) {
      _relevantMarks.clear();
      _relevantLogIndex = outcome?.logIndex ?? -1;
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.controller.lastRetrieval.removeListener(_onRetrievalChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- 动作

  void _submitRetrieval() {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) {
      // 空词不算检索：把上一张评测卡收起来即可，不写日志。
      widget.controller.clearRetrieval();
      return;
    }
    widget.controller.retrieve(q);
  }

  void _toggleRelevantMark(RetrievalOutcome outcome, String id) {
    setState(() {
      if (!_relevantMarks.add(id)) _relevantMarks.remove(id);
    });
    // 空集也是有效标注（「都不相关」→ precision 0，见控制器文档）。
    widget.controller.annotateRetrieval(outcome.logIndex, _relevantMarks);
  }

  Future<void> _openEditor({TrackedNote? existing}) async {
    final createdId = await showDialog<String>(
      context: context,
      builder: (_) => _NoteEditorDialog(
        controller: widget.controller,
        tracked: existing,
      ),
    );
    if (!mounted) return;
    // 新建成功但被当前筛选挡住 → 清筛选：刚保存的笔记必须立刻可见，
    // 不然「点了保存列表没动静」会被误读成没保存成功（核心入口要直给）。
    if (createdId != null && createdId.isNotEmpty) {
      final visible = widget.controller.visibleNotes.value
          .any((t) => t.note.id == createdId);
      if (!visible) {
        _searchCtrl.clear();
        widget.controller.clearFilters();
      }
    }
  }

  Future<void> _showTagManager() {
    return showDialog<void>(
      context: context,
      builder: (_) => _TagManagerDialog(controller: widget.controller),
    );
  }

  // ------------------------------------------------------------- 布局

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        _buildSearchField(context),
        _buildTagChips(context),
        _buildStatsRow(context),
        _buildFlushError(context),
        _buildEvalCard(context),
        Expanded(child: _buildNoteList(context)),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('知识库', style: theme.textTheme.titleLarge),
                Text(
                  '笔记与联系人档案：起草回复时的素材来源',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: () => _openEditor(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新建'),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: TextField(
        key: const Key('knowledge-search-field'),
        controller: _searchCtrl,
        textInputAction: TextInputAction.search,
        onChanged: widget.controller.setQuery,
        onSubmitted: (_) => _submitRetrieval(),
        decoration: InputDecoration(
          // 文案不带「BM25 检索」字样：那是检索结果透出卡的标题
          //（见 _submitRetrieval 的命中卡），测试用 textContaining 认它，
          // 提示文案撞子串会把「恰好一个」断言撞成两个。
          hintText: '搜索标题 / 内容 / 标签；点放大镜做检索评测',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: IconButton(
            key: const Key('knowledge-search-submit'),
            tooltip: '检索评测（BM25，写入检索日志）',
            icon: const Icon(Icons.manage_search),
            onPressed: _submitRetrieval,
          ),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buildTagChips(BuildContext context) {
    return ValueListenableBuilder<List<TagStat>>(
      valueListenable: widget.controller.tagStats,
      builder: (context, stats, _) {
        return ValueListenableBuilder<Set<String>>(
          valueListenable: widget.controller.selectedTags,
          builder: (context, selected, _) {
            final theme = Theme.of(context);
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (stats.isEmpty)
                          Text(
                            '暂无标签',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        for (final stat in stats)
                          FilterChip(
                            label: Text('${stat.tag} ${stat.count}'),
                            selected: selected.contains(stat.tag),
                            onSelected: (_) =>
                                widget.controller.toggleTagFilter(stat.tag),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '标签管理（重命名 / 全库删除）',
                    icon: const Icon(Icons.new_label),
                    onPressed: _showTagManager,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildStatsRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: ValueListenableBuilder<List<TrackedNote>>(
        valueListenable: widget.controller.notes,
        builder: (context, all, _) {
          return ValueListenableBuilder<int>(
            valueListenable: widget.controller.searchCount,
            builder: (context, searches, _) {
              final enabled = all.where((t) => t.note.enabled).length;
              return Text(
                '共 ${all.length} 条 · 启用 $enabled 条 · 检索 $searches 次',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildFlushError(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: widget.controller.flushError,
      builder: (context, error, _) {
        if (error == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            // KbStore 落盘失败不回滚内存：明说「内存已生效」，而不是静默。
            '存档写盘失败：$error（内存已生效，下次成功落盘会自动补上）',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        );
      },
    );
  }

  Widget _buildEvalCard(BuildContext context) {
    return ValueListenableBuilder<RetrievalOutcome?>(
      valueListenable: widget.controller.lastRetrieval,
      builder: (context, outcome, _) {
        if (outcome == null) return const SizedBox.shrink();
        final hits = outcome.result.hits;
        final precision = outcome.precisionAtK;
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'BM25 检索「${outcome.query}」命中 ${hits.length} 条',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      if (precision != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            'precision@k = ${precision.toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                      IconButton(
                        tooltip: '收起',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: widget.controller.clearRetrieval,
                      ),
                    ],
                  ),
                  Text(
                    outcome.annotated == null
                        ? '点「相关」标注人工相关性，precision@k 会写进检索日志。'
                        : '已标注 ${outcome.annotated!.relevantIds!.length} 条相关。',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  for (final hit in hits) _buildHitRow(context, outcome, hit),
                  if (hits.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '没有笔记命中（命中不足也是评测数据，已写入日志）。',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHitRow(
    BuildContext context,
    RetrievalOutcome outcome,
    ScoredDoc hit,
  ) {
    final theme = Theme.of(context);
    // per-term 分解取前 2 项（已按贡献降序）：「为什么命中」的最小解释。
    final topTerms =
        hit.terms.take(2).map((t) => '${t.term}×${t.tf}').join(' ');
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.controller.noteTitleOf(hit.id),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (topTerms.isNotEmpty)
                  Text(
                    '命中词：$topTerms',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('相关'),
            selected: _relevantMarks.contains(hit.id),
            onSelected: (_) => _toggleRelevantMark(outcome, hit.id),
          ),
        ],
      ),
    );
  }

  Widget _buildNoteList(BuildContext context) {
    return ValueListenableBuilder<List<TrackedNote>>(
      valueListenable: widget.controller.visibleNotes,
      builder: (context, visible, _) {
        if (visible.isEmpty) return _buildEmptyState(context);
        return ListView.separated(
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: visible.length,
          itemBuilder: (context, index) =>
              _buildNoteRow(context, visible[index]),
          separatorBuilder: (context, index) =>
              const Divider(height: 1, indent: 16),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    final hasNotes = widget.controller.notes.value.isNotEmpty;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.auto_stories,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 8),
          Text(
            hasNotes ? '没有匹配的笔记' : '还没有笔记',
            style: theme.textTheme.titleMedium,
          ),
          if (hasNotes)
            TextButton(
              onPressed: () {
                _searchCtrl.clear();
                widget.controller.clearFilters();
              },
              child: const Text('清除筛选'),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '点右上角「新建」写第一条；文档导入入口由 #13 接线。',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNoteRow(BuildContext context, TrackedNote tracked) {
    final note = tracked.note;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => _openEditor(existing: tracked),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          note.title.isEmpty ? '（无标题）' : note.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (note.alwaysOn) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '常驻',
                            style: TextStyle(
                              fontSize: 10,
                              color: scheme.onSecondaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (note.content.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        note.content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        _buildSourceBadge(context, tracked.source),
                        if (note.tags.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              note.tags.join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              key: Key('note-switch-${note.id}'),
              value: note.enabled,
              onChanged: (value) =>
                  widget.controller.setNoteEnabled(note.id, value),
            ),
          ],
        ),
      ),
    );
  }

  /// 来源标签：KbSource 值 → 展示文案；未知来源（存档向前兼容的原样值）
  /// 直接展示原文，不猜。
  Widget _buildSourceBadge(BuildContext context, String source) {
    final scheme = Theme.of(context).colorScheme;
    final label = switch (source) {
      KbSource.manual => '手动',
      KbSource.import => '导入',
      KbSource.doc => '文档',
      _ => source,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

// ------------------------------------------------------------------ 对话框

/// 新建 / 编辑笔记对话框。返回值：新建成功时返回新笔记 id（页面据此决定
/// 是否清筛选），编辑 / 取消 / 删除返回 null。
class _NoteEditorDialog extends StatefulWidget {
  const _NoteEditorDialog({required this.controller, this.tracked});

  final KnowledgeController controller;
  final TrackedNote? tracked;

  @override
  State<_NoteEditorDialog> createState() => _NoteEditorDialogState();
}

class _NoteEditorDialogState extends State<_NoteEditorDialog> {
  late final TextEditingController _title;
  late final TextEditingController _content;
  late final TextEditingController _tags;
  late bool _alwaysOn;

  @override
  void initState() {
    super.initState();
    final note = widget.tracked?.note;
    _title = TextEditingController(text: note?.title ?? '');
    _content = TextEditingController(text: note?.content ?? '');
    _tags = TextEditingController(text: note?.tags.join('，') ?? '');
    _alwaysOn = note?.alwaysOn ?? false;
    // 保存按钮的可用性跟着「标题或内容是否非空」走：输入变化时刷新。
    _content.addListener(_onTextChanged);
    _title.addListener(_onTextChanged);
  }

  void _onTextChanged() => setState(() {});

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    _tags.dispose();
    super.dispose();
  }

  /// 逗号 / 中文逗号 / 顿号 / 分号 / 空白皆可作分隔，去空去重、保持顺序。
  List<String> _parseTags(String raw) => <String>{
        for (final piece in raw.split(RegExp(r'[,，、;；\s]+')))
          if (piece.trim().isNotEmpty) piece.trim(),
      }.toList();

  void _save() {
    final note = widget.tracked?.note;
    final title = _title.text.trim();
    final content = _content.text.trim();
    final tags = _parseTags(_tags.text);
    if (note == null) {
      final id = widget.controller.createNote(
          title: title, content: content, tags: tags, alwaysOn: _alwaysOn);
      Navigator.of(context).pop(id);
      return;
    }
    // 编辑：出处（source/importedAt）由 KbStore.saveNote 保留，这里只递字段。
    widget.controller.updateNote(Note(
      id: note.id,
      title: title,
      content: content,
      tags: tags,
      alwaysOn: _alwaysOn,
      enabled: note.enabled,
      updatedAt: note.updatedAt,
      type: note.type,
    ));
    Navigator.of(context).pop(null);
  }

  Future<void> _delete() async {
    final note = widget.tracked!.note;
    final name = note.title.isEmpty ? '（无标题）' : note.title;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('「$name」将被删除，无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      widget.controller.deleteNote(note.id);
      Navigator.of(context).pop(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.tracked == null;
    // 标题或内容至少其一非空：两空 = 没有可入库的东西，保存禁用。
    final canSave =
        _content.text.trim().isNotEmpty || _title.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text(isNew ? '新建笔记' : '编辑笔记'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('note-title-field'),
            controller: _title,
            decoration: const InputDecoration(
              labelText: '标题',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('note-content-field'),
            controller: _content,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '内容',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('note-tags-field'),
            controller: _tags,
            decoration: const InputDecoration(
              labelText: '标签（逗号分隔）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('常驻注入'),
            subtitle: const Text(
              '开启后每轮分析都带上这条，不按关键词命中',
              style: TextStyle(fontSize: 12),
            ),
            value: _alwaysOn,
            onChanged: (value) => setState(() => _alwaysOn = value),
          ),
        ],
      ),
      actions: [
        if (!isNew)
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: _delete,
            child: const Text('删除'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: canSave ? _save : null,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 标签管理对话框：全库重命名 / 全库删除。
class _TagManagerDialog extends StatelessWidget {
  const _TagManagerDialog({required this.controller});

  final KnowledgeController controller;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('标签管理'),
      content: SizedBox(
        width: double.maxFinite,
        child: ValueListenableBuilder<List<TagStat>>(
          valueListenable: controller.tagStats,
          builder: (context, stats, _) {
            if (stats.isEmpty) {
              return const Text('还没有标签。在笔记编辑里填写「标签」即可创建。');
            }
            return ListView.builder(
              shrinkWrap: true,
              itemCount: stats.length,
              itemBuilder: (context, index) => _TagManagerRow(
                // 按标签名做 key：重命名后旧行整体重建，输入框文字不串位。
                key: ValueKey<String>(stats[index].tag),
                controller: controller,
                stat: stats[index],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

class _TagManagerRow extends StatefulWidget {
  const _TagManagerRow({
    super.key,
    required this.controller,
    required this.stat,
  });

  final KnowledgeController controller;
  final TagStat stat;

  @override
  State<_TagManagerRow> createState() => _TagManagerRowState();
}

class _TagManagerRowState extends State<_TagManagerRow> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.stat.tag);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _ctrl.text.trim();
    final canRename = text.isNotEmpty && text != widget.stat.tag;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            // isDense 在 InputDecoration 上（TextField 无此参数），收紧行高。
            decoration: const InputDecoration(isDense: true),
            onChanged: (_) => setState(() {}),
          ),
        ),
        IconButton(
          tooltip: '全库重命名',
          icon: const Icon(Icons.check),
          onPressed: canRename
              ? () => widget.controller.renameTag(widget.stat.tag, text)
              : null,
        ),
        IconButton(
          tooltip: '全库删除（笔记本身不动）',
          icon: const Icon(Icons.delete_outline),
          onPressed: () =>
              widget.controller.removeTagEverywhere(widget.stat.tag),
        ),
      ],
    );
  }
}

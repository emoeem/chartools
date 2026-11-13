/// legacy 数据迁移页（W6 app 层）：粘贴 → 解析预览 → 勾选 → 确认落盘 → 结果。
///
/// 流程（G8「确认后入库」，docs/migration-design.md §4.4）：
///  1. **粘贴**：三个文本框分别对应旧版导出 ZIP 里解出的 notes.json /
///     contacts.json / personas.json 内容（留空 = 迁移包里没有这个文件）；
///  2. **预览**：解析出「将导入 N / 重复跳过 M / 冲突 K」计数 + 逐条明细 +
///     问题清单（解析层不连坐：坏条目记 problem，好条目照常）；
///  3. **勾选**：insert 默认全勾、冲突默认不勾（点名 = 「仍导入」裁决）、
///     重复不可勾（无损跳过，再写只会翻倍）；
///  4. **确认落盘**：只落勾选项，段级全或无、失败即停（KbStoreSink 三原则）；
///  5. **结果**：成功 N/失败 M 对账 + 失败原因。
///
/// **文件选择器（ZIP + SAF）留给后续**：docs/migration-design.md §3.1 的
/// ZIP 解包 / manifest kind 校验 / 文件 hash 对拍属于 app 层 IO，落地时接在
/// `MigrationController.loadTexts` 之前（parseLegacyManifestJson /
/// verifyLegacyFileHash 已在 core 备好）。本页 v1 先收**文本粘贴**——textarea
/// 起步是刻意的最小可用：旧版 ZIP 解包出来是三个纯文本 JSON，复制粘贴就能
/// 走通全链路，不阻塞数据转移主线。
///
/// **main 接线留 fixer 阶段**：本文件不 import main.dart，也不自建
/// MigrationController / KbStore；构造注入由接线完成（如
/// `MigrationPage(controller: MigrationController(store: 共享 KbStore 实例))`）。
/// body-only 组件（无 Scaffold），方便嵌进路由、设置页入口或侧栏。
library;

import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/material.dart';

import '../application/migration_controller.dart';

/// 页面三阶段。
enum _Stage { input, preview, result }

/// legacy 迁移页。
class MigrationPage extends StatefulWidget {
  const MigrationPage({super.key, required this.controller});

  /// 控制器由外部构造注入（main 接线留 fixer 阶段，见文件头注释）。
  final MigrationController controller;

  @override
  State<MigrationPage> createState() => _MigrationPageState();
}

class _MigrationPageState extends State<MigrationPage> {
  _Stage _stage = _Stage.input;
  bool _busy = false;

  late final TextEditingController _notesCtrl;
  late final TextEditingController _contactsCtrl;
  late final TextEditingController _personasCtrl;

  @override
  void initState() {
    super.initState();
    _notesCtrl = TextEditingController();
    _contactsCtrl = TextEditingController();
    _personasCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    _contactsCtrl.dispose();
    _personasCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- 动作

  void _parse() {
    setState(() {
      widget.controller.loadTexts(
        notesJson: _notesCtrl.text,
        contactsJson: _contactsCtrl.text,
        personasJson: _personasCtrl.text,
      );
      _stage = _Stage.preview;
    });
  }

  Future<void> _confirm() async {
    setState(() => _busy = true);
    try {
      await widget.controller.confirm();
      if (!mounted) return;
      setState(() => _stage = _Stage.result);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _backToInput() => setState(() => _stage = _Stage.input);

  // ------------------------------------------------------------- 布局

  @override
  Widget build(BuildContext context) {
    return switch (_stage) {
      _Stage.input => _buildInput(context),
      _Stage.preview => _buildPreview(context),
      _Stage.result => _buildResult(context),
    };
  }

  // --------------------------------------------------- 阶段 1：粘贴输入

  Widget _buildInput(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('从旧版迁移数据', style: theme.textTheme.titleLarge),
      const SizedBox(height: 8),
      Text(
        '旧版（com.jev.probe）在旧版设置里导出迁移 ZIP；解压出三个 JSON 文件，'
        '把内容分别粘到下面。留空的文件视为「迁移包里没有这个数据」。',
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 16),
      _buildJsonField(
        controller: _notesCtrl,
        label: 'notes.json（笔记）',
        key: 'migration-input-notes',
      ),
      const SizedBox(height: 12),
      _buildJsonField(
        controller: _contactsCtrl,
        label: 'contacts.json（联系人）',
        key: 'migration-input-contacts',
      ),
      const SizedBox(height: 12),
      _buildJsonField(
        controller: _personasCtrl,
        label: 'personas.json（人设/专家）',
        key: 'migration-input-personas',
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        key: const Key('migration-parse'),
        onPressed: _anyTextNonEmpty ? _parse : null,
        icon: const Icon(Icons.preview_outlined),
        label: const Text('解析预览'),
      ),
    ]);
  }

  bool get _anyTextNonEmpty =>
      _notesCtrl.text.trim().isNotEmpty ||
      _contactsCtrl.text.trim().isNotEmpty ||
      _personasCtrl.text.trim().isNotEmpty;

  Widget _buildJsonField({
    required TextEditingController controller,
    required String label,
    required String key,
  }) {
    return TextField(
      key: Key(key),
      controller: controller,
      maxLines: 6,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        hintText: 'JSON 数组内容原样粘贴',
      ),
    );
  }

  // --------------------------------------------------- 阶段 2：预览勾选

  Widget _buildPreview(BuildContext context) {
    final theme = Theme.of(context);
    final p = widget.controller.preview.value;
    if (p == null) {
      // 理论不可达（preview 阶段必有预览）；防御性回输入页。
      return _buildInput(context);
    }
    final confirmCount = widget.controller.selectedCount;
    final hasPersonas = p.personas.isNotEmpty;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('迁移预览', style: theme.textTheme.titleLarge),
      const SizedBox(height: 8),
      Text(p.describe(), style: theme.textTheme.bodyMedium),
      const SizedBox(height: 8),
      Wrap(spacing: 8, children: [
        _countChip(context, '将导入 ${p.importCount}', Icons.add_circle_outline),
        if (p.duplicateCount > 0)
          _countChip(context, '重复跳过 ${p.duplicateCount}', Icons.remove_circle_outline),
        if (p.conflictCount > 0)
          _countChip(context, '冲突 ${p.conflictCount}', Icons.help_outline),
        if (p.problems.isNotEmpty)
          _countChip(context, '问题 ${p.problems.length}', Icons.warning_amber_outlined),
      ]),
      if (hasPersonas) ...[
        const SizedBox(height: 8),
        // 人设段暂无落盘通路（KbStore 只有 notes/contacts/logs；正式人设/专家
        // 库另工作流交付）——确认前就把这件事说清，绝不静默丢弃。
        Text(
          '人设段暂无落盘通路（新版人设/专家库未接入迁移）：勾选也不会写入，'
          '明细会原样保留在预览里。',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.tertiary),
        ),
      ],
      const SizedBox(height: 12),
      if (p.notes.isNotEmpty) ..._segmentSection(context, '笔记', p.notes),
      if (p.contacts.isNotEmpty) ..._segmentSection(context, '联系人', p.contacts),
      if (p.personas.isNotEmpty) ..._segmentSection(context, '人设/专家', p.personas),
      if (p.problems.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('问题明细（这些条目不会导入）', style: theme.textTheme.titleSmall),
        for (final problem in p.problems)
          ListTile(
            dense: true,
            leading: const Icon(Icons.warning_amber_outlined, size: 18),
            title: Text(problem.toString(), style: theme.textTheme.bodySmall),
          ),
      ],
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            key: const Key('migration-back'),
            onPressed: _busy ? null : _backToInput,
            child: const Text('返回修改'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            key: const Key('migration-confirm'),
            onPressed: (confirmCount > 0 && !_busy) ? _confirm : null,
            child: _busy
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text('确认导入勾选项（$confirmCount）'),
          ),
        ),
      ]),
    ]);
  }

  Widget _countChip(BuildContext context, String label, IconData icon) {
    final theme = Theme.of(context);
    return Chip(
      avatar: Icon(icon, size: 16),
      label: Text(label, style: theme.textTheme.labelMedium),
      visualDensity: VisualDensity.compact,
    );
  }

  List<Widget> _segmentSection<T>(
      BuildContext context, String title, List<MigrationItem<T>> items) {
    final theme = Theme.of(context);
    return [
      const SizedBox(height: 8),
      Text(title, style: theme.textTheme.titleSmall),
      for (final item in items) _itemRow<T>(item),
    ];
  }

  Widget _itemRow<T>(MigrationItem<T> item) {
    final theme = Theme.of(context);
    final tickable = widget.controller.isTickable(item);
    final checked =
        widget.controller.selectedKeys.value.contains(MigrationController.keyOf(item));
    return ListTile(
      dense: true,
      leading: Checkbox(
        key: Key('migration-check-${MigrationController.keyOf(item)}'),
        value: checked,
        onChanged: tickable && !_busy
            ? (v) => setState(() => widget.controller.setChecked(item, v ?? false))
            : null,
      ),
      title: Text(_entityTitle(item), style: theme.textTheme.bodyMedium),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          '${item.status.label}${item.detail.isEmpty ? '' : '：${item.detail}'}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: switch (item.status) {
              MigrationStatus.insert => theme.colorScheme.primary,
              MigrationStatus.duplicate => theme.colorScheme.outline,
              MigrationStatus.conflict => theme.colorScheme.error,
            },
          ),
        ),
        if (_entityPreview(item).isNotEmpty)
          Text(_entityPreview(item),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall),
      ]),
      isThreeLine: true,
    );
  }

  /// 明细主行：实体的身份信息（笔记标题 / 联系人名 / 人设名）。
  String _entityTitle<T>(MigrationItem<T> item) {
    final e = item.entity;
    return switch (e) {
      Note n => n.title.trim().isEmpty ? '（无标题笔记）' : n.title.trim(),
      Contact c => c.name,
      ImportedPersona p => p.name,
      _ => e.runtimeType.toString(),
    };
  }

  /// 明细次行：正文预览（预览是给人看的，截断不影响落盘内容）。
  String _entityPreview<T>(MigrationItem<T> item) {
    final e = item.entity;
    final String text = switch (e) {
      Note n => n.content,
      Contact c => [
          if (c.relationship.trim().isNotEmpty) '关系：${c.relationship.trim()}',
          if (c.notes.trim().isNotEmpty) c.notes.trim(),
        ].join('；'),
      ImportedPersona p => p.body,
      _ => '',
    };
    final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length > 60 ? '${oneLine.substring(0, 60)}…' : oneLine;
  }

  // --------------------------------------------------- 阶段 3：结果

  Widget _buildResult(BuildContext context) {
    final theme = Theme.of(context);
    final report = widget.controller.lastReport.value;
    if (report == null) {
      // 理论不可达（result 阶段必有对账）；防御性回输入页。
      return _buildInput(context);
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      Icon(
        report.ok ? Icons.check_circle_outline : Icons.error_outline,
        size: 40,
        color: report.ok
            ? theme.colorScheme.primary
            : theme.colorScheme.error,
      ),
      const SizedBox(height: 12),
      Text(
        report.ok ? '迁移完成' : '迁移未完成',
        textAlign: TextAlign.center,
        style: theme.textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      Text(report.describe(), textAlign: TextAlign.center),
      const SizedBox(height: 16),
      // 分段对账逐条列出：哪一段写入几条、跳过几条、没落盘几条，一眼核对。
      for (final segment in [report.notes, report.contacts, report.personas])
        ListTile(
          dense: true,
          leading: Icon(
            segment.ok ? Icons.check : Icons.close,
            size: 18,
            color: segment.ok
                ? theme.colorScheme.primary
                : theme.colorScheme.error,
          ),
          title: Text(segment.toString(), style: theme.textTheme.bodySmall),
        ),
      if (!report.ok) ...[
        const SizedBox(height: 8),
        Text(
          '失败即停：出错段之后的段落没有执行，库内没有半截数据；'
          '修正后可重新预览导入（已写入的部分会按内容幂等跳过）。',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.error),
        ),
      ],
      const SizedBox(height: 16),
      FilledButton(
        key: const Key('migration-again'),
        onPressed: _backToInput,
        child: const Text('再导一份'),
      ),
    ]);
  }
}

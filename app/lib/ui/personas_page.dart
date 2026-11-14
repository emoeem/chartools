import 'package:chartools_core/chartools_core.dart' show ConflictChoice;
import 'package:flutter/material.dart';

// ContactTarget 是套用目标快照（类型住在 experts_controller.dart，端口适配器
// 所在文件）——只 import 消费，不改那个文件（文件所有权纪律）。
import '../application/experts_controller.dart' show ContactTarget;
import '../application/personas_controller.dart';

/// 人设库页（人设列表 + 新建/编辑 + 复制/删除 + Character Card V2 导入 +
/// 套用为全局风格/联系人人设）。
///
/// 接线（main.dart `_openPersonas`）：`PersonasController(styleSink:
/// SettingsStyleSink(settings), contactSink: ContactStorePersonaSink(contacts))
/// ..load()`——套用动作的两个落点（全局 style / 联系人专用人设）经注入的
/// sink 生效；sink 缺位（如测试直 pump）时套用按钮照在、点了如实提示
/// 「未接线」，与 experts_page 同款。
///
/// 套用交互与 experts_page 同款同文案：StyleSource 优先级（专用人设压全局）
/// 要求「套用为全局」前先确认哪些联系人不生效；「套用为联系人」遇到已有
/// 专用人设的目标时弹「覆盖/并存」二选一（needsChoice 语义，判定在 core
/// ExpertApply，页面只问不改）。编辑表单的六个字段（称呼/关系/语气/边界/
/// 避谈/安全词）一一对应 PersonaCard 的键；页面不自己拼提示词——预览走
/// [PersonasEntry.promptPreview]（内部是 `PersonaCard.parse` →
/// `promptText()`，与起草提示词同一条路径）。CCV2 导入必须先预览、确认才
/// 落库（G8「确认后入库」纪律，映射表见 PersonasController.importCcv2 注释）。
class PersonasPage extends StatefulWidget {
  const PersonasPage({super.key, required this.controller});

  final PersonasController controller;

  @override
  State<PersonasPage> createState() => _PersonasPageState();
}

class _PersonasPageState extends State<PersonasPage> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('人设库'),
        actions: [
          IconButton(
            tooltip: '导入 Character Card (CCV2)',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _importCcv2,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.controller.entries,
        builder: (context, _) {
          final entries = [...widget.controller.entries.value]
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
          if (entries.isEmpty) {
            return const Center(
              child: Text('还没有人设。点右下角新建，或从右上角导入 CCV2 卡。'),
            );
          }
          return ListView.builder(
            key: const Key('personas_list'),
            itemCount: entries.length,
            itemBuilder: (context, i) =>
                _personaTile(context, entries[i], scheme),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('personas_new'),
        onPressed: () => _editSheet(null),
        icon: const Icon(Icons.add),
        label: const Text('新建人设'),
      ),
    );
  }

  Widget _personaTile(
      BuildContext context, PersonaEntry entry, ColorScheme scheme) {
    final badges = <String>[
      if (entry.address.trim().isNotEmpty) '称呼',
      if (entry.relation.trim().isNotEmpty) '关系',
      if (entry.tone.trim().isNotEmpty) '语气',
      if (entry.boundaries.isNotEmpty) '边界',
      if (entry.avoid.isNotEmpty) '避谈',
      if (entry.safeword.trim().isNotEmpty) '安全词',
      if (entry.firstMes.trim().isNotEmpty) '开场白',
    ];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.face_outlined),
        title: Row(
          children: [
            Flexible(child: Text(entry.name, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 6),
            if (entry.sourceRef.startsWith('ccv2'))
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  entry.sourceRef == 'ccv2'
                      ? 'CCV2'
                      : 'CCV2 ${entry.sourceRef.substring(5)}',
                  style: TextStyle(
                      fontSize: 11, color: scheme.onSecondaryContainer),
                ),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (entry.blurb().isNotEmpty)
              Text(entry.blurb(), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(
              badges.isEmpty ? '自由补充' : badges.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        onTap: () => _detailSheet(entry),
      ),
    );
  }

  // ------------------------------------------------------------------ 详情

  Future<void> _detailSheet(PersonaEntry entry) async {
    // 按 id 重查拿最新（编辑/复制后的重开场景）。
    final current = widget.controller.byId(entry.id) ?? entry;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(current.name,
                    style: Theme.of(sheetContext).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('来源：${current.sourceRef}',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(sheetContext)
                            .colorScheme
                            .onSurfaceVariant)),
                const SizedBox(height: 12),
                Text('提示词预览（PersonaCard.promptText）',
                    style: Theme.of(sheetContext).textTheme.titleSmall),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(sheetContext)
                        .colorScheme
                        .surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    current.promptPreview(),
                    style: const TextStyle(fontSize: 13, height: 1.4),
                  ),
                ),
                const SizedBox(height: 16),
                // 套用动作（本轮接线）：与 experts_page 详情同款双落点——写
                // ContactStore 的联系人人设或全局 style，不搬数据、不动专家库
                //（语义见 PersonasController 套用一节）。sink 未接线时点了
                // 如实提示，不假装成功。
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        key: const Key('personas_apply_global'),
                        onPressed: () => _applyGlobal(sheetContext, current),
                        icon: const Icon(Icons.public),
                        label: const Text('套用为全局风格'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('personas_apply_contact'),
                        onPressed: () => _applyContact(sheetContext, current),
                        icon: const Icon(Icons.person_outline),
                        label: const Text('套用为联系人人设'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        key: const Key('personas_edit'),
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          _editSheet(current);
                        },
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('编辑'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('personas_duplicate'),
                        onPressed: () async {
                          final copy =
                              await widget.controller.duplicate(current.id);
                          if (!sheetContext.mounted) return;
                          Navigator.of(sheetContext).pop();
                          _snack(copy == null
                              ? '这条人设已经不在了'
                              : '已复制为「${copy.name}」');
                        },
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('复制'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('personas_delete'),
                        onPressed: () async {
                          final goOn = await showDialog<bool>(
                            context: sheetContext,
                            builder: (dialogContext) => AlertDialog(
                              title: Text('删除「${current.name}」？'),
                              content: const Text('删除后不可恢复。'),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(dialogContext).pop(false),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () =>
                                      Navigator.of(dialogContext).pop(true),
                                  child: const Text('删除'),
                                ),
                              ],
                            ),
                          );
                          if (goOn != true || !sheetContext.mounted) return;
                          await widget.controller.remove(current.id);
                          if (!sheetContext.mounted) return;
                          Navigator.of(sheetContext).pop();
                          _snackOf(sheetContext, '已删除「${current.name}」');
                        },
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('删除'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 套用

  /// 「套用为全局风格」。StyleSource 优先级（style_source.dart:27 的既定
  /// 事实：联系人专用人设压过全局风格）要求**照实说话**：存在写了专用人设
  /// 的联系人时先弹确认，说明这次套用对 TA 们不生效——交互与文案口径与
  /// experts_page 完全一致，判定复用 PersonasController.contactHasPersona
  ///（内部即 ExpertsController → core StyleSource.resolve 的同一链条）。
  Future<void> _applyGlobal(
      BuildContext sheetContext, PersonaEntry entry) async {
    final controller = widget.controller;
    if (!controller.hasStyleSink) {
      _snackOf(sheetContext, '全局风格未接线（#13），暂时不能套用', error: true);
      return;
    }
    final shadowed = controller.contactTargets
        .where(PersonasController.contactHasPersona)
        .toList();
    if (shadowed.isNotEmpty) {
      final goOn = await _confirmStyleSourceShadow(sheetContext, shadowed);
      if (goOn != true || !sheetContext.mounted) return;
    }
    final result = await controller.applyAsGlobalStyle(entry);
    if (!sheetContext.mounted) return;
    Navigator.of(sheetContext).pop(); // 套用后收起详情。
    _snack(
        result.ok
            ? '已套用为全局风格${result.warning.isEmpty ? '' : '；${result.warning}'}'
            : result.problem,
        error: !result.ok);
  }

  /// StyleSource 优先级确认：这些联系人写了专用人设，全局风格对 TA 们不生效。
  /// 与 experts_page._confirmStyleSourceShadow 同文案（按钮 key 换人设前缀）。
  Future<bool?> _confirmStyleSourceShadow(
    BuildContext sheetContext,
    List<ContactTarget> shadowed,
  ) {
    return showDialog<bool>(
      context: sheetContext,
      builder: (dialogContext) => AlertDialog(
        title: const Text('部分联系人不会生效'),
        content: Text(
          '以下联系人写了专用人设（专用人设优先于全局风格）：\n\n'
          '${shadowed.map((t) => '· ${t.displayName}').join('\n')}\n\n'
          '这次套用只对没有专用人设的聊天生效，仍要套用吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('personas_confirm_shadowed'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('仍要套用'),
          ),
        ],
      ),
    );
  }

  /// 「套用为联系人人设」：先选目标联系人；冲突判定与选择语义收敛到 core
  /// ExpertApply——控制器首调返回 needsChoice（core 保证问询期间两个目标都
  /// 没写）时弹「覆盖/并存」二选一，选完带 ConflictChoice 再调一次。目标已有
  /// 专用人设时不可静默发生（StyleSource 优先级：专用人设一旦写入就压过
  /// 全局风格）。交互流程与 experts_page._applyContact 逐步同款。
  Future<void> _applyContact(
      BuildContext sheetContext, PersonaEntry entry) async {
    final controller = widget.controller;
    if (!controller.hasContactSink) {
      _snackOf(sheetContext, '联系人档案未接线（#13），暂时不能套用', error: true);
      return;
    }
    final targets = controller.contactTargets;
    if (targets.isEmpty) {
      _snackOf(sheetContext, '还没有联系人档案，先在联系人页建一个', error: true);
      return;
    }
    final picked = await showModalBottomSheet<ContactTarget>(
      context: sheetContext,
      builder: (pickContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('套用给哪位联系人？'),
            ),
            for (final t in targets)
              ListTile(
                title: Text(t.displayName),
                // 「已有专用人设」判定走 StyleSource.resolve 收敛口径
                //（PersonasController.contactHasPersona 转发），不手写判空。
                trailing: PersonasController.contactHasPersona(t)
                    ? const Tooltip(
                        message: '已有专用人设',
                        child: Icon(Icons.description_outlined),
                      )
                    : null,
                subtitle: PersonasController.contactHasPersona(t)
                    ? const Text('已有专用人设（套用将覆盖）')
                    : null,
                onTap: () => Navigator.of(pickContext).pop(t),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !sheetContext.mounted) return;
    // 首调：core 检测到「专用人设压全局」的冲突时返回 needsChoice 且什么都不
    // 写；无冲突则直接生效。
    var result = await controller.applyToContact(entry, picked);
    if (!sheetContext.mounted) return;
    if (result.needsChoice) {
      final choice = await showDialog<_PersonaApplyChoice>(
        context: sheetContext,
        builder: (dialogContext) => AlertDialog(
          title: Text('覆盖「${picked.displayName}」的专用人设？'),
          content: const Text(
            '这位联系人已有专用人设（专用人设优先于全局风格）。\n\n'
            '覆盖套用：与 TA 的聊天改用新人设，原专用人设被覆盖。\n'
            '并存套用：这个人设写入全局风格，原专用人设保留并继续生效'
            '（仅对没有专用人设的聊天，全局风格才会露出）。',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_PersonaApplyChoice.cancel),
              child: const Text('取消'),
            ),
            TextButton(
              // 并存要写全局风格：风格未接线时没有第二条路可走。
              onPressed: controller.hasStyleSink
                  ? () => Navigator.of(dialogContext)
                      .pop(_PersonaApplyChoice.coexist)
                  : null,
              child: const Text('并存套用'),
            ),
            FilledButton(
              key: const Key('personas_confirm_overwrite'),
              onPressed: () => Navigator.of(dialogContext)
                  .pop(_PersonaApplyChoice.overwrite),
              child: const Text('覆盖套用'),
            ),
          ],
        ),
      );
      if (!sheetContext.mounted) return;
      if (choice == null || choice == _PersonaApplyChoice.cancel) return;
      final kbChoice = choice == _PersonaApplyChoice.coexist
          ? ConflictChoice.coexist
          : ConflictChoice.overwrite;
      result = await controller.applyToContact(entry, picked, choice: kbChoice);
      if (!sheetContext.mounted) return;
      if (kbChoice == ConflictChoice.coexist) {
        Navigator.of(sheetContext).pop();
        _snack(
            result.ok
                ? '已并存套用：写入全局风格，「${picked.displayName}」的'
                    '专用人设保留并继续生效'
                : result.problem,
            error: !result.ok);
        return;
      }
    }
    Navigator.of(sheetContext).pop();
    _snack(
        result.ok
            ? '已套用为「${picked.displayName}」的专用人设'
                '${result.warning.isEmpty ? '' : '；${result.warning}'}'
            : result.problem,
        error: !result.ok);
  }

  // ------------------------------------------------------------- 新建/编辑

  /// 新建（[existing] = null）与编辑共用的表单：六个字段对应 PersonaCard
  /// 的键（见 PersonasEntry 的字段注释），名称必填，简介只进列表不进提示词。
  /// pop 载荷是表单快照（null = 取消）；controller 归表单弹层所有。
  Future<void> _editSheet(PersonaEntry? existing) async {
    final values = await showModalBottomSheet<_PersonaFormValues>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _PersonaFormSheet(existing: existing),
    );
    if (values == null || !mounted) return;
    if (existing == null) {
      final entry = await widget.controller.create(
        name: values.name,
        description: values.description,
        address: values.address,
        relation: values.relation,
        tone: values.tone,
        boundaries: values.boundaries,
        avoid: values.avoid,
        safeword: values.safeword,
      );
      if (!mounted) return;
      _snack('已新建「${entry.name}」');
    } else {
      await widget.controller.update(existing.copyWith(
        name: values.name.trim(),
        description: values.description,
        address: values.address,
        relation: values.relation,
        tone: values.tone,
        boundaries: values.boundaries,
        avoid: values.avoid,
        safeword: values.safeword,
      ));
      if (!mounted) return;
      _snack('已保存「${values.name.trim()}」');
    }
  }

  // ------------------------------------------------------------ CCV2 导入

  /// 导入 CCV2：粘贴 JSON → 解析预览（看清每个字段落到哪）→ 确认导入。
  /// 预览不通过（缺 name / 非法 JSON）时「确认导入」不可用。
  Future<void> _importCcv2() async {
    final confirmed = await showDialog<Ccv2Preview>(
      context: context,
      builder: (dialogContext) =>
          _Ccv2ImportDialog(controller: widget.controller),
    );
    if (confirmed == null || !mounted) return;
    try {
      final entry = await widget.controller.importCcv2(confirmed);
      if (!mounted) return;
      _snack('已导入「${entry.name}」（来源 ${entry.sourceRef}）');
    } on FormatException catch (e) {
      _snack('导入失败：${e.message}', error: true);
    }
  }

  // ------------------------------------------------------------------ 工具

  void _snack(String message, {bool error = false}) =>
      _snackOf(context, message, error: error);

  void _snackOf(BuildContext ctx, String message, {bool error = false}) {
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Theme.of(ctx).colorScheme.error : null,
    ));
  }
}

/// 表单取值快照：保存时由表单弹层从 controller 取值组装成 pop 载荷，
/// 页面拿到的是纯数据，异步落库不再碰已退场的控制器。
class _PersonaFormValues {
  const _PersonaFormValues({
    required this.name,
    required this.description,
    required this.address,
    required this.relation,
    required this.tone,
    required this.boundaries,
    required this.avoid,
    required this.safeword,
  });

  final String name;
  final String description;
  final String address;
  final String relation;
  final String tone;
  final List<String> boundaries;
  final List<String> avoid;
  final String safeword;
}

/// 新建/编辑人设的表单弹层。8 个输入控制器由本 State 持有并在自己的
/// dispose 里释放——弹层退场动画期间输入框还挂在树上，页面侧 await 完
/// 就 dispose 会撞「used after being disposed」断言。保存时从控制器
/// 取值组装快照作为 pop 载荷；取消 pop null。
class _PersonaFormSheet extends StatefulWidget {
  const _PersonaFormSheet({this.existing});

  final PersonaEntry? existing;

  @override
  State<_PersonaFormSheet> createState() => _PersonaFormSheetState();
}

class _PersonaFormSheetState extends State<_PersonaFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _description =
      TextEditingController(text: widget.existing?.description ?? '');
  late final TextEditingController _address =
      TextEditingController(text: widget.existing?.address ?? '');
  late final TextEditingController _relation =
      TextEditingController(text: widget.existing?.relation ?? '');
  late final TextEditingController _tone =
      TextEditingController(text: widget.existing?.tone ?? '');
  late final TextEditingController _boundaries =
      TextEditingController(text: widget.existing?.boundariesText ?? '');
  late final TextEditingController _avoid =
      TextEditingController(text: widget.existing?.avoidText ?? '');
  late final TextEditingController _safeword =
      TextEditingController(text: widget.existing?.safeword ?? '');

  @override
  void dispose() {
    for (final c in [
      _name,
      _description,
      _address,
      _relation,
      _tone,
      _boundaries,
      _avoid,
      _safeword,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return Padding(
      // 键盘顶起表单：底部的 viewInsets 让最后一个输入框不被遮。
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(existing == null ? '新建人设' : '编辑「${existing.name}」',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('personas_field_name'),
                controller: _name,
                decoration: const InputDecoration(
                    labelText: '名称（必填）', border: OutlineInputBorder()),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '名称不能为空' : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _description,
                decoration: const InputDecoration(
                  labelText: '简介（可选，仅列表展示，不进提示词）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              _sixFields(),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      key: const Key('personas_save'),
                      onPressed: () {
                        if (_formKey.currentState?.validate() != true) return;
                        Navigator.of(context).pop(_values());
                      },
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sixFields() => Column(
        children: [
          TextFormField(
            controller: _address,
            decoration: const InputDecoration(
                labelText: '称呼',
                hintText: '如：叫我主人，我称你乖',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _relation,
            decoration: const InputDecoration(
                labelText: '关系',
                hintText: '如：网调关系，我定规矩',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _tone,
            decoration: const InputDecoration(
                labelText: '语气',
                hintText: '如：短句、命令式，不解释',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextFormField(
            key: const Key('personas_field_boundaries'),
            controller: _boundaries,
            decoration: const InputDecoration(
              labelText: '硬边界（顿号分隔，写关键词）',
              hintText: '如：家人、前任——对方一提就停整轮',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _avoid,
            decoration: const InputDecoration(
              labelText: '避谈（顿号分隔，约束我的措辞）',
              hintText: '如：稳赚、保证收益——不拦对方、只管我的回复',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _safeword,
            decoration: const InputDecoration(
                labelText: '安全词',
                hintText: '如：红灯——停止只归它',
                border: OutlineInputBorder()),
          ),
        ],
      );

  _PersonaFormValues _values() => _PersonaFormValues(
        name: _name.text,
        description: _description.text,
        address: _address.text,
        relation: _relation.text,
        tone: _tone.text,
        boundaries: _PersonasPageSplit.splitList(_boundaries.text),
        avoid: _PersonasPageSplit.splitList(_avoid.text),
        safeword: _safeword.text,
      );
}

/// 边界/避谈输入框的拆分：与 PersonasController._splitList 同一组分隔符
/// （保存的原词进 [PersonaEntry.boundaries]；关键词展开只发生在
/// PersonaCard.parse）。静态收口：页面与表单弹层共用一份。
class _PersonasPageSplit {
  const _PersonasPageSplit._();

  static List<String> splitList(String value) => [
        for (final p in value.split(RegExp('[、,，;；/|]+')))
          if (p.trim().isNotEmpty) p.trim(),
      ];
}

/// CCV2 导入弹层：粘贴 JSON → 解析预览 → 确认导入。controller 与预览状态
/// 都归本 State 所有（同 [_PersonaFormSheet] 的所有权纪律），确认时把
/// 预览结果作为 pop 载荷带回；取消 pop null。
class _Ccv2ImportDialog extends StatefulWidget {
  const _Ccv2ImportDialog({required this.controller});

  final PersonasController controller;

  @override
  State<_Ccv2ImportDialog> createState() => _Ccv2ImportDialogState();
}

class _Ccv2ImportDialogState extends State<_Ccv2ImportDialog> {
  final TextEditingController _input = TextEditingController();
  Ccv2Preview? _preview;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('导入 Character Card (CCV2)'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const Key('personas_ccv2_json'),
                  controller: _input,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    hintText: '粘贴卡 JSON（支持 spec+data 包裹、裸对象与 V1 别名）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const Key('personas_ccv2_preview'),
                  onPressed: () => setState(() =>
                      _preview = widget.controller.previewCcv2(_input.text)),
                  child: const Text('解析预览'),
                ),
                if (_preview != null) ...[
                  const SizedBox(height: 8),
                  if (_preview!.ok) ...[
                    _previewRow('名称', _preview!.name),
                    _previewRow('描述 → 补充正文（进提示词）', _preview!.description),
                    _previewRow('persona → 六字段+补充', _preview!.persona),
                    _previewRow(
                        'personality → 语气（缺时补位）', _preview!.personality),
                    _previewRow('scenario → 补充（情境：）', _preview!.scenario),
                    _previewRow('first_mes → 开场白（对方示例）', _preview!.firstMes),
                    _previewRow('mes_example → 补充（示例行）', _preview!.mesExample),
                    const SizedBox(height: 4),
                    Text(
                      '导入会新建一条人设（来源：ccv2），预览确认后才落库。',
                      style: TextStyle(
                          fontSize: 12,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ] else
                    Text(
                      _preview!.problem,
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('personas_ccv2_import'),
            onPressed: (_preview?.ok ?? false)
                ? () => Navigator.of(context).pop(_preview)
                : null,
            child: const Text('确认导入'),
          ),
        ],
      );

  Widget _previewRow(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            Text(
              value.trim().isEmpty ? '（空）' : value.trim(),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      );
}

/// 套用为联系人人设时的用户裁决（core ExpertApply 的 needsChoice 语义）：
/// 覆盖专用人设 / 并存（只写全局风格、专用人设保留并继续压全局）/ 取消。
/// 与 experts_page 的同名枚举同义——两页各自私有，改名不影响对方。
enum _PersonaApplyChoice { overwrite, coexist, cancel }

import 'package:chartools_core/chartools_core.dart'
    show ConflictChoice, ExpertCatalog, ExpertPackData, InstallAction, PersonaCard;
import 'package:flutter/material.dart';

import '../application/experts_controller.dart';

/// 专家库页（专家目录浏览 + 套用 + 资产包管理）。
///
/// **接线留 #13**：main.dart 不由本工作流改动——接线时在主导航挂本页并
/// 组装 `ExpertsController(styleSink: SettingsStyleSink(settings),
/// contactSink: ContactStorePersonaSink(contacts))..load()`；未接线时页内
/// 相应动作会如实提示「未接线」而不是假装成功。
///
/// #13 收敛适配（最小改动）：控制器已切到 core 三件套（PackCodec +
/// ExpertPackManager + ExpertApply），页面只换数据来源与字段名（pack 元信息
/// 的 sourceCommit/contentHash）、按 needsChoice 流程弹「覆盖/并存」二选一，
/// 资产包区补卸载按钮与坏包提示——浏览结构与布局不重排。
///
/// 浏览层与正文层的分界（沿用 legacy 的铁律）：列表/搜索/标签只读浏览层
/// 字段；点进详情看到的「提示词预览」是 `PersonaCard.parse(body).promptText()`
/// ——与起草提示词拿到的人设卡同一条路径，页面不做任何第二份解析。
class ExpertsPage extends StatefulWidget {
  const ExpertsPage({super.key, required this.controller});

  final ExpertsController controller;

  @override
  State<ExpertsPage> createState() => _ExpertsPageState();
}

class _ExpertsPageState extends State<ExpertsPage> {
  final TextEditingController _search = TextEditingController();

  /// 当前筛选：分类（null = 全部）、标签（null = 不筛）、排序。
  String? _category;
  String? _tag;
  ExpertSort _sort = ExpertSort.comprehensive;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('专家库'),
        // 资产包管理区入口：已安装列表 + 安装入口（文件选择器预留 #13）。
        actions: [
          IconButton(
            tooltip: '资产包',
            icon: const Icon(Icons.inventory_2_outlined),
            onPressed: _openPacksSheet,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge(
            [widget.controller.installed, widget.controller.packsListenable]),
        builder: (context, _) {
          final items = widget.controller.shelf(
            category: _category,
            tag: _tag ?? '',
            query: _search.text,
            sort: _sort,
          );
          final categories = widget.controller.categories();
          final tags = widget.controller.topTags();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // —— 搜索（命中范围：名字/简介/标签/正文，ExpertCatalog.matches）——
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: TextField(
                  key: const Key('experts_search'),
                  controller: _search,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜名字、简介、标签或正文',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              // —— 领域分组 chips ——
              _chipRow(
                children: [
                  ChoiceChip(
                    label: const Text(ExpertCatalog.all),
                    selected: _category == null,
                    onSelected: (_) => setState(() => _category = null),
                  ),
                  for (final c in categories)
                    ChoiceChip(
                      label: Text(c),
                      selected: _category == c,
                      onSelected: (_) =>
                          setState(() => _category = _category == c ? null : c),
                    ),
                ],
              ),
              // —— 标签 + 排序 chips ——
              if (tags.isNotEmpty)
                _chipRow(
                  children: [
                    for (final t in tags)
                      ChoiceChip(
                        label: Text('#$t'),
                        selected: _tag == t,
                        onSelected: (_) =>
                            setState(() => _tag = _tag == t ? null : t),
                      ),
                    const VerticalDivider(width: 16),
                    for (final s in ExpertSort.values)
                      ChoiceChip(
                        label: Text(s.label),
                        selected: _sort == s,
                        onSelected: (_) => setState(() => _sort = s),
                      ),
                  ],
                ),
              const Divider(height: 1),
              Expanded(
                child: items.isEmpty
                    ? const Center(child: Text('没有匹配的专家'))
                    : GridView.builder(
                        // 固定行高的响应式网格：内置示例包的专家按名字序
                        // 排开后，单列列表在 800×600 一类首屏只能露出前几
                        // 位——两列网格让整架在首屏露脸，行高 88 与 tile
                        // 自然高度匹配不裁字。
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 420,
                          mainAxisExtent: 88,
                        ),
                        itemCount: items.length,
                        itemBuilder: (context, i) =>
                            _expertTile(items[i], scheme),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _chipRow({required List<Widget> children}) => SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          children: children,
        ),
      );

  Widget _expertTile(ExpertShelfItem item, ColorScheme scheme) {
    final blurb = item.description.trim().isNotEmpty
        ? item.description.trim()
        : _firstBodyLine(item.body);
    return Card(
      // 竖向留白收紧 + dense tile：网格行高固定 88，tile 自然高度要压在
      // 行高以内才不裁字。
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: ListTile(
        dense: true,
        leading: Text(item.avatar, style: const TextStyle(fontSize: 24)),
        title: Row(
          children: [
            Flexible(child: Text(item.name, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 6),
            if (item.inLibrary)
              _badge(
                  '已入库', scheme.secondaryContainer, scheme.onSecondaryContainer)
            else
              _badge('目录', scheme.surfaceContainerHighest,
                  scheme.onSurfaceVariant),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (blurb.isNotEmpty)
              Text(blurb, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(
              [
                if (item.category.isNotEmpty) item.category,
                if (item.tags.isNotEmpty) item.tags.take(3).join(' / '),
                item.usedCount > 0 ? '用过 ${item.usedCount} 次' : '未使用',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        onTap: () => _openDetail(item),
      ),
    );
  }

  Widget _badge(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: TextStyle(fontSize: 11, color: fg)),
      );

  /// 正文第一行（剥掉短键名当简介用，与 PersonasEntry.blurb 同一处理）。
  String _firstBodyLine(String body) {
    for (final l in body.split('\n')) {
      final t = l.trim();
      if (t.isEmpty) continue;
      final sep = t.indexOf('：');
      if (sep >= 1 && sep <= 4) return t.substring(sep + 1).trim();
      return t;
    }
    return '';
  }

  // ------------------------------------------------------------------ 详情

  /// 专家详情：浏览层信息 + promptText 预览 + 两个套用动作。
  Future<void> _openDetail(ExpertShelfItem item) async {
    // 按 id 重查：列表项可能是旧快照，重查保证正文/热度是最新的。
    final current = widget.controller.shelfItemById(item.id) ?? item;
    final preview = PersonaCard.parse(current.body).promptText();
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
                Row(
                  children: [
                    Text(current.avatar, style: const TextStyle(fontSize: 28)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(current.name,
                          style: Theme.of(sheetContext).textTheme.titleLarge),
                    ),
                    Text(current.category,
                        style: TextStyle(
                            color: Theme.of(sheetContext)
                                .colorScheme
                                .onSurfaceVariant)),
                  ],
                ),
                if (current.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(current.description.trim()),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final t in current.tags) Chip(label: Text(t)),
                  ],
                ),
                const SizedBox(height: 8),
                // 来源追踪（用户校准项）：这位专家是谁、从哪个包装进来的。
                Text(
                  '${current.usedCount > 0 ? '用过 ${current.usedCount} 次 · ' : ''}'
                  '来源：${current.sourceRef}',
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          Theme.of(sheetContext).colorScheme.onSurfaceVariant),
                ),
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
                    preview.isEmpty ? '（空正文）' : preview,
                    style: const TextStyle(fontSize: 13, height: 1.4),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        key: const Key('experts_apply_global'),
                        onPressed: () => _applyGlobal(sheetContext, current),
                        icon: const Icon(Icons.public),
                        label: const Text('套用为全局风格'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('experts_apply_contact'),
                        onPressed: () => _applyContact(sheetContext, current),
                        icon: const Icon(Icons.person_outline),
                        label: const Text('套用为联系人人设'),
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

  /// 「套用为全局风格」。StyleSource 优先级（style_source.dart:27 的既定
  /// 事实：联系人专用人设压过全局风格）要求**照实说话**：存在写了专用人设
  /// 的联系人时先弹确认，说明这次套用对 TA 们不生效——否则「点了用却没
  /// 反应」的体感误会会落到全局风格上。
  Future<void> _applyGlobal(
      BuildContext sheetContext, ExpertShelfItem item) async {
    final controller = widget.controller;
    if (!controller.hasStyleSink) {
      _snackOf(sheetContext, '全局风格未接线（#13），暂时不能套用', error: true);
      return;
    }
    final shadowed = controller.contactTargets
        .where(ExpertsController.contactHasPersona)
        .toList();
    if (shadowed.isNotEmpty) {
      final goOn = await _confirmStyleSourceShadow(sheetContext, shadowed);
      if (goOn != true || !sheetContext.mounted) return;
    }
    final result = await controller.applyAsGlobalStyle(item);
    if (!sheetContext.mounted) return;
    Navigator.of(sheetContext).pop(); // 套用后收起详情，列表刷新显示新热度。
    _snack(
        result.ok
            ? '已套用为全局风格${result.warning.isEmpty ? '' : '；${result.warning}'}'
            : result.problem,
        error: !result.ok);
  }

  /// StyleSource 优先级确认：这些联系人写了专用人设，全局风格对 TA 们不生效。
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
            key: const Key('experts_confirm_shadowed'),
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
  /// 全局风格）。
  Future<void> _applyContact(
      BuildContext sheetContext, ExpertShelfItem item) async {
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
                // （ExpertsController.contactHasPersona），不再手写 trim 判空。
                trailing: ExpertsController.contactHasPersona(t)
                    ? const Tooltip(
                        message: '已有专用人设',
                        child: Icon(Icons.description_outlined),
                      )
                    : null,
                subtitle: ExpertsController.contactHasPersona(t)
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
    // 写（expert_apply.dart:167 的既定语义）；无冲突则直接生效。
    var result = await controller.applyToContact(item, picked);
    if (!sheetContext.mounted) return;
    if (result.needsChoice) {
      final choice = await showDialog<_PersonaApplyChoice>(
        context: sheetContext,
        builder: (dialogContext) => AlertDialog(
          title: Text('覆盖「${picked.displayName}」的专用人设？'),
          content: const Text(
            '这位联系人已有专用人设（专用人设优先于全局风格）。\n\n'
            '覆盖套用：与 TA 的聊天改用新的人设，原专用人设被覆盖。\n'
            '并存套用：这条专家写入全局风格，原专用人设保留并继续生效'
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
                  ? () =>
                      Navigator.of(dialogContext).pop(_PersonaApplyChoice.coexist)
                  : null,
              child: const Text('并存套用'),
            ),
            FilledButton(
              key: const Key('experts_confirm_overwrite'),
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_PersonaApplyChoice.overwrite),
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
      result = await controller.applyToContact(item, picked, choice: kbChoice);
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

  // -------------------------------------------------------------- 资产包区

  /// 资产包管理区：已安装列表（含来源追踪）+ 安装入口。文件选择器接线留
  /// **#13**——当前以粘贴 JSON 的方式安装，入口按钮照常可用。
  Future<void> _openPacksSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.8,
          ),
          child: ListenableBuilder(
            listenable: widget.controller.packsListenable,
            builder: (context, _) {
              final packs = widget.controller.packs;
              return ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(16),
                children: [
                  Text('资产包（按需安装的专家目录）',
                      style: Theme.of(sheetContext).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  // 坏包快照（core：坏包被忽略而不是被删除，照实说）。
                  for (final p in widget.controller.packProblems.value)
                    Text(
                      p,
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(sheetContext).colorScheme.error),
                    ),
                  for (final pack in packs)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.inventory_2_outlined),
                      title: Text(
                          pack.meta.name.isEmpty ? '（未命名包）' : pack.meta.name),
                      subtitle: Text(
                        [
                          '${pack.expertCount} 位专家 · v${pack.meta.version}',
                          if (pack.meta.source.isNotEmpty) pack.meta.source,
                          if (pack.meta.sourceCommit.isNotEmpty)
                            'commit ${pack.meta.sourceCommit}',
                          if (pack.meta.contentHash.isNotEmpty)
                            '内容指纹 ${pack.meta.contentHash}',
                        ].join('\n'),
                        style: const TextStyle(fontSize: 12),
                      ),
                      // 内置包是货架底座不可卸载（core 会拒，按钮直接不给）。
                      trailing: pack.meta.id == ExpertsController.builtinPackId
                          ? null
                          : IconButton(
                              tooltip: '卸载',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _uninstallPack(sheetContext, pack),
                            ),
                    ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    key: const Key('experts_install_pack'),
                    onPressed: () => _installPack(sheetContext),
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('安装资产包'),
                  ),
                  const SizedBox(height: 4),
                  // 安装入口的「预留」部分照实说明：文件选择器走 #13 接线。
                  Text(
                    '文件选择器入口预留（#13 接线）；当前可粘贴资产包 JSON 安装。',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(sheetContext)
                            .colorScheme
                            .onSurfaceVariant),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _installPack(BuildContext sheetContext) async {
    // pop 载荷就是粘贴的 JSON（null = 取消）。controller 归弹层自己所有：
    // 页面侧 await 完就 dispose 会在退场动画期间撞 use-after-dispose。
    final json = await showDialog<String>(
      context: sheetContext,
      builder: (dialogContext) => const _PackJsonDialog(),
    );
    if (json == null || !mounted) return;
    try {
      final result = await widget.controller.installPackJson(json);
      if (!mounted) return;
      // 同版本幂等：core 什么都没写（alreadyCurrent），照实说而不是假装「已安装」。
      _snack(result.action == InstallAction.alreadyCurrent
          ? (result.warning.isEmpty ? '同版本已安装，未重复写入' : result.warning)
          : '已安装「${result.pack!.meta.name}」：${result.pack!.expertCount} 位专家'
              '${result.warning.isEmpty ? '' : '；${result.warning}'}');
    } on FormatException catch (e) {
      _snack('安装失败：${e.message}', error: true);
    } on StateError catch (e) {
      // StateError.message 非空（dart:core 现行定义）：直接展示 throw 点的
      // 诊断（如「资产包落盘失败（…），本次没有安装」）。
      _snack(e.message, error: true);
    }
  }

  /// 卸载一个已安装包（core ExpertPackManager.uninstall：内置包不可卸载、
  /// 没装过报「没有安装过」）。结果（含失败原因）直接给 SnackBar 照实说。
  Future<void> _uninstallPack(
      BuildContext sheetContext, ExpertPackData pack) async {
    final r = await widget.controller.uninstallPack(pack.meta.id);
    if (!sheetContext.mounted) return;
    _snackOf(
      sheetContext,
      r.ok
          ? '已卸载「${pack.meta.name.isEmpty ? pack.meta.id : pack.meta.name}」'
          : r.problem,
      error: !r.ok,
    );
  }

  void _snack(String message, {bool error = false}) =>
      _snackOf(context, message, error: error);

  void _snackOf(BuildContext ctx, String message, {bool error = false}) {
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Theme.of(ctx).colorScheme.error : null,
    ));
  }
}

/// 套用为联系人人设时的用户裁决（core ExpertApply 的 needsChoice 语义）：
/// 覆盖专用人设 / 并存（只写全局风格、专用人设保留并继续压全局）/ 取消。
enum _PersonaApplyChoice { overwrite, coexist, cancel }

/// 安装资产包的粘贴 JSON 弹层。controller 由弹层 State 持有并在自己的
/// dispose 里释放——退场动画期间 TextField 还挂在树上，弹层关闭后立刻在
/// 页面侧 dispose 会撞「used after being disposed」断言。
class _PackJsonDialog extends StatefulWidget {
  const _PackJsonDialog();

  @override
  State<_PackJsonDialog> createState() => _PackJsonDialogState();
}

class _PackJsonDialogState extends State<_PackJsonDialog> {
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('安装资产包'),
        content: SizedBox(
          width: 400,
          child: TextField(
            key: const Key('experts_pack_json'),
            controller: _input,
            maxLines: 8,
            decoration: const InputDecoration(
              hintText: '粘贴资产包 JSON（jev-expert-pack/1：'
                  'format + pack{id,version} + experts）',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('experts_pack_install_confirm'),
            onPressed: () => Navigator.of(context).pop(_input.text),
            child: const Text('安装'),
          ),
        ],
      );
}

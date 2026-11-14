import 'package:chartools_core/chartools_core.dart'
    show ConflictChoice, ExpertCatalog, ExpertPackData, InstallAction, PersonaCard;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../application/experts_controller.dart';

/// 专家库页（专家目录浏览 + 套用 + 我的自建专家管理 + 资产包管理）。
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
/// 我的自建专家（mine 条目）：现状与目录样品同网格混排，靠**来源徽章
/// mine/seed/pack** 区分 + 「我的库」快筛 chip 保证可见；编辑/删除入口在
/// 详情页与长按菜单（只对 mine 条目开放——updateMineExpert/deleteMineExpert
/// 对 seed:/pack: 来源拒改并抛 ArgumentError，页面不给出会失败的入口）。
/// 新建/编辑走同一个表单弹层：名称 + 结构化 PersonaCard 字段（称呼/关系/
/// 语气/情境/硬边界/安全词/避谈，与 personas_page 同款输入风格）+ 高级区
/// （直接编辑整段 promptText，进阶用户用）；保存调 createMineExpert /
/// updateMineExpert（契约见 experts_controller.dart）。空状态给「新建专家」
/// 引导（FAB + 空态按钮）。
///
/// 资产包安装三入口：粘贴 JSON（core PackCodec 严格校验）、**从文件导入**
/// （file_selector 选 .json → installPackFromFile）、**从 URL 安装**
/// （manifest 地址 → installFromRemote，packId 可选高级框；拉取中给进度并
/// 禁止重复点击，失败把 RemoteInstallReport.problem 展示给用户）。文件选择
/// 器依赖（app/pubspec.yaml 的 file_selector）由控制器侧落地，本页只
/// import 使用；测试经 [ExpertsPage.packFilePicker] 注入假选择器。
///
/// 浏览层与正文层的分界（沿用 legacy 的铁律）：列表/搜索/标签只读浏览层
/// 字段；点进详情看到的「提示词预览」是 `PersonaCard.parse(body).promptText()`
/// ——与起草提示词拿到的人设卡同一条路径，页面不做任何第二份解析。
class ExpertsPage extends StatefulWidget {
  const ExpertsPage({
    super.key,
    required this.controller,
    this.packFilePicker,
  });

  final ExpertsController controller;

  /// 「从文件导入」的文件选择器注入点（测试用）：null = 生产路径走
  /// file_selector 的 openFile（选 .json）。返回 null 表示用户取消。
  final Future<XFile?> Function()? packFilePicker;

  @override
  State<ExpertsPage> createState() => _ExpertsPageState();
}

class _ExpertsPageState extends State<ExpertsPage> {
  final TextEditingController _search = TextEditingController();

  /// 「从文件导入 / 从 URL 安装 / 粘贴安装」进行中：三个安装入口一起禁用
  /// （禁止重复点击）。用 ValueNotifier 而不是 setState——进度要反映到
  /// 资产包 sheet（独立路由，不随页面 setState 重建）。
  final ValueNotifier<bool> _installBusy = ValueNotifier(false);

  /// 当前筛选：分类（null = 全部）、标签（null = 不筛）、排序、仅看我的库。
  String? _category;
  String? _tag;
  ExpertSort _sort = ExpertSort.comprehensive;
  bool _onlyMine = false;

  @override
  void dispose() {
    _search.dispose();
    _installBusy.dispose();
    super.dispose();
  }

  /// 「这条是不是我的自建条目」：已入库且来源串为 mine（契约：
  /// createMineExpert 产出的条目 id 形如 `mine:<时间戳或uuid>`、source 标
  /// mine；旧存档自建条目的 sourceRef 同为 mine）。编辑/删除入口只对它
  /// 开放——updateMineExpert/deleteMineExpert 对 seed:/pack: 来源拒改，
  /// 不给会失败的入口。
  static bool _isMine(ExpertShelfItem item) =>
      item.inLibrary && item.sourceRef == 'mine';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('专家库'),
        // 资产包管理区入口：已安装列表 + 三种安装入口。
        actions: [
          IconButton(
            tooltip: '资产包',
            icon: const Icon(Icons.inventory_2_outlined),
            onPressed: _openPacksSheet,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('experts_mine_new'),
        onPressed: () => _openMineSheet(null),
        icon: const Icon(Icons.add),
        label: const Text('新建专家'),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge(
            [widget.controller.installed, widget.controller.packsListenable]),
        builder: (context, _) {
          final allItems = widget.controller.shelf(
            category: _category,
            tag: _tag ?? '',
            query: _search.text,
            sort: _sort,
          );
          final mineCount = allItems.where(_isMine).length;
          final items =
              _onlyMine ? allItems.where(_isMine).toList() : allItems;
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
              // ——「我的库」快筛 + 领域分组 chips ——
              //
              // mine 条目与目录样品同网格混排：快筛 chip 保证自建专家一键
              // 可见可管（与领域/标签筛选叠加），来源徽章（见 _sourceBadge）
              // 负责混排时的区分。
              _chipRow(
                children: [
                  ChoiceChip(
                    key: const Key('experts_filter_mine'),
                    label: const Text('我的库'),
                    selected: _onlyMine,
                    onSelected: (_) => setState(() => _onlyMine = !_onlyMine),
                  ),
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
                    ? Center(
                        // 空状态引导（#15）：我的库为空时直说，并给「新建专家」
                        // 按钮；筛选/搜索无命中时同样可顺手新建。
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_onlyMine && mineCount == 0
                                ? '还没有自建专家。点下面新建一个。'
                                : '没有匹配的专家'),
                            const SizedBox(height: 12),
                            FilledButton.tonalIcon(
                              key: const Key('experts_mine_new_empty'),
                              onPressed: () => _openMineSheet(null),
                              icon: const Icon(Icons.add),
                              label: const Text('新建专家'),
                            ),
                          ],
                        ),
                      )
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
            _sourceBadge(item, scheme),
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
        // 长按快捷入口：只对自建条目弹「编辑 / 删除」（契约：非 mine 来源
        // 拒改拒删，不给入口）。
        onLongPress: _isMine(item) ? () => _showMineActions(item) : null,
      ),
    );
  }

  /// 来源徽章（混排网格的区分手段）：mine=我的自建（高亮色）、seed=内置包、
  /// pack=已装资产包、目录=货架样品（未入库）。徽章字样 mine/seed/pack 同时
  /// 说明「已入库」——与「目录」相对。
  Widget _sourceBadge(ExpertShelfItem item, ColorScheme scheme) {
    if (!item.inLibrary) {
      return _badge(
          '目录', scheme.surfaceContainerHighest, scheme.onSurfaceVariant);
    }
    final ref = item.sourceRef;
    if (ref == 'mine') {
      return _badge('mine', scheme.secondaryContainer, scheme.onSecondaryContainer);
    }
    if (ref.startsWith('seed:')) {
      return _badge(
          'seed', scheme.surfaceContainerHighest, scheme.onSurfaceVariant);
    }
    if (ref.startsWith('pack:')) {
      return _badge(
          'pack', scheme.surfaceContainerHighest, scheme.onSurfaceVariant);
    }
    // 旧存档里来源串缺失的入库条目：退回「已入库」。
    return _badge('已入库', scheme.secondaryContainer, scheme.onSecondaryContainer);
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

  // ---------------------------------------------------- 我的自建专家管理

  /// 新建（[existing] = null）与编辑共用的表单弹层；pop 载荷是表单快照
  /// （null = 取消），异步落库在页面侧完成。契约照抄：createMineExpert /
  /// updateMineExpert（mine 来源条目 id 形如 mine:<时间戳或uuid>）。
  Future<void> _openMineSheet(ExpertShelfItem? existing) async {
    final values = await showModalBottomSheet<_MineExpertValues>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _MineExpertSheet(existing: existing),
    );
    if (values == null || !mounted) return;
    try {
      if (existing == null) {
        // domain/tags 不在表单字段里（契约的可选参）：domain 置空（未分类，
        // 浏览层字段不进提示词）、tags 显式传空列表（契约的 tags 无默认值
        // 形状，显式传，两侧签名兼容）。
        final expert = await widget.controller.createMineExpert(
          name: values.name,
          promptText: values.promptText,
          tags: const <String>[],
        );
        if (!mounted) return;
        _snack('已新建「${expert.name}」');
      } else {
        final expert = await widget.controller.updateMineExpert(
          existing.id,
          name: values.name,
          promptText: values.promptText,
        );
        if (!mounted) return;
        _snack('已保存「${expert.name}」');
      }
    } on ArgumentError catch (e) {
      // 名称/正文校验拒绝、非 mine 来源拒改——契约的 ArgumentError，照实说。
      if (mounted) _snack('${e.message}', error: true);
    } on StateError catch (e) {
      if (mounted) _snack(e.message, error: true);
    }
  }

  /// 长按 mine 条目的快捷菜单：编辑 / 删除（与详情页同一对动作）。
  Future<void> _showMineActions(ExpertShelfItem item) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (menuContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              key: const Key('experts_mine_edit_menu'),
              leading: const Icon(Icons.edit_outlined),
              title: Text('编辑「${item.name}」'),
              onTap: () {
                Navigator.of(menuContext).pop();
                _openMineSheet(item);
              },
            ),
            ListTile(
              key: const Key('experts_mine_delete_menu'),
              leading: const Icon(Icons.delete_outline),
              title: Text('删除「${item.name}」'),
              onTap: () => _confirmDeleteMine(menuContext, item),
            ),
          ],
        ),
      ),
    );
  }

  /// 删除一条自建专家（契约：deleteMineExpert 仅 mine 条目可删）。先确认
  /// （personas 删除同款文案），成功后收起承载它的弹层（详情页或长按菜单）
  /// 并提示；失败（非 mine / 条目已不在）照实报错。
  Future<void> _confirmDeleteMine(
      BuildContext sheetContext, ExpertShelfItem item) async {
    final goOn = await showDialog<bool>(
      context: sheetContext,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除「${item.name}」？'),
        content: const Text('删除后不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('experts_mine_delete_confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (goOn != true || !sheetContext.mounted) return;
    try {
      final expert = await widget.controller.deleteMineExpert(item.id);
      if (!sheetContext.mounted) return;
      Navigator.of(sheetContext).pop(); // 收起详情页 / 长按菜单
      _snack('已删除「${expert.name}」');
    } on ArgumentError catch (e) {
      if (sheetContext.mounted) _snackOf(sheetContext, '${e.message}', error: true);
    } on StateError catch (e) {
      if (sheetContext.mounted) _snackOf(sheetContext, e.message, error: true);
    }
  }

  // ------------------------------------------------------------------ 详情

  /// 专家详情：浏览层信息 + promptText 预览 + 两个套用动作（+ mine 条目的
  /// 编辑/删除行）。
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
                // —— 我的自建条目：编辑 / 删除。只对 mine 开放（契约：
                //    updateMineExpert/deleteMineExpert 对 seed:/pack: 来源
                //    拒改拒删；不给会失败的入口）。
                if (_isMine(current)) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          key: const Key('experts_mine_edit'),
                          onPressed: () {
                            Navigator.of(sheetContext).pop();
                            _openMineSheet(current);
                          },
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('编辑'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('experts_mine_delete'),
                          onPressed: () =>
                              _confirmDeleteMine(sheetContext, current),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('删除'),
                        ),
                      ),
                    ],
                  ),
                ],
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

  /// 资产包管理区：已安装列表（含来源追踪）+ 安装三入口（粘贴 JSON / 从文件
  /// 导入 / 从 URL 安装）。拉取或落盘进行中（_installBusy）时三入口一起禁用。
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
                  ValueListenableBuilder<bool>(
                    valueListenable: _installBusy,
                    builder: (context, busy, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FilledButton.tonalIcon(
                          key: const Key('experts_install_pack'),
                          onPressed:
                              busy ? null : () => _installPack(sheetContext),
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('安装资产包'),
                        ),
                        const SizedBox(height: 4),
                        OutlinedButton.icon(
                          key: const Key('experts_install_from_file'),
                          onPressed:
                              busy ? null : () => _installFromFile(sheetContext),
                          icon: const Icon(Icons.folder_open_outlined),
                          label: const Text('从文件导入'),
                        ),
                        const SizedBox(height: 4),
                        OutlinedButton.icon(
                          key: const Key('experts_install_from_url'),
                          onPressed:
                              busy ? null : () => _installFromUrl(sheetContext),
                          icon: const Icon(Icons.cloud_download_outlined),
                          label: const Text('从 URL 安装'),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 粘贴 JSON 安装（原入口保留）。controller 归弹层自己所有：页面侧 await
  /// 完就 dispose 会在退场动画期间撞 use-after-dispose。
  Future<void> _installPack(BuildContext sheetContext) async {
    // pop 载荷就是粘贴的 JSON（null = 取消）。
    final json = await showDialog<String>(
      context: sheetContext,
      builder: (dialogContext) => const _PackJsonDialog(),
    );
    if (json == null || !mounted) return;
    _installBusy.value = true;
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
    } finally {
      _installBusy.value = false;
    }
  }

  /// 「从文件导入」（契约：installPackFromFile(String filePath)，读文件
  /// utf8 → 复用 installPackJson；文件不存在/非 UTF-8 报可读错误）。文件
  /// 选择器依赖（file_selector）由控制器侧在 pubspec 落地，本页只 import
  /// 使用；测试经 [ExpertsPage.packFilePicker] 注入假选择器。
  Future<void> _installFromFile(BuildContext sheetContext) async {
    _installBusy.value = true;
    final XFile? file;
    try {
      file = await (widget.packFilePicker ?? _defaultPickPackFile)();
    } catch (e) {
      // 选择器本身出错（平台缺实现等）：照实说，别把锅甩给包内容。
      _installBusy.value = false;
      if (!mounted) return;
      _snack('打不开文件选择器：$e', error: true);
      return;
    }
    if (file == null) {
      _installBusy.value = false; // 用户取消
      return;
    }
    try {
      final result = await widget.controller.installPackFromFile(file.path);
      if (!mounted) return;
      if (!result.ok) {
        // 契约允许「失败以报告返回」（problem 用户可读）：照实展示。
        _snack(result.problem.isEmpty ? '导入失败' : result.problem, error: true);
        return;
      }
      // 同版本幂等：core 什么都没写（alreadyCurrent），照实说而不是假装「已导入」。
      _snack(result.action == InstallAction.alreadyCurrent
          ? (result.warning.isEmpty ? '同版本已安装，未重复写入' : result.warning)
          : '已从文件导入「${result.pack?.meta.name ?? '资产包'}」：'
              '${result.pack?.expertCount ?? 0} 位专家'
              '${result.warning.isEmpty ? '' : '；${result.warning}'}');
    } on FormatException catch (e) {
      if (mounted) _snack('导入失败：${e.message}', error: true);
    } on StateError catch (e) {
      if (mounted) _snack(e.message, error: true);
    } catch (e) {
      // 契约的「可读错误」之外的兜底（如文件系统 IO 异常）：照实说。
      if (mounted) _snack('导入失败：$e', error: true);
    } finally {
      _installBusy.value = false;
    }
  }

  /// 生产路径的文件选择器（file_selector）：选 .json。测试用
  /// [ExpertsPage.packFilePicker] 替换。
  Future<XFile?> _defaultPickPackFile() => openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: '资产包 JSON', extensions: <String>['json']),
        ],
      );

  /// 「从 URL 安装」（契约：installFromRemote(String manifestUrl,
  /// {String? packId})，packId 留空 = 装清单里的最新/第一个）。弹层内部自带
  /// 拉取进度与错误展示（_busy 期间确认键禁用 = 禁止重复点击）；失败时
  /// RemoteInstallReport.problem 留在弹层里，用户可改地址重试；成功才 pop
  /// 报告出来给一句收尾提示。
  Future<void> _installFromUrl(BuildContext sheetContext) async {
    final report = await showDialog<RemoteInstallReport>(
      context: sheetContext,
      builder: (dialogContext) =>
          _RemoteInstallDialog(controller: widget.controller),
    );
    if (report == null || !mounted) return;
    if (!report.ok) {
      _snack(report.problem.isEmpty ? '安装失败' : report.problem, error: true);
      return;
    }
    _snack('已安装资产包「${report.packId}」v${report.version}：'
        '${report.expertsInstalled} 位专家');
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

/// 「从 URL 安装」弹层：清单地址（必填）+ 包 id（可选，高级框，留空 = 装清单
/// 里的最新/第一个）。拉取中显示进度并把确认键禁用（禁止重复点击）；失败把
/// RemoteInstallReport.problem（或抛出的异常）显示在本层，地址可改后重试；
/// 成功才把报告 pop 回页面。
class _RemoteInstallDialog extends StatefulWidget {
  const _RemoteInstallDialog({required this.controller});

  final ExpertsController controller;

  @override
  State<_RemoteInstallDialog> createState() => _RemoteInstallDialogState();
}

class _RemoteInstallDialogState extends State<_RemoteInstallDialog> {
  final TextEditingController _url = TextEditingController();
  final TextEditingController _packId = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _packId.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final url = _url.text.trim();
    if (url.isEmpty) {
      setState(() => _error = '请填写清单地址');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final packId = _packId.text.trim();
      final report = await widget.controller.installFromRemote(
        url,
        packId: packId.isEmpty ? null : packId,
      );
      if (!mounted) return;
      if (!report.ok) {
        setState(() {
          _busy = false;
          _error = report.problem.isEmpty ? '安装失败' : report.problem;
        });
        return;
      }
      Navigator.of(context).pop(report);
    } catch (e) {
      // 网络层异常兜底（清单拉不到、断网等）：照实说，留在本层可重试。
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '安装失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('从 URL 安装'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('experts_remote_url'),
                controller: _url,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: '清单地址（manifest URL）',
                  hintText: 'https://…/experts-manifest.json',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('experts_remote_pack_id'),
                controller: _packId,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: '包 id（可选，高级）',
                  hintText: '留空 = 装清单里的最新/第一个',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              if (_busy)
                const Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('正在拉取清单并安装…'),
                  ],
                ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('experts_remote_confirm'),
            onPressed: _busy ? null : _confirm,
            child: const Text('安装'),
          ),
        ],
      );
}

/// 新建/编辑「我的专家」表单的取值快照：保存时由表单弹层从控制器取值组装成
/// pop 载荷，页面拿到的是纯数据，异步落库不再碰已退场的弹层（personas 同款
/// 所有权纪律）。
class _MineExpertValues {
  const _MineExpertValues({required this.name, required this.promptText});

  final String name;
  final String promptText;
}

/// 新建/编辑「我的专家」的表单弹层。
///
/// 字段 = 名称 + 结构化 PersonaCard 字段（称呼/关系/语气/情境/硬边界/安全词/
/// 避谈，输入风格与 personas_page 同款）+ 高级区（直接编辑整段 promptText，
/// 进阶用户用）。正文只有一个真相源：**高级区的文本框**——用户没碰高级区时，
/// 结构化字段的每次改动实时回写它（[ExpertPromptCard.assemble]）；用户一旦
/// 直接编辑高级区，以那里的逐字内容为准（可点「按字段重新生成」回到字段
/// 拼装）。编辑已有 mine 条目时同层预填：结构化字段从原卡解析回填，硬边界/
/// 避谈取原文行的原词（不取解析展开后的关键词集合），没进表单的卡内容
/// （主题/黄灯/语域/示例/未识别行）经原卡快照在拼装时保留。
///
/// 控制器归本弹层所有并在自己的 dispose 里释放（退场动画期间输入框还挂在
/// 树上，页面侧 await 完就 dispose 会撞「used after being disposed」断言）。
class _MineExpertSheet extends StatefulWidget {
  const _MineExpertSheet({this.existing});

  final ExpertShelfItem? existing;

  @override
  State<_MineExpertSheet> createState() => _MineExpertSheetState();
}

class _MineExpertSheetState extends State<_MineExpertSheet> {
  final _formKey = GlobalKey<FormState>();

  /// 编辑已有条目时的原卡快照：拼装时保留没进表单的键。
  late final PersonaCard _base = PersonaCard.parse(widget.existing?.body ?? '');

  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _address =
      TextEditingController(text: _base.address);
  late final TextEditingController _relation =
      TextEditingController(text: _base.relation);
  late final TextEditingController _tone =
      TextEditingController(text: _base.tone);
  late final TextEditingController _scene =
      TextEditingController(text: _base.scene);
  // 硬边界/避谈的预填取原文行的**原词**（ExpertPromptCard.rawListText）——
  // PersonaCard.parse 的 boundaries 是展开后的关键词集合（前缀/动词剥离的
  // 变体都在里面），直接回填再保存会越滚越多。
  late final TextEditingController _boundaries = TextEditingController(
      text: ExpertPromptCard.rawListText(
          widget.existing?.body ?? '', ExpertPromptCard.boundaryKeys));
  late final TextEditingController _safeword =
      TextEditingController(text: _base.safeword);
  late final TextEditingController _avoid = TextEditingController(
      text: ExpertPromptCard.rawListText(
          widget.existing?.body ?? '', ExpertPromptCard.avoidKeys));
  late final TextEditingController _advanced =
      TextEditingController(text: widget.existing?.body ?? '');

  /// 用户直接编辑过高级区：此后正文以高级区为准，结构化字段不再回写。
  bool _advancedTouched = false;

  @override
  void dispose() {
    for (final c in [
      _name,
      _address,
      _relation,
      _tone,
      _scene,
      _boundaries,
      _safeword,
      _avoid,
      _advanced,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// 结构化字段 → 高级区回写（用户没接管高级区时）。
  void _syncAdvanced() {
    if (_advancedTouched) return;
    _advanced.text = ExpertPromptCard.assemble(
      base: _base,
      address: _address.text,
      relation: _relation.text,
      tone: _tone.text,
      scene: _scene.text,
      boundaries: ExpertPromptCard.splitList(_boundaries.text),
      safeword: _safeword.text,
      avoid: ExpertPromptCard.splitList(_avoid.text),
    );
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
              Text(existing == null ? '新建专家' : '编辑「${existing.name}」',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('experts_mine_name'),
                controller: _name,
                decoration: const InputDecoration(
                    labelText: '名称（必填）', border: OutlineInputBorder()),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '名称不能为空' : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                key: const Key('experts_mine_address'),
                controller: _address,
                onChanged: (_) => _syncAdvanced(),
                decoration: const InputDecoration(
                    labelText: '称呼',
                    hintText: '如：X 总 / 平时的叫法',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextFormField(
                key: const Key('experts_mine_relation'),
                controller: _relation,
                onChanged: (_) => _syncAdvanced(),
                decoration: const InputDecoration(
                    labelText: '关系',
                    hintText: '如：朋友 / 销售和客户',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextFormField(
                key: const Key('experts_mine_tone'),
                controller: _tone,
                onChanged: (_) => _syncAdvanced(),
                decoration: const InputDecoration(
                    labelText: '语气',
                    hintText: '如：口语松弛 / 短句、结论先行',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextFormField(
                key: const Key('experts_mine_scene'),
                controller: _scene,
                onChanged: (_) => _syncAdvanced(),
                decoration: const InputDecoration(
                    labelText: '情境',
                    hintText: '如：深夜聊天 / 微信或电话跟单',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextFormField(
                key: const Key('experts_mine_boundaries'),
                controller: _boundaries,
                onChanged: (_) => _syncAdvanced(),
                decoration: const InputDecoration(
                  labelText: '硬边界（顿号分隔，写关键词）',
                  hintText: '如：家人、前任——对方一提就停整轮',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                key: const Key('experts_mine_safeword'),
                controller: _safeword,
                onChanged: (_) => _syncAdvanced(),
                decoration: const InputDecoration(
                    labelText: '安全词',
                    hintText: '如：红灯——停止只归它',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextFormField(
                key: const Key('experts_mine_avoid'),
                controller: _avoid,
                onChanged: (_) => _syncAdvanced(),
                decoration: const InputDecoration(
                  labelText: '避谈（顿号分隔，约束我的措辞）',
                  hintText: '如：稳赚、保证收益——不拦对方、只管我的回复',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              // —— 高级区：整段 promptText 直编（进阶用户用）。折叠态下字段
              //    仍在树里（ExpansionTile 的 children 恒构建），“正文不能
              //    为空”的校验不依赖展开。
              ExpansionTile(
                key: const Key('experts_mine_advanced_tile'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text('高级：直接编辑整段提示词（进阶）'),
                children: [
                  TextFormField(
                    key: const Key('experts_mine_advanced'),
                    controller: _advanced,
                    maxLines: 8,
                    onChanged: (_) => setState(() => _advancedTouched = true),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? '正文不能为空（套用空正文等于清空人设）'
                        : null,
                    decoration: const InputDecoration(
                      labelText: '提示词正文（PersonaCard 卡片键原文）',
                      hintText: '留空时按上面的字段自动生成；改动后以这里为准',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_advancedTouched)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => setState(() {
                          _advancedTouched = false;
                          _syncAdvanced();
                        }),
                        child: const Text('按字段重新生成'),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '正文以「高级」区的当前内容为准；填了上面的字段会自动生成'
                '（称呼/关系/语气/情境/硬边界/安全词/避谈）。',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
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
                      key: const Key('experts_mine_save'),
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

  _MineExpertValues _values() => _MineExpertValues(
        name: _name.text.trim(),
        promptText: _advanced.text,
      );
}

/// 「我的专家」编辑对话框的字段 ↔ promptText 拼装工具（公开给 widget 测试做
/// 纯函数断言；页面内 [_MineExpertSheet] 使用）。
///
/// 存档形状 = PersonaCard **卡片键原文**（`称呼：…\n关系：…`），不是
/// PersonaCard.promptText() 的渲染块——渲染块里的「硬边界（…）：」长键行
/// 重新解析会掉进补充区（PersonaCard._splitKeyValue 的 12 字符键上限），键值
/// 卡原文才能被 PersonaCard.parse 无损认回（详情预览与起草提示词的解析走
/// 同一条路径）。进提示词前的最后一跳才由 PersonaCard.promptText 渲染，
/// 与本类无关。
class ExpertPromptCard {
  const ExpertPromptCard._();

  /// 硬边界 / 避谈键的别名（与 PersonaCard._keyAliases 的这两组一致——本地
  /// 副本只为「读原文行」服务，解析判定仍以 PersonaCard.parse 为准）。
  static const List<String> boundaryKeys = <String>[
    '边界',
    '硬边界',
    '底线',
    '禁忌',
    'limits',
    'hardlimits',
    'limit',
  ];
  static const List<String> avoidKeys = <String>['避谈', '回避', 'avoid'];

  /// 编辑预填：从原文里取 [keys] 这一组键行的**原词**（多行按出现顺序用顿号
  /// 接回）。不取 PersonaCard.parse 展开后的关键词集合——展开会把「不要提
  /// 家人」补成「提家人」「家人」等变体，回填再保存会越滚越多。
  static String rawListText(String raw, List<String> keys) {
    final wanted = <String>{for (final k in keys) _normKey(k)};
    final out = <String>[];
    for (final line
        in raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final cut = _splitLine(t);
      if (cut == null) continue;
      if (wanted.contains(_normKey(cut.$1))) out.add(cut.$2.trim());
    }
    return out.join('、');
  }

  /// 边界/避谈输入框的拆分（与 personas_page 的 _PersonasPageSplit 同一组
  /// 分隔符：顿号/逗号/分号/斜杠/竖线）。
  static List<String> splitList(String value) => [
        for (final p in value.split(RegExp('[、,，;；/|]+')))
          if (p.trim().isNotEmpty) p.trim(),
      ];

  /// 结构化字段 → PersonaCard 卡片键原文。[base] 是编辑前的原卡：对话框没有
  /// 的键（主题/黄灯/语域/示例/未识别行）从这里原样保留，改一个字段不抹掉
  /// 其余卡内容。全部为空时返回空串（保存前的「正文不能为空」校验兜底）。
  static String assemble({
    PersonaCard base = const PersonaCard(),
    String address = '',
    String relation = '',
    String tone = '',
    String scene = '',
    String safeword = '',
    List<String> boundaries = const [],
    List<String> avoid = const [],
  }) {
    final sb = StringBuffer();
    void line(String key, String value) {
      final v = value.trim();
      if (v.isNotEmpty) sb.write('$key：$v\n');
    }

    line('称呼', address);
    line('关系', relation);
    line('语气', tone);
    line('主题', base.topic);
    line('情境', scene);
    // 语域是 PersonaCard 的显式开关（自由文本永远放不开）；存档存短形「开」，
    // 重新解析即回 true（渲染块里的长句反而认不回）。
    if (base.registerOpen) sb.write('语域：开\n');
    if (boundaries.isNotEmpty) sb.write('硬边界：${boundaries.join('、')}\n');
    line('安全词', safeword);
    if (avoid.isNotEmpty) sb.write('避谈：${avoid.join('、')}\n');
    line('黄灯', base.yellow);
    if (base.examples.isNotEmpty) {
      sb.write('示例：\n');
      for (final e in base.examples) {
        sb.write('$e\n');
      }
    }
    // 未识别行逐行原样保留（PersonaCard.parse 对裸行进 extra；「补充：」键行
    // 的值 core 落在 scalars 里读不回——与渲染块同一行为，不在此处修）。
    for (final e in base.extra) {
      sb.write('$e\n');
    }
    final out = sb.toString();
    // 行间 \n 连接、末尾不带换行（卡片键原文的逐字契约；编辑框回填也不用在
    // 末尾先删空行）。PersonaCard.parse 对有无尾换行都无损认回。
    return out.endsWith('\n') ? out.substring(0, out.length - 1) : out;
  }

  /// 键行拆分（PersonaCard._splitKeyValue 的同款规则：键短、行首）。
  static (String, String)? _splitLine(String line) {
    final cn = line.indexOf('：');
    final en = line.indexOf(':');
    final at = cn < 0 ? en : (en < 0 ? cn : (cn < en ? cn : en));
    if (at <= 0 || at > 12) return null;
    final key = line.substring(0, at).trim();
    if (key.isEmpty || (key.contains(' ') && key.length > 6)) return null;
    return (key, line.substring(at + 1));
  }

  static String _normKey(String key) => key
      .trim()
      .toLowerCase()
      .replaceAll('-', '')
      .replaceAll('_', '')
      .replaceAll(' ', '');
}

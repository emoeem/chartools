import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/material.dart';

import '../../application/capture_session.dart';
import '../../application/contact_store.dart';

// fix(kimi-review #16)：候选区共用 widget。采集页（capture_page.dart）与桌面
// 粘贴页（desktop_assistant_page.dart）的候选卡 / B7 / B8 / G1 预览原先整段
// 复制各约 150 行，抽到这里——两页只传数据与回调。逐行核对过的功能清单：
// - B8 主推/展开：主推模式排序第一张大卡带「推荐」pill（策略标签+概率），
//   备选折叠为两行小字、点按展开；展开卡带「收回」口；all 模式整列平铺。
// - B7 不用回：canSkip 出口卡（[CandidateList.canSkipReply]）与「本轮已标记
//   为不用回」的安静态（[HandledReplyCard]）都在其中。
// - G7 反馈标签：候选卡底部的 [FeedbackTagRow]（注入偏好档案才渲染）。
// - G1 预览：[SendPreviewTile] 折叠面板（判/写两路各自收到什么）。
// 卡上的「记住这条」（G8）、「回填/复制」主按钮与「更短/更礼貌/换个说法」
// 改写按钮一并保留；两页差异只有主按钮文案与回调（采集页回填 / 桌面页复制）。

/// G1 隐私预览：折叠面板，展开看本轮判断/写作两条调用各自会收到什么。
/// 内容由会话/页面在轮次开始时算好（与实际发送同源）；[preview] 为 null
/// （没有轮次）时不显示。
class SendPreviewTile extends StatelessWidget {
  const SendPreviewTile({super.key, required this.preview});

  final SendPreview? preview;

  @override
  Widget build(BuildContext context) {
    final preview = this.preview;
    if (preview == null) return const SizedBox.shrink();
    return Card(
      child: ExpansionTile(
        title: const Text('本轮将发送'),
        subtitle: const Text('隐私预览：展开查看判断与写作各自收到什么'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          _PreviewGroup('判断路（先看局势）', preview.judge),
          const SizedBox(height: 8),
          _PreviewGroup('写作路（起草候选）', preview.writer),
        ],
      ),
    );
  }
}

/// G1 预览里的一组（判断路 / 写作路）条目列表。
class _PreviewGroup extends StatelessWidget {
  const _PreviewGroup(this.title, this.lines);

  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 2),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Text(
              '· $line',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// B7「本轮已标记为不用回」的安静确认态卡（采集页与桌面页同一份）。
/// 保留「反悔」的入口：[onRedraft] 传 null = 按钮禁用（桌面页忙碌中这样传）。
class HandledReplyCard extends StatelessWidget {
  const HandledReplyCard({
    super.key,
    required this.subtitle,
    required this.onRedraft,
  });

  /// 副标题两页口径不同（采集页「自动重新分析」/ 桌面页「重新粘贴分析」），
  /// 由页面传入。
  final String subtitle;

  final VoidCallback? onRedraft;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.check_circle_outline),
        title: const Text('本轮已标记为不用回'),
        subtitle: Text(subtitle),
        trailing: TextButton(
          onPressed: onRedraft,
          child: const Text('重新起草'),
        ),
      ),
    );
  }
}

/// 候选区：B7「这条可以不回」出口卡 + 「候选回复」标题行 + 候选卡列表
/// （B8 主推/平铺）。两页差异全部走参数：
/// - [primaryLabel] / [onPrimary]：「回填」（采集页）vs「复制」（桌面页）；
/// - [emptyLabel]：桌面页空列表显示「没有候选回复」占位；采集页传 null
///   （空列表时不渲染任何头部——原先就没有）；
/// - [onSwapReplies]：采集页的「换一组」；桌面页没有这个动作，传 null。
class CandidateList extends StatelessWidget {
  const CandidateList({
    super.key,
    required this.ranked,
    required this.primaryMode,
    required this.expandedCandidates,
    required this.onToggleExpand,
    required this.refiningIndexes,
    required this.onRefine,
    required this.onPrimary,
    required this.primaryLabel,
    this.emptyLabel,
    this.onSwapReplies,
    this.canSkipReply = false,
    this.onMarkHandled,
    this.contactStore,
    this.preferences,
    this.onPreferencesMutated,
  });

  /// 本轮排序后的候选（会话/页面侧已做过 F1 策略提前）。
  final List<RankedReply> ranked;

  /// B8 当前模式：true = 主推第一张大卡、备选折叠；false = 全部平铺。
  /// 由页面按共享的 displayMode notifier 计算（[primaryMode] 取值来源在页）。
  final bool primaryMode;

  /// B8 被点开展开的备选下标集合：页面私有状态，改完由页面 setState 重绘。
  final Set<int> expandedCandidates;

  /// 折叠行点按（展开）与展开卡「收回」（折回）共用的切换回调。
  final void Function(int index) onToggleExpand;

  /// 正在快速改写的候选下标：busy 只作用于该卡。
  final Set<int> refiningIndexes;

  /// 快速改写（更短 / 更礼貌 / 换个说法）。
  final void Function(int index, String instruction) onRefine;

  /// 卡片主动作：入参是候选原文（采集页回填输入框 / 桌面页写剪贴板）。
  final void Function(String text) onPrimary;

  /// 主按钮文案：「回填」或「复制」。
  final String primaryLabel;

  /// 空列表时的占位文案（桌面页「没有候选回复」）；null = 空列表不渲染头部。
  final String? emptyLabel;

  /// 标题行右侧的「换一组」；null = 不渲染（桌面页没有这个动作）。
  final VoidCallback? onSwapReplies;

  /// B7：判断明确说「这条可以不回」时先给出口卡。
  final bool canSkipReply;

  /// 出口卡「不用回」的回调；null = 不渲染出口卡。
  final VoidCallback? onMarkHandled;

  /// G8「记住这条」的入口（A 的 ContactStore）：null = 不渲染。
  final ContactStore? contactStore;

  /// G7 结构化偏好档案：null = 候选卡不带反馈标签行。
  final PreferenceProfile? preferences;

  /// 反馈记录后的联动回调（页面负责落盘 + 重绘其它卡上的勾选态）。
  final void Function()? onPreferencesMutated;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // B7：判断明确说「这条可以不回」时，先给这个出口——点了把本轮标记为
        // 已处理（收起候选，同签名快照不再起草）。
        if (canSkipReply && onMarkHandled != null) ...[
          Card(
            child: ListTile(
              leading: const Icon(Icons.mark_chat_unread_outlined),
              title: const Text('这条可以不回'),
              subtitle: const Text('判断认为此刻不回也不影响；点了就把本轮标记为已处理。'),
              trailing: TextButton(
                onPressed: onMarkHandled,
                child: const Text('不用回'),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (ranked.isEmpty) ...[
          // 空列表：桌面页显示占位文案；采集页传 null——空列表时不渲染任何
          // 头部（原先的实现里就没有）。
          if (emptyLabel != null) ...[
            Text(emptyLabel!, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
          ],
        ] else ...[
          Row(
            children: [
              Expanded(
                  child: Text('候选回复',
                      style: Theme.of(context).textTheme.titleSmall)),
              if (onSwapReplies != null)
                TextButton(
                    onPressed: onSwapReplies, child: const Text('换一组')),
            ],
          ),
          const SizedBox(height: 4),
          // B8「一条推荐 + 两条备选」：排序第一张大卡（含策略标签+概率），
          // 其余折叠为两行小字、点击展开；all 模式保持全部平铺。
          if (primaryMode) ...[
            _CandidateCard(
              index: 0,
              reply: ranked[0],
              recommended: true,
              refining: refiningIndexes.contains(0),
              onRefine: onRefine,
              onPrimary: onPrimary,
              primaryLabel: primaryLabel,
              contactStore: contactStore,
              preferences: preferences,
              onPreferencesMutated: onPreferencesMutated,
            ),
            for (var i = 1; i < ranked.length; i++)
              expandedCandidates.contains(i)
                  ? _CandidateCard(
                      index: i,
                      reply: ranked[i],
                      expanded: true,
                      onCollapse: () => onToggleExpand(i),
                      refining: refiningIndexes.contains(i),
                      onRefine: onRefine,
                      onPrimary: onPrimary,
                      primaryLabel: primaryLabel,
                      contactStore: contactStore,
                      preferences: preferences,
                      onPreferencesMutated: onPreferencesMutated,
                    )
                  : _CollapsedCandidateRow(
                      index: i,
                      reply: ranked[i],
                      onExpand: onToggleExpand,
                    ),
          ] else
            for (var i = 0; i < ranked.length; i++)
              _CandidateCard(
                index: i,
                reply: ranked[i],
                // all 模式沿用原实现的判定：集合里还留着主推模式时代的展开
                // 下标时，那张卡照样给「收回」口（displayMode 可在设置页随时
                // 切换，集合不随之清空）。
                expanded: expandedCandidates.contains(i),
                refining: refiningIndexes.contains(i),
                onRefine: onRefine,
                onPrimary: onPrimary,
                primaryLabel: primaryLabel,
                contactStore: contactStore,
                preferences: preferences,
                onPreferencesMutated: onPreferencesMutated,
              ),
        ],
      ],
    );
  }
}

/// B8 主推模式的备选行：两行小字 + 「展开」角标，点按展开成完整候选卡。
class _CollapsedCandidateRow extends StatelessWidget {
  const _CollapsedCandidateRow({
    required this.index,
    required this.reply,
    required this.onExpand,
  });

  final int index;
  final RankedReply reply;
  final void Function(int index) onExpand;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onExpand(index),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                reply.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Icon(
              Icons.expand_more,
              size: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// 一张完整候选卡：推荐 pill（B8 主推）或元信息行（含展开卡的「收回」口）、
/// 候选正文、动作区（回填/复制、记住这条、改写三键或改写中转圈）与 G7
/// 反馈标签行。采集页/桌面页原先各有一份，逐行核对后合并。
class _CandidateCard extends StatelessWidget {
  const _CandidateCard({
    required this.index,
    required this.reply,
    required this.refining,
    required this.onRefine,
    required this.onPrimary,
    required this.primaryLabel,
    this.recommended = false,
    this.expanded = false,
    this.onCollapse,
    this.contactStore,
    this.preferences,
    this.onPreferencesMutated,
  });

  final int index;
  final RankedReply reply;

  /// B8 主推：本卡是排序第一张大卡（头部给「推荐」pill）。
  final bool recommended;

  /// B8：本卡是点开展开的备选卡（头部给「收回」口，见 [onCollapse]）。
  final bool expanded;
  final VoidCallback? onCollapse;

  /// 正在快速改写（busy 只作用于本卡：只在这张卡上转圈）。
  final bool refining;
  final void Function(int index, String instruction) onRefine;
  final void Function(String text) onPrimary;
  final String primaryLabel;
  final ContactStore? contactStore;
  final PreferenceProfile? preferences;
  final void Function()? onPreferencesMutated;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final meta = '${reply.strategy} · ${(reply.prob * 100).toStringAsFixed(0)}%'
        '${reply.reviewNote.isEmpty ? "" : " · ${reply.reviewNote}"}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (recommended) ...[
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius:
                          const BorderRadius.all(Radius.circular(999)),
                    ),
                    child: Text(
                      '推荐',
                      style: TextStyle(color: scheme.onPrimary, fontSize: 12),
                    ),
                  ),
                  const Spacer(),
                  Text(meta, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ] else ...[
              Row(
                children: [
                  Expanded(
                    child: Text(meta,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                  // B8 展开来的备选卡给一个收回口，保持折叠语义完整。
                  if (expanded)
                    GestureDetector(
                      onTap: onCollapse,
                      child: Icon(
                        Icons.expand_less,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 4),
            Text(reply.text, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonal(
                  onPressed: () => onPrimary(reply.text),
                  child: Text(primaryLabel),
                ),
                // G8「记住这条」（A 的 stageCandidateFact，调用方只有 UI）：
                // 把这条候选暂存为待确认事实——确认条上点确认才落盘。
                if (contactStore != null)
                  RememberFactButton(
                    store: contactStore!,
                    text: reply.text,
                  ),
                // ④ busy 只作用于本卡：改写中只在这张卡上转圈，其它卡的
                // 「更短/更礼貌/换个说法」照常可点。
                if (refining) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 4),
                  Text('改写中…', style: Theme.of(context).textTheme.bodySmall),
                ] else ...[
                  TextButton(
                    onPressed: () =>
                        onRefine(index, CaptureSession.refineShorter),
                    child: const Text('更短'),
                  ),
                  TextButton(
                    onPressed: () =>
                        onRefine(index, CaptureSession.refinePoliter),
                    child: const Text('更礼貌'),
                  ),
                  TextButton(
                    onPressed: () =>
                        onRefine(index, CaptureSession.refineRephrase),
                    child: const Text('换个说法'),
                  ),
                ],
              ],
            ),
            // G7 结构化反馈：六个标签小按钮，记录进「我的偏好」（可查可删）。
            // 勾选态取自偏好档案的样例（这条原文已记过该类），不是页面私肢。
            if (preferences != null) ...[
              const Divider(height: 16),
              FeedbackTagRow(
                preferences: preferences!,
                candidateText: reply.text,
                onMutated: onPreferencesMutated,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// G8 的「记住这条」入口（A 的 ContactStore.stageCandidateFact 契约：调用方
/// 只有 UI——判断/起草结果里用户主动把一条候选暂存为待确认事实）。暂存 ≠
/// 保存：只进内存暂存区（重启即清空），仍要在 StagedFactBar 上点「确认」
/// 才写进联系人资料。
class RememberFactButton extends StatelessWidget {
  const RememberFactButton(
      {super.key, required this.store, required this.text});

  final ContactStore store;

  /// 要暂存的候选原文（原样交给 A，A 侧 trim）。
  final String text;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 12),
      ),
      onPressed: () {
        store.stageCandidateFact(text);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text('已暂存为待确认事实——在「确认保存到联系人」条上确认后才会保存'),
          ));
      },
      child: Text(
        '记住这条',
        style: TextStyle(
            fontSize: 12, color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

/// G7 反馈标签的中文按钮文案（与 PreferenceTag.values 声明序一致：太正式/
/// 太热情/不够直接/事实对但表达不合适/不该承诺/这类先问我）。
String feedbackTagLabel(PreferenceTag tag) => switch (tag) {
      PreferenceTag.tooFormal => '太正式',
      PreferenceTag.tooEnthusiastic => '太热情',
      PreferenceTag.notDirectEnough => '不够直接',
      PreferenceTag.expressionMismatch => '事实对但表达不合适',
      PreferenceTag.unwantedCommitment => '不该承诺',
      PreferenceTag.askFirst => '这类先问我',
    };

/// G7：候选卡下的结构化反馈行。点标签即记进 [PreferenceProfile]（计数 + 最近
/// 样例）；已记录的标签显示 ✓ 并禁用——勾选态取自偏好档案里「这条原文已在该
/// 类样例中」这一可查事实，不是页面私有状态，在偏好面板删除后自动恢复可点。
/// 样例环形只留最近几条（C 的 preferenceExamplesPerTag），久远的原文不再显示
/// 勾选属预期（重新点按即重新记录一次）。
class FeedbackTagRow extends StatefulWidget {
  const FeedbackTagRow({
    super.key,
    required this.preferences,
    required this.candidateText,
    this.onMutated,
  });

  final PreferenceProfile preferences;

  /// 本张卡的候选原文：record 原样传入（C 侧裁剪后存样例）。
  final String candidateText;

  /// 记录后的联动回调（页面负责落盘 + 重绘其它卡上的勾选态）。
  final void Function()? onMutated;

  @override
  State<FeedbackTagRow> createState() => _FeedbackTagRowState();
}

class _FeedbackTagRowState extends State<FeedbackTagRow> {
  void _tap(PreferenceTag tag) {
    // 重复记录由 UI 挡住：已记录（样例里已有这条原文）的按钮是禁用态。
    widget.preferences.record(tag, widget.candidateText);
    widget.onMutated?.call();
    if (mounted) setState(() {});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('已记录：${feedbackTagLabel(tag)}（可在「查看我的偏好」里删除）'),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '这条回复哪里不合适？（记进「我的偏好」，可查可删）',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        Wrap(
          spacing: 2,
          children: [
            for (final tag in PreferenceTag.values) _tagButton(tag),
          ],
        ),
      ],
    );
  }

  Widget _tagButton(PreferenceTag tag) {
    final theme = Theme.of(context);
    final recorded = widget.preferences
        .examplesOf(tag)
        .contains(widget.candidateText.trim());
    return TextButton(
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 12),
      ),
      onPressed: recorded ? null : () => _tap(tag),
      child: Text(
        recorded ? '✓ ${feedbackTagLabel(tag)}' : feedbackTagLabel(tag),
        style: TextStyle(
          fontSize: 12,
          color: recorded
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

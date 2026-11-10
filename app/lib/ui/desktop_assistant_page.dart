import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/capture_session.dart';
import '../application/settings_store.dart';
import '../application/transcript_parser.dart';

/// 桌面「粘贴分析」页（Windows）：把剪贴板里的聊天记录按行解析成快照
/// （[TranscriptParser]），打上 [Provenance.desktop] 来源标记，走与 Android
/// 采集同一条 判断 → 起草 → 排序 流水线。
///
/// 本阶段没有热键与原生窗口采集：先靠人手粘贴，链路其余部分保持一致，
/// 后续接入原生采集时只换快照的来路，不用动这一页。
class DesktopAssistantPage extends StatefulWidget {
  const DesktopAssistantPage(
      {super.key, required this.config, this.displayMode});

  final ValueNotifier<JevConfig> config;

  /// 候选展示模式（p0-plan B8）：与设置页共享同一份
  /// [SettingsStore.displayMode]，primary = 主推排序第一张大卡、备选折叠；
  /// all = 全部平铺。可选注入——main.dart 传入 store.displayMode；未传时按
  /// 产品默认（displayModePrimary）渲染。
  final ValueNotifier<String>? displayMode;

  @override
  State<DesktopAssistantPage> createState() => _DesktopAssistantPageState();
}

class _DesktopAssistantPageState extends State<DesktopAssistantPage> {
  final TextEditingController _input = TextEditingController();
  final TextEditingController _relationship = TextEditingController(text: '朋友');

  /// ③ 补充背景输入框：随判断与起草一起发送（与采集页同一份实现，
  /// [CaptureSession.buildContext]），清空即移除。
  final TextEditingController _extra = TextEditingController();

  /// A3「学习我的说话方式」：从粘贴文本里的「我：」行学风格样本（只进写作路）。
  bool _styleLearning = false;

  bool _busy = false;

  /// G3 置信度门控：本屏快照来源不可靠，挂起等用户确认（与采集会话同一道
  /// 闸，[CaptureSession.confirmThreshold]）。桌面快照当前恒为缺省置信 1.0
  /// （契约只定义 a11y/ocr 基线，desktop 不参与扣分），这道闸实际不触发；
  /// 接原生窗口采集后粘贴页走的就是同一条挂起/确认路径，先把它立在这。
  bool _pendingConfirm = false;

  /// 正在快速改写的候选下标：busy 只作用于该卡。
  final Set<int> _refining = {};

  /// B8：被点开展开的备选卡下标（主推模式下备选默认折叠为两行小字）。
  final Set<int> _expandedCandidates = {};

  /// B7：本轮已标记「不用回」。
  bool _handled = false;

  /// 最近一次分析的快照（note 与消息数原样展示在结果区）。
  ChatSnapshot? _snapshot;

  /// 判断结果（判断错误在 [Analysis.error] 里，原样展示）。
  Analysis? _analysis;

  /// G1 隐私预览：与 [_snapshot] 同轮算出，与实际发送的 ctx 同源。
  SendPreview? _preview;

  /// 流水线抛出的错误文案（ApiException.message 原样透出）。
  String? _error;

  /// 跨轮持有的客户端：分析时随配置新建（改设置下一轮生效），改写复用最近
  /// 一份——改写没有「换一组」那样的重跑语义，直接用当前配置的客户端。
  JevClient? _jev;

  @override
  void initState() {
    super.initState();
    widget.displayMode?.addListener(_onDisplayModeChanged);
  }

  void _onDisplayModeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.displayMode?.removeListener(_onDisplayModeChanged);
    _input.dispose();
    _relationship.dispose();
    _extra.dispose();
    super.dispose();
  }

  /// 无法归属行数的注记文案；没有未归属行时为 null。
  /// 文案样式对齐旧仓库 OCR 的部分未知注记（ChatCaptureService.kt:1747
  /// 「OCR 分边：有 N 条」）。
  String? _noteFor(ParsedTranscript parsed) => parsed.unattributed == 0
      ? null
      : '有 ${parsed.unattributed} 行未归属：行首没有「我：/对方：」前缀，按发言人不明处理';

  Future<void> _analyze() async {
    final parsed = TranscriptParser.parse(_input.text);
    if (parsed.isEmpty) {
      setState(() {
        _snapshot = null;
        _analysis = null;
        _pendingConfirm = false;
        _error = '没有解析到任何消息：请按「对方：…」「我：…」每行一条粘贴。';
      });
      return;
    }
    final snapshot = ChatSnapshot(
      messages: parsed.messages,
      provenance: Provenance.desktop,
      note: _noteFor(parsed),
    );
    // G3 置信度门控：不高于阈值（≤，含 OCR+单条发言人未知的精确 0.5）不自动
    // 分析，挂起等确认（见 [_pendingConfirm]）。
    if (CaptureSession.shouldConfirm(snapshot)) {
      final ctx = CaptureSession.buildContext(
        extra: _extra.text,
        myMessages: CaptureSession.myMessagesOf(snapshot),
        styleLearning: _styleLearning,
      );
      setState(() {
        _snapshot = snapshot;
        _analysis = null;
        _error = null;
        _busy = false;
        _handled = false;
        _pendingConfirm = true;
        _expandedCandidates.clear();
        // 挂起态先亮预览：确认之前就能看到「确认后会把什么发出去」。
        _preview = CaptureSession.buildSendPreview(
          snapshot: snapshot,
          ctx: ctx,
          relationship: _relationship.text,
        );
      });
      return;
    }
    await _runAnalysis(snapshot);
  }

  /// G3：低置信快照的确认分析入口（与采集会话同一道闸）。非挂起态是空操作。
  Future<void> _confirmAnalyze() async {
    final snapshot = _snapshot;
    if (snapshot == null || _busy || !_pendingConfirm) return;
    await _runAnalysis(snapshot);
  }

  /// 一轮完整分析（judge → draftAndRank → 写结果区）：高置信自动路径与确认
  /// 路径（[_confirmAnalyze]）共用。ctx/预览在这里现算，与实际发送同源。
  Future<void> _runAnalysis(ChatSnapshot snapshot) async {
    // ③/A3：补充背景 + 粘贴文本里的「我：」行风格样本组装成 ctx，judge 与
    // draftAndRank 拿同一份；G1 预览由它算出，与实际发送同源。
    final relationshipText =
        _relationship.text.trim().isEmpty ? '朋友' : _relationship.text.trim();
    final ctx = CaptureSession.buildContext(
      extra: _extra.text,
      myMessages: CaptureSession.myMessagesOf(snapshot),
      styleLearning: _styleLearning,
    );
    final preview = CaptureSession.buildSendPreview(
      snapshot: snapshot,
      ctx: ctx,
      relationship: _relationship.text,
    );
    setState(() {
      _snapshot = snapshot;
      _analysis = null;
      _error = null;
      _busy = true;
      _handled = false;
      _pendingConfirm = false;
      _expandedCandidates.clear();
      _preview = preview;
    });
    try {
      // 每轮新建客户端：粘贴分析按「点一次跑一轮」走，配置改动天然在下一轮
      // 生效，也不用像采集会话那样维护失效逻辑。实例留在 [_jev] 里给改写用。
      final jev = _jev = JevClient(widget.config.value);
      final analysis = await jev.judge(snapshot, relationshipText, ctx: ctx);
      var ranked = const <RankedReply>[];
      if (analysis.error == null) {
        ranked = await jev.draftAndRank(snapshot, relationshipText,
            judgment: analysis, ctx: ctx);
        // F1：best_action 对应的策略候选提前——与采集会话同一份静态实现。
        ranked = CaptureSession.applyStrategyOrder(ranked, analysis);
      }
      if (!mounted) return;
      setState(() {
        _analysis = analysis.copyWith(rankedReplies: ranked);
      });
    } on ApiException catch (e) {
      // 错误文案原样透出：路由 + HTTP 状态 + 响应体前 120 字（见 ApiException）。
      if (!mounted) return;
      setState(() => _error = e.message);
    } on SafetyBlockedException catch (e) {
      // 安全闸的拒绝要原样给用户看：那是「助手主动拒绝」，不是网络坏了。
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// ④ 快速改写：走 [CaptureSession.refineText]（与采集页同一份实现），
  /// 成功后原位替换该卡文本，busy 只作用于该卡。
  Future<void> _refine(int index, String instruction) async {
    final analysis = _analysis;
    final snapshot = _snapshot;
    if (analysis == null || snapshot == null || _busy || _handled) return;
    if (index < 0 || index >= analysis.rankedReplies.length) return;
    if (_refining.contains(index)) return;
    final original = analysis.rankedReplies[index].text.trim();
    if (original.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _refining.add(index));
    try {
      final refined = await CaptureSession.refineText(
        jev: _jev ??= JevClient(widget.config.value),
        snapshot: snapshot,
        relationship: _relationship.text.trim().isEmpty
            ? '朋友'
            : _relationship.text.trim(),
        ctx: CaptureSession.buildContext(
          extra: _extra.text,
          myMessages: CaptureSession.myMessagesOf(snapshot),
          styleLearning: _styleLearning,
        ),
        original: original,
        instruction: instruction,
      );
      if (!mounted) return;
      if (refined == null) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('改写失败，保留原文')));
        return;
      }
      setState(() {
        final list = [..._analysis!.rankedReplies];
        if (index < list.length) {
          list[index] = list[index].copyWith(text: refined);
          _analysis = _analysis!.copyWith(rankedReplies: list);
        }
      });
    } catch (_) {
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('改写失败，保留原文')));
    } finally {
      if (mounted) setState(() => _refining.remove(index));
    }
  }

  /// B7「不用回」：把本轮标记为已处理（收起候选，不再展示）。
  void _markHandled() {
    setState(() {
      _handled = true;
      _analysis = _analysis?.copyWith(rankedReplies: const []);
    });
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
  }

  /// B8 当前模式：与设置页共用 notifier；未注入（main.dart 未传）时按产品
  /// 默认「主推一张大卡」渲染。
  bool get _primaryMode =>
      (widget.displayMode?.value ?? SettingsStore.displayModePrimary) ==
      SettingsStore.displayModePrimary;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('粘贴分析')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          TextField(
            controller: _input,
            maxLines: 10,
            minLines: 5,
            decoration: const InputDecoration(
              labelText: '聊天记录（每行一条）',
              hintText: '对方：…\n我：…',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _relationship,
            decoration: const InputDecoration(
              labelText: '与对方的关系（进提示词）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          // ③ 上下文补充：一句话背景，随判断与起草一起发送；清空即移除。
          TextField(
            controller: _extra,
            decoration: const InputDecoration(
              labelText: '补充背景（如：今天是她生日）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          // A3「学习我的说话方式」：从粘贴文本的「我：」行挑风格样本。
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _styleLearning,
            onChanged: (v) => setState(() => _styleLearning = v),
            title: const Text('学习我的说话方式'),
            subtitle: const Text('从粘贴文本的「我：」行里挑几条作为风格样本，随起草发送（只进写作路）。'),
          ),
          FilledButton.icon(
            onPressed: _busy ? null : _analyze,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.analytics_outlined),
            label: const Text('分析'),
          ),
          const SizedBox(height: 8),
          const Text(
            '行首用「我：」或「对方：」标注说话人（全半角冒号都可以）；'
            '没有前缀的行按发言人不明处理，不计入我或对方。',
            style: TextStyle(fontSize: 12),
          ),
          _previewTile(),
          const SizedBox(height: 12),
          _resultSection(),
        ],
      ),
    );
  }

  /// G1 隐私预览：折叠面板，展开看本轮判断/写作两条调用各自会收到什么。
  Widget _previewTile() {
    final preview = _preview;
    if (preview == null) return const SizedBox.shrink();
    return Card(
      child: ExpansionTile(
        title: const Text('本轮将发送'),
        subtitle: const Text('隐私预览：展开查看判断与写作各自收到什么'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          _previewGroup('判断路（先看局势）', preview.judge),
          const SizedBox(height: 8),
          _previewGroup('写作路（起草候选）', preview.writer),
        ],
      ),
    );
  }

  Widget _previewGroup(String title, List<String> lines) => Column(
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

  Widget _resultSection() {
    final scheme = Theme.of(context).colorScheme;
    if (_error != null) {
      return Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(_error!),
        ),
      );
    }
    if (_busy) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(children: [
            CircularProgressIndicator(strokeWidth: 2),
            SizedBox(width: 12),
            Text('判断与起草中…'),
          ]),
        ),
      );
    }
    // G3 置信度门控：来源不可靠的快照挂起等确认——点了才把内容发给模型。
    if (_pendingConfirm && _snapshot != null) {
      final reasons = CaptureSession.uncertainReasonsOf(_snapshot!);
      return Card(
        child: ListTile(
          leading: const Icon(Icons.privacy_tip_outlined),
          title:
              Text(reasons.isEmpty ? '来源不可靠，确认分析？' : '来源不可靠（$reasons），确认分析？'),
          subtitle: Text(CaptureSession.sourceLineOf(_snapshot!)),
          trailing: FilledButton.tonal(
            onPressed: _confirmAnalyze,
            child: const Text('确认分析'),
          ),
        ),
      );
    }
    final analysis = _analysis;
    if (analysis == null || _snapshot == null) return const SizedBox.shrink();
    // 判断路由的错误不抛异常，装在 Analysis.error 里回来（JudgeClient.judge）。
    if (analysis.error != null) {
      return Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(analysis.error!),
        ),
      );
    }
    if (_handled) {
      // B7：本轮已标记为不用回——安静的确认态，保留「反悔」的入口。
      return Card(
        child: ListTile(
          leading: const Icon(Icons.check_circle_outline),
          title: const Text('本轮已标记为不用回'),
          subtitle: const Text('内容有更新时重新粘贴分析即可；也可以现在重新起草。'),
          trailing: TextButton(
            onPressed: _busy ? null : _analyze,
            child: const Text('重新起草'),
          ),
        ),
      );
    }
    final ranked = analysis.rankedReplies;
    // B7：判断明确说「这条可以不回」时，先给这个出口。
    final shouldReplyNow = analysis.shouldReplyNow;
    final canSkip = shouldReplyNow != null && shouldReplyNow < 0.5;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // G3：来源行带置信度与原因标签（与采集页共用
        // CaptureSession.sourceLineOf 的同一份文案）。
        Text(
          '${CaptureSession.sourceLineOf(_snapshot!)}'
          ' · 消息 ${_snapshot!.messages.length} 条',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        // 未归属注记（快照 note，进提示词的那份文案）原样展示。
        if (_snapshot!.note != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _snapshot!.note!,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 8),
        if (canSkip) ...[
          Card(
            child: ListTile(
              leading: const Icon(Icons.mark_chat_unread_outlined),
              title: const Text('这条可以不回'),
              subtitle: const Text('判断认为此刻不回也不影响；点了就把本轮标记为已处理。'),
              trailing: TextButton(
                onPressed: _markHandled,
                child: const Text('不用回'),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (ranked.isEmpty)
          Text('没有候选回复', style: Theme.of(context).textTheme.bodySmall)
        else
          Text('候选回复', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        // B8「一条推荐 + 两条备选」：排序第一张大卡（含策略标签+概率），其余
        // 折叠为两行小字、点击展开；all 模式保持全部平铺。
        if (ranked.isNotEmpty && _primaryMode) ...[
          _candidateCard(0, ranked[0], recommended: true),
          for (var i = 1; i < ranked.length; i++)
            _expandedCandidates.contains(i)
                ? _candidateCard(i, ranked[i])
                : _collapsedCandidate(i, ranked[i]),
        ] else
          for (var i = 0; i < ranked.length; i++) _candidateCard(i, ranked[i]),
      ],
    );
  }

  Widget _collapsedCandidate(int index, RankedReply r) => InkWell(
        onTap: () => setState(() => _expandedCandidates.add(index)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  r.text,
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

  Widget _candidateCard(int index, RankedReply r, {bool recommended = false}) {
    final meta = '${r.strategy} · ${(r.prob * 100).toStringAsFixed(0)}%'
        '${r.reviewNote.isEmpty ? "" : " · ${r.reviewNote}"}';
    final refining = _refining.contains(index);
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
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius:
                          const BorderRadius.all(Radius.circular(999)),
                    ),
                    child: Text(
                      '推荐',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimary,
                        fontSize: 12,
                      ),
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
                  if (_expandedCandidates.contains(index))
                    GestureDetector(
                      onTap: () =>
                          setState(() => _expandedCandidates.remove(index)),
                      child: Icon(
                        Icons.expand_less,
                        size: 18,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 4),
            Text(r.text, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonal(
                  onPressed: () => _copy(r.text),
                  child: const Text('复制'),
                ),
                // ④ busy 只作用于本卡：改写中只在这张卡上转圈。
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
                        _refine(index, CaptureSession.refineShorter),
                    child: const Text('更短'),
                  ),
                  TextButton(
                    onPressed: () =>
                        _refine(index, CaptureSession.refinePoliter),
                    child: const Text('更礼貌'),
                  ),
                  TextButton(
                    onPressed: () =>
                        _refine(index, CaptureSession.refineRephrase),
                    child: const Text('换个说法'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

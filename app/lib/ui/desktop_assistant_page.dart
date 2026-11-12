import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/capture_session.dart';
import '../application/contact_store.dart';
import '../application/hotkey_controller.dart';
import '../application/settings_store.dart';
import '../application/transcript_parser.dart';
// 联系人 / G7 偏好的共享 UI 在采集页文件里（两个文件同属交互写手）：
// ContactSection / StagedFactBar / showPreferencesSheet。候选区（候选卡 /
// B7 / B8 / G1 预览）与卡上的 G7 反馈标签行、「记住这条」按钮抽在
// widgets/candidate_list.dart（kimi-review #16 共用 widget，两页只传数据
// 与回调）。
import 'capture_page.dart';
import 'widgets/candidate_list.dart';

/// 桌面「粘贴分析」页（Windows）：把剪贴板里的聊天记录按行解析成快照
/// （[TranscriptParser]），打上 [Provenance.desktop] 来源标记，走与 Android
/// 采集同一条 判断 → 起草 → 排序 流水线。
///
/// 本阶段没有原生窗口采集：先靠人手粘贴，链路其余部分保持一致，后续接入
/// 原生采集时只换快照的来路，不用动这一页。Windows 全局热键（Ctrl+Alt+C）
/// 已接入：开关在页内，触发 = 把本页切到前台并聚焦粘贴输入框
/// （[HotkeyController]，不读剪贴板、不自动分析）。
class DesktopAssistantPage extends StatefulWidget {
  const DesktopAssistantPage({
    super.key,
    required this.config,
    this.displayMode,
    this.scenarioId,
    this.contactStore,
    this.preferences,
    this.persistPreferences,
    this.usage,
  });

  final ValueNotifier<JevConfig> config;

  /// 候选展示模式（p0-plan B8）：与设置页共享同一份
  /// [SettingsStore.displayMode]，primary = 主推排序第一张大卡、备选折叠；
  /// all = 全部平铺。可选注入——main.dart 传入 store.displayMode；未传时按
  /// 产品默认（displayModePrimary）渲染。
  final ValueNotifier<String>? displayMode;

  /// 场景选择（fix(#11 P0-N)）：与设置页共享同一份
  /// [SettingsStore.scenarioId]（引导页「选场景」写入的那份 notifier）。
  /// 分析时经 [CaptureSession.resolveScenario] 现查模板传给
  /// JevClient.draftAndRank——采集流与桌面流共用同一个解析点，空串/未知 id
  /// 一律落到「无场景」。可选注入——main.dart 传入 store.scenarioId；未传
  /// （旧构造方/测试）时与没有场景功能之前逐字节一致。每轮分析现读，改场景
  /// 下一轮生效（桌面页没有常驻会话，无监听必要）。
  final ValueNotifier<String>? scenarioId;

  /// #6 联系人档案（A 的 ContactStore）：可选注入——main.dart 传入共享实例。
  /// 未注入时联系人区不渲染，粘贴分析不带联系人上下文（与基线一致）。
  final ContactStore? contactStore;

  /// G7 结构化偏好（C 的 PreferenceProfile）：可选注入。未注入时候选卡的
  /// 反馈标签行与「查看我的偏好」入口不渲染。
  final PreferenceProfile? preferences;

  /// G7 偏好落盘回调（main.dart 注入）：record/clear 之后由页面触发。
  final void Function()? persistPreferences;

  /// C9 使用统计（可选注入，[SettingsStore.usage] 同一份实例）：传入后本页
  /// 的判断/起草/改写调用打点写进它，设置页统计卡读同一份对象。桌面流不经
  /// [CaptureSession]，需要单独注入。null = 不打点（与接入前逐字节一致）。
  final UsageStats? usage;

  @override
  State<DesktopAssistantPage> createState() => _DesktopAssistantPageState();
}

class _DesktopAssistantPageState extends State<DesktopAssistantPage> {
  final TextEditingController _input = TextEditingController();

  /// 热键唤起后的聚焦目标：全局热键把本页切到前台时定位到这里
  /// （[HotkeyController.activationTick] 触发，见 [_onHotkeyActivated]）。
  final FocusNode _inputFocus = FocusNode();
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

  /// fix(kimi-review #18)：改写发起时所在轮次的 token，每轮分析自增。改写
  /// await 期间用户可点「分析」开新一轮（[_runAnalysis] 整体替换候选）——
  /// 旧快照的改写结果返回后比对 token，轮次已换就作废，不许按 index 写进
  /// 新轮次的候选。按任务原话持 analysis 实例做 identical 比对不够用：同轮
  /// 并发的两张卡改写（不同卡可同时改写，[_refining] 只挡同下标），先返回
  /// 的一张 copyWith 换了 [_analysis] 实例，后返回的一张会被误判成换轮、
  /// 结果静默丢弃。采集会话对同一问题用的就是轮次 token（见
  /// capture_session.dart refineCandidate「与 _onSnapshot 同一道防护」）。
  int _analysisRound = 0;

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
    // 热键接线（仅 Windows；控制器在别的平台是空操作，但 UI 与监听一并隐藏
    // 更干净）：页面向控制器登记自己的在树状态与监听——热键触发时控制器负责
    // 切前台与路由，本页只管把焦点放进粘贴输入框。
    if (HotkeyController.isSupported) {
      HotkeyController.instance.attachPage();
      HotkeyController.instance.activationTick.addListener(_onHotkeyActivated);
      // 本次热键触发恰好把本页新推入栈的路径：监听注册晚于信号发出，
      // initState 里补一次消费（消费即清位，两个入口不会重复聚焦）。
      if (HotkeyController.instance.consumePendingFocus()) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _focusInput());
      }
    }
  }

  /// 热键触发（页面已在树上）：取走聚焦请求，把光标放进粘贴输入框。
  void _onHotkeyActivated() {
    if (HotkeyController.instance.consumePendingFocus()) _focusInput();
  }

  void _focusInput() {
    if (mounted) _inputFocus.requestFocus();
  }

  void _onDisplayModeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (HotkeyController.isSupported) {
      HotkeyController.instance.detachPage();
      HotkeyController.instance.activationTick
          .removeListener(_onHotkeyActivated);
    }
    widget.displayMode?.removeListener(_onDisplayModeChanged);
    _inputFocus.dispose();
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

  /// #6 当前激活联系人（A 的 ContactStore.activeContact 直接读；未注入或无
  /// 激活返回 null）。
  ContactProfile? get _activeContact =>
      widget.contactStore?.activeContact.value;

  /// 组装本轮 ctx（补充背景 + 风格样本 + 激活联系人 + G7 偏好附言）：judge 与
  /// draftAndRank 必须拿同一份，G1 预览由它算出。contact 走 A 的 buildContext
  /// 契约扩展（ContactProfile? 可选参数）——无激活联系人且无偏好记录时传
  /// null/空，请求与基线逐字节一致。偏好附言只进写作路（buildContext 内按
  /// 固定 id 笔记承载，core 侧 background 刻意跳过），G1 预览同步列出。
  ChatContext? _buildCtx(ChatSnapshot snapshot) => CaptureSession.buildContext(
        extra: _extra.text,
        myMessages: CaptureSession.myMessagesOf(snapshot),
        styleLearning: _styleLearning,
        contact: _activeContact,
        preferences: widget.preferences,
      );

  /// G7 偏好变更（记录/删除/清空）后的页面联动：先落盘回调（main.dart 注入），
  /// 再重绘——勾选态取自偏好档案的样例，删除后要立即取消对应卡上的 ✓。
  void _onPreferencesMutated() {
    widget.persistPreferences?.call();
    if (mounted) setState(() {});
  }

  Future<void> _analyze() async {
    final parsed = TranscriptParser.parse(_input.text);
    if (parsed.isEmpty) {
      setState(() {
        _snapshot = null;
        _analysis = null;
        _pendingConfirm = false;
        _error = '没有解析到任何消息：请按「对方：…」「我：…」每行一条粘贴。';
        // fix(kimi-review #18)：清场也算换轮——在途改写的结果不许写回。
        _analysisRound++;
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
      final ctx = _buildCtx(snapshot);
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
    final ctx = _buildCtx(snapshot);
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
      // fix(kimi-review #18)：换轮记号——在途改写返回后据此作废。
      _analysisRound++;
    });
    try {
      // 每轮新建客户端：粘贴分析按「点一次跑一轮」走，配置改动天然在下一轮
      // 生效，也不用像采集会话那样维护失效逻辑。实例留在 [_jev] 里给改写用。
      // C9：统计实例随构造传入（C9 接线契约，usage_stats.dart）。
      final jev = _jev = JevClient(widget.config.value, stats: widget.usage);
      final analysis = await jev.judge(snapshot, relationshipText, ctx: ctx);
      var ranked = const <RankedReply>[];
      if (analysis.error == null) {
        // fix(#11 P0-N)：场景随 store.scenarioId 进起草路，与采集流同一份
        // 解析（CaptureSession.resolveScenario）；null 时与接入前逐字节一致。
        // 判断路不消费场景（ScenarioTemplate 只有起草侧附加段），judge 不传。
        ranked = await jev.draftAndRank(snapshot, relationshipText,
            judgment: analysis,
            ctx: ctx,
            scenario: CaptureSession.resolveScenario(widget.scenarioId));
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
    // fix(kimi-review #18)：持有发起改写时的 analysis 引用（下标边界与原文
    // 都按它解释）与轮次 token；返回后 token 不一致 = await 期间点了「分析」
    // 开了新一轮，旧快照的改写结果作废。
    final analysis = _analysis;
    final snapshot = _snapshot;
    final round = _analysisRound;
    if (analysis == null || snapshot == null || _busy || _handled) return;
    if (index < 0 || index >= analysis.rankedReplies.length) return;
    if (_refining.contains(index)) return;
    final original = analysis.rankedReplies[index].text.trim();
    if (original.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _refining.add(index));
    try {
      final refined = await CaptureSession.refineText(
        jev: _jev ??= JevClient(widget.config.value, stats: widget.usage),
        snapshot: snapshot,
        relationship: _relationship.text.trim().isEmpty
            ? '朋友'
            : _relationship.text.trim(),
        ctx: _buildCtx(snapshot),
        original: original,
        instruction: instruction,
      );
      if (!mounted) return;
      // fix(kimi-review #18)：轮次已换就不写回——旧快照的改写结果按 index
      // 写进新轮次候选，等于把上一轮的内容串进这一轮。
      if (round != _analysisRound) return;
      if (refined == null) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('改写失败，保留原文')));
        return;
      }
      setState(() {
        // 同轮写回读当前 [_analysis]（同轮另一张卡的改写可能已先写回过、
        // copyWith 换了实例），只替换自己这张卡。「标记不用回」可能已把本轮
        // 候选清空：此时没有可替换的卡，与采集会话同一条守卫。
        final list = [..._analysis!.rankedReplies];
        if (index < list.length) {
          list[index] = list[index].copyWith(text: refined);
          _analysis = _analysis!.copyWith(rankedReplies: list);
        }
      });
    } catch (_) {
      if (!mounted) return;
      // fix(kimi-review #18)：同上——轮次已换就不再对当前屏幕报「改写失败」。
      if (round != _analysisRound) return;
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
      appBar: AppBar(
        title: const Text('粘贴分析'),
        actions: [
          // G7「查看我的偏好」入口：列出全部已记录的反馈并支持删除——
          // 用户可查可改可删是硬约束（p0-plan G7）。
          if (widget.preferences != null)
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: '查看我的偏好',
              onPressed: () => showPreferencesSheet(
                context,
                widget.preferences!,
                onMutated: _onPreferencesMutated,
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          TextField(
            controller: _input,
            focusNode: _inputFocus,
            maxLines: 10,
            minLines: 5,
            decoration: const InputDecoration(
              labelText: '聊天记录（每行一条）',
              hintText: '对方：…\n我：…',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          // #6 联系人入口（与采集页同一份组件）：选择/新建联系人，两区分开
          // 标注；激活联系人的 relationship/persona/avoidWords 经
          // [CaptureSession.buildContext] 进入下一轮判断与起草。
          if (widget.contactStore != null) ...[
            ContactSection(store: widget.contactStore!),
            const SizedBox(height: 8),
          ],
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
          // Windows 全局热键（任务契约 2/3/4）：开关 + 热键显示 + 注册失败的
          // 可见提示。非 Windows（含 Web）整段不渲染——热键是 Windows 桌面能力。
          // 触发语义在开关文案里写明：只唤起窗口与输入框，不读剪贴板、
          // 不自动分析，粘贴与分析始终由用户决定。
          if (HotkeyController.isSupported) ...[
            ValueListenableBuilder<bool>(
              valueListenable: HotkeyController.instance.enabled,
              builder: (context, hotkeyOn, _) => SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: hotkeyOn,
                onChanged: (v) => HotkeyController.instance.setEnabled(v),
                title: Text('全局热键唤起（${HotkeyController.hotkeyLabel}）'),
                subtitle: const Text('在任意应用按下热键，把本页切到前台并定位到粘贴输入框。'
                    '热键只负责唤起：不读剪贴板、不自动分析，粘什么、分析与否都由你决定。'),
              ),
            ),
            // 注册失败的可见提示（任务契约 3）：控制器把注册结果写进
            // [HotkeyController.error]，这里原样展示；开关随后续注册失败弹回
            // 关位，提示与开关相邻，一眼能对上因果。
            ValueListenableBuilder<String?>(
              valueListenable: HotkeyController.instance.error,
              builder: (context, hotkeyError, _) {
                if (hotkeyError == null) return const SizedBox.shrink();
                return Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  margin: const EdgeInsets.only(top: 8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline,
                            size: 18,
                            color:
                                Theme.of(context).colorScheme.onErrorContainer),
                        const SizedBox(width: 8),
                        Expanded(child: Text(hotkeyError)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
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
          // G8「确认后入库」的确认条（与采集页同一份共享组件）：「记住这条」
          // 暂存的候选事实在这里确认/丢弃，确认前绝不写联系人资料。
          if (widget.contactStore != null) ...[
            StagedFactBar(store: widget.contactStore!),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 12),
          _resultSection(),
        ],
      ),
    );
  }

  /// G1 隐私预览：折叠面板，展开看本轮判断/写作两条调用各自会收到什么
  /// （kimi-review #16 抽成共用 widget，采集流同一条）。
  Widget _previewTile() => SendPreviewTile(preview: _preview);

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
      // B7：本轮已标记为不用回——安静的确认态，保留「反悔」的入口（共用
      // widget，采集流同一条；副标题两页口径不同，由页面传；忙碌中按钮禁用）。
      return HandledReplyCard(
        subtitle: '内容有更新时重新粘贴分析即可；也可以现在重新起草。',
        onRedraft: _busy ? null : _analyze,
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
        // 候选区（B7 出口 + B8 主推/平铺 + 卡片动作 + G7 反馈标签 + 记住这条）
        // 抽成了共用 widget：两页只传数据与回调（kimi-review #16）。本页差异：
        // 主按钮是「复制」、空列表显示占位文案、没有「换一组」。
        CandidateList(
          ranked: ranked,
          primaryMode: _primaryMode,
          expandedCandidates: _expandedCandidates,
          onToggleExpand: _toggleCandidateExpansion,
          refiningIndexes: _refining,
          onRefine: _refine,
          onPrimary: _copy,
          primaryLabel: '复制',
          emptyLabel: '没有候选回复',
          canSkipReply: canSkip,
          onMarkHandled: _markHandled,
          contactStore: widget.contactStore,
          preferences: widget.preferences,
          onPreferencesMutated: _onPreferencesMutated,
        ),
      ],
    );
  }

  /// B8 备选卡展开/收回的切换（共用 widget 的回调）：点折叠行展开、点展开卡
  /// 的「收回」折回。集合是页面私有状态；新一轮分析会清空（见 [_runAnalysis]），
  /// 下标语义只对当批候选有效。
  void _toggleCandidateExpansion(int index) {
    setState(() {
      if (!_expandedCandidates.remove(index)) _expandedCandidates.add(index);
    });
  }
}

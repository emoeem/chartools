import 'package:capture_android/capture_android.dart';
import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/material.dart';

import '../application/capture_session.dart';
import '../application/settings_store.dart';

/// 采集助手页（Android）：无障碍开关入口、采集范围配置、悬浮窗开关、实时
/// 快照与建议。
///
/// 建议在页面上完整展示，同时（开关打开时）推到悬浮窗 OverlayController；
/// 「回填」把候选填进聊天输入框，从不自动发送。
class CapturePage extends StatefulWidget {
  const CapturePage({
    super.key,
    required this.config,
    required this.relationship,
    required this.overlayEnabled,
    this.displayMode,
    this.blockedPackages,
  });

  final ValueNotifier<JevConfig> config;

  /// 与对方的关系：与设置页共享同一份 [SettingsStore.relationship]，采集页
  /// 输入框写的就是流水线读的那个值。
  final ValueNotifier<String> relationship;

  /// 悬浮窗开关：与设置页共享同一份 [SettingsStore.overlayEnabled]，也是
  /// [CaptureSession] 推悬浮窗用的开关——单一事实来源，没有第二轨。
  final ValueNotifier<bool> overlayEnabled;

  /// 候选展示模式（p0-plan B8）：与设置页共享同一份
  /// [SettingsStore.displayMode]，primary = 主推排序第一张大卡、备选折叠；
  /// all = 全部平铺。可选注入——main.dart 传入 store.displayMode；未传时按
  /// 产品默认（displayModePrimary）渲染。
  final ValueNotifier<String>? displayMode;

  /// 采集应用黑名单（p0-plan ⑦，隐私底线清单）：可选注入——main.dart 传入
  /// [SettingsStore.blockedPackages]，与设置页共享同一份（单一事实来源）。
  /// 本页「采集范围」卡的黑名单区读写它：点按标签移除、输入框添加（改动
  /// 立即经 [_pushConfigure] 下发）。未传时编辑落在页面本地兜底集合，初始
  /// 值为 [SettingsStore.defaultBlockedPackages]。黑名单优先于白名单（由
  /// Kotlin 侧 isBlocked() 保证）；每次 [_pushConfigure] 都以当前值为准。
  final ValueNotifier<Set<String>>? blockedPackages;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  late final CaptureSession _session;
  late final TextEditingController _relationship;

  /// ③ 补充背景输入框：逐键写进 [CaptureSession.extraContext]，清空即移除。
  final TextEditingController _extra = TextEditingController();

  bool _serviceRunning = false;
  bool _ocrFallback = true;

  /// A3「学习我的说话方式」开关：写入 [CaptureSession.styleLearning]，下一轮
  /// 起草生效。
  bool _styleLearning = false;

  /// ⑦ 黑名单「添加包名」输入框：回车或「添加」按钮把包名写进黑名单。
  final TextEditingController _blockedInput = TextEditingController();

  /// ⑦ 黑名单的本地兜底集合：main.dart 未注入 [CapturePage.blockedPackages]
  /// 时（工具页直开本页的测试场景）编辑落在这里；正常注入时只读不写——
  /// 编辑一律写回共享 notifier（与设置页持久化同一份）。
  Set<String> _localBlocked = Set.of(SettingsStore.defaultBlockedPackages);

  /// 当前生效的黑名单：注入时以共享 notifier 为单一事实来源。
  Set<String> get _effectiveBlocked =>
      widget.blockedPackages?.value ?? _localBlocked;

  /// ⑦ 黑名单增删的唯一写入口：写回（notifier 或本地兜底）→ 重绘 → 立即
  /// 重推 configure（黑名单优先于白名单由 Kotlin 侧保证，改完即生效）。
  void _commitBlocked(Set<String> next) {
    final notifier = widget.blockedPackages;
    if (notifier != null) {
      notifier.value = next;
    } else {
      _localBlocked = next;
    }
    setState(() {});
    _pushConfigure();
  }

  /// ⑦ 「添加包名」：trim 后入黑名单；空串与重复项直接忽略，输入框清空。
  void _addBlocked() {
    final pkg = _blockedInput.text.trim();
    if (pkg.isEmpty || _effectiveBlocked.contains(pkg)) {
      _blockedInput.clear();
      return;
    }
    _commitBlocked(Set.of(_effectiveBlocked)..add(pkg));
    _blockedInput.clear();
  }

  /// B8：被点开展开的备选卡下标（主推模式下备选默认折叠为两行小字）。
  final Set<int> _expandedCandidates = {};

  /// v1 适配清单（与旧仓库 ChatApps 一致的子集，包名按需增减）。
  static const Map<String, String> _knownApps = {
    'com.tencent.mobileqq': 'QQ',
    'com.tencent.tim': 'TIM',
    'org.telegram.messenger': 'Telegram',
    'com.whatsapp': 'WhatsApp',
    'com.tencent.mm': '微信（OCR 兜底）',
    'com.ss.android.ugc.aweme': '抖音（OCR 兜底）',
  };

  final Set<String> _packages = {
    'com.tencent.mobileqq',
    'org.telegram.messenger',
    'com.whatsapp',
  };

  @override
  void initState() {
    super.initState();
    _session = CaptureSession(
      config: widget.config,
      relationship: widget.relationship,
      overlayEnabled: widget.overlayEnabled,
      // B8：展示模式跟随设置页同一份 notifier，推悬浮窗时透传给原生侧。
      displayMode: widget.displayMode,
    );
    // 会话状态（快照/分析/忙碌/错误）与改写中的卡片集合变化时重绘：stream 回调
    // 不经过 setState，不监听的话「实时快照与建议」永远停在首次 build。
    _session.state.addListener(_onStateChanged);
    _session.refiningCards.addListener(_onStateChanged);
    // #3 遗留 low：showSuggestions 返回 false → 权限引导 SnackBar + 开关打回关。
    _session.overlayPermissionLost.addListener(_onOverlayPermissionLost);
    // B8 展示模式在设置页被改时同步重绘（与设置页共用同一份 notifier）。
    widget.displayMode?.addListener(_onStateChanged);
    _session.start();
    _relationship = TextEditingController(text: widget.relationship.value);
    _relationship.addListener(() {
      widget.relationship.value = _relationship.text;
    });
    _refreshServiceStatus();
    _pushConfigure();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  /// 消费权限丢失通知：弹权限引导 SnackBar（session 已把开关打回关，这里
  /// 顺手重绘开关状态），并把通知清回 null——监听再触发时直接跳过。
  void _onOverlayPermissionLost() {
    final message = _session.overlayPermissionLost.value;
    if (!mounted || message == null) return;
    _session.overlayPermissionLost.value = null;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: '去设置',
          onPressed: () async {
            try {
              await CaptureAndroid().openOverlaySettings();
            } catch (_) {}
          },
        ),
      ));
    setState(() {});
  }

  @override
  void dispose() {
    _session.state.removeListener(_onStateChanged);
    _session.refiningCards.removeListener(_onStateChanged);
    _session.overlayPermissionLost.removeListener(_onOverlayPermissionLost);
    widget.displayMode?.removeListener(_onStateChanged);
    _session.dispose();
    _relationship.dispose();
    _extra.dispose();
    _blockedInput.dispose();
    super.dispose();
  }

  Future<void> _refreshServiceStatus() async {
    try {
      final running = await CaptureAndroid().isRunning();
      if (mounted) setState(() => _serviceRunning = running);
    } catch (_) {
      // Windows 上打开本页会走到这里（通道不存在）；页面本身只在 Android 入口出现。
      if (mounted) setState(() => _serviceRunning = false);
    }
  }

  Future<void> _pushConfigure() async {
    try {
      await CaptureAndroid().configure(
        packages: _packages,
        ocrFallback: _ocrFallback,
        blocked: _effectiveBlocked,
      );
    } catch (_) {
      // 同上：无引擎通道时静默，状态行会显示「未连接」。
    }
  }

  Future<void> _refill(String text) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _session.refill(text);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(ok ? '已填入输入框（未发送）' : '没找到可写的输入框；文本已复制到剪贴板'),
      ));
  }

  /// ④ 快速改写：会话原位替换该卡文本（busy 只作用该卡）。失败才提示——
  /// 成功时卡片文字原地更新，不必再打扰。
  Future<void> _refine(int index, String instruction) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _session.refineCandidate(index, instruction);
    if (!mounted || ok) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('改写失败，保留原文')));
  }

  /// 悬浮窗开关：打开前先查 SYSTEM_ALERT_WINDOW。这是特殊权限，没有运行时
  /// 对话框，只能引导用户去系统设置页（canDrawOverlays →
  /// ACTION_MANAGE_OVERLAY_PERMISSION）；授权回来后用户再打开一次。
  Future<void> _toggleOverlay(bool v) async {
    final messenger = ScaffoldMessenger.of(context);
    if (v) {
      var granted = false;
      try {
        granted = await CaptureAndroid().canDrawOverlays();
      } catch (_) {
        // 通道不可用（Windows 调试 / 引擎未挂）：按未授权处理，走引导分支。
      }
      if (!granted) {
        try {
          await CaptureAndroid().openOverlaySettings();
        } catch (_) {}
        if (!mounted) return;
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text('请在系统设置里允许「显示在其他应用上层」，返回后重新打开悬浮窗'),
          ));
        return; // 权限未给：开关保持关
      }
    }
    if (!mounted) return;
    // 关闭时由 session 负责立即收起悬浮窗（见 _onOverlayEnabledChanged）。
    widget.overlayEnabled.value = v;
    setState(() {});
  }

  Widget _overlayCard() => Card(
        child: SwitchListTile(
          value: widget.overlayEnabled.value,
          onChanged: (v) => _toggleOverlay(v),
          title: const Text('悬浮窗'),
          subtitle: const Text('有新候选时在聊天应用上方弹出；需要「显示在其他应用上层」权限。'),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('采集助手')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _serviceCard(scheme),
          const SizedBox(height: 8),
          _overlayCard(),
          const SizedBox(height: 8),
          _scopeCard(),
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
            onChanged: (v) => _session.extraContext = v,
            decoration: const InputDecoration(
              labelText: '补充背景（如：今天是她生日）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          // A3「学习我的说话方式」：从本会话我方消息挑风格样本，只进写作路。
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _styleLearning,
            onChanged: (v) => setState(() {
              _styleLearning = v;
              _session.styleLearning = v;
            }),
            title: const Text('学习我的说话方式'),
            subtitle: const Text('从本会话「我」发出的消息里挑几条作为风格样本，随起草发送（只进写作路）。'),
          ),
          const SizedBox(height: 8),
          _snapshotCard(),
          _previewTile(),
          const SizedBox(height: 8),
          _suggestionsSection(scheme),
        ],
      ),
    );
  }

  Widget _serviceCard(ColorScheme scheme) => Card(
        child: ListTile(
          leading: Icon(
            _serviceRunning ? Icons.sensors : Icons.sensors_off,
            color: _serviceRunning ? scheme.primary : scheme.error,
          ),
          title: Text(_serviceRunning ? '采集服务运行中' : '采集服务未启用'),
          subtitle: const Text('需要无障碍权限读取聊天窗口内容；不会自动发送任何消息。'),
          trailing: TextButton(
            onPressed: () async {
              try {
                await CaptureAndroid().openAccessibilitySettings();
              } catch (_) {}
            },
            child: const Text('去启用'),
          ),
        ),
      );

  Widget _scopeCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                      child: Text('采集范围',
                          style: Theme.of(context).textTheme.titleSmall)),
                  const Text('OCR 兜底'),
                  Switch(
                    value: _ocrFallback,
                    onChanged: (v) {
                      setState(() => _ocrFallback = v);
                      _pushConfigure();
                    },
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                children: [
                  for (final entry in _knownApps.entries)
                    FilterChip(
                      label: Text(entry.value),
                      selected: _packages.contains(entry.key),
                      onSelected: (sel) {
                        setState(() {
                          if (sel) {
                            _packages.add(entry.key);
                          } else {
                            _packages.remove(entry.key);
                          }
                        });
                        _pushConfigure();
                      },
                    ),
                ],
              ),
              // ⑦ 采集应用黑名单区：名单内的包即使加进白名单也不采（隐私
              // 底线清单，黑名单优先于白名单由 Kotlin 侧 isBlocked() 保证）。
              // 已存项渲染为 FilterChip，点按即移除；底部输入框添加新包名。
              // 「com.android.bank 前缀命中即拦」的底线规则不进这份可编辑
              // 集合（硬编码在 Kotlin 侧），UI 上看不到也不可清空。
              const SizedBox(height: 12),
              Text('黑名单（点按标签移除）',
                  style: Theme.of(context).textTheme.titleSmall),
              Text(
                '名单内的应用永远不采集，即使它在上面被勾选（隐私底线）。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                children: [
                  for (final pkg in _effectiveBlocked.toList()..sort())
                    FilterChip(
                      label: Text(pkg),
                      selected: true,
                      onSelected: (_) => _commitBlocked(
                        Set.of(_effectiveBlocked)..remove(pkg),
                      ),
                    ),
                  if (_effectiveBlocked.isEmpty)
                    const Text('（空——没有应用被拉黑）',
                        style: TextStyle(color: Colors.black38, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _blockedInput,
                      onSubmitted: (_) => _addBlocked(),
                      decoration: const InputDecoration(
                        labelText: '添加包名（如 com.example.app）',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  TextButton(onPressed: _addBlocked, child: const Text('添加')),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _snapshotCard() {
    final state = _session.state.value;
    final snap = state.snapshot;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    snap == null ? '尚未捕获聊天窗口' : '当前会话：${snap.title ?? "（无标题）"}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: '手动整屏 OCR（不在适配清单的应用用这个）',
                  onPressed: _session.manualOcr,
                  icon: const Icon(Icons.document_scanner_outlined),
                ),
              ],
            ),
            if (snap != null) ...[
              // G3：来源行带置信度与原因标签（与桌面流共用
              // CaptureSession.sourceLineOf 的同一份文案）。
              Text('${CaptureSession.sourceLineOf(snap)}'
                  ' · 消息 ${snap.messages.length} 条'),
              const SizedBox(height: 4),
              for (final m in snap.messages.skip(
                  snap.messages.length > 6 ? snap.messages.length - 6 : 0))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${m.side == "me" ? "我" : (m.side == "other" ? "对方" : "发言人不明")}：${m.text}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// G1 隐私预览：折叠面板，展开看本轮判断/写作两条调用各自会收到什么。
  /// 内容由会话在轮次开始时算好（与实际发送同源），没有轮次时不显示。
  Widget _previewTile() {
    final preview = _session.state.value.preview;
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

  /// B8 当前模式：与设置页共用 notifier；未注入（main.dart 未传）时按产品
  /// 默认「主推一张大卡」渲染。
  bool get _primaryMode =>
      (widget.displayMode?.value ?? SettingsStore.displayModePrimary) ==
      SettingsStore.displayModePrimary;

  Widget _suggestionsSection(ColorScheme scheme) {
    final state = _session.state.value;
    if (state.error != null) {
      return Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(state.error!),
        ),
      );
    }
    if (state.busy) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(children: [
            CircularProgressIndicator(strokeWidth: 2),
            SizedBox(width: 12),
            Text('判断与起草中…')
          ]),
        ),
      );
    }
    // G3 置信度门控：来源不可靠的快照没有自动分析（session 挂在
    // needsConfirm），给「确认分析」的出口——点了才把这一屏内容发给模型。
    if (state.needsConfirm) {
      final snap = state.snapshot;
      if (snap != null) {
        final reasons = CaptureSession.uncertainReasonsOf(snap);
        return Card(
          child: ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title:
                Text(reasons.isEmpty ? '来源不可靠，确认分析？' : '来源不可靠（$reasons），确认分析？'),
            subtitle: Text(CaptureSession.sourceLineOf(snap)),
            trailing: FilledButton.tonal(
              onPressed: _session.confirmAnalyze,
              child: const Text('确认分析'),
            ),
          ),
        );
      }
    }
    final ranked = state.analysis?.rankedReplies ?? const <RankedReply>[];
    if (state.handled) {
      // B7：本轮已标记为不用回——安静的确认态，保留「反悔」的入口。
      return Card(
        child: ListTile(
          leading: const Icon(Icons.check_circle_outline),
          title: const Text('本轮已标记为不用回'),
          subtitle: const Text('内容有更新时会自动重新分析；也可以现在重新起草。'),
          trailing: TextButton(
            onPressed: _session.regenerate,
            child: const Text('重新起草'),
          ),
        ),
      );
    }
    if (ranked.isEmpty && !state.canSkipReply) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // B7：判断明确说「这条可以不回」时，先给这个出口——点了把本轮标记为
        // 已处理（收起候选，同签名快照不再起草）。
        if (state.canSkipReply) ...[
          Card(
            child: ListTile(
              leading: const Icon(Icons.mark_chat_unread_outlined),
              title: const Text('这条可以不回'),
              subtitle: const Text('判断认为此刻不回也不影响；点了就把本轮标记为已处理。'),
              trailing: TextButton(
                onPressed: _session.markHandled,
                child: const Text('不用回'),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (ranked.isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                  child: Text('候选回复',
                      style: Theme.of(context).textTheme.titleSmall)),
              TextButton(
                  onPressed: _session.regenerate, child: const Text('换一组')),
            ],
          ),
          const SizedBox(height: 4),
          // B8「一条推荐 + 两条备选」：排序第一张大卡（含策略标签+概率），
          // 其余折叠为两行小字、点击展开；all 模式保持全部平铺。
          if (_primaryMode && ranked.isNotEmpty) ...[
            _fullCandidateCard(0, ranked[0], scheme, recommended: true),
            for (var i = 1; i < ranked.length; i++)
              _expandedCandidates.contains(i)
                  ? _fullCandidateCard(i, ranked[i], scheme)
                  : _collapsedCandidate(i, ranked[i]),
          ] else
            for (var i = 0; i < ranked.length; i++)
              _fullCandidateCard(i, ranked[i], scheme),
        ],
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

  Widget _fullCandidateCard(
    int index,
    RankedReply r,
    ColorScheme scheme, {
    bool recommended = false,
  }) {
    final meta = '${r.strategy} · ${(r.prob * 100).toStringAsFixed(0)}%'
        '${r.reviewNote.isEmpty ? "" : " · ${r.reviewNote}"}';
    final refining = _session.refiningCards.value.contains(index);
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
                  if (_expandedCandidates.contains(index))
                    GestureDetector(
                      onTap: () =>
                          setState(() => _expandedCandidates.remove(index)),
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
            Text(r.text, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonal(
                  onPressed: () => _refill(r.text),
                  child: const Text('回填'),
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

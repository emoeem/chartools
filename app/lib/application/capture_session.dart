import 'dart:async';

import 'package:capture_android/capture_android.dart';
import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// G1 隐私预览：一轮分析的两条模型调用（判断、写作）各自会收到什么。
/// 只列条目与数量，消息原文以页面上的快照卡为准——预览的职责是让用户在
/// 发送前知道「有哪些类目的内容出去了」，而不是把聊天记录再抄一遍。
class SendPreview {
  const SendPreview({required this.judge, required this.writer});

  /// 判断路收到的条目（JevQuestions.buildState 的 state 载荷）。
  final List<String> judge;

  /// 写作路收到的条目（ReplyPrompt.draftUserPrompt / refineUserPrompt）。
  final List<String> writer;
}

/// 一轮「采集 → 判断 → 起草」的可见状态。
class CaptureState {
  const CaptureState({
    this.snapshot,
    this.analysis,
    this.busy = false,
    this.error,
    this.preview,
    this.handled = false,
    this.needsConfirm = false,
  });

  final ChatSnapshot? snapshot;
  final Analysis? analysis;
  final bool busy;
  final String? error;

  /// G1 隐私预览：本轮两条模型调用各自会收到什么（判/写两路分开列）。
  /// 轮次开始时随快照一起算好，与实际随轮发出的 ctx 同源，不是两套清单。
  final SendPreview? preview;

  /// B7 注释口径（全仓库统一）：判断路的结论写作「这条可以不回」
  /// （[canSkipReply]）；用户按下按钮之后的标记写作「不用回」
  /// （[handled] / markHandled）。
  ///
  /// B7「不用回」按下后的本轮标记：候选已收起，不再起草。同签名快照
  /// 不会重开一轮（_onSnapshot 的去重看到 analysis 仍在）；内容变化的快照
  /// signature 不同，自然开新轮并落回默认 false。
  final bool handled;

  /// G3 置信度门控：本快照来源不可靠（confidence ≤ 0.5，见
  /// [CaptureSession.confirmThreshold]），没有自动分析，等用户在页面上点
  /// 「确认分析」（[CaptureSession.confirmAnalyze]）才起轮。确认后该标记随
  /// busy 态落回 false；内容更新的快照（signature 不同）进门时按其自身
  /// 置信度重新判定。忙碌/已有结果/挂起三种态互斥，UI 按这个顺序渲染。
  final bool needsConfirm;

  /// B7：判断结果明确说「这条可以不回」（shouldReplyNow < 0.5）。只有判断
  /// 成功时该字段才非 null——判断失败（error）不会误报。
  bool get canSkipReply {
    final v = analysis?.shouldReplyNow;
    return v != null && v < 0.5;
  }

  /// 供去重用的稳定指纹（与旧仓库同语义：最后几条消息的拼接）。
  String get signature => snapshot?.signature() ?? '';
}

/// Android 端的应用层编排：订阅采集服务的快照流，跑 core 流水线，给出建议。
///
/// 刻意放在 app 而不是插件：判断/起草是纯 Dart 领域逻辑（core 已带测试），
/// 插件只负责「读屏产快照」「回填」与「悬浮窗展示」。悬浮窗
/// （OverlayController，已移植）由本类驱动：建议更新后经 showSuggestions 推
/// 候选，悬浮窗上的「填入/复制」按钮以 overlay_action 事件回到这里，由 Dart
/// 决定回填输入框还是写剪贴板——悬浮窗自身不调模型。
class CaptureSession {
  /// 三个 notifier 都由外部（[SettingsStore]）持有、采集页与设置页共用同一
  /// 份值：本类只读（relationship/overlayEnabled 由页面写），dispose 时只摘
  /// 自己的监听，不 dispose 它们。
  CaptureSession({
    required this.config,
    required this.relationship,
    required this.overlayEnabled,
    this.displayMode,
  });

  /// 应用内存里的模型路由配置；改设置后下一轮立即生效（JevClient 每轮重建）。
  final ValueNotifier<JevConfig> config;

  final state = ValueNotifier<CaptureState>(const CaptureState());

  /// 关系（进入提示词与判断 state 的那个字段）。旧仓库 Prefs.relationship 的
  /// 对应物：由采集页/设置页的输入框写入，流水线用前自行 trim。
  final ValueNotifier<String> relationship;

  /// 「悬浮窗」开关。旧仓库 Prefs.enabled 的对应物（默认开）：打开后建议
  /// 更新时弹悬浮窗，关掉立即收起；采集页与设置页写的是同一份 notifier。
  final ValueNotifier<bool> overlayEnabled;

  /// B8 候选展示模式（可选注入，[SettingsStore.displayMode] 同一份）：推
  /// 悬浮窗时透传给原生侧——'primary' 主推第一张大卡、备选折叠，null/'all'
  /// 整列平铺（旧行为）。切换后下一批候选生效。
  final ValueNotifier<String>? displayMode;

  /// ③ 上下文补充：用户在输入框里写的一句话背景（如「今天是她生日」）。
  /// 由采集页输入框逐键写入，每轮开始时现读——「换一组」不清它（regenerate
  /// 照常组装），输入框清空即移除（空串让 [buildContext] 返回 null）。
  String extraContext = '';

  /// A3「学习我的说话方式」开关：打开后每轮从快照里我方消息挑几条风格样本
  /// 注入写作路（见 [buildContext]）。采集页的开关写入，轮次开始时现读。
  bool styleLearning = false;

  /// G3 置信度门控阈值：快照 confidence 不高于它（≤）不自动分析，挂起
  /// （needsConfirm）等用户确认。按通道契约的扣分口径，掉到 0.5 及以下意味
  /// 着身份已经存疑——最尖锐的是 OCR 基线 0.6 恰好叠一条 unknown-speaker
  /// （整数上的精确 0.5）：说话人不可归属的快照按 p0-plan G3「身份不明确
  /// 宁可拒绝，不猜测」必须停下，不能贴线放行，所以比较用 ≤ 不用 <。
  /// 采集页与桌面流共用这一个值与同一份判定（[shouldConfirm]）。
  static const double confirmThreshold = 0.5;

  /// G3 门控判定（唯一比较点，采集流与桌面流共用）：confidence 不高于
  /// [confirmThreshold] 就挂起等用户确认。阈值本身算「不可信」——见上，
  /// 0.5 正是「OCR + 一条发言人未知」的落点。
  static bool shouldConfirm(ChatSnapshot snapshot) =>
      snapshot.confidence <= confirmThreshold;

  /// ④ 快速改写指令 → 提示词的映射（规格④原文）。采集页与桌面页共用同一
  /// 份常量，UI 上就是每张候选卡的「更短 / 更礼貌 / 换个说法」三个按钮。
  static const String refineShorter = '把这条改得更短，保留原意';
  static const String refinePoliter = '把这条改得更礼貌委婉，不要卑微';
  static const String refineRephrase = '换一种说法，意思不变';

  /// ④ 正在快速改写的卡片下标集合：busy 只作用于该卡，其余卡与「换一组」
  /// 在改写期间照常可用。页面监听重绘；写回永远换新集合（ValueNotifier 按
  /// identical 判定，原地改 Set 不会通知）。
  final ValueNotifier<Set<int>> refiningCards = ValueNotifier(const <int>{});

  /// #3 遗留 low：showSuggestions 返回 false（窗口加不出——最常见是「显示在
  /// 其他应用上层」权限被系统收回）时的一次性通知。本类把开关打回关并置位，
  /// 采集页监听它弹权限引导 SnackBar，消费后把值清回 null，避免重复弹。
  final ValueNotifier<String?> overlayPermissionLost = ValueNotifier(null);

  final CaptureAndroid _capture = CaptureAndroid();
  StreamSubscription<ChatSnapshot>? _sub;
  StreamSubscription<OverlayAction>? _overlaySub;
  JevClient? _jev;

  /// 轮次序号：快照流不等上一轮的网络返回就推下一事件，judge/draft 的延迟又
  /// 不齐，旧轮次可能在新轮次之后完成。每轮开始时 +1 并记下手里的序号，完成
  /// 时只有仍是最新一轮才写 [state] 与推悬浮窗——被更新的快照抢了先的旧轮次
  /// 直接丢弃，防止旧快照的结果覆盖新快照（乱序/并发防护）。
  int _round = 0;

  /// dispose 后在途的异步回写（改写/轮次完成）会碰已 dispose 的 notifier：
  /// 置位后回写入口直接放弃，不再碰 [state] 与 [refiningCards]。
  bool _disposed = false;

  /// 最近一次推给悬浮窗的候选：overlay_action 只带下标，按这个列表解释。
  List<RankedReply> _overlayCandidates = const [];

  /// ③ 补充背景进 ChatContext 的承载说明：ChatContext 没有「裸 background」
  /// 字段——background 是从 contact + notes 推导的（core kb_models.dart 的
  /// ChatContext.background），所以补充背景按一条「用户补充」笔记承载：两路
  /// 的 background() 都渲染出「用户补充: …」一行，判断侧拿到的仍是 state 的
  /// background 字段（JevQuestions.backgroundNote 的既定语义），与规格意图
  /// 一致；冒号格式随笔记模板走半角「: 」。
  static const String _extraNoteId = 'extra_context';

  /// ③+A3：组装本轮进 judge/draftAndRank 的上下文。没有补充背景、也没开
  /// 风格学习时返回 null——请求与旧版「不带 ctx」逐字节一致（载荷、缓存键
  /// 都不动），任何一个开关打开才发。
  ///
  /// [myMessages] 是风格样本的原料；采集页传快照里我方消息（[myMessagesOf]），
  /// 桌面页传粘贴文本解析出的「我：」行。
  static ChatContext? buildContext({
    String? extra,
    List<Msg> myMessages = const [],
    bool styleLearning = false,
  }) {
    final extraText = extra?.trim() ?? '';
    final styleOn = styleLearning && myMessages.isNotEmpty;
    if (extraText.isEmpty && !styleOn) return null;
    final notes = <Note>[];
    if (extraText.isNotEmpty) {
      notes.add(Note(id: _extraNoteId, title: '用户补充', content: extraText));
    }
    if (styleOn) {
      try {
        // A3 契约（core 的 style_profile.buildStyleSamples）：List<Msg> →
        // List<Note>(type: style_sample)。max 用默认 3，与写作提示词
        // <user_style_examples> 通道一轮最多引用 3 条的既有规则对齐。
        notes.addAll(buildStyleSamples(myMessages));
      } catch (_) {
        // 风格学习是尽力而为的增强：样本构建出意外不该拖垮整轮分析。
      }
    }
    if (notes.isEmpty) return null;
    return ChatContext(notes: notes);
  }

  /// A3：风格样本的原料——本会话里确认是我自己发的消息。
  static List<Msg> myMessagesOf(ChatSnapshot snapshot) => [
        for (final m in snapshot.messages)
          if (m.side == 'me') m
      ];

  /// G1：算出本轮隐私预览。[ctx] 必须是真正会随本轮发出的那份（先
  /// [buildContext] 再传进来），预览与实际发送同源；[relationship] 是用户
  /// 输入的原始关系描述（不必先 trim）——流水线在留空时以「朋友」下发，
  /// 预览按同一条缺省规则注明「默认按朋友」，两边说同一件事。
  ///
  /// 窗口数与 core 一致：判断路取最近 10 条（JevQuestions.buildState），写作
  /// 路取最近 20 条（replyWindow）。联系人备注当前版本恒为「无」（联系人库
  /// 是 #5 的范围），仍按有无如实列出，接入后无需改这段。
  static SendPreview buildSendPreview({
    required ChatSnapshot snapshot,
    ChatContext? ctx,
    String relationship = '',
  }) {
    final total = snapshot.messages.length;
    final judgeCount = total > 10 ? 10 : total;
    final writerCount = total > replyWindow ? replyWindow : total;
    var extra = '';
    var kbNotes = 0;
    var styleSamples = 0;
    for (final n in ctx?.notes ?? const <Note>[]) {
      if (n.id == _extraNoteId) {
        extra = n.content.trim();
      } else if (n.type == noteTypeStyleSample) {
        styleSamples++;
      } else {
        kbNotes++;
      }
    }
    final contact = ctx?.contact;
    final hasContact = contact != null &&
        (contact.notes.trim().isNotEmpty ||
            contact.relationship.trim().isNotEmpty ||
            contact.autoSummary.trim().isNotEmpty);
    final historyCount = ctx?.history.length ?? 0;
    final rel = relationship.trim();
    final note = (snapshot.note ?? '').trim();

    List<String> common(String window) => [
          // #4 遗留：关系留空时流水线仍会以缺省「朋友」下发，预览要如实
          // 列出，不能因为没填就整行隐去（写出去了什么就列什么）。
          if (rel.isNotEmpty) '关系描述：「$rel」' else '关系描述：未填写，默认按「朋友」',
          '聊天消息：$window',
          if (extra.isNotEmpty) '背景补充：「$extra」（你输入的一句话）',
          if (hasContact) '联系人备注：有' else '联系人备注：无',
          '知识库笔记：$kbNotes 条',
          '更早历史：$historyCount 条',
        ];

    return SendPreview(
      judge: [
        ...common('最近 $judgeCount 条（共 $total 条，判断只取最近 10 条）'),
        // #4 遗留：采集说明（快照 note）只进判断路——JevQuestions.buildState
        // 把它放进 state.chat.note、由判断模型渲染为 NOTE from the capture
        // step；写作路（ReplyPrompt.draftUserPrompt/refineUserPrompt）只拿
        // 消息正文，从不读 note，故从这里挪到仅判断路。排序轮复用判断模型
        // 与 buildState 也会带上它；G1 预览按「模型通道」分组，归判断路一列。
        if (note.isNotEmpty) '采集说明：「$note」',
      ],
      writer: [
        ...common('最近 $writerCount 条（共 $total 条，写作最多看 $replyWindow 条）'),
        '说话方式样本：$styleSamples 条'
            '（开了「学习我的说话方式」才有；只进写作路，判断路不看）',
      ],
    );
  }

  /// G3：快照卡上的来源行，采集页与桌面流共用同一份文案：
  /// 「来源：OCR · 置信 0.6 · 原因：发言人未知」。没有原因标签时省略原因段。
  static String sourceLineOf(ChatSnapshot snapshot) {
    final line = StringBuffer('来源：${Provenance.labelOf(snapshot.provenance)}'
        ' · 置信 ${formatConfidence(snapshot.confidence)}');
    final reasons = uncertainReasonsOf(snapshot);
    if (reasons.isNotEmpty) line.write(' · 原因：$reasons');
    return line.toString();
  }

  /// G3：原因标签串（如「发言人未知、标题为空」）；没有标签返回空串。
  static String uncertainReasonsOf(ChatSnapshot snapshot) => [
        for (final r in snapshot.uncertain)
          if (r.trim().isNotEmpty) r.trim(),
      ].join('、');

  /// G3：置信度展示格式——两位小数再去掉末尾多余的 0（1.00→1.0、0.60→0.6、
  /// 0.55→0.55），契约口径的 0.05 步进扣分也能如实显示。
  static String formatConfidence(double v) {
    var s = v.toStringAsFixed(2);
    if (s.endsWith('0')) s = s.substring(0, s.length - 1);
    return s;
  }

  /// F1：判断给出的 best_action 对应的策略候选提前到第一位（StrategyOrder 的
  /// 稳定提升，只动显示顺序、不改概率）。draftAndRank/regenerate 的结果入
  /// state 前都要过这里；桌面流也调这个静态方法，两端同一份提升逻辑。
  static List<RankedReply> applyStrategyOrder(
    List<RankedReply> ranked,
    Analysis? analysis,
  ) =>
      StrategyOrder.order(
          ranked, StrategyOrder.preferred(analysis?.bestAction?.choice));

  /// ④ 一次快速改写调用：采集页走 [refineCandidate]（带状态管理），桌面页直接
  /// 调这里（同一份实现，规格④「两页复用」）。成功返回改写文本；模型没给
  /// 内容返回 null，网络异常原样抛给调用方。
  static Future<String?> refineText({
    required JevClient jev,
    required ChatSnapshot snapshot,
    required String relationship,
    ChatContext? ctx,
    required String original,
    required String instruction,
  }) async {
    final refined = await jev.refineReply(
        snapshot, relationship, ctx, original, instruction);
    final text = refined?.text.trim() ?? '';
    return text.isEmpty ? null : text;
  }

  void start() {
    _sub ??= _capture
        .snapshots()
        .listen(_onSnapshot, onError: (Object e) => _setError('$e'));
    // 悬浮窗按钮动作（填入/复制）回到 Dart。
    _overlaySub ??= _capture
        .overlayActions()
        .listen(_onOverlayAction, onError: (Object e) => _setError('$e'));
    // 配置变化后下一轮生效：provider 端点/模型在客户端实例里，改配置就换实例
    // （JevClient 自己的缓存键还会挡掉同输入的重复调用，不受影响）。
    config.addListener(_onConfigChanged);
    overlayEnabled.addListener(_onOverlayEnabledChanged);
  }

  void _onConfigChanged() {
    _jev = null;
  }

  void _onOverlayEnabledChanged() {
    // 关掉开关立即收起悬浮窗；打开则等下一批建议落地时再弹（不主动弹旧的）。
    if (!overlayEnabled.value) _hideSuggestionsQuietly();
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _overlaySub?.cancel();
    _overlaySub = null;
  }

  void _setError(String message) {
    // G3：挂起确认态不能被一条流错误顺手吞掉（快照还在等用户放行）。
    state.value = CaptureState(
      snapshot: state.value.snapshot,
      error: message,
      needsConfirm: state.value.needsConfirm,
    );
  }

  Future<void> _onSnapshot(ChatSnapshot snapshot) async {
    // 服务端已按签名去重；这里再防一道（服务重连后补发最近一条的场景）。
    // 忙碌中的同签名重放也拦：那一轮已经在跑，再来一轮只会重复请求；不忙但
    // 没有分析结果（上一轮失败）时放行，让下一个快照能触发重试。挂起
    // （needsConfirm）态不拦：重放只是重画同一张待确认卡，不起任何网络请求。
    final current = state.value;
    if (snapshot.signature() == current.signature &&
        (current.busy || current.analysis != null)) {
      return;
    }
    // 轮次 token 在门口先 +1：无论本快照走自动分析还是 G3 挂起，在途旧轮
    // 都作废——挂起态要抢在旧轮结果之前写回，否则旧结果会盖掉待确认卡。
    final round = ++_round;
    // G3 置信度门控：来源不可靠（如 OCR 兜底、发言人不可归属）的快照不自动
    // 分析，state 置 needsConfirm 挂起；采集页显示「确认分析？」按钮，点了
    // 才起轮（[confirmAnalyze]）。阈值之上照旧自动开轮。
    if (shouldConfirm(snapshot)) {
      final ctx = buildContext(
        extra: extraContext,
        myMessages: myMessagesOf(snapshot),
        styleLearning: styleLearning,
      );
      state.value = CaptureState(
        snapshot: snapshot,
        needsConfirm: true,
        // 挂起态就把预览亮出来：确认之前用户就能看到「确认后会把什么发出
        // 去」，与 G1 的信任目标一致；真正起轮时 [_runRound] 会按当时的
        // 输入（关系/补充背景可能已改）重算一份写回。
        preview: buildSendPreview(
          snapshot: snapshot,
          ctx: ctx,
          relationship: relationship.value,
        ),
      );
      return;
    }
    await _runRound(snapshot, round);
  }

  /// G3 置信度门控的手动放行：needsConfirm 挂起态下用户点了「确认分析」，
  /// 用当前快照起一轮——与自动路径共用 [_runRound]，轮次 token 同一道防护。
  /// 非挂起态（没快照/已在分析/已有结果）是空操作。
  Future<void> confirmAnalyze() async {
    if (_disposed) return;
    final s = state.value;
    final snapshot = s.snapshot;
    if (snapshot == null || !s.needsConfirm) return;
    final round = ++_round;
    await _runRound(snapshot, round);
  }

  /// 一轮完整分析：组装 ctx/预览 → judge → draftAndRank → 写 state、推悬浮窗。
  /// 自动路径（高置信快照）与手动确认路径（[confirmAnalyze]）共用这一份；
  /// [round] 是进门时领到的轮次 token，await 期间被更新的快照/确认抢先就
  /// 整轮作废（见 [_round] 的乱序/并发防护），旧结果不许写回。
  Future<void> _runRound(ChatSnapshot snapshot, int round) async {
    // ③/A3：本轮上下文在进 try 前组好——judge 与 draftAndRank 必须拿同一份，
    // G1 预览也由它算出（预览与实际发送同源，不是两套各说各话的清单）。
    final ctx = buildContext(
      extra: extraContext,
      myMessages: myMessagesOf(snapshot),
      styleLearning: styleLearning,
    );
    final preview = buildSendPreview(
      snapshot: snapshot,
      ctx: ctx,
      relationship: relationship.value,
    );
    state.value =
        CaptureState(snapshot: snapshot, busy: true, preview: preview);
    try {
      final jev = _jev ??= JevClient(config.value);
      final relationshipText =
          relationship.value.trim().isEmpty ? '朋友' : relationship.value.trim();

      final analysis = await jev.judge(snapshot, relationshipText, ctx: ctx);
      // await 期间可能已有更新的快照开轮：本轮作废，不许覆盖新快照的状态。
      if (round != _round) return;
      var ranked = const <RankedReply>[];
      if (analysis.error == null) {
        // 新快照一律从头起草（avoid 只在「换一组」的当次请求里生效）。
        ranked = await jev.draftAndRank(
          snapshot,
          relationshipText,
          judgment: analysis,
          ctx: ctx,
        );
        if (round != _round) return;
        // F1：best_action 对应的策略候选提前（仅显示顺序，概率不变）。
        ranked = applyStrategyOrder(ranked, analysis);
      }
      state.value = CaptureState(
        snapshot: snapshot,
        analysis: analysis.copyWith(rankedReplies: ranked),
        preview: preview,
      );
      _pushSuggestions();
    } on SafetyBlockedException catch (e) {
      // 安全闸的拒绝要原样给用户看：那是「助手主动拒绝」，不是网络坏了。
      if (round != _round) return;
      state.value = CaptureState(
        snapshot: snapshot,
        error: e.message,
        preview: preview,
      );
    } catch (e) {
      if (round != _round) return;
      state.value = CaptureState(
        snapshot: snapshot,
        error: '$e',
        preview: preview,
      );
    }
  }

  /// 换一组：对最近一个快照重新起草。avoid 取卡片当前候选（与旧仓库
  /// overlay.currentReplyTexts() 同语义：每轮现取，只在这一个请求里生效，
  /// 不落字段、不跨轮残留）；判断沿用卡上已有的结果（置忙态会把它清掉，
  /// 所以先取局部再写 state）。③：extraContext 与风格学习开关照常生效
  /// （「换一组」保留补充背景），F1 的策略提升同样接入。
  Future<void> regenerate() async {
    final snapshot = state.value.snapshot;
    if (snapshot == null || state.value.busy) return;
    final judgment = state.value.analysis;
    final avoid = [
      for (final r in judgment?.rankedReplies ?? const <RankedReply>[])
        if (r.text.isNotEmpty) r.text,
    ];
    final round = ++_round;
    final ctx = buildContext(
      extra: extraContext,
      myMessages: myMessagesOf(snapshot),
      styleLearning: styleLearning,
    );
    final preview = buildSendPreview(
      snapshot: snapshot,
      ctx: ctx,
      relationship: relationship.value,
    );
    state.value =
        CaptureState(snapshot: snapshot, busy: true, preview: preview);
    try {
      final relationshipText =
          relationship.value.trim().isEmpty ? '朋友' : relationship.value.trim();
      final ranked = await (_jev ??= JevClient(config.value)).draftAndRank(
        snapshot,
        relationshipText,
        judgment: judgment,
        avoid: avoid,
        ctx: ctx,
      );
      if (round != _round) return;
      final ordered = applyStrategyOrder(ranked, judgment);
      state.value = CaptureState(
        snapshot: snapshot,
        analysis: judgment?.copyWith(rankedReplies: ordered),
        preview: preview,
      );
      _pushSuggestions();
    } catch (e) {
      if (round != _round) return;
      state.value = CaptureState(
        snapshot: snapshot,
        error: '$e',
        preview: preview,
      );
    }
  }

  /// B7「不用回」按钮：把本轮标记为已处理——收起候选与悬浮窗，不再起草。
  /// 保留快照与判断对象：签名去重靠 analysis 非 null 拦住同签名重放；
  /// [CaptureState.handled] 让 UI 换成「已标记不用回」的安静态。忙碌中不收
  /// （那一轮的结果还没回来，收了也会被写回覆盖）。悬浮窗侧的同款按钮需要
  /// 插件加动作事件，本轮只在采集页/桌面页提供入口。
  Future<void> markHandled() async {
    if (_disposed) return;
    final s = state.value;
    // G3：挂起（needsConfirm）态没有「不用回」可言——还没分析过，标记动作
    // 只属于已开过轮的快照（UI 在挂起态也不提供这个入口，这里兜一道）。
    if (s.snapshot == null || s.busy || s.handled || s.needsConfirm) return;
    state.value = CaptureState(
      snapshot: s.snapshot,
      analysis: s.analysis?.copyWith(rankedReplies: const []),
      preview: s.preview,
      handled: true,
    );
    _overlayCandidates = const [];
    await _hideSuggestionsQuietly();
  }

  /// ④ 快速改写：只替换 [index] 这张卡的文本——原位替换、不重排序、不动概率
  /// （重排序是 rank 轮的事，改写只换字）。busy 只作用于该卡（[refiningCards]）。
  /// 返回是否替换成功；失败（模型没给内容 / 网络 / 被新快照抢轮）保留原文。
  Future<bool> refineCandidate(int index, String instruction) async {
    if (_disposed) return false;
    final s = state.value;
    final snapshot = s.snapshot;
    final analysis = s.analysis;
    if (snapshot == null || s.busy || s.handled || analysis == null) {
      return false;
    }
    if (index < 0 || index >= analysis.rankedReplies.length) return false;
    if (refiningCards.value.contains(index)) return false;
    final original = analysis.rankedReplies[index].text.trim();
    if (original.isEmpty) return false;
    // 轮次 token（与 _onSnapshot 同一道防护）：改写等待期间来了新快照或点了
    // 「换一组」，_round 变化，本轮卡片已被整体替换，改写结果作废不许写回。
    final round = _round;
    final relationshipText =
        relationship.value.trim().isEmpty ? '朋友' : relationship.value.trim();
    _setRefining(index, true);
    try {
      final refined = await refineText(
        jev: _jev ??= JevClient(config.value),
        snapshot: snapshot,
        relationship: relationshipText,
        ctx: buildContext(
          extra: extraContext,
          myMessages: myMessagesOf(snapshot),
          styleLearning: styleLearning,
        ),
        original: original,
        instruction: instruction,
      );
      if (round != _round || _disposed || refined == null) return false;
      final cur = state.value;
      final list = [...?cur.analysis?.rankedReplies];
      // 「标记不用回」可能已把本轮候选清空：此时没有可替换的卡。
      if (index >= list.length) return false;
      list[index] = list[index].copyWith(text: refined);
      state.value = CaptureState(
        snapshot: cur.snapshot,
        analysis: cur.analysis?.copyWith(rankedReplies: list),
        preview: cur.preview,
        handled: cur.handled,
      );
      // 悬浮窗按钮下标按 _overlayCandidates 解释：文本换了，列表与弹窗一起
      // 换，否则「填入」会把改写前的旧文本塞回输入框。
      _overlayCandidates = list;
      await _pushSuggestions();
      return true;
    } catch (_) {
      // 改写失败保留原文：调用方（页面）负责提示，这里不动候选。
      return false;
    } finally {
      // 页面可能在等待期间离开（session 已 dispose）：不能再碰 notifier。
      if (!_disposed) _setRefining(index, false);
    }
  }

  void _setRefining(int index, bool active) {
    final next = {...refiningCards.value};
    if (active) {
      next.add(index);
    } else {
      next.remove(index);
    }
    refiningCards.value = next;
  }

  /// 建议更新后把候选推给悬浮窗（开关打开时）。候选列表存进
  /// [_overlayCandidates]：悬浮窗按钮事件只带下标，按它解释。
  Future<void> _pushSuggestions() async {
    if (_disposed || !overlayEnabled.value) return;
    final ranked = state.value.analysis?.rankedReplies ?? const <RankedReply>[];
    if (ranked.isEmpty) return;
    _overlayCandidates = ranked;
    try {
      final ok = await _capture.showSuggestions(
        list: [
          for (final r in ranked)
            (text: r.text, strategy: r.strategy, prob: r.prob),
        ],
        title: state.value.snapshot?.title,
        // B8 悬浮窗同构：主推模式（大卡+备选折叠）随 notifier 当前值透传。
        mode: displayMode?.value,
      );
      // #3 遗留 low：false = 窗口加不出（窗口 token 失效 / 权限被收回）。
      // 开关打回关——避免「开着却永远弹不出」的哑态——并置位通知采集页弹
      // 权限引导 SnackBar；用户已经手动关掉开关的话就不必再打扰。
      if (!ok && overlayEnabled.value) {
        overlayEnabled.value = false;
        overlayPermissionLost.value = '悬浮窗没有弹出来：可能缺少「显示在其他应用上层」权限，'
            '请在系统设置里重新允许后再打开开关。';
      }
    } catch (_) {
      // 服务未连接（control 通道不存在）等：静默。开关在采集页上，服务状态
      // 卡片显示得一清二楚。
    }
  }

  /// 收起悬浮窗；通道缺失时静默。
  Future<void> _hideSuggestionsQuietly() async {
    try {
      await _capture.hideSuggestions();
    } catch (_) {}
  }

  /// 候选卡折回胶囊（只收卡不撤窗）；通道缺失时静默。
  Future<void> _collapseSuggestionsQuietly() async {
    try {
      await _capture.collapseSuggestions();
    } catch (_) {}
  }

  /// 悬浮窗按钮（填入/复制）回到 Dart。index 按 [_overlayCandidates] 解释；
  /// 「填入」走无障碍回填，失败退回剪贴板（与采集页按钮同一策略）；「复制」
  /// 直接写剪贴板。
  Future<void> _onOverlayAction(OverlayAction action) async {
    final ranked = _overlayCandidates;
    final text = (action.index >= 0 && action.index < ranked.length)
        ? ranked[action.index].text
        : null;
    if (text == null || text.isEmpty) return;
    if (action.action == 'refill') {
      final ok = await refill(text);
      if (ok) {
        // 填入成功后折回胶囊（只收卡不撤窗）：输入框和键盘露出来给用户
        // 检查/发送，胶囊留在屏上可再点开——与 OverlayController「填入后
        // 折回胶囊」同一语义（遗留 low 的统一结论）；整窗撤下只发生在
        // 悬浮窗开关关闭时（见 _onOverlayEnabledChanged）。
        await _collapseSuggestionsQuietly();
      } else {
        await Clipboard.setData(ClipboardData(text: text));
      }
    } else if (action.action == 'copy') {
      await Clipboard.setData(ClipboardData(text: text));
    }
  }

  /// 把一条建议回填进输入框（只填不发；失败返回 false，UI 提示用剪贴板）。
  Future<bool> refill(String text) => _capture.refill(text);

  /// 手动整屏 OCR（聊天应用不在适配清单时的兜底入口）。
  Future<void> manualOcr() async {
    try {
      final snapshot = await _capture.manualOcr();
      if (snapshot != null) await _onSnapshot(snapshot);
    } catch (e) {
      _setError('整屏 OCR 失败：$e');
    }
  }

  void dispose() {
    _disposed = true;
    stop();
    config.removeListener(_onConfigChanged);
    overlayEnabled.removeListener(_onOverlayEnabledChanged);
    _overlayCandidates = const [];
    refiningCards.dispose();
    overlayPermissionLost.dispose();
    state.dispose();
    // config/relationship/overlayEnabled 是外部（SettingsStore）持有的共享
    // notifier：只摘自己的监听，所有权与 dispose 留给持有方。
  }
}

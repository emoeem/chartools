import 'dart:async';

import 'package:capture_android/capture_android.dart';
import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'contact_store.dart';

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

/// C10 会话检查点（p0-plan C10）：一次采集会话的最小可恢复状态——最近快照
/// 签名 + 当时的全局关系描述 + 激活联系人 id。
///
/// 只存这三样是有意的：签名是「上次会话进行到哪一屏」的标识（不是内容——
/// 快照正文不落盘），relationship 与激活联系人是要在「待确认恢复上次会话」
/// 上点过确认才回填的会话上下文。**恢复必须过用户确认**（不静默恢复）：
/// checkpoint 本身只是存档位，谁都不许启动时直接拿它重放会话。
class SessionCheckpoint {
  const SessionCheckpoint({
    required this.signature,
    required this.relationship,
    this.activeContactId,
  });

  /// 最近快照签名（[ChatSnapshot.signature] 的原样拷贝，空串 = 还没有快照）。
  final String signature;

  /// 检查点时刻的全局关系描述（SettingsStore 的 relationship notifier 原样值，
  /// 不 trim——存取习惯与 SettingsStore.relationship 一致，修剪留给使用方）。
  final String relationship;

  /// 检查点时刻的激活联系人 id；null = 当时没有激活联系人。恢复时由 UI 拿
  /// ContactStore.byId 解析回档案（档案可能已被用户删除——解析不到就按
  /// 「无联系人」恢复，不猜测）。
  final String? activeContactId;

  /// 存档形状（键名固定，fromJson 与这里共用）。SettingsStore 把它当作不透明
  /// 的 Map 存取，形状的真相在这里。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'signature': signature,
        'relationship': relationship,
        'activeContactId': activeContactId,
      };

  /// 容错解析：缺字段落默认值，绝不抛（坏存档按「没有可恢复内容」处理）。
  factory SessionCheckpoint.fromJson(Map<String, dynamic> j) =>
      SessionCheckpoint(
        signature: j['signature'] is String ? j['signature'] as String : '',
        relationship:
            j['relationship'] is String ? j['relationship'] as String : '',
        activeContactId: j['activeContactId'] is String
            ? j['activeContactId'] as String
            : null,
      );

  /// 没有任何可恢复内容（UI 据此决定要不要弹「待确认恢复」提示）。
  bool get isEmpty =>
      signature.isEmpty && relationship.isEmpty && activeContactId == null;

  @override
  bool operator ==(Object other) =>
      other is SessionCheckpoint &&
      other.signature == signature &&
      other.relationship == relationship &&
      other.activeContactId == activeContactId;

  @override
  int get hashCode => Object.hash(signature, relationship, activeContactId);
}

/// C10 检查点的落盘句柄：把一份检查点存档覆盖写下去（传 null = 清除「待确认
/// 恢复」）。由 SettingsStore 的存档实现（settings_store.dart 的
/// saveSessionCheckpoint，检查点作为 `sessionCheckpoint` 键并入整包 JSON），
/// UI 接线时把 `store.saveSessionCheckpoint` 撕下传进来；测试用内存实现。
typedef CheckpointWriter = Future<void> Function(
    Map<String, dynamic>? checkpoint);

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
    this.scenarioId,
    this.writeCheckpoint,
    this.stats,
    this.preferences,
    this.knowledgeBase,
  });

  /// C10 检查点的落盘句柄（可选注入；[CheckpointWriter] 的说明与接线方式见
  /// 那里）。null = 检查点只算不写（测试/桌面流默认），采集行为不受影响。
  final CheckpointWriter? writeCheckpoint;

  /// C9 使用统计（可选注入，[SettingsStore.usage] 那一份实例，接线契约见
  /// core 的 usage_stats.dart）：传进来后 JevClient 四条路由的打点写进它，
  /// 设置页统计卡读的是同一个对象。null = 不打点（工具页直开的测试场景），
  /// 行为与统计接入前逐字节一致。
  final UsageStats? stats;

  /// G7 结构化偏好（可选注入，[PreferenceProfile]）：传入后每轮把
  /// [PreferenceProfile.styleAddendum] 作为一条固定 id 的偏好笔记随 ctx 进
  /// **写作路**（不进判断路，见 [_preferenceNoteId]），G1 预览同步列出。
  /// null = 不注入（与没有记录时同样不发偏好内容）。
  final PreferenceProfile? preferences;

  /// 知识检索注入（超越点，可选注入）：传入 [KbStore] 后每轮起草前用「最后
  /// 一条对方消息」作 query 走 [KbStore.search]（top-k=[kbRefTopK]），命中的
  /// **启用**笔记以「知识参考（来源：知识库笔记《标题》）」段随 ctx 进提示
  /// 词——来源标注随段出门，候选引用了哪条笔记在提示词里可追溯。注入走
  /// ctx.notes（type 默认 'note'），判断路的 background 与写作路的
  /// knowledgeBlock 都会渲染这一段；S1 复查提示词当前不读 ctx.notes（
  /// reply_review.dart 的既定形状，见 ReplyReview.user 参数表），要让复查也
  /// 看到依据得改 core 复查装配，不属于本文件。
  ///
  /// 开关口径与 KnowledgeController 的启用开关同源：直接读 KbStore 的启用位
  /// （[KbStore.search] 默认只搜未禁用笔记），**不引入新的设置键**。null =
  /// 未注入（旧构造方/工具页直开的测试场景）：所有轮次的请求与缓存键和接入
  /// 前逐字节一致。生产已接线（独立复核补接）：main.dart 把应用级 KbStore
  /// 经 CapturePage 传入，与知识库页同一份实例。无命中/对方消息为空/检索
  /// 异常一律静默跳过（[knowledgeRefsOf]）：search 是同步内存 BM25、k=3，
  /// 个人库量级不构成起草路径的可见延迟。
  final KbStore? knowledgeBase;

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

  /// 场景选择（fix(#11 P0-N)，可选注入，[SettingsStore.scenarioId] 同一份）：
  /// 引导页「选场景」写入、[SettingsStore.load] 从存档恢复的那份 notifier，
  /// 这里只读。每轮起草时经 [resolveScenario] 现查 [Scenarios.byId] 并把模板
  /// 传给 JevClient.draftAndRank——场景换掉后下一轮立即生效（与 extraContext/
  /// styleLearning 的「每轮现读」同一节奏），不注册监听（流水线没有重绘诉求）。
  ///
  /// null = 未注入（测试/旧构造方）：所有轮次都不带场景，请求与缓存键和接入
  /// 前逐字节同构（键在 core 侧多一个空串分量，提示词一个字节都不变）。
  /// 注入了但值是空串或未知 id 时同样落到「无场景」（Scenarios.byId 返回
  /// null 的约定，settings_store.dart scenarioId 字段注释）。
  final ValueNotifier<String>? scenarioId;

  /// 场景 id → 场景模板的唯一解析点（fix(#11 P0-N)）。采集会话每轮用它把
  /// [scenarioId] notifier 的当前值换成 [ScenarioTemplate] 传给
  /// JevClient.draftAndRank；桌面流（desktop_assistant_page）与测试也走这里，
  /// 保证两端「空串/未知 id → 无场景」的回退口径一致。
  ///
  /// notifier 为 null（未注入）或值查不到内置场景（空串、已下线的 id）时返回
  /// null——null 场景进 JevClient 后提示词逐字节不变（chat_copilot 的附加段
  /// 是空串，选了默认场景与没选在提示词上等价）。
  static ScenarioTemplate? resolveScenario(ValueNotifier<String>? scenarioId) =>
      scenarioId == null ? null : Scenarios.byId(scenarioId.value);

  /// 当前激活联系人档案（UI 经 [applyContact] 喂进来）。null = 没有激活，
  /// 每一处组 ctx / 算关系 / 算预览的路径都回到改前的原样（逐字节一致）。
  ///
  /// G8 隔离（有意）：本类只**读**这份档案，不持有 ContactStore、也没有任何
  /// 写回 ContactProfile 的通路——判断/起草的结果绝不自动进联系人档案。
  /// UI 改了档案（编辑表单、确认入库）要自己重新调 [applyContact] 喂最新值。
  ContactProfile? _activeContact;

  /// 激活/切换/取消联系人档案（UI 在联系人选择器与档案编辑后调用）。
  ///
  /// - null：取消激活。此后每一轮与改前完全同构：buildContext 不带联系人、
  ///   relationshipText 就是全局输入、预览不含联系人行——载荷与缓存键都回到
  ///   逐字节一致的旧形状。
  /// - 非空：下一轮起，relationship/persona/avoidWords 三个正文字段进
  ///   ChatContext（contact 关系压全局走 core 的 effectiveRelationship，人设
  ///   正文经 StyleSource 压全局 style，avoidWords 走一条固定标题的知识笔记）；
  ///   **notes（浏览信息）在这里被刻意丢弃，永不进提示词**（核心原则④，见
  ///   ContactProfile 类文档）。
  ///
  /// 只换档案引用，不动当前 state（挂起/结果卡照旧显示）：预览在真正起轮时
  /// 由 _runRound 按当时输入重算，与 G3 挂起注释里的既定行为一致。
  void applyContact(ContactProfile? contact) {
    _activeContact = contact;
    _writeCheckpoint(state.value.signature);
  }

  /// C10：用户在「待确认恢复上次会话」提示上点了确认之后，UI 用存档里的
  /// 检查点调这里回填会话上下文。只恢复检查点里有的东西：关系描述回填全局
  /// notifier，激活联系人由 UI 先拿 ContactStore.byId 解析（解析不到传 null，
  /// 按「无联系人」恢复——档案可能已被删除，不猜测）。快照本身不恢复：签名
  /// 只是标识，正文从未落盘。
  ///
  /// 这是本类**唯一**写全局 relationship notifier 的地方（其余场合它都由
  /// 页面写、本类只读）——恢复动作本身就是一次显式的用户输入转达。
  void restoreCheckpoint(SessionCheckpoint checkpoint,
      {ContactProfile? contact}) {
    relationship.value = checkpoint.relationship;
    applyContact(contact);
  }

  /// C10：把当前会话状态（最近快照签名 / 全局关系 / 激活联系人）写进检查点。
  /// 尽力而为：没有句柄或写盘失败都静默——检查点丢了顶多少一次恢复提示，
  /// 不能让采集主流程为它失败。
  Future<void> _writeCheckpoint(String signature) async {
    final writer = writeCheckpoint;
    if (writer == null || _disposed) return;
    try {
      await writer(SessionCheckpoint(
        signature: signature,
        relationship: relationship.value,
        activeContactId: _activeContact?.id,
      ).toJson());
    } catch (_) {
      // 检查点写盘失败不拦截采集：下次快照进门会再写。
    }
  }

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

  /// 联系人 avoidWords 进 ChatContext 的承载笔记 id（G7「反馈结构化」）：
  /// 一条固定标题的知识笔记，两路的 background() 都渲染出「避免用词: …」。
  /// 用固定 id 让 G1 预览能把它从普通知识笔记里认出来单独列行。
  static const String _contactAvoidNoteId = 'contact_avoid_words';

  /// G7 偏好附言进 ChatContext 的承载笔记 id：一条固定 id 的偏好笔记，内容是
  /// [PreferenceProfile.styleAddendum] 的原文。**只进写作路、不进判断路**：
  /// 笔记 type 用 [noteTypePreferenceAddendum]，core 的 ChatContext.background
  /// 对该 type 刻意跳过——判断路的 state 与判断缓存键因此都看不到它；写作路
  /// 的 knowledgeBlock 渲染它。固定 id 同样供 G1 预览单独列行（写出去了什么
  /// 就列什么）。规格出处：workflow-drafts chartools-6 记忆与个性化包
  /// .dwf.ts:109「这段进 ReplyPrompt.styleBlock 之后由调用方拼接……调用方在
  /// app 侧拼」——app 侧的拼接点就是这里（把附言变成随 ctx 出门的笔记）。
  static const String _preferenceNoteId = 'preference_addendum';

  /// G7 偏好附言 → 一条知识笔记；无记录（附言空串）返回 null，不产空笔记。
  /// 每轮现算：用户在偏好面板删除后，下一轮起草立即不再带附言。
  static Note? _preferenceNoteOf(PreferenceProfile? preferences) {
    final addendum = preferences?.styleAddendum() ?? '';
    if (addendum.isEmpty) return null;
    return Note(
      id: _preferenceNoteId,
      title: '用户的风格偏好反馈',
      content: addendum,
      type: noteTypePreferenceAddendum,
    );
  }

  /// avoidWords 笔记的正文前缀：笔记内容 = 前缀 + 「、」连接的词表；G1 预览
  /// 显示词表时按它剥前缀。
  static const String _avoidNotePrefix = '不要使用这些词/说法：';

  /// 检索注入的 top-k：一轮最多注入 3 条知识参考。k 刻意小——个人库量级下
  /// 检索本身便宜，但注入的每条都会占提示词预算，与风格样本一轮 ≤3 条的
  /// 既有规则（style_profile.buildStyleSamples）同数量级。
  static const int kbRefTopK = 3;

  /// 检索注入笔记的 id 前缀：G1 预览用它把「知识参考」从普通知识笔记里认
  /// 出来单独列行（同 [_extraNoteId]/[_preferenceNoteId] 的固定 id 手法，
  /// 前缀 + 命中笔记 id 保证唯一）。
  static const String kbRefIdPrefix = 'kb_ref_';

  /// 检索注入（超越点）：最后一条对方消息 → [KbStore.search]（top-k=3）→
  /// 命中的**启用**笔记变成随 ctx 出门的「知识参考」段。
  ///
  /// 静默契约：未注入 / 没有对方消息 / 无命中 / 检索抛异常 → 返回空表，
  /// 绝不拖垮或拖慢起草路径（search 是同步内存 BM25，k 小；异常全吞为不
  /// 注入）。评测日志刻意不写（logSearch: false）：注入检索是自动行为，
  /// 写进去会污染检索评测数据（SearchLogEntry 的口径是「用户提交的查询」，
  /// 见 KnowledgeController.retrieve 的分工注释）。
  ///
  /// 返回的笔记 id 带 [kbRefIdPrefix] 前缀（G1 预览识别用），标题即来源标注
  /// 「知识参考（来源：知识库笔记《标题》）」；正文逐字搬运，不做改写。
  static List<Note> knowledgeRefsOf(KbStore? store, ChatSnapshot snapshot) {
    if (store == null) return const <Note>[];
    // query = 最后一条对方消息（从最新往回找第一条 side == other）。快照里
    // 只有我方消息（自己先开口的屏）或发言人不可知时没有可检索的线头，静默
    // 跳过——拿我方消息检索会把「我想说的」当成「对方在说的」。
    String query = '';
    for (final m in snapshot.messages.reversed) {
      if (m.side == 'other') {
        query = m.text.trim();
        break;
      }
    }
    if (query.isEmpty) return const <Note>[];
    try {
      final result = store.search(query, k: kbRefTopK, logSearch: false);
      final refs = <Note>[];
      for (final hit in result.hits) {
        final tracked = store.note(hit.id);
        // 双保险：search 已按启用位过滤（includeDisabled 缺省 false，与
        // KnowledgeController 的启用开关同口径），这里再核对存在与启用——
        // 防「检索到、注入前」的窄窗里笔记被删/停用。空正文的笔记没有可
        // 参考的内容，同样跳过。
        if (tracked == null || !tracked.note.enabled) continue;
        if (tracked.note.content.trim().isEmpty) continue;
        final title = tracked.note.title.trim();
        refs.add(Note(
          id: '$kbRefIdPrefix${tracked.note.id}',
          title: '知识参考（来源：知识库笔记《${title.isEmpty ? '无标题' : title}》）',
          content: tracked.note.content,
        ));
      }
      return refs;
    } catch (_) {
      // 坏档/检索异常：不注入，绝不把它变成起草路径的故障。
      return const <Note>[];
    }
  }

  /// ③+A3+联系人+检索注入：组装本轮进 judge/draftAndRank 的上下文。没有补充
  /// 背景、没开风格学习、没有带正文字段的激活联系人、也没有知识参考时返回
  /// null——请求与旧版「不带 ctx」逐字节一致（载荷、缓存键都不动），任何
  /// 一个来源有货才发。
  ///
  /// [myMessages] 是风格样本的原料；采集页传快照里我方消息（[myMessagesOf]），
  /// 桌面页传粘贴文本解析出的「我：」行。
  ///
  /// [contact] 是激活联系人档案（采集页传 [CaptureSession.applyContact] 存下
  /// 的那份；桌面流不传）。三个正文字段的通路：relationship/persona 挂在
  /// ChatContext.contact 上（人设正文经 core StyleSource 压全局 style、关系
  /// 经 effectiveRelationship 压全局——两条优先级都是 core 的既定语义）；
  /// avoidWords 走 [_contactAvoidNoteId] 那条知识笔记。档案的 notes（浏览
  /// 信息）**在这里被刻意丢弃**——它与 core Contact.notes 同名不同义，后者
  /// 经 background() 进提示词，照抄就破坏了浏览/正文分离（ContactProfile
  /// 类文档的硬约束）。
  ///
  /// [preferences] 是 G7 结构化偏好（采集页/桌面页传 [SettingsStore.usage]
  /// 同层的 store 注入）：非空且有记录时，[PreferenceProfile.styleAddendum]
  /// 的附言作为一条 [_preferenceNoteId] 笔记进 ctx——只进写作路（笔记 type
  /// 决定 core 两侧的分流，见 [_preferenceNoteId] 的注释），G1 预览按同一份
  /// ctx 列出。无记录时与不注入逐字节一致。
  ///
  /// [knowledgeRefs] 是检索注入的知识参考（[CaptureSession.knowledgeRefsOf]
  /// 产出，采集流四个组 ctx 的入口传同一份）：非空时作为「知识参考（来源：
  /// 知识库笔记《标题》）」段进 ctx.notes——type 是默认 'note'，随
  /// background() 进判断路与写作路两路，来源标注随段出门；为空时与不传
  /// 逐字节一致（未注入 KbStore 的构造方行为不变）。
  static ChatContext? buildContext({
    String? extra,
    List<Msg> myMessages = const [],
    bool styleLearning = false,
    ContactProfile? contact,
    PreferenceProfile? preferences,
    List<Note> knowledgeRefs = const [],
  }) {
    final extraText = extra?.trim() ?? '';
    final styleOn = styleLearning && myMessages.isNotEmpty;
    final coreContact = _coreContactOf(contact);
    final avoidNote = _avoidWordsNoteOf(contact);
    final preferenceNote = _preferenceNoteOf(preferences);
    if (extraText.isEmpty &&
        !styleOn &&
        coreContact == null &&
        avoidNote == null &&
        preferenceNote == null &&
        knowledgeRefs.isEmpty) {
      return null;
    }
    final notes = <Note>[];
    if (avoidNote != null) {
      notes.add(avoidNote);
    }
    if (preferenceNote != null) {
      notes.add(preferenceNote);
    }
    if (extraText.isNotEmpty) {
      notes.add(Note(id: _extraNoteId, title: '用户补充', content: extraText));
    }
    // 检索注入的知识参考放最后：它们是「对着最后一条对方消息」的会话级参考，
    // 排在联系人/偏好/补充背景之后读起来最自然。空表时 addAll 是空操作，
    // notes 与改前逐字节一致。
    notes.addAll(knowledgeRefs);
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
    // 只写了关系/人设、没有 avoidWords/补充背景/风格样本的联系人也会走到
    // 这里：notes 为空但 coreContact 在场，照常发——联系人正文本就是 ctx
    // 的一等来源，不能被「笔记空」吞掉。两头都空才回落「不带 ctx」。
    if (notes.isEmpty && coreContact == null) return null;
    return ChatContext(contact: coreContact, notes: notes);
  }

  /// 联系人档案 → core Contact 的映射（进提示词的只有三个正文字段）。
  /// relationship 与 persona 都为空时返回 null：档案里没有任何进提示词的
  /// 内容，就当没激活过——避免一个空壳 contact 让预览/空判断说出「有联系人
  /// 数据」的假话。
  static Contact? _coreContactOf(ContactProfile? profile) {
    if (profile == null) return null;
    final rel = profile.relationship.trim();
    final persona = profile.persona.trim();
    if (rel.isEmpty && persona.isEmpty) return null;
    return Contact(
      id: profile.id,
      name: profile.displayName,
      aliases: List<String>.of(profile.aliases),
      relationship: rel,
      persona: persona,
      // 浏览信息（档案 notes）到此为止：不进提示词，也绝不冒充 core 侧的
      // contact notes 通道（见 buildContext 的文档）。
      notes: '',
      autoSummary: '',
      updatedAt: profile.updatedAt,
    );
  }

  /// 联系人 avoidWords → 一条知识笔记（id [_contactAvoidNoteId]）；词表为空
  /// 返回 null，不产空笔记。
  static Note? _avoidWordsNoteOf(ContactProfile? profile) {
    if (profile == null) return null;
    final words = <String>[
      for (final w in profile.avoidWords)
        if (w.trim().isNotEmpty) w.trim(),
    ];
    if (words.isEmpty) return null;
    return Note(
      id: _contactAvoidNoteId,
      title: '避免用词',
      content: '$_avoidNotePrefix${words.join('、')}',
    );
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
  /// 路取最近 20 条（replyWindow）。激活联系人（ctx.contact 来自
  /// [buildContext] 的映射）时如实列出：关系行显示联系人关系并注明压过全局、
  /// avoidWords 单独一行、专用人设也算「联系人备注：有」（它经 StyleSource
  /// 压全局 style 出了门）。没有激活联系人时所有行与改前逐字节一致。
  /// G7 偏好附言（[_preferenceNoteId] 笔记，与实际发送同源）列进写作路一列；
  /// 检索注入的知识参考（[kbRefIdPrefix] 前缀笔记，判断/写作两路都渲染）
  /// 按条列进公共一列。
  static SendPreview buildSendPreview({
    required ChatSnapshot snapshot,
    ChatContext? ctx,
    String relationship = '',
  }) {
    final total = snapshot.messages.length;
    final judgeCount = total > 10 ? 10 : total;
    final writerCount = total > replyWindow ? replyWindow : total;
    var extra = '';
    var avoid = '';
    var preference = '';
    var kbNotes = 0;
    var kbRefs = 0;
    var styleSamples = 0;
    for (final n in ctx?.notes ?? const <Note>[]) {
      if (n.id == _extraNoteId) {
        extra = n.content.trim();
      } else if (n.id == _contactAvoidNoteId) {
        final c = n.content.trim();
        avoid = c.startsWith(_avoidNotePrefix)
            ? c.substring(_avoidNotePrefix.length)
            : c;
      } else if (n.id == _preferenceNoteId) {
        // G7 偏好附言：与实际发送同源（同一份 ctx），列进写作路一列——它
        // 不进判断路（[_preferenceNoteId] 的注释），判断列里也不出现。
        preference = n.content.trim();
      } else if (n.id.startsWith(kbRefIdPrefix)) {
        // 检索注入的知识参考：进 ctx.notes → 判断/写作两路都渲染，common()
        // 列行（写出去了什么就列什么）。来源标注在笔记标题里，随段出门。
        kbRefs++;
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
            // 专用人设压全局 style（StyleSource.resolve），也算联系人数据
            // 出了门——只查 notes/relationship 会把 persona-only 的档案漏报
            // 成「无」，违反 G1「写出去了什么就列什么」。
            contact.persona.trim().isNotEmpty ||
            contact.autoSummary.trim().isNotEmpty);
    final historyCount = ctx?.history.length ?? 0;
    final contactRel = contact?.relationship.trim() ?? '';
    final rel = relationship.trim();
    final note = (snapshot.note ?? '').trim();

    List<String> common(String window) => [
          // #4 遗留：关系留空时流水线仍会以缺省「朋友」下发，预览要如实
          // 列出，不能因为没填就整行隐去（写出去了什么就列什么）。联系人
          // 自己写了关系时显示联系人那份并注明压过全局——与流水线实际下发
          // 的 effectiveRelationship 同源，两边说同一件事。
          if (contactRel.isNotEmpty)
            '关系描述：「$contactRel」（来自联系人「${contact?.name ?? ''}」，压过全局）'
          else if (rel.isNotEmpty)
            '关系描述：「$rel」'
          else
            '关系描述：未填写，默认按「朋友」',
          '聊天消息：$window',
          if (extra.isNotEmpty) '背景补充：「$extra」（你输入的一句话）',
          if (avoid.isNotEmpty) '避免用词：「$avoid」（联系人档案）',
          if (hasContact) '联系人备注：有' else '联系人备注：无',
          '知识库笔记：$kbNotes 条',
          // 检索注入的知识参考按条列出（判断/写作两路都带，所以列在 common）：
          // 行文点明来源口径，用户能对上「知识库页里那条笔记出门了」。
          if (kbRefs > 0)
            '知识参考：$kbRefs 条'
                '（来源：知识库笔记，按最后一条对方消息检索注入，含来源标注）',
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
        // G7 偏好附言原文照列（写出去了什么就列什么）；它是用户自己的标注
        // 统计，不是聊天内容，附言里也从不引用候选原文。
        if (preference.isNotEmpty) '偏好反馈附言：「$preference」（你在候选卡上标注的结构化偏好，只进写作路）',
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
    // C10 检查点：快照进门即记一笔（自动分析与挂起确认两条路共用这一刻）——
    // 「上次会话进行到哪一屏、什么关系、激活了谁」在这里定格。尽力而为：
    // 写失败静默（见 _writeCheckpoint），不阻塞本轮。
    unawaited(_writeCheckpoint(snapshot.signature()));
    // G3 置信度门控：来源不可靠（如 OCR 兜底、发言人不可归属）的快照不自动
    // 分析，state 置 needsConfirm 挂起；采集页显示「确认分析？」按钮，点了
    // 才起轮（[confirmAnalyze]）。阈值之上照旧自动开轮。
    if (shouldConfirm(snapshot)) {
      final ctx = buildContext(
        extra: extraContext,
        myMessages: myMessagesOf(snapshot),
        styleLearning: styleLearning,
        contact: _activeContact,
        preferences: preferences,
        // 检索注入：挂起态的预览也要如实列出知识参考——真正起轮时
        // [_runRound] 按当时输入重算，两处同一份产出，预览与发送同源。
        knowledgeRefs: knowledgeRefsOf(knowledgeBase, snapshot),
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
  ///
  /// P0 判断降级（裁定：判断路由默认关闭 + 优雅降级）：
  /// - **未配置就跳过判断**：`config.value.judgeRouteConfigured()` 为 false
  ///   （判据唯一在 JevConfig，典型落点：全新安装 judgeProvider='jev' +
  ///   judgeBaseUrl='' → 端点是相对地址，发不出 POST）时**不发起 judge 调用**
  ///   （连打点都不记——路由没配就不算「调用」），合成一个无错误、无
  ///   best_action 的空判断对象直接进起草。判定用与客户端同一份
  ///   `config.value`（JevClient 每 config 变更重建，见 [_onConfigChanged]，
  ///   不存在门与客户端各读一份旧值的分叉）；core 的 JudgeClient.judge 还有
  ///   一道同判据的门兜住其它调用方（桌面页/analyze）。
  /// - **已配置但调用失败照样起草**：judge 失败的既有语义是返回
  ///   `Analysis.error`（不抛），原来 error 非 null 就整轮放弃起草、候选恒
  ///   空（P0 取证路径）。现在失败只降级判断，不拦起草；错误**留在
  ///   state 的可见位置**——`CaptureState.analysis.error` 原样保留（桌面
  ///   助手页按它渲染判断错误卡，不静默吞；采集页当前只渲染顶层
  ///   [CaptureState.error]，候选与错误互斥的渲染改进归 UI 文件，见
  ///   capture_page.dart `_suggestionsSection` 的注释责任划分），本轮
  ///   刻意**不**写顶层 error：写了它采集页就用错误卡顶掉候选列表，等于
  ///   从后门复刻「候选恒空」。进起草的 judgment 经
  ///   [JudgeClient.usableJudgment] 过滤（失败/空判断 → null 盲写，
  ///   提示词不引入「看不出×3」的噪声块）。
  Future<void> _runRound(ChatSnapshot snapshot, int round) async {
    // ③/A3/联系人：本轮上下文在进 try 前组好——judge 与 draftAndRank 必须
    // 拿同一份，G1 预览也由它算出（预览与实际发送同源，不是两套各说各话的
    // 清单）。激活联系人的三个正文字段在这里随 ctx 进两路。
    final ctx = buildContext(
      extra: extraContext,
      myMessages: myMessagesOf(snapshot),
      styleLearning: styleLearning,
      contact: _activeContact,
      preferences: preferences,
      // 检索注入（超越点）：最后一条对方消息 → KbStore.search → 知识参考段。
      // 同步、k=3、异常全吞（[knowledgeRefsOf]），不拖慢起草路径；未注入
      // KbStore 时恒为空表，ctx 与接入前逐字节一致。
      knowledgeRefs: knowledgeRefsOf(knowledgeBase, snapshot),
    );
    final preview = buildSendPreview(
      snapshot: snapshot,
      ctx: ctx,
      relationship: relationship.value,
    );
    state.value =
        CaptureState(snapshot: snapshot, busy: true, preview: preview);
    try {
      final jev = _jev ??= JevClient(config.value, stats: stats);
      // 联系人自己写了关系就压过全局（core 的 effectiveRelationship 语义，
      // kb_models.dart:172-176「两行打架」的既定结论）；没有激活联系人或档案
      // 没写关系时，fallback 分支就是改前的原样计算，逐字节一致。
      final relationshipText = effectiveRelationship(
        ctx,
        relationship.value.trim().isEmpty ? '朋友' : relationship.value.trim(),
      );

      // P0 判断降级第一道门：未配置跳过 judge 调用（含打点），合成空判断。
      // 空对象形状与 core 门（JudgeClient.judge 未配置分支）一致，两处共用
      // JevConfig.judgeRouteConfigured 这一份判据；判定与客户端构造读同一份
      // config.value，门与请求用的配置不会各拿各的。
      final Analysis analysis;
      if (config.value.judgeRouteConfigured()) {
        analysis = await jev.judge(snapshot, relationshipText, ctx: ctx);
      } else {
        analysis = Analysis(
          rankedReplies: const [],
          latencyMs: 0,
        );
      }
      // await 期间可能已有更新的快照开轮：本轮作废，不许覆盖新快照的状态。
      if (round != _round) return;
      // 新快照一律从头起草（avoid 只在「换一组」的当次请求里生效）。
      // P0 判断降级：judge 失败/未配置不再拦起草——判断不可用就盲写。
      // fix(#11 P0-N)：场景随 notifier 当前值进起草路（判断路不消费场景，
      // judge 调用不动）——resolveScenario 为 null 时与接入前逐字节一致。
      final usable = JudgeClient.usableJudgment(analysis);
      var ranked = await jev.draftAndRank(
        snapshot,
        relationshipText,
        judgment: usable,
        ctx: ctx,
        scenario: resolveScenario(scenarioId),
      );
      if (round != _round) return;
      // F1：best_action 对应的策略候选提前（仅显示顺序，概率不变）。判断
      // 不可用时 usable 的 best_action 为 null → StrategyOrder 无偏好 →
      // 原序返回，与「判断不可用」语义一致。
      ranked = applyStrategyOrder(ranked, usable);
      // 错误随 analysis 原样保留（含判 latency）：桌面页渲染判断错误卡，
      // 采集页候选区照常出卡——见方法头注释的可见位置说明。
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
  /// （「换一组」保留补充背景）；激活联系人的正文字段照常随 ctx 进来；
  /// F1 的策略提升同样接入。
  ///
  /// P0 判断降级：卡上的判断可能不可用（未配置合成的空对象 / 调用失败带错
  /// 对象）——写回 state 的仍用**原对象**（错误标注、候选载体不能丢，桌面
  /// 页的错误卡靠它），但进起草路 judgment 的按 [JudgeClient.usableJudgment]
  /// 过滤成 null（盲写），与 [_runRound] 的降级轮同构：同快照同配置下，
  /// 首轮与「换一组」的起草提示词形状一致，不会一轮带「看不出」噪声块、
  /// 一轮不带。可用判断（error == null 且有信号）的行为与改前一致。
  Future<void> regenerate() async {
    final snapshot = state.value.snapshot;
    if (snapshot == null || state.value.busy) return;
    final stored = state.value.analysis;
    // 盲写口径与 _runRound 同一份准入判定：判断不可用 → null。
    final judgment = JudgeClient.usableJudgment(stored);
    final avoid = [
      for (final r in stored?.rankedReplies ?? const <RankedReply>[])
        if (r.text.isNotEmpty) r.text,
    ];
    final round = ++_round;
    final ctx = buildContext(
      extra: extraContext,
      myMessages: myMessagesOf(snapshot),
      styleLearning: styleLearning,
      contact: _activeContact,
      preferences: preferences,
      // 检索注入：「换一组」与首轮同一份知识参考口径——同快照同库，检索
      // 结果相同，重新起草的候选站在同一批依据上。
      knowledgeRefs: knowledgeRefsOf(knowledgeBase, snapshot),
    );
    final preview = buildSendPreview(
      snapshot: snapshot,
      ctx: ctx,
      relationship: relationship.value,
    );
    state.value =
        CaptureState(snapshot: snapshot, busy: true, preview: preview);
    try {
      // 与 _runRound 同一份 effectiveRelationship 语义（无联系人时即原样）。
      final relationshipText = effectiveRelationship(
        ctx,
        relationship.value.trim().isEmpty ? '朋友' : relationship.value.trim(),
      );
      final ranked =
          await (_jev ??= JevClient(config.value, stats: stats)).draftAndRank(
        snapshot,
        relationshipText,
        judgment: judgment,
        avoid: avoid,
        ctx: ctx,
        // fix(#11 P0-N)：「换一组」同样按当前场景起草——用户改了场景再点
        // 换一组，缓存键换掉，不会命中旧场景的候选。
        scenario: resolveScenario(scenarioId),
      );
      if (round != _round) return;
      final ordered = applyStrategyOrder(ranked, judgment);
      state.value = CaptureState(
        snapshot: snapshot,
        // 写回用原对象（含 error / 空判断语义），只换候选列表。
        analysis: stored?.copyWith(rankedReplies: ordered),
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
    _setRefining(index, true);
    try {
      // 与 _runRound 同一份 effectiveRelationship 语义（无联系人时即原样）。
      // ctx 在 try 内现组：改写请求与当轮采集的两路拿同一份联系人正文字段。
      final ctx = buildContext(
        extra: extraContext,
        myMessages: myMessagesOf(snapshot),
        styleLearning: styleLearning,
        contact: _activeContact,
        preferences: preferences,
        // 检索注入：改写路同口径——改出来的候选与起草站在同一批知识依据上，
        // 不会「改写后依据消失」。
        knowledgeRefs: knowledgeRefsOf(knowledgeBase, snapshot),
      );
      final relationshipText = effectiveRelationship(
        ctx,
        relationship.value.trim().isEmpty ? '朋友' : relationship.value.trim(),
      );
      final refined = await refineText(
        jev: _jev ??= JevClient(config.value, stats: stats),
        snapshot: snapshot,
        relationship: relationshipText,
        ctx: ctx,
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

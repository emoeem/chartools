import '../config/jev_config.dart';
import '../jev_client/api_exception.dart';
import '../jev_client/http_scope.dart';
import '../models/models.dart';
import '../persona_kb/kb_models.dart';
import '../persona_kb/style_source.dart';
import 'ai_flavor_linter.dart';
import 'intensity.dart';
import 'judge_client.dart';
import 'reply_cache_key.dart';
import 'reply_client.dart';
import 'reply_review.dart';
import 'usage_stats.dart';

/// Thin facade over the split clients so callers keep one entry point.
/// Construct with [JevConfig] — every route reads its own address / key / model
/// from there, so switching providers in settings takes effect on the next call.
class JevClient {
  /// [stats] 传 app 层 SettingsStore.usage 这一份实例（C9 接线契约，见
  /// usage_stats.dart）：打点方与设置页统计卡读写同一个对象。缺省 null =
  /// 完全不打点，现有调用方与测试零改动。
  ///
  /// [onTrace] 是 fix(#9 K-3) 的诊断留痕回调：管线里「行为保留但静默」的
  /// 降级路径经它留一行中文痕（目前只有 [rankOnly] 的排序资格守卫）。core
  /// 是纯 Dart 包，不自己打印——与 [UsageStats] 同款接线契约，app 层愿意
  /// 听就传一个回调，缺省 null = 零开销直通，现有调用方与测试零改动。
  JevClient(JevConfig config,
      {UsageStats? stats, void Function(String message)? onTrace})
      : _judgeClient = JudgeClient(config),
        _replyClient = ReplyClient(config),
        _config = config,
        _stats = stats,
        _trace = onTrace;

  final JevConfig _config;
  final JudgeClient _judgeClient;
  final ReplyClient _replyClient;

  /// 使用统计（C9）：null 时所有打点行是 `?.` 空操作，行为不变。
  final UsageStats? _stats;

  /// 诊断 trace（fix(#9 K-3)）：null 时 `?.` 空操作，行为不变。
  final void Function(String message)? _trace;

  /// 回复缓存：Dart 的 [LinkedHashMap] 只有插入序；命中时把键摘出重插到末尾，
  /// 等价 Kotlin LinkedHashMap 的 access-order=true，淘汰时删最旧的一条。
  final Map<String, List<RankedReply>> _cache = {};

  /// Judgments get their own small LRU. The judge is the slowest call of a round
  /// (it is a reasoning prompt), and the same conversation is re-judged whenever
  /// a round is re-started — "换一组" asks only for new candidates, but a repeat
  /// analysis of an unchanged chat asks the same seven questions again.
  final Map<String, Analysis> _judgeCache = {};

  List<RankedReply>? _cached(String key) {
    final hit = _cache.remove(key);
    if (hit == null) return null;
    _cache[key] = hit;
    return hit;
  }

  void _putCached(String key, List<RankedReply> value) {
    _cache.remove(key);
    // data class copy() 的对应物：缓存里放一份浅拷贝，调用方改动自己的
    // RankedReply 不会污染缓存里的候选。
    _cache[key] = [for (final r in value) r.copyWith()];
    while (_cache.length > _replyCacheSize) {
      _cache.remove(_cache.keys.first);
    }
  }

  Analysis? _cachedJudge(String key) {
    final hit = _judgeCache.remove(key);
    if (hit == null) return null;
    _judgeCache[key] = hit;
    return hit;
  }

  void _putCachedJudge(String key, Analysis value) {
    _judgeCache.remove(key);
    _judgeCache[key] = value;
    while (_judgeCache.length > _judgeCacheSize) {
      _judgeCache.remove(_judgeCache.keys.first);
    }
  }

  /// C9 打点包装：四条路由的真实调用统一从这里走 —— 发起前记一次调用，
  /// 异常（用户取消除外）补记一次失败后原样上抛，调用方已有的兜底分支
  /// （换候选、复查放弃、降权保留原文）行为不变。stats 为 null 时零开销
  /// 直通。打点只读写内存计数器，不碰提示词与请求体 —— 不改变任何请求字节。
  Future<T> _tracked<T>(UsageRoute route, Future<T> Function() call) async {
    final s = _stats;
    if (s == null) return call();
    s.recordCall(route);
    try {
      return await call();
    } on RequestCancelledException {
      rethrow;
    } catch (_) {
      s.recordFailure(route);
      rethrow;
    }
  }

  /// The 7 judgment questions. Errors come back inside [Analysis.error].
  ///
  /// Only successful judgments are cached: a cached transport error would make a
  /// one-off network blip stick to the conversation for the rest of the session,
  /// so a retry always goes back to the server.
  Future<Analysis> judge(
    ChatSnapshot snapshot,
    String relationship, {
    ChatContext? ctx,
    HttpScope? scope,
  }) async {
    final key = _judgeKey(snapshot, relationship, ctx);
    final hit = _cachedJudge(key);
    if (hit != null) {
      _stats?.recordCacheHit(UsageRoute.judge);
      return hit;
    }
    final a = await _tracked(
        UsageRoute.judge,
        () =>
            _judgeClient.judge(snapshot, relationship, ctx: ctx, scope: scope));
    // 判断路由的失败不是异常而是 Analysis.error（JudgeClient.judge 的既有
    // 语义：错误返回不抛出）—— 这里补记；异常路径的失败已由 _tracked 记过。
    if (a.error != null) _stats?.recordFailure(UsageRoute.judge);
    if (a.error == null) _putCachedJudge(key, a);
    return a;
  }

  /// Draft [count] candidates on the reply route, then rank them on the judge
  /// route. A single candidate has nothing to rank, so that round is skipped.
  /// [avoid] = replies already shown for this chat (the "换一组" request).
  /// [judgment] is the verdict already in hand; the drafter needs it to pick a
  /// register (see [ReplyPrompt.judgmentBlock]) and is not itself the ranking.
  ///
  /// [aiFlavorLintEnabled] 是 A2 的中文 AI 腔 linter 开关（默认开）：终榜之后
  /// 逐条检测，命中特征 ≥ [AiFlavorLinter.rewriteThreshold] 的候选自动走润色
  /// 路由重写（见 [_applyFlavorLint]）。经参数传入而不是读配置——
  /// 配置字段归 app 层与 JevConfig 的所有方接线，core 不反依赖 app。
  Future<List<RankedReply>> draftAndRank(
    ChatSnapshot snapshot,
    String relationship, {
    ChatContext? ctx,
    int count = 3,
    List<String> avoid = const [],
    Analysis? judgment,
    Intensity intensity = Intensity.auto,
    bool aiFlavorLintEnabled = true,
    HttpScope? scope,
  }) async {
    final key = _cacheKey(
        snapshot, relationship, ctx, count, avoid, judgment, intensity,
        aiFlavorLintEnabled: aiFlavorLintEnabled);
    final hit = _cached(key);
    if (hit != null) {
      _stats?.recordCacheHit(UsageRoute.reply);
      return hit;
    }

    final candidates = await _tracked(
      UsageRoute.reply,
      () => _replyClient.draft(
        snapshot,
        relationship,
        ctx: ctx,
        count: count,
        avoid: avoid,
        judgment: judgment,
        style: _config.style,
        intensity: intensity,
        scope: scope,
      ),
    );
    if (candidates.length <= 1) {
      // 单条候选没有「终榜」，A2 的挂接点（终榜后）在这里不存在：保持原行为，
      // 整组特征也无从谈起。
      final result = [
        for (final c in candidates) c.copyWith(prob: 1.0, ranked: false),
      ];
      _putCached(key, result);
      return result;
    }
    List<RankedReply> ranked;
    try {
      final scored = await _tracked(
        UsageRoute.judge,
        () => _judgeClient.rank(
          snapshot,
          relationship,
          [for (final c in candidates) c.text],
          ctx: ctx,
          scope: scope,
        ),
      );
      ranked = [
        for (var i = 0; i < scored.length; i++)
          scored[i].copyWith(
            strategy: i < candidates.length ? candidates[i].strategy : '',
            ranked: true,
          ),
      ];
    } on RequestCancelledException {
      rethrow;
    } catch (_) {
      ranked = [for (final c in candidates) c.copyWith(ranked: false)];
    }
    final result = await _applyReview(
        snapshot, relationship, ctx, judgment, ranked, scope);
    final polished = aiFlavorLintEnabled
        ? await _applyFlavorLint(snapshot, relationship, ctx, result, scope)
        : result;
    _putCached(key, polished);
    return polished;
  }

  /// 未排序的候选（轮内的"先判后写"路径和「再给 2 条」）。[intensity] 与
  /// [draftAndRank] 共享同一份档位语义，进同一份缓存键。
  ///
  /// [judgment] 是这一轮已经到手的判断结果：首轮起草现在等判断（见采集层的
  /// DraftTrigger），带着它写，模型才知道这一场是吵架、玩笑还是角色扮演；
  /// 判断路由超时才盲写（null）。
  Future<List<RankedReply>> draftOnly(
    ChatSnapshot snapshot,
    String relationship, {
    ChatContext? ctx,
    int count = 3,
    List<String> avoid = const [],
    Analysis? judgment,
    Intensity intensity = Intensity.auto,
    HttpScope? scope,
  }) =>
      _tracked(
        UsageRoute.reply,
        () => _replyClient.draftOnly(
          snapshot,
          relationship,
          ctx: ctx,
          count: count,
          avoid: avoid,
          judgment: judgment,
          style: _config.style,
          intensity: intensity,
          scope: scope,
        ),
      );

  /// S1 证据复查。默认关（[JevConfig.reviewEnabled]）：开着时让模型逐条核验排序
  /// 结果，把站不住的那几条走润色路由重写一次（见 [ReplyReview]）。
  ///
  /// 三道保险，任何一道不满足就原样返回 [ranked]：
  ///  1. 复查失败或不可解析 → [ReplyClient.review] 返回 null；
  ///  2. 复查判定全部保留 → 不动，不为「还能更好」白花一次调用；
  ///  3. 重写调用失败或重写结果为空 → 放弃替换。
  /// 也就是说复查只可能改好，不可能改坏，更不可能让候选变少。
  Future<List<RankedReply>> _applyReview(
    ChatSnapshot snapshot,
    String relationship,
    ChatContext? ctx,
    Analysis? judgment,
    List<RankedReply> ranked,
    HttpScope? scope,
  ) async {
    if (!_config.reviewEnabled || ranked.length <= 1) return ranked;
    final texts = [for (final r in ranked) r.text];
    ReviewResult? review;
    try {
      review = await _tracked(
        UsageRoute.review,
        () => _replyClient.review(
          relationship,
          convoLines(snapshot.messages),
          ctx,
          judgment,
          texts,
          scope: scope,
        ),
      );
    } on RequestCancelledException {
      rethrow;
    } catch (_) {
      return ranked;
    }
    if (review == null) {
      // 复查的 HTTP 异常已由 _tracked 记过失败；这里补记「响应成功但不可
      // 解析」（ReplyClient.review 返回 null）这一笔，调用数已由 _tracked 记过。
      _stats?.recordFailure(UsageRoute.review);
      return ranked;
    }

    final rejected = review.rejected;
    if (rejected.isEmpty) return ranked;
    // 重写走润色路由（A4）：复查已经给了理由，逐条把驳回的那条改写到位。
    // 旧版是一次批量 draft（avoid 里塞全部候选与驳回理由）；换成单条重写后，
    // 旧契约里「条数对不上 → 放弃替换」的分支在结构上消失——任何一条失败
    // 或为空就整轮放弃替换，「复查只可能改好」的语义原样保留。
    // 「被判定为」的理由进改写指令：重写要修的不只是那条原文，还有它错在哪。
    //
    // fix(kimi-review #20)：被拒候选的重写彼此独立、ReplyClient 无状态
    // （每次请求各自构造），Future.wait 并行发出——原先 3 条全拒 = 3 次串行
    // 润色往返。Future.wait 按输入顺序回收结果，下面的替换映射不受完成先后
    // 影响；其余 future 的迟到错误由 wait 吸收，不会变成未处理异常。并行化
    // 的固有代价：某一条先失败时其余请求已经发出（白跑一趟润色），但落点
    // 与串行版一致——整轮放弃替换，ranked 原样返回。
    List<RankedReply?> rewrites;
    try {
      rewrites = await Future.wait([
        for (final v in rejected)
          _tracked(
            UsageRoute.polish,
            () => _replyClient.rewriteOnPolishRoute(
              snapshot,
              relationship,
              texts[v.index - 1],
              '复查判定这条回复站不住：${v.reason}。'
              '按这个问题把它改写到位，保持原意、称呼与事实，'
              '不要复读最近对话里已经说过的内容。',
              ctx: ctx,
              style: _config.style,
              scope: scope,
            ),
          ),
      ]);
    } on RequestCancelledException {
      rethrow;
    } catch (_) {
      return ranked;
    }
    final replacements = <RankedReply>[];
    for (final r in rewrites) {
      if (r == null || r.text.trim().isEmpty) {
        // 同复查：异常失败已在 _tracked 记过，这里补记「拿到响应却没产出」。
        // 与串行版一致：记到第一处即整轮放弃，不把同一轮多记几笔。
        _stats?.recordFailure(UsageRoute.polish);
        return ranked;
      }
      replacements.add(r);
    }

    final atIndex = <int, RankedReply>{};
    for (var i = 0; i < rejected.length; i++) {
      atIndex[rejected[i].index] = replacements[i];
    }
    return [
      for (var i = 0; i < ranked.length; i++)
        if (atIndex[i + 1] == null)
          ranked[i].copyWith(
              reviewNote:
                  i < review.verdicts.length ? review.verdicts[i].reason : '')
        else
          atIndex[i + 1]!.copyWith(
            prob: ranked[i].prob,
            strategy: ranked[i].strategy,
            ranked: ranked[i].ranked,
            reviewNote:
                i < review.verdicts.length ? review.verdicts[i].reason : '',
          ),
    ];
  }

  /// A2 中文 AI 腔本地 linter 的挂接点：终榜（排序 + 证据复查）之后逐条检测，
  /// 命中特征 ≥ [AiFlavorLinter.rewriteThreshold] 的候选走润色路由重写
  /// （[ReplyClient.rewriteOnPolishRoute]，A4），指令 = 命中规则的人话描述
  /// （[AiFlavorLinter.refineInstruction]）。手动 refine（候选卡按钮）不经
  /// 这里，继续走回复路由的 [refineReply]。
  ///
  /// 三条与 [_applyReview] 同款的保险：
  ///  1. 单一特征不动手——一次误伤的 refine 是真金白银和延迟，两个独立特征
  ///     叠加才基本坐实「这条像 AI 写的」；
  ///  2. 重写失败或不可解析 → 保留原文，只把概率降 0.1（不降为 0：排序里还
  ///     看得见它，降权后用户优先看到的是没被动过的那几条）；
  ///  3. 重写只在原位替换文本，概率、策略、排序标记、复查备注全部保留，
  ///     绝不重排——与候选卡上手动 refine 的契约一致。
  Future<List<RankedReply>> _applyFlavorLint(
    ChatSnapshot snapshot,
    String relationship,
    ChatContext? ctx,
    List<RankedReply> ranked,
    HttpScope? scope,
  ) async {
    if (ranked.length <= 1) return ranked;
    final hits = AiFlavorLinter.lintGroup([for (final r in ranked) r.text]);
    // fix(kimi-review #20)：过门槛的候选并行重写（原先逐条 await，3 条全中
    // = 3 次串行润色往返）。改写彼此独立、ReplyClient 无状态，可直接并行；
    // Future.wait 按输入顺序回收，下面的组装顺序与串行版一致。
    final flagged = <int>[];
    for (var i = 0; i < ranked.length; i++) {
      if (hits[i].length >= AiFlavorLinter.rewriteThreshold) flagged.add(i);
    }
    if (flagged.isEmpty) return ranked;

    // 逐条隔离非取消异常：某一条的重写失败只影响那一条（保留原文并降权
    // 0.1），其余候选照常换上重写结果——与串行版逐条 try/catch 的语义一致；
    // RequestCancelledException 原样上抛，整轮作废。
    Future<RankedReply?> rewriteOne(int i) async {
      try {
        return await _tracked(
          UsageRoute.polish,
          () => _replyClient.rewriteOnPolishRoute(
            snapshot,
            relationship,
            ranked[i].text,
            AiFlavorLinter.refineInstruction(hits[i]),
            ctx: ctx,
            style: _config.style,
            scope: scope,
          ),
        );
      } on RequestCancelledException {
        rethrow;
      } catch (_) {
        return null;
      }
    }

    List<RankedReply?> rewrites;
    try {
      rewrites = await Future.wait([for (final i in flagged) rewriteOne(i)]);
    } on RequestCancelledException {
      rethrow;
    } catch (_) {
      // rewriteOne 已隔离非取消异常，此处理论不可达；真发生时按全部失败
      // 处理，不让异常冒出 draftAndRank——与串行版「lint 失败不外泄」一致。
      rewrites = List<RankedReply?>.filled(flagged.length, null);
    }

    final out = <RankedReply>[];
    for (var i = 0; i < ranked.length; i++) {
      final k = flagged.indexOf(i);
      if (k < 0) {
        out.add(ranked[i]);
        continue;
      }
      final rewritten = rewrites[k];
      if (rewritten == null || rewritten.text.trim().isEmpty) {
        // 失败保留原文并降权 0.1；概率不为负（负数会画出负长度的概率条）。
        // 这里不补记失败：rewriteOne 的 catch 把结果置 null 后与「成功但空
        // 解析」已无法区分，异常失败由 _tracked 记过，再记会把同一笔双计。
        final lowered = ranked[i].prob - 0.1;
        out.add(ranked[i].copyWith(prob: lowered < 0.0 ? 0.0 : lowered));
      } else {
        out.add(rewritten.copyWith(
          prob: ranked[i].prob,
          strategy: ranked[i].strategy,
          ranked: ranked[i].ranked,
          reviewNote: ranked[i].reviewNote,
        ));
      }
    }
    return out;
  }

  /// 候选卡上的手动改写（p0-plan ④ 的 refine UI）：走回复路由的
  /// [ReplyClient.refine]。与自动重写（linter 命中、复查驳回）走润色路由的
  /// [ReplyClient.rewriteOnPolishRoute] 是两条路——用户点名的精修和后台的
  /// 自动整改分开。
  Future<RankedReply?> refineReply(
    ChatSnapshot snapshot,
    String relationship,
    ChatContext? ctx,
    String original,
    String instruction, {
    HttpScope? scope,
  }) =>
      _tracked(
        UsageRoute.reply,
        () => _replyClient.refine(
          snapshot,
          relationship,
          original,
          instruction,
          ctx: ctx,
          style: _config.style,
          scope: scope,
        ),
      );

  /// The opt-in streaming draft: same candidates as [draftOnly] (unranked), but
  /// [onVisible] receives the readable text as it arrives so the card can fill in
  /// while the model is still writing. Deliberately outside the LRU — a cached
  /// answer would defeat the point of watching it stream — and the caller keeps
  /// [draftOnly] as the fallback when a server does not speak SSE.
  ///
  /// [judgment] 同 [draftOnly]：判断先行时的流式轮也带着判断写。
  Future<List<RankedReply>> draftStream(
    ChatSnapshot snapshot,
    String relationship, {
    ChatContext? ctx,
    int count = 3,
    List<String> avoid = const [],
    Analysis? judgment,
    Intensity intensity = Intensity.auto,
    required void Function(String) onVisible,
    HttpScope? scope,
  }) async {
    final out = await _tracked(
      UsageRoute.reply,
      () => _replyClient.draftStream(
        snapshot,
        relationship,
        ctx: ctx,
        count: count,
        avoid: avoid,
        judgment: judgment,
        style: _config.style,
        intensity: intensity,
        onVisible: onVisible,
        scope: scope,
      ),
    );
    return [for (final r in out) r.copyWith(ranked: false, prob: 0.0)];
  }

  /// 只排序、不起草：把外部（如流式路径）攒出的候选交给判断路由排出
  /// best-first 顺序。候选不是 3 条时不抛异常，显式按 ranked:false 原样
  /// 返回并经 [_trace] 留痕（fix(#9 K-3)）。
  ///
  /// fix(#9 K-3)：守卫里的 3 不是「调用方的 count 契约」——count 是可配
  /// 参数（本文件三个起草入口的默认值，起草侧另有 clamp(1,3)），而这里是
  /// **排序协议的固定槽位数**：JevQuestions.rankQuestion 只构造 reply_a/b/c
  /// 三个键、非 3 条会抛 ArgumentError（jev_questions.dart 的守卫）。把
  /// 这两处并成同一个「条数常量」会把可配条数焊死在协议槽位上，将来任一
  /// 侧单独调整就会误导；且真正的协议守卫在 jev_questions.dart，本文件
  /// 够不着。所以选「保留行为但可见」：资格判定保持 3 = 协议槽位数并写明
  /// 依据，不符时显式 ranked:false + trace 留痕，不再静默退化。
  Future<List<RankedReply>> rankOnly(
    ChatSnapshot snapshot,
    String relationship,
    ChatContext? ctx,
    List<RankedReply> candidates, {
    HttpScope? scope,
  }) async {
    if (candidates.length != 3) {
      _trace?.call(
          'rankOnly：候选 ${candidates.length} 条 ≠ 排序协议固定 3 条'
          '（reply_a/b/c），本轮不排序，按 ranked:false 原样返回。');
      return [for (final c in candidates) c.copyWith(ranked: false, prob: 0.0)];
    }
    final scored = await _tracked(
      UsageRoute.judge,
      () => _judgeClient.rank(
        snapshot,
        relationship,
        [for (final c in candidates) c.text],
        ctx: ctx,
        scope: scope,
      ),
    );
    return [
      for (var i = 0; i < scored.length; i++)
        scored[i].copyWith(
          strategy: i < candidates.length ? candidates[i].strategy : '',
          ranked: true,
        ),
    ];
  }

  /// Everything the judge prompt is built from. Same shape as the reply key minus
  /// the reply-only inputs (count, avoid, style, params, ledger) plus the judge
  /// route's own model and protocol, so switching either provider invalidates it.
  String _judgeKey(
          ChatSnapshot snapshot, String relationship, ChatContext? ctx) =>
      ReplyCacheKey.judge(
        title: snapshot.title ?? '',
        signature: snapshot.signature(),
        relationship: relationship,
        judgeModel: _config.judgeModel,
        judgeProtocol: _config.effectiveJudgeProtocol(),
        ctxKey: _judgeCtxKey(ctx, relationship),
      );

  String _cacheKey(
    ChatSnapshot snapshot,
    String relationship,
    ChatContext? ctx,
    int count,
    List<String> avoid,
    Analysis? judgment,
    Intensity intensity, {
    bool aiFlavorLintEnabled = true,
  }) {
    // 键里的 style 必须是**真正进提示词**的那段：联系人写了专用人设时它压过
    // 全局 style，只锁全局 style 的话，改联系人专用人设会同键命中旧人设的
    // 候选（和专家库那次是同一类静默等价）。
    final effectiveStyle =
        StyleSource.resolve(_config.style, ctx?.contact?.persona).text;
    final ctxKey = _replyCtxKey(ctx, relationship);
    // 台账进的是回复提示词，不进 Jev 的 state，所以它只进回复缓存键：
    // 台账一重建，上一轮的候选就必须作废。
    final ledgerKey = ctx?.ledger?.render() ?? '';
    // 置信度驱动低置信度降级块，shouldReplyNow 驱动「可不急回」附加行——
    // 两个都改提示词，漏了就是判断变了、候选没变。
    final judgmentKey = _judgmentKey(judgment);
    // A2 的 linter 开关也在 params 里：它决定终榜后要不要改写候选。漏了的话，
    // 关掉 linter 的一次调用会命中开着时缓存的改写结果（与 reviewEnabled 同理）。
    return ReplyCacheKey.reply(
      title: snapshot.title ?? '',
      signature: snapshot.signature(),
      relationship: relationship,
      style: effectiveStyle,
      replyModel: _config.replyModel,
      count: count,
      avoid: avoid,
      ctxKey: ctxKey,
      ledgerKey: ledgerKey,
      judgmentKey: judgmentKey,
      intensity: intensity.name,
      params: '${_replyParams()}|lint:$aiFlavorLintEnabled',
    );
  }

  /// 上一轮判断里会改提示词的字段（Kotlin 侧是六个可空值 joinToString("|")，
  /// null 打印成 "null"——键是内部值，不是面向模型的文案）。
  String _judgmentKey(Analysis? judgment) {
    if (judgment == null) return '';
    final parts = <String?>[
      judgment.trueIntent?.choice,
      judgment.trueIntent?.confidence.toString(),
      judgment.dangerLevel?.score.toString(),
      judgment.sheNeeds?.choice,
      judgment.bestAction?.choice,
      judgment.shouldReplyNow.toString(),
    ];
    return [for (final p in parts) p ?? 'null'].join('|');
  }

  /// 采样与开关打包成一个分量：语言 / 长度 / 温度 / 两个惩罚 / 证据复查 + 模型
  /// / 润色模型。润色模型进键与复查同理——终榜后的自动重写（linter 命中、
  /// 复查驳回）走润色路由，换了润色模型，缓存里的改写结果就得作废。
  String _replyParams() => [
        _config.replyLanguage,
        _config.replyLength,
        _config.replyTemperature.toString(),
        _config.replyFrequencyPenalty.toString(),
        _config.replyPresencePenalty.toString(),
        _config.reviewEnabled.toString(),
        _config.effectiveReviewModel(),
        _config.effectivePolishModel(),
      ].join('|');

  /// 判断侧读的上下文：background + history + skills。风格样本与 L1 技能目录是
  /// 写给写手的（见 [_replyCtxKey]），判断侧刻意不看——不进判断键，免得换个
  /// 技能目录就把判断缓存全作废。
  String _judgeCtxKey(ChatContext? ctx, String relationship) =>
      ctx == null ? '' : _ctxKeyBase(ctx, relationship);

  /// 回复侧的上下文 = 判断侧那三样 + 风格样本笔记（`knowledgeBlock` 逐条引用）
  /// + 技能 L1 目录（`skillNote` 永远骑在 user prompt 最前面）。后两样谁都进
  /// 提示词，谁就得进键。
  ///
  /// G7 偏好附言（[noteTypePreferenceAddendum] 笔记）同理由 reply_prompt 渲染
  /// 进写作提示词，故也进键——用户在偏好面板删除/记录后，下一轮起草立即换键。
  /// 段位挂在键尾且无附言时整段缺席：没有偏好记录的请求，键与接入前逐字节
  /// 一致（既有缓存与兼容测试不动）。判断侧不经这里：background() 对该 type
  /// 刻意跳过，判断键与判断提示词都不含附言。
  String _replyCtxKey(ChatContext? ctx, String relationship) {
    if (ctx == null) return '';
    final styleSamples = [
      for (final n in ctx.notes)
        if (n.type == noteTypeStyleSample) '${n.id}:${n.content}',
    ].join('|');
    final preference = [
      for (final n in ctx.notes)
        if (n.type == noteTypePreferenceAddendum) '${n.id}:${n.content}',
    ].join('|');
    final preferenceKey = preference.isEmpty ? '' : '|$preference';
    return '${_ctxKeyBase(ctx, relationship)}'
        '|$styleSamples|${ctx.catalogue}$preferenceKey';
  }

  String _ctxKeyBase(ChatContext ctx, String relationship) =>
      '${ctx.background(relationship)}|'
      '${[for (final h in ctx.history) '${h.side}:${h.text}'].join('|')}|'
      '${[for (final s in ctx.skills) '${s.name}:${s.body}'].join('|')}';

  /// Judge + replies, sequential. Used by the settings connectivity test.
  Future<Analysis> analyze(ChatSnapshot snapshot, String relationship,
      {ChatContext? ctx}) async {
    final a = await judge(snapshot, relationship, ctx: ctx);
    if (a.error != null) return a;
    List<RankedReply> ranked;
    try {
      ranked = await draftAndRank(snapshot, relationship, ctx: ctx);
    } on RequestCancelledException {
      rethrow;
    } catch (_) {
      ranked = const [];
    }
    return a.copyWith(rankedReplies: ranked);
  }
}

/// 回复缓存的容量上限（旧仓库 CACHE_SIZE = 50）。
const int _replyCacheSize = 50;

/// 判断缓存的容量上限（旧仓库 JevClient.kt 的 CACHE_SIZE = 50；那里
/// LinkedHashMap 构造参数里的 16 只是**初始容量**，淘汰判据是
/// removeEldestEntry 里的 size > CACHE_SIZE —— 与回复缓存同一条上限）。
const int _judgeCacheSize = 50;

import '../config/jev_config.dart';
import '../jev_client/api_exception.dart';
import '../jev_client/chat_judge.dart';
import '../jev_client/http_json.dart';
import '../jev_client/http_scope.dart';
import '../jev_client/judge_answers.dart';
import '../jev_client/judge_retry.dart';
import '../jev_client/jsonx.dart';
import '../jev_client/jev_questions.dart';
import '../jev_client/routes.dart';
import '../models/models.dart';
import '../persona_kb/kb_models.dart';

/// The Jev judgment route only: the 7 judgment questions in one call, and the
/// ranking question over already-drafted candidates. Reads judgeProvider /
/// judgeBaseUrl / judgeKey / judgeModel from [JevConfig]; nothing generative
/// here.
///
/// Two protocols share this route, chosen by [JevConfig.effectiveJudgeProtocol]:
/// the native Jev/TypeSafe `decisions` protocol ([_sendDecisions]) and an
/// OpenAI-compatible chat turn over the same question set ([_sendChat], see
/// [ChatJudge]) for hosts that serve no judgment model — DeepSeek official.
/// Everything downstream of `answers` is identical for both.
///
/// P0 判断降级（判断路由默认关闭 + 优雅降级）的防线在本类：路由未配置
/// （[JevConfig.judgeRouteConfigured] == false，判据唯一）时 [judge] 不发
/// 网络请求、合成无错误的空判断对象，[rank] 原序返回——采集会话的主路径
/// 在 app 层还有一道同判据的门（跳过 judge 调用本身，连打点都不记），
/// 本类这道门兜住所有其它调用方（桌面助手页、连通性 analyze），让「判断
/// 没配」在任何入口都不再拦起草。
class JudgeClient {
  JudgeClient(this._config);

  final JevConfig _config;

  /// 判断结果进起草路的准入判定（P0 降级的「判断不可用」语义，唯一实现）：
  /// - null / 带 [Analysis.error]（判断调用失败）→ null——起草按「盲写」
  ///   处理（judgmentBlock(null) 为空串，提示词与无判断轮逐字节一致）；
  /// - 全字段皆空的判断（未配置合成的空对象、chat 协议答案全缺）→ null——
  ///   若把空对象塞给起草，judgmentBlock 会产出「判断结果（先按它读局势…）
  ///   看不出×3」的噪声块：头部命令「按它读局势」、内容却是「看不出」，
  ///   正是 P0 裁定要避免的「空判断引入奇怪文案」。盲写不给提示词塞任何
  ///   判断噪声。
  /// - 有任一判断信号（五个进提示词/排序的字段任一非空）→ 原样返回。
  ///
  /// 采集会话（capture_session）与桌面助手页共用这一个静态方法，保证两端
  /// 「判断不可用 → 盲写」的口径一致；「换一组」也经它过滤缓存卡上的
  /// 降级判断，两轮提示词同构。
  static Analysis? usableJudgment(Analysis? judgment) {
    if (judgment == null || judgment.error != null) return null;
    final hasSignal = judgment.trueIntent != null ||
        judgment.dangerLevel != null ||
        judgment.sheNeeds != null ||
        judgment.bestAction != null ||
        judgment.shouldReplyNow != null;
    return hasSignal ? judgment : null;
  }

  /// The 7 judgment questions (fast, ~1s). Errors are returned, not thrown —
  /// 取消除外：一轮被放弃时取消要一路传出去，不能被装成一次失败的判断。
  ///
  /// P0 判断降级：路由未配置（judgeBaseUrl 空 + 非 chat 协议的典型落点）
  /// 时不发任何网络请求，返回**无错误**的空判断对象（全字段 null、无
  /// best_action）——调用方照常起草，候选不再因判断问题恒空。latencyMs
  /// 记真实耗时（本地合成 ≈0），不用它冒充网络往返。
  ///
  /// @param ctx D-stage knowledge context; null or empty means the request body
  ///        is byte-for-byte what v1.2 sent.
  /// @param scope when given, the request is registered there so an abandoned
  ///        round can close its socket instead of waiting out the read timeout.
  Future<Analysis> judge(
    ChatSnapshot snapshot,
    String relationship, {
    ChatContext? ctx,
    HttpScope? scope,
  }) async {
    final start = DateTime.now().millisecondsSinceEpoch;
    if (!_config.judgeRouteConfigured()) {
      return Analysis(
        rankedReplies: const [],
        latencyMs: DateTime.now().millisecondsSinceEpoch - start,
      );
    }
    try {
      final answers = await _postJudge(
          snapshot, relationship, ctx, JevQuestions.judge(), scope);
      return Analysis(
        trueIntent: JudgeAnswers.choice(optMap(answers, 'true_intent')),
        dangerLevel: JudgeAnswers.score(optMap(answers, 'danger_level')),
        sheNeeds: JudgeAnswers.choice(optMap(answers, 'she_needs')),
        shouldReplyNow: _optNoul(answers, 'should_reply_now'),
        bestAction: JudgeAnswers.choice(optMap(answers, 'best_action')),
        tensionResolved: _optNoul(answers, 'tension_resolved'),
        literalQuestion: _optNoul(answers, 'literal_question'),
        rankedReplies: const [],
        latencyMs: DateTime.now().millisecondsSinceEpoch - start,
      );
    } on RequestCancelledException {
      rethrow;
    } catch (e) {
      final msg = e.toString().trim();
      return Analysis(
        latencyMs: DateTime.now().millisecondsSinceEpoch - start,
        error: msg.isEmpty ? '判断接口请求失败' : msg,
      );
    }
  }

  /// Ask Jev which of the candidate replies is best; throws on failure.
  ///
  /// P0 判断降级：路由未配置时不发请求，按输入顺序原样返回（prob 0.0 = 没有
  /// 排序信息，ranked:false 标记同样如实）。不走「抛 ApiException」——那会
  /// 被调用方的 catch 兜成同样的原序，却先白吃三次重试 + 每轮记一笔判断
  /// 失败（统计卡随之长刺）；门口直返零成本。prob 刻意 0.0 不匀摊：没有
  /// 排序就没有概率，编一个均匀分布是假数据。
  Future<List<RankedReply>> rank(
    ChatSnapshot snapshot,
    String relationship,
    List<String> candidates, {
    ChatContext? ctx,
    HttpScope? scope,
  }) async {
    if (!_config.judgeRouteConfigured()) {
      return [
        for (final c in candidates)
          RankedReply(text: c, prob: 0.0, ranked: false),
      ];
    }
    final q = JevQuestions.rankQuestion(candidates);
    final questions = <String, dynamic>{'best_reply': q['best_reply']};
    final answers =
        await _postJudge(snapshot, relationship, ctx, questions, scope);
    return JudgeAnswers.ranked(optMap(answers, 'best_reply'), candidates);
  }

  /// POST one judgment request in whichever protocol the route speaks, with the
  /// knowledge fields when there are any.
  ///
  /// Defensive retry: whether the live `alpha/decisions` endpoint accepts the
  /// new `background` / `history` state fields or rejects unknown ones with a
  /// 4xx is not verified against production yet (see the A-stage report). If a
  /// request carrying them comes back 4xx, it is sent again once without them,
  /// so an unverified field can degrade the analysis but never break it.
  Future<Map<String, dynamic>> _postJudge(
    ChatSnapshot snapshot,
    String relationship,
    ChatContext? ctx,
    Map<String, dynamic> questions,
    HttpScope? scope,
  ) async {
    final background = ctx?.background(relationship) ?? '';
    final history = [
      for (final h in ctx?.history ?? const <LogEntry>[])
        (side: h.side, text: h.text),
    ];
    final enriched = background.trim().isNotEmpty || history.isNotEmpty;
    try {
      return await _send(
        JevQuestions.buildState(
          snapshot,
          relationship,
          background: background,
          history: history,
        ),
        questions,
        scope,
      );
    } on ApiException catch (e) {
      if (enriched && JudgeRetry.shouldDropEnrichment(e.status)) {
        return await _send(
          JevQuestions.buildState(snapshot, relationship),
          questions,
          scope,
        );
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _send(
    Map<String, dynamic> state,
    Map<String, dynamic> questions,
    HttpScope? scope,
  ) {
    // 与旧仓库 Prefs.PROTO_CHAT 对齐：协议值就是 'chat' / 'decisions' 字面量。
    if (_config.effectiveJudgeProtocol() == 'chat') {
      return _sendChat(state, questions, scope);
    }
    return _sendDecisions(state, questions, scope);
  }

  /// Jev/TypeSafe `decisions`: one POST, `answers` straight back.
  ///
  /// P0 判断降级接线：密钥/模型改走 [JevConfig.effectiveJudgeKey] /
  /// [JevConfig.effectiveJudgeModel]——非跟随档两者与 judgeKey/judgeModel
  /// 逐字节相等（推导原样返回），请求体与接入前一致；「跟随回复路由」档
  /// 在这里拿到回复路由的 key 与模型。
  Future<Map<String, dynamic>> _sendDecisions(
    Map<String, dynamic> state,
    Map<String, dynamic> questions,
    HttpScope? scope,
  ) async {
    final url = _config.judgeEndpoint();
    final body = <String, dynamic>{
      'model': _config.effectiveJudgeModel(),
      'state': state,
      'questions': questions,
    };
    final resp = await HttpJson.post(
      url,
      _config.effectiveJudgeKey(),
      body,
      Route.judge,
      extraHeaders: HttpJson.headersFor(url),
      scope: scope,
    );
    return optMap(resp, 'answers') ?? const {};
  }

  /// OpenAI-compatible chat: the question set is rendered into a prompt and the
  /// reply normalized back into the decisions answer shape (see [ChatJudge]).
  ///
  /// `response_format: json_object` is what keeps a chat model from wrapping its
  /// answer in prose, but not every OpenAI-compatible host accepts the field. A
  /// 400/422 body-shape rejection is therefore retried once without it instead
  /// of failing the whole analysis; an auth or server error is not retried.
  ///
  /// 密钥/模型同 [_sendDecisions]：effectiveJudgeKey / effectiveJudgeModel，
  /// 非跟随档请求字节不变，跟随档拿到回复路由的 key 与模型。
  Future<Map<String, dynamic>> _sendChat(
    Map<String, dynamic> state,
    Map<String, dynamic> questions,
    HttpScope? scope,
  ) async {
    final url = _config.judgeEndpoint();
    // 不能声明成 final 再在 try 和 catch 里各赋一次：流分析把 catch 里的变量
    // 视为「可能已赋值」（try 里赋值之后才抛异常的情形），final 会报错。
    Map<String, dynamic> resp;
    try {
      resp = await HttpJson.post(
        url,
        _config.effectiveJudgeKey(),
        ChatJudge.body(_config.effectiveJudgeModel(), state, questions,
            jsonMode: true),
        Route.judge,
        extraHeaders: HttpJson.headersFor(url),
        scope: scope,
      );
    } on ApiException catch (e) {
      if (shouldRetryWithoutJsonMode(e.status)) {
        resp = await HttpJson.post(
          url,
          _config.effectiveJudgeKey(),
          ChatJudge.body(_config.effectiveJudgeModel(), state, questions,
              jsonMode: false),
          Route.judge,
          extraHeaders: HttpJson.headersFor(url),
          scope: scope,
        );
      } else {
        rethrow;
      }
    }
    final content = ChatJudge.contentOf(resp);
    if (content.isEmpty) throw emptyChatContentException();
    return ChatJudge.answersFrom(content, questions);
  }

  /// `optJSONObject(key)?.optDouble("noul")` 的对应读取：整题缺失返回 null。
  /// 题目在而 noul 缺失时 org.json 会给 NaN；移植层把「没说」统一读成 null
  /// （下游只做 `< 0.5` 比较，NaN 与 null 的行为本来就相同）。
  static double? _optNoul(Map<String, dynamic> answers, String key) {
    final o = optMap(answers, key);
    if (o == null) return null;
    if (o['noul'] == null) return null;
    return optDouble(o, 'noul');
  }
}

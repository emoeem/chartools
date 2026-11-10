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
class JudgeClient {
  JudgeClient(this._config);

  final JevConfig _config;

  /// The 7 judgment questions (fast, ~1s). Errors are returned, not thrown —
  /// 取消除外：一轮被放弃时取消要一路传出去，不能被装成一次失败的判断。
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
  Future<List<RankedReply>> rank(
    ChatSnapshot snapshot,
    String relationship,
    List<String> candidates, {
    ChatContext? ctx,
    HttpScope? scope,
  }) async {
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
  Future<Map<String, dynamic>> _sendDecisions(
    Map<String, dynamic> state,
    Map<String, dynamic> questions,
    HttpScope? scope,
  ) async {
    final url = _config.judgeEndpoint();
    final body = <String, dynamic>{
      'model': _config.judgeModel,
      'state': state,
      'questions': questions,
    };
    final resp = await HttpJson.post(
      url,
      _config.judgeKey,
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
        _config.judgeKey,
        ChatJudge.body(_config.judgeModel, state, questions, jsonMode: true),
        Route.judge,
        extraHeaders: HttpJson.headersFor(url),
        scope: scope,
      );
    } on ApiException catch (e) {
      if (shouldRetryWithoutJsonMode(e.status)) {
        resp = await HttpJson.post(
          url,
          _config.judgeKey,
          ChatJudge.body(_config.judgeModel, state, questions, jsonMode: false),
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

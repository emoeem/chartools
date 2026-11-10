import '../config/jev_config.dart';
import '../jev_client/api_exception.dart';
import '../jev_client/http_json.dart';
import '../jev_client/http_scope.dart';
import '../jev_client/jsonx.dart';
import '../jev_client/routes.dart';
import '../jev_client/stream_text.dart';
import '../models/models.dart';
import '../persona_kb/domain_brief.dart';
import '../persona_kb/kb_models.dart';
import '../persona_kb/ledger.dart';
import '../persona_kb/persona_card.dart';
import '../persona_kb/style_source.dart';
import '../safety/safety_gate.dart';
import 'intensity.dart';
import 'reply_prompt.dart';
import 'reply_review.dart';

/// The generative route: any OpenAI-compatible `/chat/completions` endpoint.
/// Drafts the 3 candidate replies, and (D stage) summarizes text. Reads
/// replyBaseUrl / replyKey / replyModel from [JevConfig].
class ReplyClient {
  ReplyClient(this._config);

  final JevConfig _config;

  /// [count] varied candidate replies (1..3), in the language of the other
  /// person's latest message (English chats get English replies). [avoid] holds
  /// replies already shown for this chat ("换一组"), which the model must not repeat.
  ///
  /// @param ctx D-stage knowledge context. When present its background and
  ///        history are prepended to the prompt with an instruction to stay
  ///        consistent with them and invent nothing beyond them.
  /// @param judgment the judge round's verdict, when it is already known. The
  ///        drafter then writes for the actual situation instead of guessing
  ///        one — without it a fresh draft has no idea whether the thread is a
  ///        fight, a joke or flirting.
  /// @param style the user's own tone/persona note.
  /// @param scope when given, the request is registered there so an abandoned
  ///        round closes its socket instead of waiting out the read timeout.
  Future<List<RankedReply>> draft(
    ChatSnapshot snapshot,
    String relationship, {
    ChatContext? ctx,
    int count = 3,
    List<String> avoid = const [],
    Analysis? judgment,
    String style = '',
    Intensity intensity = Intensity.auto,
    HttpScope? scope,
  }) async {
    final ask = _draftAsk(
        snapshot, relationship, ctx, count, avoid, judgment, style, intensity);
    final content = await _chat(
      ask.system,
      ask.user,
      ask.temperature,
      scope: scope,
      frequencyPenalty: ask.frequencyPenalty,
      presencePenalty: ask.presencePenalty,
    );
    return _parseN(content, ask.count);
  }

  /// Streaming variant of [draft] (opt-in; the caller decides whether the switch
  /// is on). Same request with `stream=true`, and [onVisible] is handed the
  /// *readable* text each time it grows — [StreamText] hides the JSON envelope and
  /// the prompt's own array format. Returns exactly what [draft] returns, so the
  /// finished stream feeds the same ranking path as a buffered reply.
  ///
  /// No retry: a half-delivered stream that restarts would repeat itself. The
  /// caller falls back to [draft] when this throws.
  Future<List<RankedReply>> draftStream(
    ChatSnapshot snapshot,
    String relationship, {
    ChatContext? ctx,
    int count = 3,
    List<String> avoid = const [],
    Analysis? judgment,
    String style = '',
    Intensity intensity = Intensity.auto,
    required void Function(String) onVisible,
    HttpScope? scope,
  }) async {
    final ask = _draftAsk(
        snapshot, relationship, ctx, count, avoid, judgment, style, intensity);
    final url = _config.replyEndpoint();
    final raw = StringBuffer();
    var lastShown = '';
    await HttpJson.stream(
      url,
      _config.effectiveReplyKey(),
      _chatBody(
        ask.system,
        ask.user,
        ask.temperature,
        true,
        frequencyPenalty: ask.frequencyPenalty,
        presencePenalty: ask.presencePenalty,
      ),
      Route.reply,
      extraHeaders: HttpJson.headersFor(url),
      scope: scope,
      onData: (payload) {
        final fragment = StreamText.delta(payload);
        if (fragment == null) return;
        raw.write(fragment);
        final visible = StreamText.visible(raw.toString());
        if (visible != lastShown) {
          lastShown = visible;
          onVisible(visible);
        }
      },
    );
    if (raw.isEmpty) throw ApiException(Route.reply, null, '流式响应没有内容');
    return _parseN(raw.toString(), ask.count);
  }

  /// Draft candidates without waiting for Jev judgment.
  Future<List<RankedReply>> draftOnly(
    ChatSnapshot snapshot,
    String relationship, {
    ChatContext? ctx,
    int count = 3,
    List<String> avoid = const [],
    Analysis? judgment,
    String style = '',
    Intensity intensity = Intensity.auto,
    HttpScope? scope,
  }) async {
    final out = await draft(
      snapshot,
      relationship,
      ctx: ctx,
      count: count,
      avoid: avoid,
      judgment: judgment,
      style: style,
      intensity: intensity,
      scope: scope,
    );
    return [
      for (final r in out) r.copyWith(ranked: false, prob: 0.0),
    ];
  }

  /// Refine exactly one visible candidate; never regenerates the whole set.
  Future<RankedReply?> refine(
    ChatSnapshot snapshot,
    String relationship,
    String original,
    String instruction, {
    ChatContext? ctx,
    String style = '',
    HttpScope? scope,
  }) async {
    final convo = convoLines(snapshot.messages);
    final system = '你是即时通讯回复改写助手。只输出一个 JSON 数组，且只能有一个对象：'
        '{"strategy":"safe","text":"..."}。'
        '保持原意和事实，不补造记忆，不解释，不加引号。';
    final user = refineUserPrompt(
      relationship,
      ctx,
      _config.contextHistoryCount,
      style,
      instruction,
      original,
      convo,
    );
    final out = await _chat(
      system,
      user,
      0.65,
      scope: scope,
      frequencyPenalty: _config.replyFrequencyPenalty,
      presencePenalty: _config.replyPresencePenalty,
    );
    final parsed = _parseN(out, 1);
    if (parsed.isEmpty) return null;
    return parsed.first.copyWith(ranked: false, prob: 0.0);
  }

  /// One plain chat round trip for the settings connectivity test. Deliberately
  /// NOT [summarize]: the test should exercise the ordinary path, not whatever
  /// the summary prompt happens to be.
  Future<String> ping() async =>
      (await _chat('你是连通性测试助手，只按要求回答，不要解释。', '请只回复两个字：收到', 0.0)).trim();

  /// Condense a block of text (used by the D-stage contact auto-summary).
  Future<String> summarize(String text) async {
    if (text.trim().isEmpty) return '';
    const sys = '你是中文摘要助手。把给到的聊天记录压缩成不超过 120 字的第三人称要点摘要，'
        '只保留事实、偏好、承诺和待办，不要评论，不要编造。直接输出摘要正文。';
    return (await _chat(sys, text, 0.2)).trim();
  }

  /// 领域卡预扫：把知识库的均衡采样压成一段设定卡。走生成侧路由（和
  /// [summarize] 同一个 key / endpoint / model），因为它是生成任务。
  ///
  /// 温度 0.3：这活是归纳不是创作，但 0.0 会让它把采样里那段话原样抄回来。
  /// 失败一律抛出去 —— 调用方负责说人话地报错，绝不能把一段半成品写进知识库。
  Future<String> domainBrief(String topic, String sample,
      {HttpScope? scope}) async {
    if (sample.trim().isEmpty) return '';
    return (await _chat(
      DomainBrief.system,
      DomainBrief.user(topic, sample),
      0.3,
      scope: scope,
    ))
        .trim();
  }

  /// S1 台账构建：把 [transcript] 这一段记录整理进 [previous] 之后的台账。
  ///
  /// 走生成侧路由（和 [summarize] 同一个 key / endpoint / model）：它是生成任务，
  /// 不是判断任务，放判断路由上会把 Jev 的题集协议和这段自然语言混在一起。
  /// 失败一律抛出去，由构建 [ChatContext] 的一侧兜住并保留旧台账 ——
  /// 台账永远不能让这一轮分析失败。
  Future<Ledger?> rebuildLedger(
    Ledger? previous,
    String transcript,
    int coveredUntil,
  ) async {
    if (transcript.trim().isEmpty) return null;
    final raw = await _chat(
      LedgerPrompt.system(),
      LedgerPrompt.user(previous?.encode(), transcript),
      0.2,
    );
    return Ledger.parse(raw, coveredUntil, DateTime.now().millisecondsSinceEpoch);
  }

  /// S1 证据复查：逐条核验候选，见 [ReplyReview]。走**复查路由**
  /// ([JevConfig.reviewEndpoint] / [JevConfig.effectiveReviewKey] /
  /// [JevConfig.effectiveReviewModel])，三个字段都留空时它就是回复路由 —— 这是
  /// wenyi 的 per-operation 模型路由，但没有默认的配置负担。
  ///
  /// 返回 null 表示「没有复查」：网络失败、返回不可解析，都算，调用方保持排序结果不动。
  Future<ReviewResult?> review(
    String relationship,
    String convo,
    ChatContext? ctx,
    Analysis? judgment,
    List<String> candidates, {
    HttpScope? scope,
  }) async {
    if (candidates.isEmpty) return null;
    // 复查必须拿到和起草**同一张**人设卡：第 3、5 条标准是「有没有和已知的
    // 称呼/边界冲突」，不给它卡，这两条就只能退化成「读着像不像」。
    final rawStyle =
        StyleSource.resolve(_config.style, ctx?.contact?.persona).text;
    final card = PersonaCard.parse(rawStyle);
    final raw = await _chatOn(
      _config.reviewEndpoint(),
      _config.effectiveReviewKey(),
      _config.effectiveReviewModel(),
      ReplyReview.system(candidates.length),
      // 关系先过 effectiveRelationship：复查和起草要看到同一段关系
      // （联系人自己的关系压过全局），第 3 条标准才不是各说各话。
      ReplyReview.user(effectiveRelationship(ctx, relationship), convo,
          judgment, ctx?.ledger, candidates,
          card: card),
      0.0,
      scope,
    );
    return ReplyReview.parse(raw, candidates.length);
  }

  /// One chat-completions round trip; returns the assistant message content.
  Future<String> _chat(
    String system,
    String user,
    double temperature, {
    HttpScope? scope,
    double frequencyPenalty = 0.0,
    double presencePenalty = 0.0,
  }) {
    final url = _config.replyEndpoint();
    return _chatOn(url, _config.effectiveReplyKey(), _config.replyModel, system,
        user, temperature, scope, frequencyPenalty, presencePenalty);
  }

  /// Same round trip on an explicit route. The S1 review step needs a second
  /// route; everything else in this file keeps going through [_chat].
  Future<String> _chatOn(
    String url,
    String key,
    String model,
    String system,
    String user,
    double temperature,
    HttpScope? scope, [
    double frequencyPenalty = 0.0,
    double presencePenalty = 0.0,
  ]) async {
    final resp = await HttpJson.post(
      url,
      key,
      chatRequestBody(model, system, user, temperature, false,
          frequencyPenalty: frequencyPenalty, presencePenalty: presencePenalty),
      Route.reply,
      extraHeaders: HttpJson.headersFor(url),
      scope: scope,
    );
    final message = optMap(optMapAt(optList(resp, 'choices'), 0), 'message');
    return optString(message, 'content');
  }

  /// The request body both paths send. Shared so the streaming request can never
  /// drift from the buffered one — the only intended difference is `stream`.
  Map<String, dynamic> _chatBody(
    String system,
    String user,
    double temperature,
    bool stream, {
    double frequencyPenalty = 0.0,
    double presencePenalty = 0.0,
  }) =>
      chatRequestBody(_config.replyModel, system, user, temperature, stream,
          frequencyPenalty: frequencyPenalty, presencePenalty: presencePenalty);

  /// The prompt pair a draft sends, built once and used by both draft paths.
  _Ask _draftAsk(
    ChatSnapshot snapshot,
    String relationship,
    ChatContext? ctx,
    int count,
    List<String> avoid,
    Analysis? judgment,
    String style,
    Intensity intensity,
  ) {
    final n = count.clamp(1, 3);
    final convo = convoLines(snapshot.messages);
    // The persona note may be a key/value card (PersonaCard). Free text parses to
    // structured = false and comes back verbatim, so this is byte-for-byte the
    // string the app sent before cards existed.
    final rawStyle = StyleSource.resolve(style, ctx?.contact?.persona).text;
    final card = PersonaCard.parse(rawStyle);
    // Pre-flight, before anything leaves the device: some rounds this app will not
    // draft for, and the user has to be told which and why. Silently returning no
    // candidates is indistinguishable from a network failure.
    // Only the other side (and anything we could not attribute) is checked: the
    // limits are about what is being asked of the user.
    final verdict = SafetyGate.check(
      [
        for (final m in snapshot.messages)
          if (m.side != 'me') m.text,
      ],
      card,
    );
    final blockReason = verdict.blockReason;
    if (blockReason != null) throw SafetyBlockedException(blockReason);
    // The prompt itself is assembled by ReplyPrompt so the layering can be
    // asserted in a plain unit test, with no config and no server.
    final user = ReplyPrompt.draftUserPrompt(
      relationship,
      ctx,
      _config.contextHistoryCount,
      judgment,
      card,
      verdict.caution,
      convo,
      avoid,
      n,
      intensity: intensity,
    );
    // 档位解析一次、两处共用：system 的策略契约和 user 的档位块必须拿到
    // 同一个结果，否则会出现「必须推进」和「不要推进」同场。
    final resolvedIntensity = Intensity.resolve(intensity, judgment);
    return _Ask(
      system: ReplyPrompt.draftSystemPrompt(
        n,
        _config.replyLanguage,
        _config.replyLength,
        card,
        intensity: resolvedIntensity,
        // A1 正向示范开关（p0-plan A1）从配置透传：默认 false 时输出与该
        // 参数存在之前逐字节一致（A1 兼容锁测试钉住的就是这条默认路径）。
        usePositiveExamples: _config.usePositiveExamples,
      ),
      user: ReplyPrompt.skillNote(ctx) + user,
      // 用户设的温度就是温度：跨轮 avoid 现在几乎每轮非空，旧的「avoid
      // 非空就 +0.1」等于全局偷偷调参，反重复交给 avoid 文本和复查兜着。
      temperature: _config.replyTemperature,
      count: n,
      frequencyPenalty: _config.replyFrequencyPenalty,
      presencePenalty: _config.replyPresencePenalty,
    );
  }

  /// Parse structured strategy candidates, with a tolerant legacy-text fallback.
  static List<RankedReply> _parseN(String content, int n) {
    final start = content.indexOf('[');
    final end = content.lastIndexOf(']');
    if (start >= 0 && end > start) {
      final arr = tryDecodeList(content.substring(start, end + 1));
      if (arr != null) {
        final out = <RankedReply>[];
        for (final item in arr) {
          if (item is Map<String, dynamic>) {
            final text = optString(item, 'text').trim();
            if (text.isNotEmpty) {
              final strategy = optString(item, 'strategy', 'safe').trim();
              out.add(RankedReply(
                text: text,
                prob: 0.0,
                strategy: strategy.isEmpty ? 'safe' : strategy,
                ranked: false,
              ));
            }
          } else {
            final text = (item is String ? item : item.toString()).trim();
            if (text.isNotEmpty) {
              out.add(RankedReply(
                text: text,
                prob: 0.0,
                strategy: _strategyForIndex(out.length),
                ranked: false,
              ));
            }
          }
        }
        if (out.isNotEmpty) return _normalizeStrategies(out.take(n).toList());
      }
    }
    final lines = content
        .split('\n')
        .map((line) => line
            .trim()
            .replaceFirst(_lineLeadChars, '')
            .replaceFirst(_lineTrailChars, ''))
        .where((line) => line.trim().isNotEmpty && line != '[' && line != ']')
        .take(n)
        .toList();
    return [
      for (var i = 0; i < lines.length; i++)
        RankedReply(
          text: lines[i],
          prob: 0.0,
          strategy: _strategyForIndex(i),
          ranked: false,
        ),
    ];
  }

  /// 按行回退时剥掉的行首字符（Kotlin `trimStart('-', '*', '1', '2', '3', '.', ' ', '"')`）。
  static final RegExp _lineLeadChars = RegExp('^[-*123. "]+');

  /// 按行回退时剥掉的行尾字符（Kotlin `trimEnd('"', ',')`）。
  static final RegExp _lineTrailChars = RegExp('[",]+\$');

  static String _strategyForIndex(int i) => switch (i) {
        1 => 'forward',
        2 => 'angle',
        _ => 'safe',
      };

  static List<RankedReply> _normalizeStrategies(List<RankedReply> items) => [
        for (var i = 0; i < items.length; i++)
          items[i].copyWith(
            strategy: switch (items[i].strategy) {
              'safe' || 'forward' || 'angle' => items[i].strategy,
              _ => _strategyForIndex(i),
            },
            ranked: false,
          ),
      ];
}

class _Ask {
  const _Ask({
    required this.system,
    required this.user,
    required this.temperature,
    required this.count,
    required this.frequencyPenalty,
    required this.presencePenalty,
  });

  final String system;
  final String user;
  final double temperature;
  final int count;
  final double frequencyPenalty;
  final double presencePenalty;
}

/// The last [replyWindow] messages as `who：text` lines, for the drafting, refine
/// and review prompts. One shared builder on purpose: this loop used to be written
/// out twice, and the refine copy was assembled from four concatenated string
/// literals (`"$" + "{who}：" + …`), so the model received the placeholder text
/// instead of the conversation.
///
/// A side the capture step could not read is labelled 发言人不明 — it must never
/// be presented to the model as the other person's message.
///
/// 20 而不是 10：2026-10-07 用户实测 Telegram 的反馈是「分不清上下文」。写作模型
/// 每轮只看最近 10 条，快节奏聊天里十条之前的设定（时间、任务、约定）全部出窗，
/// 模型只能瞎接。判断层（Jev state）仍是 10 条——那边是校准过的载荷，不在这里动。
String convoLines(List<Msg> messages) {
  final window = messages.length <= replyWindow
      ? messages
      : messages.sublist(messages.length - replyWindow);
  return [
    for (final m in window)
      '${switch (m.side) {
        'me' => '我',
        'other' => '对方',
        _ => '发言人不明',
      }}：${m.text}',
  ].join('\n');
}

/// The OpenAI-compatible request body, pure so a test can pin the wire format.
///
/// The penalties ride along ONLY when non-zero: a zero value is omitted rather
/// than sent as `0`, so the request stays byte-for-byte what it was before this
/// field existed — providers that reject unknown-or-defaulted params keep working.
Map<String, dynamic> chatRequestBody(
  String model,
  String system,
  String user,
  double temperature,
  bool stream, {
  double frequencyPenalty = 0.0,
  double presencePenalty = 0.0,
}) =>
    {
      'model': model,
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
      'temperature': temperature,
      'stream': stream,
      if (frequencyPenalty != 0.0) 'frequency_penalty': frequencyPenalty,
      if (presencePenalty != 0.0) 'presence_penalty': presencePenalty,
    };

/// The refine round's user prompt. Kept apart from the network call so a test can
/// assert on the exact string the model would receive.
String refineUserPrompt(
  String relationship,
  ChatContext? ctx,
  int historyCount,
  String style,
  String instruction,
  String original,
  String convo,
) =>
    ReplyPrompt.knowledgeBlock(relationship, ctx, historyCount) +
    ReplyPrompt.styleBlock(style) +
    '\n改写要求：$instruction\n原回复：$original'
        '\n\n最近对话：\n$convo\n不要原样照抄原回复，必须真的改写。';

/// 写作侧可见的对话窗口；判断层不走这里。
const int replyWindow = 20;

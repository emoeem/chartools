import 'api_exception.dart';
import 'json_slice.dart';
import 'jsonx.dart';
import 'routes.dart';

/// The chat-completions flavour of the judge route.
///
/// The judge route's native protocol is Jev/TypeSafe `decisions`: one POST of
/// `{model, state, questions}` to a Jev-compatible host, answered with
/// `{answers}`. A plain chat model — DeepSeek official, or any OpenAI-compatible
/// host — serves no such endpoint. But that protocol is only a prompt plus a
/// JSON shape, so here the SAME state and the SAME question set are rendered
/// into one chat turn, and the model's JSON is normalized back into the very
/// `answers` object `decisions` would have returned. JudgeClient's parsing and
/// the whole UI are therefore shared, not duplicated.
///
/// What this is not: Jev is a purpose-trained, calibrated judgment model. Here
/// a general chat model answers the same questions in words, so its
/// probabilities and danger levels are its own estimates. Enough to steer a
/// draft; not the same instrument.
abstract final class ChatJudge {
  /// The system message. English because the question set it describes — Jev's
  /// instructions and criteria — is English, and Jev was trained on English
  /// questions; only the chat text itself stays in its original language.
  static const String system = '''
You are a strict judgment model for a chat assistant. You never write replies into the conversation and never explain your reasoning.

Answer the questions about ONE conversation and return EXACTLY ONE JSON object and nothing else: no markdown fence, no sentence before or after it.

Shape, one entry per question, keyed by the question id:
{"answers":{
  "<id of a noul question>":{"noul":<0..1>,"confidence":<0..1>},
  "<id of a choice question>":{"choice":"<one listed key>","confidence":<0..1>,"probabilities":{"<listed key>":<0..1>}},
  "<id of a score question>":{"score":<level number>,"confidence":<0..1>}
}}

Rules:
- "noul" is the probability from 0 to 1 that the question's "true" statement holds rather than its "false" statement. Fractions, not percentages.
- "confidence" is how sure you are of your own answer, 0 to 1.
- For a choice question, "choice" MUST be one of the listed keys, and "probabilities" must cover those keys and add up to about 1.
- For a score question, "score" is the level number of the matching criterion: the first criterion listed is 0, the next is 1, and so on.
- Judge only from the conversation and the background given. Never invent facts that are not there.
- Follow each question's instructions and criteria literally; they define the right answer.
- The conversation may be in Chinese. Keep chat text exactly as it is; keep this JSON structure exactly as specified.''';

  /// Request body for one judgment turn.
  static Map<String, dynamic> body(
    String model,
    Map<String, dynamic> state,
    Map<String, dynamic> questions, {
    required bool jsonMode,
  }) {
    final messages = [
      {'role': 'system', 'content': system},
      {'role': 'user', 'content': userPrompt(state, questions)},
    ];
    final b = <String, dynamic>{
      'model': model,
      'messages': messages,
      'temperature': 0.0,
      'stream': false,
    };
    // Not every OpenAI-compatible host accepts this field; JudgeClient
    // retries without it when a host rejects the body.
    if (jsonMode) b['response_format'] = {'type': 'json_object'};
    return b;
  }

  /// The assistant's text out of an OpenAI-compatible response, or "".
  static String contentOf(Map<String, dynamic> resp) {
    final choices = resp['choices'];
    if (choices is! List<dynamic> || choices.isEmpty) return '';
    final first = choices.first;
    if (first is! Map<String, dynamic>) return '';
    final message = first['message'];
    if (message is! Map<String, dynamic>) return '';
    return (message['content'] as String? ?? '').trim();
  }

  /// The user message: the conversation, then the question set, then the ask.
  static String userPrompt(
    Map<String, dynamic> state,
    Map<String, dynamic> questions,
  ) {
    final sb = StringBuffer();
    sb.write('=== CONVERSATION ===\n');
    final chat = optMap(state, 'chat');
    if (chat != null) {
      sb
        ..write('Relationship: ')
        ..write(optString(chat, 'relationship'))
        ..write('\n')
        ..write('Messages, oldest first (from=me is me, from=other is the '
                'other person; the last line is the latest message):\n');
      _appendMessages(sb, chat['messages']);
      final unclear = optInt(chat, 'sides_unclear', 0);
      if (unclear > 0) {
        sb
          ..write('NOTE: ')
          ..write(unclear.toString())
          ..write(' of the lines above could not be attributed to a speaker; '
                  'they are marked unknown-speaker. Do NOT assume they are the '
                  "other person's — the capture step could not read who said "
                  'them, and say so if that changes your answer.\n');
      }
      final note = optString(chat, 'note');
      if (note.trim().isNotEmpty) {
        sb.write('NOTE from the capture step: $note\n');
      }
    }
    final background = optString(state, 'background').trim();
    if (background.isNotEmpty) {
      sb
        ..write('\nBackground (given context, not off-topic):\n')
        ..write(background)
        ..write('\n');
    }
    final history = state['history'];
    if (history is List<dynamic> && history.isNotEmpty) {
      sb.write('\nEarlier messages in this same conversation, oldest first:\n');
      _appendMessages(sb, history);
    }
    sb.write('\n=== QUESTIONS ===\n');
    var n = 0;
    for (final id in questions.keys) {
      final q = questions[id];
      if (q is! Map<String, dynamic>) continue;
      n++;
      _appendQuestion(sb, n, id, q);
    }
    sb.write('\n=== ANSWER ===\nReturn the JSON object now: an "answers" '
        'object keyed by the ids above.\n');
    return sb.toString();
  }

  static void _appendMessages(StringBuffer sb, dynamic msgs) {
    if (msgs is! List<dynamic>) return;
    for (final m in msgs) {
      if (m is! Map<String, dynamic>) continue;
      final from = optString(m, 'from');
      final label = switch (from) {
        'me' => 'me: ',
        'other' => 'other: ',
        // An unknown side must never be printed as the other person's
        // message: that is how a screen of my own messages became an
        // incoming conversation.
        _ => 'unknown-speaker: ',
      };
      sb..write(label)..write(optString(m, 'text'))..write('\n');
    }
  }

  static void _appendQuestion(
    StringBuffer sb,
    int n,
    String id,
    Map<String, dynamic> q,
  ) {
    sb
      ..write('\n')
      ..write(n.toString())
      ..write('. id: ')
      ..write(id)
      ..write('\n   type: ')
      ..write(optString(q, 'type'))
      ..write('\n   instructions: ')
      ..write(optString(q, 'instructions'))
      ..write('\n');
    switch (optString(q, 'type')) {
      case 'noul':
        final criteria = q['criteria'];
        if (criteria is Map<String, dynamic>) {
          sb
            ..write('   true means: ')
            ..write(optString(criteria, 'true'))
            ..write('\n')
            ..write('   false means: ')
            ..write(optString(criteria, 'false'))
            ..write('\n');
        }
      case 'score':
        final levels = q['criteria'];
        sb.write('   criteria, by level number (0 is the first):\n');
        if (levels is List<dynamic>) {
          for (var i = 0; i < levels.length; i++) {
            final v = levels[i];
            sb..write('     ')..write(i.toString())..write(' = ')..write(
                v is String ? v : v.toString())..write('\n');
          }
        }
      default:
        final options = q['criteria'];
        if (options is Map<String, dynamic>) {
          sb.write('   options ("choice" must be one of these keys):\n');
          for (final k in options.keys) {
            final v = options[k];
            sb
              ..write('     ')
              ..write(k)
              ..write(' = ')
              ..write(v is String ? v : v.toString())
              ..write('\n');
          }
        }
    }
  }

  /// Normalizes a chat model's reply into the `answers` object JudgeClient
  /// parses. Anything the model did not answer, or answered off-menu, is left
  /// out rather than guessed at: absent reads as "not answered".
  static Map<String, dynamic> answersFrom(
    String content,
    Map<String, dynamic> questions,
  ) {
    final raw = JsonSlice.firstObject(content);
    if (raw == null) {
      throw StateError(
          '判断接口（聊天模式）没有返回 JSON：${_take(content, 120)}');
    }
    final parsed = tryDecode<Map<String, dynamic>>(raw);
    if (parsed == null) {
      throw StateError(
          '判断接口（聊天模式）返回的 JSON 解析失败：${_take(raw, 120)}');
    }
    // Most models honour the wrapper; a bare answers object is accepted too.
    final answersField = _raw(parsed, 'answers');
    final answers =
        answersField is Map<String, dynamic> ? answersField : parsed;
    final out = <String, dynamic>{};
    for (final id in questions.keys) {
      final q = questions[id];
      if (q is! Map<String, dynamic>) continue;
      final answer = _answerObject(answers, id, optString(q, 'type'));
      if (answer == null) continue;
      final normalized = switch (optString(q, 'type')) {
        'choice' => _normalizeChoice(answer, q),
        'score' => _normalizeScore(answer, q),
        _ => _normalizeNoul(answer),
      };
      if (normalized != null) out[id] = normalized;
    }
    return out;
  }

  /// The answer for [id], tolerating a different case or a bare value.
  static Map<String, dynamic>? _answerObject(
    Map<String, dynamic> answers,
    String id,
    String type,
  ) {
    final value =
        optAnyKey(answers, id);
    if (value == null) return null;
    if (value is Map<String, dynamic>) return value;
    // Some models answer with the value alone ({"should_reply_now": true},
    // {"danger_level": 4}, {"literal_question": "0.2"}).
    return switch (value) {
      final bool v => {'noul': v ? 1.0 : 0.0},
      final num v when type == 'score' => {'score': v.toDouble()},
      final num v => {'noul': v.toDouble()},
      final String v when type == 'score' => {'score': v},
      final String v when type == 'choice' => {'choice': v},
      final String v => {'noul': v},
      _ => null,
    };
  }

  /// [key] out of an answer object, tolerating a capitalized spelling.
  static dynamic _raw(Map<String, dynamic> a, String key) => optAnyKey(a, key);

  static Map<String, dynamic>? _normalizeChoice(
    Map<String, dynamic> a,
    Map<String, dynamic> q,
  ) {
    final options = q['criteria'];
    if (options is! Map<String, dynamic>) return null;
    final keys = options.keys.toList();
    if (keys.isEmpty) return null;
    final probabilities = <String, double>{};
    final p = _raw(a, 'probabilities');
    if (p is Map<String, dynamic>) {
      for (final rawKey in p.keys) {
        final key = keys.where((k) => k.toLowerCase() == rawKey.toLowerCase()).firstOrNull;
        if (key == null) continue;
        probabilities[key] = _number(p, rawKey, 0.0).clamp(0.0, 1.0);
      }
    }
    final said = (_raw(a, 'choice') as String?)?.trim() ?? '';
    var choice = keys.where((k) => k.toLowerCase() == said.toLowerCase()).firstOrNull;
    // Some models echo the option's text instead of its key.
    choice ??= keys
        .where((k) => _asText(options[k]).trim().toLowerCase() == said.toLowerCase())
        .firstOrNull;
    // ...or fill only the probabilities, which still names the winner.
    choice ??= () {
      if (probabilities.isEmpty) return null;
      var bestKey = '';
      var bestVal = -1.0;
      probabilities.forEach((k, v) {
        if (v > bestVal) {
          bestVal = v;
          bestKey = k;
        }
      });
      return bestKey;
    }();
    if (choice == null) return null;
    final out = <String, dynamic>{
      'choice': choice,
      'confidence': _probability(a, 'confidence'),
    };
    if (probabilities.isNotEmpty) out['probabilities'] = probabilities;
    return out;
  }

  static Map<String, dynamic>? _normalizeScore(
    Map<String, dynamic> a,
    Map<String, dynamic> q,
  ) {
    final levels = q['criteria'];
    if (levels is! List<dynamic> || levels.isEmpty) return null;
    final count = levels.length;
    // Jev's danger scale is 0..9 for ten criteria, so the level is the
    // 0-based index into them, and the legend below hands JudgeClient the
    // 9 the UI prints as "score/maxLevel".
    final level = switch (_raw(a, 'score')) {
      final num v => v.toInt(),
      final String v => int.tryParse(v.trim()) ?? _levelOf(levels, v.trim()),
      _ => null,
    };
    if (level == null) return null;
    final out = <String, dynamic>{
      'score': level.clamp(0, count - 1),
      'confidence': _probability(a, 'confidence'),
    };
    final legend = <String, String>{
      for (var i = 0; i < count; i++)
        i.toString(): levels[i] is String ? levels[i] as String : levels[i].toString(),
    };
    out['legend'] = legend;
    return out;
  }

  static Map<String, dynamic>? _normalizeNoul(Map<String, dynamic> a) {
    final p = switch (_raw(a, 'noul')) {
      final num v => v.toDouble(),
      final bool v => v ? 1.0 : 0.0,
      final String v =>
        double.tryParse(v.trim()) ??
            switch (v.trim().toLowerCase()) {
              'true' || 'yes' => 1.0,
              'false' || 'no' => 0.0,
              _ => null,
            },
      _ => null,
    };
    if (p == null) return null;
    return {
      'noul': p.clamp(0.0, 1.0),
      'confidence': _probability(a, 'confidence'),
    };
  }

  /// 0-based level of the criterion whose text was echoed instead of its number.
  static int? _levelOf(List<dynamic> levels, String text) {
    if (text.isEmpty) return null;
    for (var i = 0; i < levels.length; i++) {
      final v = levels[i];
      if (_asText(v).trim().toLowerCase() == text.toLowerCase()) return i;
    }
    return null;
  }

  static double _number(Map<String, dynamic> a, String key, double fallback) =>
      switch (_raw(a, key)) {
        final num v => v.toDouble(),
        final String v => double.tryParse(v.trim()) ?? fallback,
        _ => fallback,
      };

  static double _probability(Map<String, dynamic> a, String key) =>
      _number(a, key, 0.0).clamp(0.0, 1.0);

  static String _asText(Object? v) => v is String ? v : v.toString();

  static String _take(String s, int n) => s.length <= n ? s : s.substring(0, n);
}

/// Chat 模式「response_format 被拒」时的防御性重试判定（400/422 是形状抱怨，
/// 其余不重试）。见 JudgeClient.sendChat。
bool shouldRetryWithoutJsonMode(int? status) => status == 400 || status == 422;

/// Chat 模式下取不到正文时的错误（供 JudgeClient 抛出）。
ApiException emptyChatContentException() =>
    ApiException(Route.judge, null, '聊天模式返回内容为空');

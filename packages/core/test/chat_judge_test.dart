import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// 聊天模式判断的归一化锁 —— 对照旧仓库 `jev/ChatJudgeTest.kt` 的思路。
///
/// 聊天模式让任意 OpenAI 兼容模型回答 Jev 的同一套问题，再把模型的 JSON
/// 抹回 `decisions` 协议返回的 `answers` 形状（这是 DeepSeek 能当判断路由
/// 的前提）。模型不可信：有 fence、有客套话、键大小写乱来、答出菜单 ——
/// 归一化的每个边角都要钉死：没答的留在「未答」，出菜单的不猜。
void main() {
  final questions = JevQuestions.judge();

  // 一封 DeepSeek 形状的回信：有 fence、有客套话、七题全答。
  const deepSeekReply = '''
Sure, here is the judgment:

```json
{
  "answers": {
    "literal_question": {"noul": 0.2, "confidence": 0.8},
    "true_intent": {"choice": "confirm_you_care", "confidence": 0.7,
                    "probabilities": {"confirm_you_care": 0.7, "vent_anger": 0.2, "casual_chat": 0.1}},
    "danger_level": {"score": 4, "confidence": 0.6},
    "should_reply_now": {"noul": false, "confidence": 0.9},
    "she_needs": {"choice": "care", "confidence": 0.55,
                  "probabilities": {"care": 0.55, "apology": 0.45}},
    "best_action": {"choice": "apologize", "confidence": 0.6, "probabilities": {"apologize": 1.0}},
    "tension_resolved": {"noul": "0.15", "confidence": 0.5}
  }
}
```
''';

  Map<String, dynamic> answerOf(Map<String, dynamic> answers, String id) =>
      answers[id] as Map<String, dynamic>;

  group('ChatJudge.answersFrom 归一化', () {
    test('带 fence 的回信抹回 decisions 的 answers 形状', () {
      final answers = ChatJudge.answersFrom(deepSeekReply, questions);
      expect(answers.keys.toSet(), questions.keys.toSet());

      final intent = JudgeAnswers.choice(answerOf(answers, 'true_intent'));
      expect(intent!.choice, 'confirm_you_care');
      expect(intent.confidence, 0.7);
      expect(intent.probabilities['vent_anger'], 0.2);

      // 关键之处：Jev 十条危险标准的第 4 级；legend 就是要变成浮层
      // 「4/9」的那张表。
      final danger = JudgeAnswers.score(answerOf(answers, 'danger_level'));
      expect(danger!.score, 4.0);
      expect(danger.maxLevel, 9);

      expect(answerOf(answers, 'literal_question')['noul'], 0.2);
      expect(answerOf(answers, 'should_reply_now')['noul'], 0.0);
      expect(answerOf(answers, 'tension_resolved')['noul'], 0.15);
    });

    test('没有 answers 包壳的裸对象也接受', () {
      const content = '{"true_intent":{"choice":"vent_anger","confidence":0.4}}';
      final answers = ChatJudge.answersFrom(content, questions);
      expect(answerOf(answers, 'true_intent')['choice'], 'vent_anger');
      expect(answers.length, 1);
    });

    test('出菜单的选项宁可空着也不猜', () {
      const content = '{"true_intent":{"choice":"be_nice","confidence":0.9}}';
      final answers = ChatJudge.answersFrom(content, questions);
      expect(answers.containsKey('true_intent'), isFalse);
      // strict-casts 下 dynamic 不能隐式降级，按 answersFrom 的键值形状显式转。
      expect(
        JudgeAnswers.choice(answers['true_intent'] as Map<String, dynamic>?),
        isNull,
      );
    });

    test('choice 可以只靠 probabilities，也可以来自选项原文', () {
      final byProbs = ChatJudge.answersFrom(
          '{"true_intent":{"probabilities":{"vent_anger":0.8,"casual_chat":0.2}}}',
          questions);
      expect(answerOf(byProbs, 'true_intent')['choice'], 'vent_anger');

      final byText = ChatJudge.answersFrom(
          '{"true_intent":{"choice":"They want a concrete action, time, '
          'deliverable, or commitment from you now, and this is a real ask, '
          'not a loyalty test."}}',
          questions);
      expect(answerOf(byText, 'true_intent')['choice'], 'request_action');
    });

    test('键大小写不敏感，裸布尔也接受', () {
      const content =
          '{"Answers":{"True_Intent":{"Choice":"Vent_Anger"},"Should_Reply_Now":true}}';
      final answers = ChatJudge.answersFrom(content, questions);
      expect(answerOf(answers, 'true_intent')['choice'], 'vent_anger');
      expect(answerOf(answers, 'should_reply_now')['noul'], 1.0);
    });

    test('裸值落进题型期望的字段', () {
      const content =
          '{"danger_level":4,"literal_question":"0.2","should_reply_now":"false"}';
      final answers = ChatJudge.answersFrom(content, questions);
      expect(JudgeAnswers.score(answerOf(answers, 'danger_level'))!.score, 4.0);
      expect(answerOf(answers, 'literal_question')['noul'], 0.2);
      expect(answerOf(answers, 'should_reply_now')['noul'], 0.0);
    });

    test('score 接受回显的标准原文，越界等级被钳住', () {
      final echoed = ChatJudge.answersFrom(
          '{"danger_level":{"score":"Active rupture: they said it is over, '
          'told you not to reply, deleted you, or are exploding."}}',
          questions);
      expect(JudgeAnswers.score(answerOf(echoed, 'danger_level'))!.score, 9.0);

      final tooHigh =
          ChatJudge.answersFrom('{"danger_level":{"score":42}}', questions);
      expect(JudgeAnswers.score(answerOf(tooHigh, 'danger_level'))!.score, 9.0);

      final tooLow =
          ChatJudge.answersFrom('{"danger_level":{"score":-3}}', questions);
      expect(JudgeAnswers.score(answerOf(tooLow, 'danger_level'))!.score, 0.0);
    });

    test('noul 钳在 0 与 1 之间，yes/true/false 字符串也读', () {
      final answers = ChatJudge.answersFrom(
          '{"literal_question":{"noul":1.7},"tension_resolved":{"noul":-0.4},'
          '"should_reply_now":{"noul":"yes"}}',
          questions);
      expect(answerOf(answers, 'literal_question')['noul'], 1.0);
      expect(answerOf(answers, 'tension_resolved')['noul'], 0.0);
      expect(answerOf(answers, 'should_reply_now')['noul'], 1.0);

      final asStrings = ChatJudge.answersFrom(
          '{"should_reply_now":{"noul":"true"},"tension_resolved":{"noul":"false"}}',
          questions);
      expect(answerOf(asStrings, 'should_reply_now')['noul'], 1.0);
      expect(answerOf(asStrings, 'tension_resolved')['noul'], 0.0);
    });

    test('没答的题留在未答状态，UI 才能如实显示', () {
      final answers = ChatJudge.answersFrom(
          '{"answers":{"true_intent":{"choice":"casual_chat"}}}', questions);
      expect(answers.length, 1);
      expect(
        JudgeAnswers.choice(answers['she_needs'] as Map<String, dynamic>?),
        isNull,
      );
    });

    test('一个 JSON 都没有时大声失败（面向用户的中文错误）', () {
      expect(
        () => ChatJudge.answersFrom('I cannot answer that.', questions),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('没有返回 JSON'))),
      );
    });

    test('JSON 不完整时大声失败', () {
      expect(
        () => ChatJudge.answersFrom('{ "answers": , }', questions),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('解析失败'))),
      );
    });

    test('contentOf 读出 assistant 正文并去掉首尾空白', () {
      final resp = <String, dynamic>{
        'choices': [
          {'message': {'content': '  hello  '}},
        ],
      };
      expect(ChatJudge.contentOf(resp), 'hello');
      expect(ChatJudge.contentOf(const <String, dynamic>{}), '');
    });
  });
}

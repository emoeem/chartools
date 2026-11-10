import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// JudgeAnswers 的三条读法：choice / score / ranked（对照旧仓库
/// `jev/ChatJudgeTest.kt` 里落在 JudgeAnswers 上的断言）。
///
/// 两条协议在 JudgeClient 处汇成同一个 `answers` 对象，这里读成 UI 的模型。
/// `legend`/`probabilities` 两个约定正是浮层显示「5/9」还是「5/10」的
/// 分歧点，逐条钉住。
void main() {
  group('JudgeAnswers.choice', () {
    test('读出所选键与置信度，概率表原样带回', () {
      final c = JudgeAnswers.choice(const {
        'choice': 'vent_anger',
        'confidence': 0.4,
        'probabilities': {'vent_anger': 0.6, 'casual_chat': 0.4},
      });
      expect(c!.choice, 'vent_anger');
      expect(c.confidence, 0.4);
      expect(c.probabilities['vent_anger'], 0.6);
      expect(c.probabilities['casual_chat'], 0.4);
    });

    test('缺省字段回 0，概率表为空', () {
      final c = JudgeAnswers.choice(const {'choice': 'care'});
      expect(c!.confidence, 0.0);
      expect(c.probabilities, isEmpty);
    });

    test('字符串数字也能读（模型爱把 confidence 写成文本）', () {
      final c = JudgeAnswers.choice(const {'choice': 'care', 'confidence': '0.5'});
      expect(c!.confidence, 0.5);
    });

    test('null 进 null 出', () {
      expect(JudgeAnswers.choice(null), isNull);
    });
  });

  group('JudgeAnswers.score', () {
    test('legend 决定 maxLevel（Jev 十条危险标准 → 9）', () {
      final s = JudgeAnswers.score({
        'score': 4,
        'confidence': 0.6,
        'legend': {for (var i = 0; i < 10; i++) '$i': '级别 $i'},
      });
      expect(s!.score, 4.0);
      expect(s.confidence, 0.6);
      expect(s.maxLevel, 9);
    });

    test('legend 更长时 maxLevel 跟着 legend 走', () {
      final s = JudgeAnswers.score({
        'score': 5,
        'legend': {for (var i = 0; i < 12; i++) '$i': '级别 $i'},
      });
      expect(s!.maxLevel, 11);
    });

    test('无 legend 时保持历史默认 9（危险量表一直是这个刻度）', () {
      final s = JudgeAnswers.score(const {'score': 3, 'confidence': 0.5});
      expect(s!.score, 3.0);
      expect(s.maxLevel, 9);
    });

    test('legend 里的非数字键跳过，不动默认刻度', () {
      final s = JudgeAnswers.score(const {
        'score': 1,
        'legend': {'a': 'x', '0': 'y'},
      });
      expect(s!.maxLevel, 9);
    });

    test('null 进 null 出', () {
      expect(JudgeAnswers.score(null), isNull);
    });
  });

  group('JudgeAnswers.ranked', () {
    test('按 reply_a/b/c 的概率从高到低排序，最优者第一', () {
      final ranked = JudgeAnswers.ranked(
        const {
          'probabilities': {'reply_a': 0.1, 'reply_b': 0.8, 'reply_c': 0.1},
        },
        const ['A', 'B', 'C'],
      );
      expect(ranked.map((r) => r.text).toSet(), {'A', 'B', 'C'});
      expect(ranked.first.text, 'B');
      expect(ranked.first.prob, 0.8);
    });

    test('只认 reply_a/b/c 三个键，缺概率的候选得 0', () {
      final ranked = JudgeAnswers.ranked(
        const {
          'probabilities': {'reply_a': 0.5},
        },
        const ['A', 'B', 'C', 'D'],
      );
      double probOf(String text) =>
          ranked.firstWhere((r) => r.text == text).prob;
      expect(probOf('A'), 0.5);
      expect(probOf('B'), 0.0);
      expect(probOf('C'), 0.0);
      // 第 4 条候选没有对应的键，得 0 分垫底。
      expect(probOf('D'), 0.0);
    });

    test('没有概率表（或整个对象缺失）时全部 0 分', () {
      final ranked = JudgeAnswers.ranked(const {}, const ['A', 'B']);
      expect(ranked.map((r) => r.prob), everyElement(0.0));
      final fromNull = JudgeAnswers.ranked(null, const ['A', 'B']);
      expect(fromNull.map((r) => r.prob), everyElement(0.0));
    });
  });
}

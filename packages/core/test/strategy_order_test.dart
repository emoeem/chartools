import 'package:chartools_core/src/models/models.dart';
import 'package:chartools_core/src/pipeline/strategy_order.dart';
import 'package:test/test.dart';

/// 对拍旧仓库 `StrategyOrderTest.kt`。
///
/// 判断层只按 best_reply 打分，执行 best_action 的那行候选可能排在第 3 位；
/// 这里把执行该动作的策略提到顶部。有意思的性质是：提升稳定（其余保持原
/// 位）、无偏好时不动、绝不凭空造出一行。
void main() {
  RankedReply r(String text, String strategy,
          {double prob = 0.5, bool ranked = true}) =>
      RankedReply(text: text, prob: prob, strategy: strategy, ranked: ranked);

  List<String> texts(List<RankedReply> list) =>
      list.map((x) => x.text).toList();

  test('收着类动作指向 safe 线', () {
    // 承认、表示听到了、少说、去查事实——回复模型查不了任何东西，不编造
    // 答案的 safe 线是 check_history 的诚实匹配。
    expect(StrategyOrder.preferred('apologize'), 'safe');
    expect(StrategyOrder.preferred('acknowledge'), 'safe');
    expect(StrategyOrder.preferred('say_less'), 'safe');
    expect(StrategyOrder.preferred('check_history'), 'safe');
  });

  test('实质推进类动作指向 forward', () {
    expect(StrategyOrder.preferred('give_commitment'), 'forward');
    expect(StrategyOrder.preferred('explain'), 'forward');
    expect(StrategyOrder.preferred('make_plan'), 'forward');
  });

  test('无判断或未映射的动作等于无偏好', () {
    expect(StrategyOrder.preferred(null), isNull);
    expect(StrategyOrder.preferred(''), isNull);
    expect(StrategyOrder.preferred('angle'), isNull); // 判断层没有「换话题」动作
    expect(StrategyOrder.preferred('something_new'), isNull);
  });

  test('被推荐的行提到顶部，其余保持原顺序', () {
    final list = [
      r('最高分但推进', 'forward', prob: 0.71),
      r('稳妥承接', 'safe', prob: 0.30),
      r('换个角度', 'angle', prob: 0.55),
    ];
    final out = StrategyOrder.order(list, 'safe');
    expect(texts(out), ['稳妥承接', '最高分但推进', '换个角度']);
    // 只挪位置不改分数：概率仍是判断给的，排序层不许造假分。
    expect(out.first.prob, 0.30);
    expect(out.first.strategy, 'safe');
  });

  test('推荐行已在顶部时列表原样返回', () {
    final list = [r('稳妥', 'safe'), r('推进', 'forward')];
    expect(texts(StrategyOrder.order(list, 'safe')), ['稳妥', '推进']);
  });

  test('列表里没有该策略或无偏好时原样返回', () {
    final list = [r('推进', 'forward'), r('换角度', 'angle')];
    expect(texts(StrategyOrder.order(list, 'safe')), ['推进', '换角度']);
    expect(texts(StrategyOrder.order(list, null)), ['推进', '换角度']);
    expect(texts(StrategyOrder.order(list, '')), ['推进', '换角度']);
    // 纯空白偏好与无偏好同义（strategy_order.dart 的 trim 分支）。
    expect(texts(StrategyOrder.order(list, '  ')), ['推进', '换角度']);
  });

  test('未打分的候选也参与重排，策略照样适用', () {
    final list = [
      r('稳妥', 'safe', prob: 0.0, ranked: false),
      r('推进', 'forward', prob: 0.0, ranked: false),
    ];
    expect(texts(StrategyOrder.order(list, 'forward')), ['推进', '稳妥']);
  });

  test('只提升第一个命中行，重复行不会翻倍', () {
    final list = [
      r('a', 'forward'),
      r('b', 'safe'),
      r('c', 'safe'),
      r('d', 'angle'),
    ];
    final out = StrategyOrder.order(list, 'safe');
    expect(texts(out), ['b', 'a', 'c', 'd']);
    // 是「挪位」不是「复制」：行数必须不变。
    expect(out.length, list.length);
  });

  test('空列表安全', () {
    expect(StrategyOrder.order(const [], 'safe'), isEmpty);
  });
}

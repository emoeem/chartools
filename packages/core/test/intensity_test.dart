import 'package:chartools_core/src/models/models.dart';
import 'package:chartools_core/src/pipeline/intensity.dart';
import 'package:test/test.dart';

/// 对拍旧仓库 `IntensityTest.kt`。
///
/// 「自动」档的原则：宁可保守——错的方向若是「该收的时候加码」伤害最大，
/// 所以所有偏冷信号都压到收着，只有「双方约好的角色场景且局势轻松」才自动
/// 加码。映射全部来自判断层已有输出（Analysis），没有新感知能力。
void main() {
  // 与 Kotlin 参考的 judgment() 辅助同构：只填映射用得到的三个字段。
  Analysis judgment({String? intent, double? danger, double? shouldReplyNow}) =>
      Analysis(
        trueIntent:
            intent == null ? null : Choice(choice: intent, confidence: 0.9),
        dangerLevel: danger == null
            ? null
            : Score(score: danger, confidence: 0.9, maxLevel: 9),
        shouldReplyNow: shouldReplyNow,
        latencyMs: 0,
      );

  test('没有判断时退回自然', () {
    // 会话第一轮、或起草没等到判断：没有证据就不偏移默认行为。
    expect(Intensity.auto_(null), Intensity.natural);
  });

  test('局势紧了收着', () {
    expect(Intensity.auto_(judgment(danger: 6.0)), Intensity.soft);
    expect(Intensity.auto_(judgment(danger: 9.0)), Intensity.soft);
    // 紧张但没过线（>=6 才压档）时不压。
    expect(Intensity.auto_(judgment(danger: 5.0)), Intensity.natural);
  });

  test('对方在发泄情绪时收着，与紧张度无关', () {
    // 发泄时加码等于火上浇油——这条不看紧张度分数。
    expect(Intensity.auto_(judgment(intent: 'vent_anger', danger: 2.0)),
        Intensity.soft);
    // 没给 dangerLevel 时发泄信号单独生效。
    expect(Intensity.auto_(judgment(intent: 'vent_anger')), Intensity.soft);
  });

  test('此刻不适合给实质时收着', () {
    expect(Intensity.auto_(judgment(shouldReplyNow: 0.2)), Intensity.soft);
    // 边界：< 0.5 才压档，恰好 0.5 不压。
    expect(Intensity.auto_(judgment(shouldReplyNow: 0.5)), Intensity.natural);
    expect(Intensity.auto_(judgment(shouldReplyNow: 0.8)), Intensity.natural);
  });

  test('约好的角色场景且局势轻松时加码', () {
    expect(Intensity.auto_(judgment(intent: 'intimate_roleplay', danger: 2.0)),
        Intensity.forward);
    // 档位下限边界：lvl<=3 都算轻松。
    expect(Intensity.auto_(judgment(intent: 'intimate_roleplay', danger: 3.0)),
        Intensity.forward);
    // 没有 dangerLevel（lvl == null）时场景也算轻松。
    expect(Intensity.auto_(judgment(intent: 'intimate_roleplay')),
        Intensity.forward);
    // 场景还在但局势真的紧了，推进同样要停。
    expect(Intensity.auto_(judgment(intent: 'intimate_roleplay', danger: 6.0)),
        Intensity.soft);
  });

  test('每个档位都有非空标签', () {
    for (final i in Intensity.values) {
      expect(i.label, isNotEmpty);
    }
  });

  test('手选档原样，自动档按判断映射', () {
    // system 策略契约和 user 档位块共用这一个解析——两边各算各的就会出现
    // 「必须推进」和「不要推进」同场。
    final tense = judgment(danger: 7.0);
    expect(Intensity.resolve(Intensity.auto, tense), Intensity.soft);
    expect(Intensity.resolve(Intensity.soft, null), Intensity.soft);
    expect(Intensity.resolve(Intensity.forward, tense), Intensity.forward);
    expect(Intensity.resolve(Intensity.natural, null), Intensity.natural);
    expect(Intensity.resolve(Intensity.auto, null), Intensity.natural);
  });

  test('fromName 与 Kotlin 侧 Prefs 存的枚举名对齐', () {
    expect(Intensity.fromName('soft'), Intensity.soft);
    expect(Intensity.fromName('forward'), Intensity.forward);
    // 未知或缺失的名字回退自动档。
    expect(Intensity.fromName('bogus'), Intensity.auto);
    expect(Intensity.fromName(null), Intensity.auto);
  });
}

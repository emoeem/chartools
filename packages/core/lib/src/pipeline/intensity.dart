import '../models/models.dart';

/// 候选回复的推进档位 —— 分析卡上的一排档位，以及「自动」档根据判断结果的映射。
///
/// 三档的语义不是"热情程度"，而是候选策略的倾向：收着 ≈ safe（承接确认、不推进），
/// 自然 = 默认三策略不动，加码 ≈ forward（表达感受、发出具体邀请、推进话题）。
/// 起草的 strategy 契约（safe/forward/angle 各一条）不变，档位只调整语气指引与
/// 策略侧重 —— 排序和解析层不用动。
///
/// 「自动」档的映射全部来自判断层已有输出（[Analysis]），没有新感知能力：
/// 局势偏紧、对方在发泄情绪、此刻不适合给实质 → 收着；双方约好的角色场景且
/// 局势轻松 → 加码；其余 → 自然。宁可保守：自动档错的方向如果是
/// "该收的时候加码"，伤害最大。
enum Intensity {
  auto('自动'),
  soft('收着'),
  natural('自然'),
  forward('加码');

  const Intensity(this.label);
  final String label;

  /// 档位的最终生效值：手选档原样，自动档按判断结果映射。
  /// system 提示词的策略契约和 user 提示词的档位块都必须用同一个
  /// 解析结果——两边各算各的就会一个说「必须推进」一个说「不要推进」。
  static Intensity resolve(Intensity mode, Analysis? judgment) =>
      mode == auto ? auto_(judgment) : mode;

  /// 「自动」档的判断结果 → 档位映射。判断为 null（会话第一轮、或起草
  /// 没等到判断）时退回自然 —— 没有证据就不偏移默认行为。
  static Intensity auto_(Analysis? judgment) {
    final a = judgment;
    if (a == null) return natural;
    final lvl = a.dangerLevel?.score;
    if (lvl != null && lvl >= 6) return soft;
    if (a.trueIntent?.choice == 'vent_anger') return soft;
    final shouldReplyNow = a.shouldReplyNow;
    if (shouldReplyNow != null && shouldReplyNow < 0.5) return soft;
    if (a.trueIntent?.choice == 'intimate_roleplay' &&
        (lvl == null || lvl <= 3)) {
      return forward;
    }
    return natural;
  }

  /// [fromName] 与 Kotlin 侧 `Prefs` 存的名字对齐（枚举 name）。
  static Intensity fromName(String? name) => values
      .where((v) => v.name == name)
      .firstOrNull ?? auto;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

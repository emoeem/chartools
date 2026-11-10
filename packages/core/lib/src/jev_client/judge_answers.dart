import '../models/models.dart';
import 'jsonx.dart';

/// Reads the `answers` object of a judgment response into the UI's models.
///
/// Both judgment protocols end here: the Jev/TypeSafe `decisions` shape and the
/// OpenAI chat shape normalized by [ChatJudge] are the same object by the time
/// JudgeClient calls in. Kept separate so this parsing can be unit-tested
/// without an HTTP round trip — the two `legend`/`probabilities` conventions
/// below are exactly what decides whether the overlay shows "5/9" or "5/10".
abstract final class JudgeAnswers {
  /// A multiple-choice answer: the chosen key plus the model's own odds.
  static Choice? choice(Map<String, dynamic>? o) {
    if (o == null) return null;
    final probs = <String, double>{};
    final p = optMap(o, 'probabilities');
    if (p != null) {
      for (final k in p.keys) {
        probs[k] = optDouble(p, k);
      }
    }
    return Choice(
      choice: optString(o, 'choice'),
      confidence: optDouble(o, 'confidence'),
      probabilities: probs,
    );
  }

  /// A 0-based level answer. The scale size comes from the `legend` map the
  /// Jev response carries (criteria index -> label); without one we keep the
  /// historical default of 9, which is what the danger scale has always been.
  static Score? score(Map<String, dynamic>? o) {
    if (o == null) return null;
    var maxLevel = 9;
    final legend = optMap(o, 'legend');
    if (legend != null) {
      for (final k in legend.keys) {
        final i = int.tryParse(k);
        if (i != null && i > maxLevel) maxLevel = i;
      }
    }
    return Score(
      score: optDouble(o, 'score'),
      confidence: optDouble(o, 'confidence'),
      maxLevel: maxLevel,
    );
  }

  /// The reply ranking: candidates in by text, out best-first.
  static List<RankedReply> ranked(
    Map<String, dynamic>? o,
    List<String> candidates,
  ) {
    const keys = ['reply_a', 'reply_b', 'reply_c'];
    final probs = o == null ? null : optMap(o, 'probabilities');
    final list = <RankedReply>[];
    for (var i = 0; i < candidates.length; i++) {
      final prob = probs == null
          ? 0.0
          : optDouble(probs, i < keys.length ? keys[i] : '');
      list.add(RankedReply(text: candidates[i], prob: prob));
    }
    list.sort((a, b) => b.prob.compareTo(a.prob));
    return list;
  }
}

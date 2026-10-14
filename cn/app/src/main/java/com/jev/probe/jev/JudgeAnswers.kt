package com.jev.probe.jev

import com.jev.probe.core.Choice
import com.jev.probe.core.RankedReply
import com.jev.probe.core.Score
import org.json.JSONObject

/**
 * Reads the `answers` object of a judgment response into the UI's models.
 *
 * Both judgment protocols end here: the Jev/TypeSafe `decisions` shape and the
 * OpenAI chat shape normalized by [ChatJudge] are the same object by the time
 * [JudgeClient] calls in. Kept separate from [JudgeClient] and `internal` (not
 * private) so this parsing can be unit-tested without an HTTP round trip — the
 * two `legend`/`probabilities` conventions below are exactly what decides
 * whether the overlay shows "5/9" or "5/10".
 */
internal object JudgeAnswers {

    /** A multiple-choice answer: the chosen key plus the model's own odds. */
    fun choice(o: JSONObject?): Choice? {
        o ?: return null
        val probs = HashMap<String, Double>()
        o.optJSONObject("probabilities")?.let { p ->
            p.keys().forEach { k -> probs[k] = p.optDouble(k) }
        }
        return Choice(o.optString("choice"), o.optDouble("confidence", 0.0), probs)
    }

    /**
     * A 0-based level answer. The scale size comes from the `legend` map the
     * Jev response carries (criteria index -> label); without one we keep the
     * historical default of 9, which is what the danger scale has always been.
     */
    fun score(o: JSONObject?): Score? {
        o ?: return null
        val legend = o.optJSONObject("legend")
        val maxLevel = legend?.keys()?.asSequence()?.mapNotNull { it.toIntOrNull() }?.maxOrNull() ?: 9
        return Score(o.optDouble("score", 0.0), o.optDouble("confidence", 0.0), maxLevel)
    }

    /** The reply ranking: candidates in by text, out best-first. */
    fun ranked(o: JSONObject?, candidates: List<String>): List<RankedReply> {
        val keys = listOf("reply_a", "reply_b", "reply_c")
        val probs = o?.optJSONObject("probabilities")
        val list = candidates.mapIndexed { i, text ->
            RankedReply(text, probs?.optDouble(keys.getOrElse(i) { "" }, 0.0) ?: 0.0)
        }
        return list.sortedByDescending { it.prob }
    }
}

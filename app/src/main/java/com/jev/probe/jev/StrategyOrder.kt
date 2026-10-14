package com.jev.probe.jev

import com.jev.probe.core.RankedReply

/**
 * The judge already decides *what kind of move* to make (`best_action`), while the
 * three candidates are generated one per strategy (safe / forward / angle). The
 * rank step, however, only scores `best_reply`, so the candidate that actually
 * carries out the recommended action can end up as row #3.
 *
 * This maps the action onto the strategy that performs it and promotes that row.
 * The probabilities still come from the judge — only the display order changes, so
 * nothing here can fake a score. Ordering is stable: the rest keep their rank.
 */
internal object StrategyOrder {

    /**
     * best_action choice -> the strategy that carries it out. Absent or unmapped
     * means "no preference", and the judge's own order stands.
     */
    fun preferred(bestAction: String?): String? = when (bestAction) {
        // Holding moves: admit, show you heard them, say less, or go find the fact.
        // The reply model cannot look anything up, so the honest match for
        // check_history is the safe line that does not invent an answer.
        "apologize", "acknowledge", "say_less", "check_history" -> "safe"
        // Substance: a promise, an explanation, or logistics — all move it forward.
        "give_commitment", "explain", "make_plan" -> "forward"
        else -> null
    }

    /**
     * Promote the first row whose strategy is [preferred] to the top; keep every
     * other row exactly where it was. No preference, no match, or a match already
     * on top all return the list unchanged.
     */
    fun order(list: List<RankedReply>, preferred: String?): List<RankedReply> {
        if (preferred.isNullOrBlank()) return list
        val hit = list.indexOfFirst { it.strategy == preferred }
        if (hit <= 0) return list
        return list.toMutableList().also { it.add(0, it.removeAt(hit)) }
    }
}

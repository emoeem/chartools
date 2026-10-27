package com.jev.probe.core

import com.jev.probe.core.RankedReply
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Promoting the candidate that performs the judge's own `best_action`. The judge
 * ranks on `best_reply` only, so without this the recommended move can sit at #3.
 * The interesting properties are that the promise is stable (the rest keep their
 * rank), that no preference changes nothing, and that it can never invent a row.
 */
class StrategyOrderTest {

    private fun r(text: String, strategy: String, prob: Double = 0.5, ranked: Boolean = true) =
        RankedReply(text = text, prob = prob, strategy = strategy, ranked = ranked)

    private fun texts(list: List<RankedReply>) = list.map { it.text }

    @Test
    fun holdingActionsPointAtTheSafeLine() {
        assertEquals("safe", StrategyOrder.preferred("apologize"))
        assertEquals("safe", StrategyOrder.preferred("acknowledge"))
        assertEquals("safe", StrategyOrder.preferred("say_less"))
        assertEquals("safe", StrategyOrder.preferred("check_history"))
    }

    @Test
    fun substanceActionsPointAtMovingForward() {
        assertEquals("forward", StrategyOrder.preferred("give_commitment"))
        assertEquals("forward", StrategyOrder.preferred("explain"))
        assertEquals("forward", StrategyOrder.preferred("make_plan"))
    }

    @Test
    fun noJudgmentOrAnUnmappedActionMeansNoPreference() {
        assertNull(StrategyOrder.preferred(null))
        assertNull(StrategyOrder.preferred(""))
        assertNull(StrategyOrder.preferred("angle"))   // the judge has no "change topic" action
        assertNull(StrategyOrder.preferred("something_new"))
    }

    @Test
    fun theRecommendedRowIsPromotedAndTheOthersKeepTheirOrder() {
        val list = listOf(
            r("最高分但推进", "forward", 0.71),
            r("稳妥承接", "safe", 0.30),
            r("换个角度", "angle", 0.55)
        )
        assertEquals(listOf("稳妥承接", "最高分但推进", "换个角度"), texts(StrategyOrder.order(list, "safe")))
    }

    @Test
    fun aListThatAlreadyLeadsWithTheRecommendationIsUntouched() {
        val list = listOf(r("稳妥", "safe"), r("推进", "forward"))
        assertEquals(list, StrategyOrder.order(list, "safe"))
    }

    @Test
    fun aStrategyThatIsMissingFromTheListChangesNothing() {
        val list = listOf(r("推进", "forward"), r("换角度", "angle"))
        assertEquals(list, StrategyOrder.order(list, "safe"))
        assertEquals(list, StrategyOrder.order(list, null))
        assertEquals(list, StrategyOrder.order(list, ""))
    }

    @Test
    fun unrankedCandidatesAreReorderedTooBecauseStrategyStillApplies() {
        val list = listOf(
            r("稳妥", "safe", 0.0, ranked = false),
            r("推进", "forward", 0.0, ranked = false)
        )
        assertEquals(listOf("推进", "稳妥"), texts(StrategyOrder.order(list, "forward")))
    }

    @Test
    fun onlyTheFirstMatchMovesSoDuplicatesCannotDuplicateRows() {
        val list = listOf(
            r("a", "forward"), r("b", "safe"), r("c", "safe"), r("d", "angle")
        )
        val out = StrategyOrder.order(list, "safe")
        assertEquals(listOf("b", "a", "c", "d"), texts(out))
        assertEquals(list.size, out.size)
    }

    @Test
    fun anEmptyListIsSafe() {
        assertEquals(emptyList<RankedReply>(), StrategyOrder.order(emptyList(), "safe"))
    }
}

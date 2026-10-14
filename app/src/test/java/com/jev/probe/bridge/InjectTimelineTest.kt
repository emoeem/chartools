package com.jev.probe.bridge

import com.jev.probe.core.Msg
import com.jev.probe.core.Provenance
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 注入层的「有界」是这个片子里最容易写错、也最容易拖坏宿主 App 的地方：
 * 无界读取会把对方的聊天页拖死，截半条会把断掉的上下文送进判断。所以这里
 * 逐条钉住 [InjectTimeline.bound] 的边界行为。
 */
class InjectTimelineTest {

    private fun m(text: String, side: String = "other", id: String? = null) =
        Msg(side = side, text = text, id = id)

    @Test
    fun anEmptyTimelineBoundsToNothing() {
        assertTrue(InjectTimeline.bound(emptyList()).isEmpty())
    }

    @Test
    fun aShortTimelineIsKeptWholeInOrder() {
        val raw = listOf(m("一"), m("二"), m("三"))
        assertEquals(listOf("一", "二", "三"), InjectTimeline.bound(raw).map { it.text })
    }

    @Test
    fun onlyTheNewestMessagesAreKept() {
        val raw = (1..50).map { m("m$it") }
        val bounded = InjectTimeline.bound(raw, maxMessages = 40)
        assertEquals(40, bounded.size)
        // 保留的是最新的 40 条（11..50），最新的在最后。
        assertEquals("m11", bounded.first().text)
        assertEquals("m50", bounded.last().text)
    }

    @Test
    fun theCharacterBudgetStopsInsteadOfSkipping() {
        // 每条 10 字，预算 25：只能放下最新两条，更老的一条不再尝试（不跳过）。
        val raw = listOf(m("a".repeat(10)), m("b".repeat(10)), m("c".repeat(10)))
        val bounded = InjectTimeline.bound(raw, maxChars = 25)
        assertEquals(listOf("b".repeat(10), "c".repeat(10)), bounded.map { it.text })
    }

    @Test
    fun oneOversizedMessageStillTravelsSoTheLadderHasSomethingToShow() {
        // 单条就超预算：仍然带上它。空快照会被上层当成「注入层没数据」，
        // 那样反而看不出来是「读到了但太大」。
        val raw = listOf(m("x".repeat(20_000)))
        assertEquals(1, InjectTimeline.bound(raw, maxChars = 100).size)
    }

    @Test
    fun aMessageIsNeverCutInHalf() {
        val raw = listOf(m("a".repeat(100)), m("b".repeat(100)))
        val bounded = InjectTimeline.bound(raw, maxChars = 150)
        assertEquals(1, bounded.size)
        assertEquals(100, bounded[0].text.length)
    }

    @Test
    fun theSnapshotIsMarkedAsInjectedAndBounded() {
        val snapshot = InjectTimeline.snapshot("张三", (1..60).map { m("m$it") })
        assertEquals(Provenance.INJECT, snapshot.provenance)
        assertEquals(InjectTimeline.MAX_MESSAGES, snapshot.messages.size)
        assertEquals("张三", snapshot.title)
    }

    @Test
    fun aBlankOrMissingTitleBecomesNull() {
        assertNull(InjectTimeline.snapshot("   ", listOf(m("hi"))).title)
        assertNull(InjectTimeline.snapshot(null, listOf(m("hi"))).title)
    }

    @Test
    fun theSignatureIsStableForTheSameMessages() {
        val raw = listOf(m("在吗", id = "7"), m("嗯", side = "me", id = "8"))
        assertEquals(InjectTimeline.signature(raw), InjectTimeline.signature(raw))
    }

    @Test
    fun theSignatureChangesWhenTheNewestMessageChanges() {
        val before = listOf(m("在吗", id = "7"))
        val after = listOf(m("在吗", id = "7"), m("？", id = "9"))
        assertFalse(InjectTimeline.signature(before) == InjectTimeline.signature(after))
    }

    @Test
    fun theSignatureOnlyLooksAtTheLastEightMessages() {
        val older = (1..5).map { m("old$it") }
        val tail = (1..8).map { m("t$it") }
        assertEquals(
            InjectTimeline.signature(tail),
            InjectTimeline.signature(older + tail),
        )
    }

    @Test
    fun theSignatureNeverCarriesTheMessageBody() {
        val raw = listOf(m("这是一句不该出现在日志里的私聊", id = "7"))
        val signature = InjectTimeline.signature(raw)
        assertFalse(signature.contains("私聊"))
        assertFalse(signature.contains("这是"))
        // 长度与哈希仍在，够判断「变没变」。
        assertTrue(signature.contains("7:"))
    }

    @Test
    fun messagesWithoutAnIdStillGetAStableSignature() {
        val raw = listOf(m("在吗"), m("嗯", side = "me"))
        assertEquals(InjectTimeline.signature(raw), InjectTimeline.signature(raw))
        assertTrue(InjectTimeline.signature(raw).contains("#other"))
    }
}

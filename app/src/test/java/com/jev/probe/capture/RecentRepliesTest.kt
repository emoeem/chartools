package com.jev.probe.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 跨轮反重复的原料环。2026-10-07 实测聊天记录里整场复读「跪好 / 报数 / 乖」，
 * 根因之一是每条新消息进来的新一轮起草拿到的是空 avoid——上一轮展示过的候选
 * 没有任何机制传下去。这里钉住这个环的行为：记住、去重、封顶、随会话清空。
 */
class RecentRepliesTest {

    @Test
    fun remembersInOrderAndFeedsThemBackAsAvoid() {
        val r = RecentReplies()
        assertTrue(r.isEmpty())
        r.remember(listOf("跪好。现在报数。", "乖，手放膝上。"))
        assertEquals(listOf("跪好。现在报数。", "乖，手放膝上。"), r.asAvoid())
    }

    @Test
    fun aRepeatMovesToTheEndInsteadOfDuplicating() {
        val r = RecentReplies()
        r.remember(listOf("跪好。", "报数。", "跪好。"))
        assertEquals(listOf("报数。", "跪好。"), r.asAvoid())
    }

    @Test
    fun blankEntriesAreIgnored() {
        val r = RecentReplies()
        r.remember(listOf("  ", "", "乖。"))
        assertEquals(listOf("乖。"), r.asAvoid())
    }

    @Test
    fun theRingDropsTheOldestPastItsCap() {
        val r = RecentReplies(maxTexts = 3)
        r.remember(listOf("一", "二", "三"))
        r.remember(listOf("四"))
        assertEquals(listOf("二", "三", "四"), r.asAvoid())
    }

    @Test
    fun longCandidatesAreTruncatedSoTheAvoidBlockStaysSmall() {
        val r = RecentReplies(maxTexts = 3, maxChars = 10)
        r.remember(listOf("跪好别动。现在报数，从一数到十，数完再请安。"))
        // take(10)：跪 好 别 动 。 现 在 报 数 ，
        assertEquals(listOf("跪好别动。现在报数，"), r.asAvoid())
    }

    @Test
    fun leavingTheConversationClearsTheRing() {
        // 会话切换不清空的话，上一个联系人的候选会漏进下一个联系人的 avoid。
        val r = RecentReplies()
        r.remember(listOf("跪好。"))
        r.clear()
        assertTrue(r.isEmpty())
    }
}

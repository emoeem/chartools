package com.jev.probe.capture

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The text heuristics of the OCR paths, now that they are pure functions instead of
 * private methods on the service. `group` itself needs android.graphics.Rect, so it
 * stays covered by the on-device pixel path; what is testable here is the side
 * assignment and the junk stripping, which is where the two classic bugs live — an
 * unknown side silently becoming "other", and a read receipt leaking into the text.
 */
class OcrGroupingTest {

    private fun box(top: Int, bottom: Int, side: String) =
        WeChatBubbles.Box(left = 0, top = top, right = 100, bottom = bottom, side = side)

    @Test
    fun theBubbleCoveringTheLinesMostNamesTheSide() {
        val boxes = listOf(
            box(0, 40, "me"),
            box(30, 90, "other")   // overlaps 30..40 more than the first
        )
        assertEquals("other", OcrGrouping.sideFor(35, 85, boxes))
    }

    @Test
    fun linesNoBubbleCoversStayUnknownInsteadOfBecomingTheOtherPerson() {
        val boxes = listOf(box(0, 40, "me"), box(200, 260, "other"))
        assertEquals(OcrGrouping.SIDE_UNKNOWN, OcrGrouping.sideFor(100, 140, boxes))
        assertEquals(OcrGrouping.SIDE_UNKNOWN, OcrGrouping.sideFor(1, 2, emptyList()))
        assertEquals("?", OcrGrouping.SIDE_UNKNOWN)
    }

    @Test
    fun aTieKeepsTheEarlierBubble() {
        val boxes = listOf(box(0, 100, "me"), box(0, 100, "other"))
        assertEquals("me", OcrGrouping.sideFor(10, 90, boxes))
    }

    @Test
    fun aTrailingReadReceiptIsStripped() {
        assertEquals("在路上了", OcrGrouping.cleanBubbleText("在路上了 已读"))
        assertEquals("在路上了", OcrGrouping.cleanBubbleText("在路上了未读"))
        assertEquals("在路上了", OcrGrouping.cleanBubbleText("  在路上了 已读  "))
    }

    @Test
    fun aTrailingTimestampIsStrippedInBothColonWidths() {
        assertEquals("我到了", OcrGrouping.cleanBubbleText("我到了 11:31"))
        assertEquals("我到了", OcrGrouping.cleanBubbleText("我到了 9：05"))
    }

    @Test
    fun receiptAndTimestampTogetherAreStrippedInOnePass() {
        assertEquals("内容", OcrGrouping.cleanBubbleText("内容 11:31 已读"))
    }

    @Test
    fun aTimeInTheMiddleOfTheSentenceIsContentNotATimestamp() {
        assertEquals("明天11:30见", OcrGrouping.cleanBubbleText("明天11:30见"))
    }

    @Test
    fun aBubbleThatIsNothingButATimestampBecomesEmpty() {
        assertEquals("", OcrGrouping.cleanBubbleText("11:31"))
        assertEquals("", OcrGrouping.cleanBubbleText(""))
        assertEquals("", OcrGrouping.cleanBubbleText("   "))
    }

    @Test
    fun aMessageEndingInATimeAttachedToTextKeepsItsEnding() {
        // 时间粘在正文上没有前导空白：真实消息的结尾不能被当成粘连的时间戳吃掉
        //（「会议改到10:30」曾被截成「会议改到」）。
        assertEquals("会议改到10:30", OcrGrouping.cleanBubbleText("会议改到10:30"))
        assertEquals("截止到9:00", OcrGrouping.cleanBubbleText("截止到9:00"))
    }

    @Test
    fun aTimeSeparatedByWhitespaceIsStillStripped() {
        // 有空白分隔的尾部时间戳照剥——这是飞书粘连回执的形状。
        assertEquals("在开会", OcrGrouping.cleanBubbleText("在开会 14:32"))
    }
}

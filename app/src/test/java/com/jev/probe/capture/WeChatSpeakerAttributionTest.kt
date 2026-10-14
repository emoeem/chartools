package com.jev.probe.capture

import org.junit.Assert.assertEquals
import org.junit.Test

class WeChatSpeakerAttributionTest {

    private fun box(top: Int, bottom: Int, side: String) =
        WeChatBubbles.Box(100, top, 500, bottom, side)

    private fun label(text: String, top: Int, bottom: Int, left: Int = 110) =
        WeChatSpeakerAttribution.Label(text, left, top, left + 80, bottom)

    @Test
    fun oneToOneWithoutSenderLabelsKeepsMeAndOtherCompatibility() {
        val boxes = listOf(box(200, 300, "other"), box(340, 440, "me"))
        assertEquals(
            listOf("other", "me"),
            WeChatSpeakerAttribution.assign(boxes, emptyList())
        )
    }

    @Test
    fun alternatingGroupMembersBecomeNamedMembers() {
        val boxes = listOf(
            box(220, 300, "other"),
            box(360, 440, "other"),
            box(500, 580, "other")
        )
        val labels = listOf(
            label("张三", 190, 210),
            label("李四", 330, 350),
            label("张三", 470, 490)
        )
        assertEquals(
            listOf("member:张三", "member:李四", "member:张三"),
            WeChatSpeakerAttribution.assign(boxes, labels)
        )
    }

    @Test
    fun consecutiveMessagesCanInheritTheSameMember() {
        val boxes = listOf(
            box(220, 300, "other"),
            box(320, 400, "other"),
            box(500, 580, "me")
        )
        val labels = listOf(label("张三", 190, 210))
        assertEquals(
            listOf("member:张三", "member:张三", "me"),
            WeChatSpeakerAttribution.assign(boxes, labels)
        )
    }

    @Test
    fun groupWithUnreadableMemberDoesNotInventANewName() {
        val boxes = listOf(
            box(220, 300, "other"),
            box(500, 580, "other")
        )
        val labels = listOf(
            label("张三", 190, 210),
            label("李四", 450, 470)
        )
        assertEquals(
            listOf("member:张三", "member:李四"),
            WeChatSpeakerAttribution.assign(boxes, labels)
        )
    }

    @Test
    fun groupWithNoSafeLabelForAFarAwayBubbleUsesUnknown() {
        val boxes = listOf(
            box(220, 300, "other"),
            box(500, 580, "other")
        )
        val labels = listOf(label("张三", 190, 210))
        assertEquals(
            listOf("member:张三", "unknown"),
            WeChatSpeakerAttribution.assign(boxes, labels)
        )
    }
}

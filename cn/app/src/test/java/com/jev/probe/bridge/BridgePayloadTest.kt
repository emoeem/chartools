package com.jev.probe.bridge

import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Msg
import com.jev.probe.core.Provenance
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 线上格式的往返。只写一半的契约（注入侧 render 出去、主 App 那边凭印象 parse
 * 回来）要等 S3 真接上才第一次发现对不上，而那时它在另一个进程里 —— 所以这一
 * 份两端都测。
 */
class BridgePayloadTest {

    private fun snap() = ChatSnapshot(
        title = "小可爱",
        messages = listOf(
            Msg("other", "在吗", id = "m1", at = 1_700_000_000_000L, sender = "小可爱"),
            Msg("me", "在"),
        ),
        history = listOf(Msg("other", "昨天那句", id = "h1", at = 1_699_000_000_000L)),
    )

    @Test fun aFullSnapshotSurvivesTheRoundTrip() {
        val back = BridgePayload.parse(BridgePayload.render(snap()))
        assertEquals("小可爱", back?.title)
        assertEquals(2, back?.messages?.size)
        assertEquals("other", back?.messages?.get(0)?.side)
        assertEquals("在吗", back?.messages?.get(0)?.text)
        assertEquals("m1", back?.messages?.get(0)?.id)
        assertEquals(1_700_000_000_000L, back?.messages?.get(0)?.at)
        assertEquals("小可爱", back?.messages?.get(0)?.sender)
        // 第二条没带 id / sender，回来也得是 null 而不是空串。
        assertNull(back?.messages?.get(1)?.id)
        assertNull(back?.messages?.get(1)?.sender)
        assertEquals(0L, back?.messages?.get(1)?.at)
        assertEquals(1, back?.history?.size)
        assertEquals("h1", back?.history?.get(0)?.id)
    }

    /** 来源由**解析方**盖章，不由发送方自称：注入层说自己是 L1 没有意义。 */
    @Test fun whatComesOutOfTheBridgeIsAlwaysMarkedAsInjected() {
        val back = BridgePayload.parse(BridgePayload.render(snap()))
        assertEquals(Provenance.INJECT, back?.provenance)
        assertTrue(back!!.bubbleRects.isEmpty())
    }

    @Test fun anEmptyConversationIsStillAValidSnapshot() {
        val back = BridgePayload.parse("""{"v":1,"title":"群","messages":[]}""")
        assertEquals("群", back?.title)
        assertEquals(0, back?.messages?.size)
        assertEquals(0, back?.history?.size)
    }

    @Test fun noTitleComesBackAsNoTitle() {
        assertNull(BridgePayload.parse("""{"v":1,"messages":[]}""")?.title)
        assertNull(BridgePayload.parse("""{"v":1,"title":"","messages":[]}""")?.title)
        assertNull(BridgePayload.parse("""{"v":1,"title":null,"messages":[]}""")?.title)
    }

    @Test fun aVersionFromTheFutureIsRefusedWhole() {
        assertNull(BridgePayload.parse("""{"v":2,"messages":[]}"""))
        assertNull(BridgePayload.parse("""{"v":99,"messages":[]}"""))
    }

    @Test fun aVersionThatIsMissingOrNonsenseIsRefused() {
        assertNull(BridgePayload.parse("""{"messages":[]}"""))
        assertNull(BridgePayload.parse("""{"v":0,"messages":[]}"""))
        assertNull(BridgePayload.parse("""{"v":"1","messages":[]}"""))
    }

    /** 半条时间线比没有更坏：一条消息字段不全，整段判不可信。 */
    @Test fun oneBadMessageInvalidatesTheWholeSnapshot() {
        assertNull(BridgePayload.parse("""{"v":1,"messages":[{"side":"me","text":"a"},{"side":"other"}]}"""))
        assertNull(BridgePayload.parse("""{"v":1,"messages":[{"side":"sideways","text":"a"}]}"""))
        assertNull(BridgePayload.parse("""{"v":1,"messages":[{"text":"a"}]}"""))
        assertNull(BridgePayload.parse("""{"v":1,"messages":["不是对象"]}"""))
    }

    @Test fun aMissingMessagesArrayIsNotSilentlyAnEmptyOne() {
        assertNull(BridgePayload.parse("""{"v":1,"title":"x"}"""))
    }

    @Test fun garbageIsNotAnEmptySnapshot() {
        assertNull(BridgePayload.parse(null))
        assertNull(BridgePayload.parse(""))
        assertNull(BridgePayload.parse("   "))
        assertNull(BridgePayload.parse("not json"))
        assertNull(BridgePayload.parse("[1,2,3]"))
    }
}

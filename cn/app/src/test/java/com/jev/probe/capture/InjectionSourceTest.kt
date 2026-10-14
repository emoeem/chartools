package com.jev.probe.capture

import com.jev.probe.bridge.BridgeContract
import com.jev.probe.bridge.BridgeLedger
import com.jev.probe.bridge.BridgePayload
import com.jev.probe.core.Msg
import com.jev.probe.core.Provenance
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * 能力阶梯 L1 的取数规则。
 *
 * 这个类唯一要证明的事：**每一种「取不到」都安静地返回 null**，让调用方一个
 * `?:` 落回 L0。任何一条规则写反（比如坏了也返回半条），主采集路径就会拿到
 * 一个空快照、把对话当成「对方什么都没说」。
 */
class InjectionSourceTest {

    private var now = 5_000_000L
    private val tg = "org.telegram.messenger"

    private val good = BridgePayload.render(
        com.jev.probe.core.ChatSnapshot(
            title = "小可爱",
            messages = listOf(Msg("other", "在吗", id = "m1", at = 4_999_000L)),
            history = listOf(Msg("me", "在的", id = "m0", at = 4_998_000L)),
        )
    )

    private fun source(push: BridgeLedger.Push?) = InjectionSource(latest = { push }, now = { now })

    @Test fun theSwitchBeingOffMeansWeDoNotEvenLook() {
        var asked = 0
        val s = InjectionSource(latest = { asked++; null }, now = { now })
        assertNull(s.snapshot(tg, enabled = false))
        assertEquals(0, asked)
    }

    @Test fun anUnknownOrBlankPackageIsNothing() {
        assertNull(source(BridgeLedger.Push(good, now)).snapshot(null, enabled = true))
        assertNull(source(BridgeLedger.Push(good, now)).snapshot("", enabled = true))
        assertNull(source(BridgeLedger.Push(good, now)).snapshot("   ", enabled = true))
    }

    @Test fun aModuleThatNeverPushedIsNothing() {
        assertNull(source(null).snapshot(tg, enabled = true))
    }

    @Test fun aBrokenPayloadIsNothingRatherThanHalfASnapshot() {
        for (bad in listOf("", "   ", "not json", """{"messages":[]}""", """{"v":9,"messages":[]}""",
            """{"v":1,"messages":[{"side":"sideways","text":"a"}]}""")) {
            assertNull("payload=${bad}", source(BridgeLedger.Push(bad, now)).snapshot(tg, enabled = true))
        }
    }

    @Test fun aGoodPayloadComesBackAsTheInjectedLayer() {
        val snap = source(BridgeLedger.Push(good, now)).snapshot(tg, enabled = true)
        assertEquals("小可爱", snap?.title)
        assertEquals(1, snap?.messages?.size)
        assertEquals(1, snap?.history?.size)
        assertEquals(Provenance.INJECT, snap?.provenance)
    }

    /** 超过两分钟的快照在账本那一层就已经是 null 了，这里证明它确实传不过来。 */
    @Test fun aSnapshotTheLedgerAlreadyDroppedStaysDropped() {
        val ledger = BridgeLedger(now = { now })
        val stamp = com.jev.probe.bridge.Stamp("a", 1L, now)
        assertNull(ledger.snapshot(tg, stamp, good))
        now += BridgeContract.MAX_PAYLOAD_AGE_MS + 1
        assertNull(source(ledger.latest(tg)).snapshot(tg, enabled = true))
    }

    /**
     * 模块退出聊天页时推的是**空快照**（撤回上一会话）。它必须落地成 null。
     *
     * 不能返回一个 messages 为空的非 null 快照：`ChatCaptureService` 那一行是
     * `injected ?: adapter.extract(...)`，一个非 null 的空快照会把无障碍的那一份
     * 也挡掉 —— 明明 L0 读得到，却因为注入层「撤回了」而什么都没有，比不撤回更坏。
     */
    @Test fun aRetractedEmptySnapshotFallsBackToTheA11yLayer() {
        val retracted = BridgePayload.render(
            com.jev.probe.core.ChatSnapshot(title = null, messages = emptyList())
        )
        assertNull(source(BridgeLedger.Push(retracted, now)).snapshot(tg, enabled = true))
    }

    /** 但「当前屏没读到、只有屏幕外历史」仍然算有数据，不能被这条规则顺手丢掉。 */
    @Test fun historyAloneStillCountsAsData() {
        val onlyHistory = BridgePayload.render(
            com.jev.probe.core.ChatSnapshot(
                title = "小可爱",
                messages = emptyList(),
                history = listOf(Msg("me", "在的", id = "m0", at = 4_998_000L)),
            )
        )
        val snap = source(BridgeLedger.Push(onlyHistory, now)).snapshot(tg, enabled = true)
        assertEquals(1, snap?.history?.size)
        assertEquals(0, snap?.messages?.size)
    }
}

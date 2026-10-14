package com.jev.probe.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BridgeLedgerTest {

    private var clock = 1_000_000L

    private fun ledger() = BridgeLedger(now = { clock })

    private val tg = "org.telegram.messenger"
    private val wechat = "com.tencent.mm"

    private fun stamp(boot: String = "a", seq: Long = 1L, at: Long = 1_000_000L) = Stamp(boot, seq, at)

    @Test fun anUnscopedPackageIsRefusedOnBothStreams() {
        val l = ledger()
        assertEquals(BridgeContract.R_OUT_OF_SCOPE, l.hello(wechat, stamp(), "1.9"))
        assertEquals(BridgeContract.R_OUT_OF_SCOPE, l.snapshot(wechat, stamp(), "{}"))
        assertNull(l.alive(wechat))
        assertNull(l.latest(wechat))
    }

    @Test fun aMissingPackageIsRefusedRatherThanTreatedAsAScope() {
        val l = ledger()
        assertEquals(BridgeContract.R_OUT_OF_SCOPE, l.hello(null, stamp(), "1.9"))
        assertEquals(BridgeContract.R_OUT_OF_SCOPE, l.snapshot(null, stamp(), "{}"))
    }

    @Test fun theFirstPushIsAcceptedAndReadBack() {
        val l = ledger()
        assertNull(l.snapshot(tg, stamp(), """{"v":1,"messages":[]}"""))
        assertNotNull(l.latest(tg))
        assertEquals("""{"v":1,"messages":[]}""", l.latest(tg)?.payload)
    }

    /**
     * 心跳和快照是两条独立的流。报到用 seq=5 之后，第一条快照仍然可以是 seq=1：
     * 把两条流塞进同一个计数器的话，模块每报一次到都会把自己的第一条快照吃掉。
     */
    @Test fun theHeartbeatAndTheSnapshotsDoNotShareACounter() {
        val l = ledger()
        assertNull(l.hello(tg, stamp(seq = 5L), "1.9"))
        assertNull(l.snapshot(tg, stamp(seq = 1L), "{}"))
        assertNotNull(l.latest(tg))
    }

    @Test fun aStragglerCannotOverwriteANewerSnapshot() {
        val l = ledger()
        assertNull(l.snapshot(tg, stamp(seq = 2L), """{"v":1,"messages":[]}"""))
        assertEquals(BridgeContract.R_STALE, l.snapshot(tg, stamp(seq = 1L), """{"v":1,"messages":[]}"""))
        assertEquals("""{"v":1,"messages":[]}""", l.latest(tg)?.payload)
    }

    @Test fun aRestartedModuleIsNotSilencedByItsOldCounter() {
        val l = ledger()
        assertNull(l.snapshot(tg, stamp(boot = "a", seq = 99L, at = 1_000_000L), "old"))
        assertNull(l.snapshot(tg, stamp(boot = "b", seq = 1L, at = 1_010_000L), "new"))
        assertEquals("new", l.latest(tg)?.payload)
    }

    /** 超限整条拒收，不是截断：半条时间线比没有更坏。 */
    @Test fun anOverlongPayloadIsRefusedWhole() {
        val l = ledger()
        val tooLong = "x".repeat(BridgeContract.MAX_PAYLOAD_CHARS + 1)
        assertEquals(BridgeContract.R_TOO_LARGE, l.snapshot(tg, stamp(), tooLong))
        assertNull(l.latest(tg))
        // 边界上的一条仍然收：拒收线是「超过」，不是「达到」。
        val atLimit = "x".repeat(BridgeContract.MAX_PAYLOAD_CHARS)
        assertNull(l.snapshot(tg, stamp(seq = 2L), atLimit))
        assertNotNull(l.latest(tg))
    }

    @Test fun anAbsentPayloadIsABadArgumentNotAnEmptySnapshot() {
        val l = ledger()
        assertEquals(BridgeContract.R_BAD_ARGS, l.snapshot(tg, stamp(), null))
    }

    @Test fun anOldSnapshotIsNotShownAtAll() {
        val l = ledger()
        assertNull(l.snapshot(tg, stamp(at = clock), "{}"))
        assertNotNull(l.latest(tg))
        clock += BridgeContract.MAX_PAYLOAD_AGE_MS + 1
        assertNull(l.latest(tg))
    }

    @Test fun aStaleHeartbeatIsNotAliveEither() {
        val l = ledger()
        assertNull(l.hello(tg, stamp(at = clock), "1.9"))
        assertNotNull(l.alive(tg))
        clock += BridgeContract.MAX_PAYLOAD_AGE_MS + 1
        assertNull(l.alive(tg))
    }

    /** 模块没带时间戳（at=0）时用本机时钟兜底，否则那条会立刻被判过期。 */
    @Test fun aModuleWithoutAWallClockFallsBackToOurs() {
        val l = ledger()
        assertNull(l.hello(tg, Stamp("a", 1L, 0L), "1.9"))
        assertEquals(clock, l.alive(tg)?.at)
    }

    @Test fun theReportedVersionIsBounded() {
        val l = ledger()
        assertNull(l.hello(tg, stamp(), "v".repeat(200)))
        assertEquals(64, l.alive(tg)?.version?.length)
    }

    @Test fun forgettingAPackageDropsBothStreams() {
        val l = ledger()
        assertNull(l.hello(tg, stamp(), "1.9"))
        assertNull(l.snapshot(tg, stamp(), "{}"))
        l.forget(tg)
        assertNull(l.alive(tg))
        assertNull(l.latest(tg))
    }

    @Test fun theDefaultScopeIsTheOneTheModuleIsAllowedInto() {
        val l = BridgeLedger(now = { clock })
        assertNull(l.hello(HookTargets.SCOPED.first(), stamp(), "1.9"))
        assertTrue(l.alive(HookTargets.SCOPED.first()) != null)
    }
}

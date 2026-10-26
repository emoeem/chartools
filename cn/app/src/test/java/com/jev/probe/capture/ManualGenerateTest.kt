package com.jev.probe.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「手动生成」判定的行为锁。
 *
 * 这套用例守的不是某个字符串，而是**每一条路都有可见结果**这条不变量：
 * 旧代码在快照为空、token 失效、上一轮还在跑时全是静默 return，用户在 QQ 里
 * 看到的正是"点了没反应"。
 */
class ManualGenerateTest {

    private fun decide(
        enabled: Boolean = true,
        hasKey: Boolean = true,
        hasSnapshot: Boolean = false,
        canCapture: Boolean = false,
        busyAgeMs: Long? = null,
        forceGraceMs: Long = ManualGenerate.FORCE_GRACE_MS,
    ) = ManualGenerate.decide(enabled, hasKey, hasSnapshot, canCapture, busyAgeMs, forceGraceMs)

    @Test
    fun masterSwitchOffExplainsBeforeAnythingElse() {
        val d = decide(enabled = false, hasSnapshot = true, busyAgeMs = 0L)
        assertTrue(d is ManualGenerate.Decision.Explain)
        d as ManualGenerate.Decision.Explain
        assertTrue(d.reason.contains("总开关"))
        assertFalse("是可行动的原因，不该当过程提示", d.transient)
    }

    @Test
    fun missingKeyExplainsHowToFix() {
        val d = decide(hasKey = false, hasSnapshot = true)
        assertTrue(d is ManualGenerate.Decision.Explain)
        assertTrue((d as ManualGenerate.Decision.Explain).reason.contains("密钥"))
    }

    @Test
    fun busyRoundInsideGraceIsATransientHintNotAnError() {
        val d = decide(hasSnapshot = true, busyAgeMs = 1_000L, forceGraceMs = 8_000L)
        assertTrue(d is ManualGenerate.Decision.Explain)
        d as ManualGenerate.Decision.Explain
        assertTrue("双击不该把正常的一轮顶成错误卡", d.transient)
        assertTrue(d.reason.contains("正在生成"))
    }

    @Test
    fun busyRoundPastGraceTakesOverAndRegenerates() {
        val age = 9_000L
        val d = decide(hasSnapshot = true, busyAgeMs = age, forceGraceMs = 8_000L)
        assertEquals(ManualGenerate.Decision.Regenerate, d)
        assertTrue(ManualGenerate.shouldForceTakeOver(age, 8_000L))
    }

    @Test
    fun graceBoundaryCountsAsStuck() {
        // >= 即接管：卡在边界上那一刻再点一次，用户期待的是"重来"，不是"再等等"。
        assertEquals(ManualGenerate.Decision.Regenerate,
            decide(hasSnapshot = true, busyAgeMs = 8_000L, forceGraceMs = 8_000L))
        assertTrue(ManualGenerate.shouldForceTakeOver(8_000L, 8_000L))
        assertFalse(ManualGenerate.shouldForceTakeOver(7_999L, 8_000L))
        assertFalse("不忙不该被当成卡死", ManualGenerate.shouldForceTakeOver(null, 8_000L))
    }

    @Test
    fun snapshotPresentRegenerates() {
        assertEquals(ManualGenerate.Decision.Regenerate, decide(hasSnapshot = true))
    }

    @Test
    fun noSnapshotButCapturableCapturesFirst() {
        assertEquals(ManualGenerate.Decision.CaptureFirst,
            decide(hasSnapshot = false, canCapture = true))
    }

    @Test
    fun nothingToWorkWithSaysSoInsteadOfDoingNothing() {
        val d = decide(hasSnapshot = false, canCapture = false)
        assertTrue(d is ManualGenerate.Decision.Explain)
        d as ManualGenerate.Decision.Explain
        assertFalse(d.transient)
        assertTrue("要指到下一步，而不是一句'失败'", d.reason.contains("截屏识别"))
    }

    @Test
    fun captureIsOnlyPreferredWhenThereIsNoSnapshot() {
        // 有快照时永远先走重起草：截图比读节点树贵，也没必要。
        assertEquals(ManualGenerate.Decision.Regenerate, decide(hasSnapshot = true, canCapture = true))
    }
}

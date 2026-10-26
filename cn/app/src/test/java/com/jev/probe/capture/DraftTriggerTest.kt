package com.jev.probe.capture

import com.jev.probe.core.Analysis
import com.jev.probe.core.Choice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 首轮「先判后写」的触发语义。真正的服务编排跑在 Android 的 Handler 上，
 * JVM 测不到；这里钉住的是它的全部决策规则：fire 恰好成功一次、判断优先于
 * 超时、盲写不带判断。语义错了，服务层的接线再对也没用。
 */
class DraftTriggerTest {

    private fun judgment() = Analysis(
        trueIntent = Choice("casual_chat", 0.8, emptyMap()),
        dangerLevel = null, sheNeeds = null, shouldReplyNow = null, bestAction = null,
        tensionResolved = null, literalQuestion = null,
        rankedReplies = emptyList(), latencyMs = 0
    )

    @Test
    fun judgmentArrivingFirstCarriesIntoTheDraft() {
        val t = DraftTrigger()
        val j = judgment()
        assertTrue(t.fireWithJudgment(j))
        assertTrue(t.started)
        assertEquals(j, t.judgment)
        // 第二个触发点（超时兜底）必须被挡掉：一轮只起草一次。
        assertFalse(t.fireBlind())
        assertEquals(j, t.judgment)
    }

    @Test
    fun aTimeoutFiresBlindAndALateJudgmentIsDropped() {
        val t = DraftTrigger()
        assertTrue(t.fireBlind())
        assertTrue(t.started)
        assertNull(t.judgment)
        // 判断 3 秒后才回来：起草已经盲写发出，这轮不重来——重写会重复候选。
        assertFalse(t.fireWithJudgment(judgment()))
        assertNull(t.judgment)
    }

    @Test
    fun aJudgmentWithAnErrorIsPassedThroughAsBlind() {
        // 调用方约定：判断自身带 error 时换成 null 再传（盲写等价）。触发器
        // 只管次序——但这条约定钉在这里，服务层忘了会表现为「判断失败的那轮
        // 起草也失败」，那正是要避免的。
        val t = DraftTrigger()
        assertTrue(t.fireWithJudgment(null))
        assertTrue(t.started)
        assertNull(t.judgment)
    }
}

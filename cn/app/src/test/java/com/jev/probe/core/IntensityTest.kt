package com.jev.probe.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「自动」档的判断结果 → 档位映射。原则：宁可保守——自动档错的方向如果是
 * 「该收的时候加码」，伤害最大；所以所有偏冷信号都压到收着，只有「双方约好的
 * 角色场景且局势轻松」才自动加码。
 */
class IntensityTest {

    private fun judgment(
        intent: String? = null,
        danger: Double? = null,
        shouldReplyNow: Double? = null
    ) = Analysis(
        trueIntent = intent?.let { Choice(it, 0.9, emptyMap()) },
        dangerLevel = danger?.let { Score(it, 0.9, 9) },
        sheNeeds = null, shouldReplyNow = shouldReplyNow, bestAction = null,
        tensionResolved = null, literalQuestion = null,
        rankedReplies = emptyList(), latencyMs = 0
    )

    @Test
    fun noJudgmentStaysNatural() {
        assertEquals(Intensity.NATURAL, Intensity.auto(null))
    }

    @Test
    fun highTensionSoftens() {
        assertEquals(Intensity.SOFT, Intensity.auto(judgment(danger = 6.0)))
        assertEquals(Intensity.SOFT, Intensity.auto(judgment(danger = 9.0)))
        // 紧张但没过线时不压档。
        assertEquals(Intensity.NATURAL, Intensity.auto(judgment(danger = 5.0)))
    }

    @Test
    fun ventingAngerSoftensEvenAtLowTension() {
        // 对方在发泄情绪时，加码等于火上浇油——这条不看紧张度分数。
        assertEquals(Intensity.SOFT, Intensity.auto(judgment(intent = "vent_anger", danger = 2.0)))
    }

    @Test
    fun noSubstanceYetSoftens() {
        assertEquals(Intensity.SOFT, Intensity.auto(judgment(shouldReplyNow = 0.2)))
        assertEquals(Intensity.NATURAL, Intensity.auto(judgment(shouldReplyNow = 0.8)))
    }

    @Test
    fun anAgreedSceneAtLowTensionAdvances() {
        assertEquals(Intensity.FORWARD, Intensity.auto(judgment(intent = "intimate_roleplay", danger = 2.0)))
        // 场景还在但局势真的紧了，推进同样要停。
        assertEquals(Intensity.SOFT, Intensity.auto(judgment(intent = "intimate_roleplay", danger = 6.0)))
    }

    @Test
    fun labelsCoverEveryEntry() {
        Intensity.entries.forEach { assertTrue(it.label.isNotBlank()) }
    }

    @Test
    fun resolveKeepsManualChoicesAndMapsAuto() {
        // 手选原样、自动按判断映射——system 策略契约和 user 档位块共用这一个
        // 解析，各算各的就会出现「必须推进」和「不要推进」同场。
        val tense = judgment(danger = 7.0)
        assertEquals(Intensity.SOFT, Intensity.resolve(Intensity.AUTO, tense))
        assertEquals(Intensity.SOFT, Intensity.resolve(Intensity.SOFT, null))
        assertEquals(Intensity.FORWARD, Intensity.resolve(Intensity.FORWARD, tense))
        assertEquals(Intensity.NATURAL, Intensity.resolve(Intensity.AUTO, null))
    }
}

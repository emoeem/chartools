package com.jev.probe.core.kb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 库里每条人设那一行副标题。
 *
 * 它要回答的是**「这条套用之后会不会真的有变化」**，因为认不出键是静默的：
 * 一张写成散文的卡在列表里看起来完全正常，套用后回复照旧，用户会以为功能坏了。
 */
class PersonaStatusShortTest {

    @Test
    fun aStructuredCardListsWhatWillActuallyTakeEffect() {
        val card = PersonaCard.parse(
            "称呼：王总\n主题：销售\n语气：短句\n硬边界：稳赚、保证收益\n示例：\n我：方案改好了"
        )
        val line = PersonaStatus.short(card)
        assertTrue(line, line.contains("主题「销售」"))
        assertTrue(line, line.contains("称呼「王总」"))
        // 硬边界按「条数」报，不把关键词铺满一行 —— 关键词是给闸门用的，不是标题。
        assertTrue(line, line.contains("硬边界 2 条"))
        assertTrue(line, line.contains("示例 1 句"))
        assertFalse("副标题不该是警告", line.startsWith("⚠"))
    }

    @Test
    fun freeTextIsCalledOutAsNotTakingEffect() {
        val line = PersonaStatus.short(PersonaCard.parse("说话短一点，别太客气"))
        assertTrue(line, line.startsWith("⚠"))
        assertTrue(line, line.contains("不生效"))
    }

    @Test
    fun anEmptyCardIsNotPretendedToBeAPersona() {
        val line = PersonaStatus.short(PersonaCard.parse("   "))
        assertTrue(line, line.contains("空"))
    }

    @Test
    fun theRegisterSwitchIsSurfacedBecauseItLiftsThePromptBans() {
        val open = PersonaStatus.short(PersonaCard.parse("主题：网调\n语域：亲密"))
        assertTrue(open, open.contains("语域放开"))
        val closed = PersonaStatus.short(PersonaCard.parse("主题：网调\n语气：短句"))
        assertFalse(closed, closed.contains("语域放开"))
    }

    @Test
    fun aRecognisedButContentlessCardSaysSoInsteadOfShowingNothing() {
        // 「情境」是认得的键，但它不会改变称呼/主题/边界/示例，副标题里也就没什么可报的。
        // 这一格空白容易被当成「卡片是坏的」，所以说一句，而不是留白。
        val line = PersonaStatus.short(PersonaCard.parse("情境：隔着屏幕"))
        assertEquals("键都认出来了，但没有实质内容（只有 补充 那几行）", line)
    }
}

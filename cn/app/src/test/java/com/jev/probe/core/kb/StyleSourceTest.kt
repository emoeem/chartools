package com.jev.probe.core.kb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 守住「哪段正文进提示词」这件事。
 *
 * 这组测试的重点不是 [StyleSource] 自己好不好看，而是它和**改造前那行代码**
 * 逐字等价：起草与复查原来各写了一遍
 * `persona?.trim().takeUnless { isNullOrBlank() } ?: style`，现在两处都走这里。
 * 等价性用 [legacy] 当对照物写死 —— 以后谁想「顺手 trim 一下专家正文」，
 * 提示词的字节会变，这里立刻红。
 */
class StyleSourceTest {

    /** 改造前的原文表达式，只作对照，不参与生产。 */
    private fun legacy(expert: String, persona: String?): String =
        persona?.trim().takeUnless { it.isNullOrBlank() } ?: expert

    private val cases: List<Pair<String, String?>> = listOf(
        "专家正文" to null,
        "专家正文" to "",
        "专家正文" to "   ",
        "专家正文" to "\n\t ",
        "专家正文" to "对这个人客气点",
        "专家正文" to "  对这个人客气点  ",
        "" to null,
        "" to "",
        "" to "只有联系人",
        "   " to null,
        "   " to "",
        "带尾随空格的正文 " to null,
        " 带前导空格的正文" to null,
        "多行\n正文" to null,
        "含\u001e分隔符" to null
    )

    @Test
    fun `text 与改造前那行代码逐字等价`() {
        for ((expert, persona) in cases) {
            assertEquals(
                "expert=[$expert] persona=[$persona]",
                legacy(expert, persona),
                StyleSource.resolve(expert, persona).text
            )
        }
    }

    @Test
    fun `专家正文不 trim`() {
        // 目录里有正文带尾随空格；trim 一下提示词就变了，而「换了风格回复不变」
        // 是最难查的一类回归 —— 它不报错，只是静默等价。
        assertEquals("带尾随空格的正文 ", StyleSource.resolve("带尾随空格的正文 ", null).text)
        assertEquals(" 带前导空格的正文", StyleSource.resolve(" 带前导空格的正文", null).text)
    }

    @Test
    fun `联系人专用人设压过专家正文`() {
        val r = StyleSource.resolve("专家正文", "对这个人客气点")
        assertEquals("对这个人客气点", r.text)
        assertEquals(StyleSource.From.CONTACT, r.from)
        assertTrue(r.shadowed)
        assertEquals("专家正文", r.shadowedExpert)
    }

    @Test
    fun `联系人写的是空白时回落到专家正文`() {
        for (blank in listOf("", "   ", "\n\t ")) {
            val r = StyleSource.resolve("专家正文", blank)
            assertEquals("[$blank]", "专家正文", r.text)
            assertEquals(StyleSource.From.EXPERT, r.from)
            assertFalse(r.shadowed)
        }
    }

    @Test
    fun `联系人那句话会被 trim`() {
        assertEquals("对这个人客气点", StyleSource.resolve("专家正文", "  对这个人客气点  ").text)
    }

    @Test
    fun `两边都空时没有人设`() {
        val r = StyleSource.resolve("", null)
        assertEquals("", r.text)
        assertEquals(StyleSource.From.NONE, r.from)
        assertFalse(r.shadowed)
    }

    @Test
    fun `没有专家正文时谈不上被盖住`() {
        // 用户没套用过专家，只在联系人里写了人设：这不是「专家没生效」。
        val r = StyleSource.resolve("", "只写了联系人")
        assertEquals("只写了联系人", r.text)
        assertFalse(r.shadowed)
        assertEquals("", r.shadowedExpert)
    }

    @Test
    fun `被盖住的专家正文原样保留`() {
        // 界面只拿它判断「有没有」，不改写、不进提示词。
        val r = StyleSource.resolve(" 专家 ", "联系人")
        assertEquals(" 专家 ", r.shadowedExpert)
        assertEquals("联系人", r.text)
    }

    @Test
    fun `解析结果能直接喂给人设卡`() {
        // 下游是 PersonaCard.parse(text)：解析不能抛，结构化与否都不影响消费。
        for ((expert, persona) in cases) {
            val r = StyleSource.resolve(expert, persona)
            val card = PersonaCard.parse(r.text)
            assertEquals(r.text, card.raw)
        }
    }
}

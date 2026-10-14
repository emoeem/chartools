package com.jev.probe.core.kb.extract

import com.jev.probe.core.retrieve.LexicalSearch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The repairs in [TextNorm] are not cosmetic — each one is the difference
 * between a note that can be found and a note that cannot.
 */
class TextNormTest {

    // ---------- the OCR path ----------

    @Test
    fun `spaces the OCR puts between Han characters are removed`() {
        // What the scan path actually produced. The gap before the colon stays:
        // it is Han-to-punctuation, not Han-to-Han, and punctuation is not part
        // of any bigram either way.
        assertEquals(
            "这篇教程只写给一种男性主导 :",
            TextNorm.canonical("这 篇 教 程 只 写 给 一 种 男 性 主 导 :")
        )
    }

    @Test
    fun `the repaired OCR text tokenises into real bigrams`() {
        // The point of the repair: before it, every bigram was destroyed by a
        // space and the note could never be retrieved by any query.
        assertTrue(LexicalSearch.tokenize("这 篇 教 程").isEmpty())
        assertEquals(
            listOf("这篇", "篇教", "教程"),
            LexicalSearch.tokenize(TextNorm.canonical("这 篇 教 程"))
        )
    }

    @Test
    fun `spaces that are real layout survive`() {
        assertEquals("Write a Python script", TextNorm.canonical("Write a Python script"))
        // Space around a digit is layout; space *between* two Han characters is
        // not, so only the latter goes.
        assertEquals("第 1 章开始", TextNorm.canonical("第 1 章 开始"))
        // A space before a newline is a line break, not an OCR gap.
        assertEquals("第一段  \n第二段", TextNorm.canonical("第一段  \n第二段"))
        // Newlines are never treated as removable gaps.
        assertEquals("网调\n教程", TextNorm.canonical("网 调\n教 程"))
    }

    // ---------- the radical / compatibility path ----------

    @Test
    fun `Kangxi radicals become the characters people type`() {
        // U+2F79 KANGXI RADICAL NET, not U+7F51 网. PDF text layers emit these.
        val radical = "\u2F79调"
        assertEquals("网调", TextNorm.canonical(radical))
        assertTrue(LexicalSearch.tokenize(radical).isEmpty())
        assertEquals(listOf("网调"), LexicalSearch.tokenize(TextNorm.canonical(radical)))
    }

    @Test
    fun `compatibility ideographs and full-width latin fold too`() {
        assertEquals("神", TextNorm.canonical("\uFA19"))       // U+FA19 神 compatibility form
        assertEquals("123", TextNorm.canonical("１２３"))
        assertEquals("abc", TextNorm.canonical("ａｂｃ"))
    }

    @Test
    fun `full-width punctuation is deliberately left alone`() {
        // It is not part of any bigram, so folding it would only make Chinese
        // prose render wrong in the knowledge list.
        val punct = "，。：；？！（）“”"
        assertEquals(punct, TextNorm.canonical(punct))
    }

    // ---------- shape guarantees ----------

    @Test
    fun `plain text is returned unchanged`() {
        val plain = "这是一段本来就没有问题的中文，不需要任何修改。\n第二行也一样。"
        assertEquals(plain, TextNorm.canonical(plain))
    }

    @Test
    fun `running it twice changes nothing more`() {
        val messy = "⼀ 个 测 试 \u2F79 调 １２３ ａｂｃ"
        val once = TextNorm.canonical(messy)
        assertEquals(once, TextNorm.canonical(once))
    }

    @Test
    fun `empty and whitespace-only input is safe`() {
        assertEquals("", TextNorm.canonical(""))
        assertEquals("   ", TextNorm.canonical("   "))
        assertEquals("\n\n", TextNorm.canonical("\n\n"))
    }
}

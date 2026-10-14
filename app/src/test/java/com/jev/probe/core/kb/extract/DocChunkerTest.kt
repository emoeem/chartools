package com.jev.probe.core.kb.extract

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The chunker is the only thing standing between a long document and a knowledge
 * note, so its contract is simple and tested hard: paragraphs stay whole when
 * they fit, no chunk is ever longer than the budget, and nothing is silently
 * dropped on the way through.
 */
class DocChunkerTest {

    private val budget = 1200

    @Test
    fun `short paragraphs are packed into one chunk`() {
        val text = "第一段。\n第二段。\n第三段。"
        assertEquals(listOf("第一段。\n第二段。\n第三段。"), DocChunker.split(text, budget))
    }

    @Test
    fun `paragraphs are split once the budget would be exceeded`() {
        // 5 x 300 characters: exactly three fit per 1200 character chunk.
        val paragraph = "a".repeat(299) + "。"
        val text = (1..5).joinToString("\n") { paragraph }
        val chunks = DocChunker.split(text, budget)

        assertEquals(2, chunks.size)
        assertEquals(3, chunks[0].count { it == '。' })
        assertEquals(2, chunks[1].count { it == '。' })
        assertTrue(chunks.all { it.length <= budget })
    }

    @Test
    fun `blank paragraphs and stray whitespace do not create empty chunks`() {
        val text = "\n\n   \nFirst\n\n\n\t\nSecond\n   \n"
        assertEquals(listOf("First\nSecond"), DocChunker.split(text, budget))
    }

    @Test
    fun `an over long paragraph is broken at a sentence end`() {
        // 10 sentences of 200 characters each = 2000, over the 1200 budget.
        val sentence = "x".repeat(199) + "。"
        val paragraph = sentence.repeat(10)
        val chunks = DocChunker.split(paragraph, budget)

        assertTrue(chunks.size >= 2)
        // Every break lands after a sentence, so no sentence is cut in half.
        assertTrue(chunks.dropLast(1).all { it.endsWith("。") })
        assertTrue(chunks.all { it.length <= budget })
        // Nothing was lost.
        assertEquals(paragraph, chunks.joinToString(""))
    }

    @Test
    fun `a paragraph with no punctuation is still hard wrapped inside the budget`() {
        val paragraph = "z".repeat(budget * 2 + 37)
        val chunks = DocChunker.split(paragraph, budget)

        assertTrue(chunks.all { it.length <= budget })
        assertEquals(paragraph, chunks.joinToString(""))
    }

    @Test
    fun `every chunk respects a small budget`() {
        val text = "一二三四五六七八九十".repeat(200)
        val chunks = DocChunker.split(text, 64)
        assertTrue(chunks.isNotEmpty())
        assertTrue(chunks.all { it.length <= 64 })
    }

    @Test
    fun `text with nothing to keep produces nothing`() {
        assertEquals(emptyList<String>(), DocChunker.split("", budget))
        assertEquals(emptyList<String>(), DocChunker.split("\n\n   \n\t\n", budget))
    }

    @Test
    fun `a non positive budget is refused rather than looped forever`() {
        assertEquals(emptyList<String>(), DocChunker.split("some text", 0))
        assertEquals(emptyList<String>(), DocChunker.split("some text", -5))
    }

    @Test
    fun `a paragraph that exactly fills the budget is one chunk`() {
        val paragraph = "b".repeat(budget)
        assertEquals(listOf(paragraph), DocChunker.split(paragraph, budget))
    }
}

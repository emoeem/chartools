package com.jev.probe.core.retrieve

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * BM25 over a knowledge base that is mostly Chinese.
 *
 * The regression this guards is the one the retrieval survey measured: a
 * whitespace/`\w+` tokenizer produces zero query terms for Chinese, so every
 * document scores exactly 0.0 and `search` silently returns storage order. Two
 * of four "hits" looked right that way. Character bigrams are the fix.
 */
class LexicalSearchTest {

    // ---------- tokenize ----------

    @Test
    fun chineseBecomesOverlappingBigrams() {
        assertEquals(listOf("翻译", "译这", "这段", "段文"), LexicalSearch.tokenize("翻译这段文"))
    }

    @Test
    fun latinIsLowercasedWords() {
        assertEquals(listOf("write", "a", "python", "script"), LexicalSearch.tokenize("Write a Python script"))
    }

    @Test
    fun mixedTextKeepsBothSidesAndDropsPunctuation() {
        // A lone leading Han character produces no bigram; the latin runs survive.
        assertEquals(
            listOf("go", "写一", "一个", "cli"),
            LexicalSearch.tokenize("用Go写一个CLI!")
        )
    }

    @Test
    fun aLoneHanziYieldsNoTerm() {
        // One character is not a unit of meaning; emitting it would let 的/了
        // match everything.
        assertTrue(LexicalSearch.tokenize("的").isEmpty())
    }

    @Test
    fun blankTextYieldsNoTerms() {
        assertTrue(LexicalSearch.tokenize("  \n\t ").isEmpty())
    }

    // ---------- search ----------

    private val docs = listOf(
        "翻译助手: 当用户需要把一段中文翻译成英文时使用。",
        "会议纪要: 把会议录音整理成要点。",
        "Code review: 检查 diff 里的 bug。",
        "写周报: 汇总本周工作。",
        "PDF 摘要: 把长文档压缩成要点。",
        "Emoji 风格: 回复里多用表情。"
    )

    @Test
    fun chineseQueryActuallyScores() {
        val hits = LexicalSearch.search("帮我把这段话翻译一下", docs, k = 3)
        assertTrue("中文查询必须给出非零分", hits.isNotEmpty())
        assertTrue("最高分必须 > 0", hits[0].score > 0.0)
        assertEquals("第一条是翻译助手", 0, hits[0].index)
    }

    @Test
    fun englishQueryMatchesTheEnglishDocument() {
        val hits = LexicalSearch.search("code review", docs, k = 3)
        assertTrue(hits.isNotEmpty())
        assertEquals(2, hits[0].index)
    }

    @Test
    fun rankingIsByScoreNotStorageOrder() {
        // The PDF doc sits fourth; it must still come first for a PDF question.
        val hits = LexicalSearch.search("这是一个很长的 PDF 文档，帮我读一读", docs, k = 6)
        assertTrue(hits.isNotEmpty())
        assertEquals(4, hits[0].index)
    }

    @Test
    fun noOverlapReturnsNothingRatherThanEverything() {
        assertTrue(LexicalSearch.search("zzzzz", docs, k = 5).isEmpty())
    }

    @Test
    fun minScoreFiltersWeakHits() {
        val all = LexicalSearch.search("会议", docs, k = 5)
        val strict = LexicalSearch.search("会议", docs, k = 5, minScore = 1e9)
        assertTrue(all.isNotEmpty())
        assertTrue(strict.isEmpty())
    }

    @Test
    fun aShortQueryOfStopCharactersStillSearches() {
        // 会议 ("meeting") survives the function-character filter even though 会
        // is also the modal "can": it is the query's only bigram, and a false
        // positive on a two-character query means answering "nothing matches".
        val hits = LexicalSearch.search("会议", docs, k = 1)
        assertEquals(1, hits[0].index)
    }

    @Test
    fun aLongQueryThatIsAllFillerMatchesNothing() {
        // Eight bigrams, every one of them grammar. There is nothing to search
        // for, and returning storage order would look like a result.
        assertTrue(LexicalSearch.search("的了吗呢吧啊哦嗯", docs, k = 5).isEmpty())
    }

    @Test
    fun kCapsTheResultCount() {
        val hits = LexicalSearch.search("翻译 会议 代码 周报 PDF", docs, k = 2)
        assertTrue(hits.size <= 2)
    }

    @Test
    fun emptyCorpusIsEmpty() {
        assertTrue(LexicalSearch.search("翻译", emptyList(), k = 3).isEmpty())
    }
}

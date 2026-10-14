package com.jev.probe.core.kb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 4.3: history de-duplication. The old rule was an exact `side + " " + text`
 * compare, which OCR defeats on its own — the same message read twice comes back
 * one character different, so both copies were kept and both went into the
 * prompt. The replacement is a bigram Dice coefficient.
 */
class ContextBuilderTest {

    @Test
    fun theSameLineIsIdenticalWhateverTheWhitespace() {
        assertEquals(1.0, ContextBuilder.similarity("明天下午三点见", "明天下午三点见"), 1e-9)
        assertEquals(1.0, ContextBuilder.similarity("hello there", "hello   there"), 1e-9)
    }

    /** The case that motivated the change: one misread character. */
    @Test
    fun oneMisreadCharacterStillCountsAsTheSameMessage() {
        val onScreen = "明天下午三点在老地方见，别迟到"
        val ocrReread = "明天下午三点在老地方见，别迟到了"
        val score = ContextBuilder.similarity(onScreen, ocrReread)
        assertTrue("jitter scored $score", score >= 0.8)
    }

    @Test
    fun unrelatedLinesAreNotFoldedTogether() {
        assertTrue(ContextBuilder.similarity("明天下午三点见", "我肚子好饿先吃饭了") < 0.8)
        assertTrue(ContextBuilder.similarity("好", "我肚子好饿先吃饭了") < 0.8)
        assertTrue(ContextBuilder.similarity("", "有内容") < 0.8)
    }

    /** A blank line must not silently swallow every other blank line's neighbour. */
    @Test
    fun anEmptyLineMatchesNothingNonEmpty() {
        assertEquals(0.0, ContextBuilder.similarity("", "明天见"), 1e-9)
    }
}

package com.jev.probe.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WeChatVoiceTextTest {
    @Test
    fun recognizesCommonVoiceDurationLabels() {
        listOf("3\"", "12″", " 8 秒 ", "5s", "14''").forEach {
            assertTrue(it, WeChatVoiceText.isDurationLabel(it))
        }
    }

    @Test
    fun doesNotClassifyTranscriptOrPlainNumbersAsDuration() {
        listOf("你好，听得到吗", "12", "12 秒后见", "").forEach {
            assertFalse(it, WeChatVoiceText.isDurationLabel(it))
        }
    }

    @Test
    fun removesDurationWhenOcrReadsItBesideTheTranscript() {
        assertTrue(WeChatVoiceText.isDurationLabel("6\""))
        assertFalse(WeChatVoiceText.isDurationLabel("6\" 你好，听得到吗"))
        assertEquals("你好，听得到吗", WeChatVoiceText.stripDurationLabels("6\" 你好，听得到吗"))
    }

    @Test
    fun blocksStaleAnalysisOnlyForAnUntranscribedLatestIncomingVoice() {
        assertTrue(WeChatVoiceText.shouldBlockAnalysis(true, true, false))
        assertFalse(WeChatVoiceText.shouldBlockAnalysis(true, true, true))
        assertFalse(WeChatVoiceText.shouldBlockAnalysis(false, true, false))
        assertFalse(WeChatVoiceText.shouldBlockAnalysis(true, false, false))
    }
}

package com.jev.probe.capture

import com.jev.probe.core.Analysis
import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Intensity
import com.jev.probe.core.Msg
import com.jev.probe.core.kb.ChatContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptureConversationStateTest {

    @Test
    fun resetConversationClearsRoundStateAndMessageGates() {
        val state = CaptureConversationState()
        state.lastSignature = "signature"
        state.activePkg = "chat.app"
        state.analyzing = true
        state.regenerating = true
        state.gate.observe(listOf(Msg("other", "seen before")))
        state.recentReplies.remember(listOf("previous suggestion"))
        state.lastIntensity = Intensity.FORWARD
        state.lastAnalyzed = ChatSnapshot("Contact", listOf(Msg("other", "hello")))
        state.lastContext = ChatContext(null, emptyList(), emptyList())
        state.lastJudgment = Analysis(null, null, null, null, null, null, null, emptyList(), 0)
        state.lastOcrSignature = "ocr-signature"

        state.resetConversation()

        assertNull(state.activePkg)
        assertFalse(state.analyzing)
        assertFalse(state.regenerating)
        assertEquals("", state.lastSignature)
        assertEquals("", state.lastOcrSignature)
        assertEquals(Intensity.AUTO, state.lastIntensity)
        assertNull(state.lastAnalyzed)
        assertNull(state.lastContext)
        assertNull(state.lastJudgment)
        assertTrue(state.recentReplies.isEmpty())
        assertEquals(
            NewMessageGate.Verdict.FIRST_LOOK,
            state.gate.observe(listOf(Msg("other", "seen before")))
        )
    }
}

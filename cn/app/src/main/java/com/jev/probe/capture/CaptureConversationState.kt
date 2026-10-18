package com.jev.probe.capture

import com.jev.probe.core.Analysis
import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Intensity
import com.jev.probe.core.kb.ChatContext

/**
 * Ephemeral state owned by the currently observed conversation.
 *
 * The accessibility service coordinates Android callbacks and IO; this object
 * keeps the in-memory conversation state together so a target change can reset
 * the same set of values in one place.
 */
internal class CaptureConversationState {

    var lastSignature: String = ""
    var activePkg: String? = null
    var analyzing = false
    var regenerating = false
    val gate = NewMessageGate()
    val recentReplies = RecentReplies()
    var lastIntensity = Intensity.AUTO
    var lastAnalyzed: ChatSnapshot? = null
    var lastContext: ChatContext? = null
    var lastJudgment: Analysis? = null
    var lastNonEmptyTarget: ConversationSession.Target? = null
    var emptySinceTarget: ConversationSession.Target? = null
    var emptySinceAt = 0L
    var lastOcrSignature: String = ""
    var lastWeChatShotAt = 0L
    var weChatTitle = WeChatTitleState()

    fun resetConversation() {
        activePkg = null
        analyzing = false
        regenerating = false
        lastSignature = ""
        lastOcrSignature = ""
        gate.reset()
        lastAnalyzed = null
        lastContext = null
        lastJudgment = null
        recentReplies.clear()
        lastIntensity = Intensity.AUTO
    }
}

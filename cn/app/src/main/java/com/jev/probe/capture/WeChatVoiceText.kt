package com.jev.probe.capture

/** Text-only checks for WeChat's visible voice-message UI. */
internal object WeChatVoiceText {
    private val durationToken = Regex(
        """(?i)(?<!\S)\d{1,3}\s*(?:"|''|″|＂|秒|s)(?!\S)"""
    )

    fun stripDurationLabels(text: String): String = durationToken.replace(text, " ")
        .replace(Regex("""\s+"""), " ")
        .trim()

    fun isDurationLabel(text: String): Boolean = stripDurationLabels(text).isEmpty() &&
        durationToken.containsMatchIn(text)

    fun shouldBlockAnalysis(
        latestBubbleIsIncoming: Boolean,
        latestBubbleIsVoice: Boolean,
        latestVoiceHasTranscript: Boolean,
    ): Boolean = latestBubbleIsIncoming && latestBubbleIsVoice && !latestVoiceHasTranscript
}

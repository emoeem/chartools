package com.jev.probe.capture

/**
 * Sticky OCR title for WeChat, which exposes no node tree at all.
 *
 * The title is not decoration: the session identity is app + window + title, and
 * [ConversationSession.isCurrent] uses it, so a single frame that misreads a
 * message line as the title re-identifies the conversation, invalidates the
 * in-flight token and resets the card — one source of the "一会有一会没有"
 * flicker. Hence the rule: a pick that differs from the current title is only
 * accepted once the *same* pick shows up twice in a row.
 *
 * Immutable so the rule is a pure function and can be unit tested; the service
 * just holds one of these and reassigns it.
 */
internal data class WeChatTitleState(
    val title: String? = null,
    val windowId: Int = -1,
    val pending: String? = null
) {

    /** The title, but only for the window it was read in (a new window re-reads it). */
    fun titleForWindow(id: Int): String? = title.takeIf { windowId == id }

    /**
     * Fold one OCR pick into the state.
     *
     * - no pick → nothing changes (an unreadable top band must not erase the title)
     * - same as current, no title yet, or a different window → accept immediately
     * - a repeat of the pending pick → accept (it was seen twice in a row)
     * - anything else → remember it as pending and keep showing the old title
     */
    fun accept(picked: String?, windowId: Int): WeChatTitleState {
        if (picked == null) return this
        if (picked == title || title == null || this.windowId != windowId) {
            return WeChatTitleState(picked, windowId)
        }
        if (picked == pending) return WeChatTitleState(picked, windowId)
        // Dropped the previous candidate on purpose: only a consecutive repeat counts.
        return copy(pending = picked)
    }
}

package com.jev.probe.capture

import android.os.Bundle
import android.view.accessibility.AccessibilityNodeInfo

/**
 * The only place that writes into the chat's own input box.
 *
 * Deliberately narrow: it can *fill* a composer and nothing else — no taps that
 * could send, no scrolling, no sending key. It refuses apps it has no verified
 * handle for (the caller falls back to explicit clipboard copy) and refuses
 * ambiguous editors (more than one editable node on screen), because a wrong write
 * is worse than no write. Every step re-resolves the originating conversation, so
 * a chat switch mid-retry can never land the text in the wrong window.
 */
internal class InputFiller(private val host: Host) {

    /** What the filler needs from the service; everything else stays out here. */
    interface Host {
        /** The active window's root, or null when there is nothing to read. */
        fun activeRoot(): AccessibilityNodeInfo?

        /** Which conversation a root belongs to (null when it is not one we track). */
        fun targetOf(root: AccessibilityNodeInfo): ConversationSession.Target?

        /** Re-resolve *the same* chat; a write must never land in whatever came next. */
        fun isCurrent(token: ConversationSession.Token): Boolean

        /** Run later on the main thread — retries must never sleep the UI thread. */
        fun post(delayMs: Long, action: () -> Unit)

        fun copyToClipboard(text: String)
    }

    /** Resolve only the originating chat's input, never an arbitrary foreground editor. */
    fun inputFor(token: ConversationSession.Token): AccessibilityNodeInfo? {
        if (!host.isCurrent(token)) return null
        val root = host.activeRoot() ?: return null
        if (host.targetOf(root) != token.target) return null
        val input = when (token.target.pkg) {
            "com.tencent.mobileqq" -> root.findAccessibilityNodeInfosByViewId("com.tencent.mobileqq:id/input").firstOrNull()
            "com.tencent.tim" -> root.findAccessibilityNodeInfosByViewId("com.tencent.tim:id/input").firstOrNull()
            "com.ss.android.lark" -> root.findAccessibilityNodeInfosByViewId("com.ss.android.lark:id/kb_rich_text_content").firstOrNull()
            // Twitter and Telegram publish their composer as an ordinary editable
            // node (no stable id), so the generic finder is the only handle.
            "com.twitter.android" -> findEditable(root)
            "org.telegram.messenger" -> findEditable(root)
            else -> null // Unknown apps support explicit clipboard copy, not unverified writes.
        }
        // Re-read the node after SET_TEXT: the accessibility cache may still
        // contain the previous draft even though the write already succeeded.
        input ?: return null
        if (!input.refresh()) return null
        return input.takeIf { it.isVisibleToUser && it.isEnabled && !it.isPassword }
    }

    /**
     * Fill without blocking the main thread; all retries re-resolve the original
     * target. [onResult] receives false when the write could not be verified, and
     * the caller then falls back to the clipboard.
     */
    fun fill(token: ConversationSession.Token, text: String, onResult: (Boolean) -> Unit) {
        if (!host.isCurrent(token)) return
        if (inputFor(token) == null) { onResult(false); return }
        GuardedInputWriter(
            resolve = {
                inputFor(token)?.let { node ->
                    object : GuardedInputWriter.Input {
                        override val text: String? get() = node.text?.toString()
                        override fun setText(text: String) = setTextRaw(node, text)
                        override fun focus() { node.performAction(AccessibilityNodeInfo.ACTION_CLICK) }
                        override fun paste() { node.performAction(AccessibilityNodeInfo.ACTION_PASTE) }
                    }
                }
            },
            later = { delay, action -> host.post(delay, action) },
            copy = { host.copyToClipboard(it) },
            complete = onResult
        ).fill(text)
    }

    private fun setTextRaw(edit: AccessibilityNodeInfo, text: String): Boolean {
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        return edit.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    /**
     * The one editable node under [root], or null. More than one editable means we
     * cannot tell the composer from a search box or a nickname field, so nothing is
     * written and the caller copies instead.
     */
    private fun findEditable(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.addLast(root)
        var guard = 0
        var found: AccessibilityNodeInfo? = null
        while (stack.isNotEmpty() && guard < 5000) {
            guard++
            val node = stack.removeLast()
            if (node.isEditable && node.isVisibleToUser && node.isEnabled && !node.isPassword) {
                if (found != null) return null // Ambiguous editor: clipboard only.
                found = node
            }
            for (i in node.childCount - 1 downTo 0) node.getChild(i)?.let { stack.addLast(it) }
        }
        return if (stack.isEmpty()) found else null
    }
}

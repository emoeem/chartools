package dev.chartools.capture

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
internal class InputFiller(
    private val host: Host,
    /** 输入框定位交给适配器契约（[ChatAppAdapter.findInput]）；查不到 = 剪贴板。 */
    private val adapterFor: (String) -> ChatAppAdapter?
) {

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
        // fix(kimi-review #13)：targetOf 的提取缓存落在 Host 层（CaptureService 的
        // TargetMemo，pkg+windowId 键 + 无障碍事件失效）。前一版在本类里按 root
        // 实例引用（===）缓存——框架每次 getRootInActiveWindow 都返回新实例，
        // 引用恒不等，缓存从未命中（死代码，独立复核 2026-11-12）；且实例/键都
        // 不配失效钩子的话，「窗口内切聊天」会漏检（sameConversation 靠提取的
        // 标题辨认换会话），违反本类「换会话绝不写错窗口」的契约。这里只管每
        // 次 resolve 都如实问 Host，缓存与失效策略收敛在 Host 一处。
        val target = host.targetOf(root)
        // fix(kimi-review #6)：会话身份按 Target.sameConversation（pkg+windowId+title）判断，不做 data class 全等——对方在会话里又发一条消息只微变 messagesSignature（sameConversation 的注释契约：指纹微变不算换会话），全等会误判成「换了会话」、回填失败退剪贴板。
        if (target == null || !token.target.sameConversation(target)) return null
        val input = adapterFor(token.target.pkg)?.findInput(root)
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
        // fix(kimi-review #13)：入口检查与首个 resolve 原本各做一次完整 inputFor
        // （各一次全树提取 + 一次输入框查找）。两者在同一段同步栈里——首个
        // resolve 不经 host.post，主线程上树不可能在中间变——共用同一次解析，
        // 每次 fill 稳省一遍全树遍历。
        var pendingFirst = inputFor(token)
        if (pendingFirst == null) { onResult(false); return }
        GuardedInputWriter(
            resolve = {
                val resolved = pendingFirst ?: inputFor(token)
                pendingFirst = null
                resolved?.let { node ->
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
}

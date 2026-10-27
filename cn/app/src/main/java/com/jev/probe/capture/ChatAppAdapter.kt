package com.jev.probe.capture

import android.content.res.Resources
import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import com.jev.probe.core.BubbleRect
import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Msg

/**
 * Per-app capture rules. An adapter turns one messaging app's open chat window
 * into a neutral [ChatSnapshot]; everything downstream (Jev judgment, overlay,
 * fill) is app-agnostic.
 *
 * [extract]'s three-way contract (v1.3 B stage — the service depends on it):
 * - `null`            → not in this app's chat window (list screen, moments,
 *                       settings…). The service does nothing at all.
 * - messages empty    → in a chat window, but the tree carries no message text.
 *                       The service may fall back to screenshot + OCR. Each
 *                       adapter names below what proves "we are in a chat".
 * - messages non-empty→ normal capture.
 *
 * Adapters only read what the app exposes to an ordinary accessibility service.
 * An app that hides its node tree or blocks screenshots is not supported.
 */
interface ChatAppAdapter {
    val pkg: String

    /** 展示名：主页支持列表、知识库联系人标签都从这里派生，别再各自写死。 */
    val displayName: String

    /**
     * 在当前窗口里定位这个 App 的输入框（只找，不写；写由 [InputFiller] 负责）。
     * 默认 null = 本 App 没有验证过的写入口，填入回退到显式剪贴板复制。
     */
    fun findInput(root: AccessibilityNodeInfo): AccessibilityNodeInfo? = null

    /** 截屏 / OCR 兜底是否允许。WhatsApp 永不截屏（含手动「截屏识别一次」）。 */
    val allowScreenshot: Boolean get() = true

    fun extract(root: AccessibilityNodeInfo, res: Resources): ChatSnapshot?
}

/**
 * 无稳定 id 的输入框（X、Telegram 把 composer 发布成普通可编辑节点）的通用查找：
 * 全树恰好一个合格可编辑节点才算，两个以上视为歧义、宁可剪贴板。
 */
internal fun findEditableNode(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
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

/** Shared helpers. */
private fun looksLikeTimestamp(t: String): Boolean =
    Regex("""\d{1,2}[:：]\d{2}""").containsMatchIn(t) ||
        Regex("""\d+月\d+日""").containsMatchIn(t) ||
        t == "昨天" || t == "今天"

/**
 * Conversation title in the top action bar: the topmost short, roughly centered
 * text above the first message bubble. Constrained so we never grab an in-chat
 * timestamp. Used by QQ as a fallback when its title id is absent, by X, and by
 * the bubble menu's manual OCR capture.
 */
internal fun findTitleInActionBar(
    root: AccessibilityNodeInfo,
    firstBubbleTop: Int,
    width: Int,
    res: Resources,
    minCenterRatio: Double = 0.25,
    maxCenterRatio: Double = 0.75
): String? {
    val actionBarMax = minOf(firstBubbleTop, (res.displayMetrics.heightPixels * 0.14).toInt())
    val minCenterX = (width * minCenterRatio).toInt()
    val maxCenterX = (width * maxCenterRatio).toInt()
    val stack = ArrayDeque<AccessibilityNodeInfo>()
    stack.addLast(root)
    var best: String? = null
    var bestTop = Int.MAX_VALUE
    var guard = 0
    while (stack.isNotEmpty() && guard < 5000) {
        guard++
        val node = stack.removeLast()
        val text = node.text?.toString()
        if (!text.isNullOrBlank() && text.length <= 24 && !looksLikeTimestamp(text)) {
            val b = Rect(); node.getBoundsInScreen(b)
            if (b.bottom in 1 until actionBarMax && b.centerX() in minCenterX..maxCenterX) {
                if (b.top < bestTop) { bestTop = b.top; best = text }
            }
        }
        for (i in node.childCount - 1 downTo 0) node.getChild(i)?.let { stack.addLast(it) }
    }
    return best
}

/**
 * Mobile QQ (com.tencent.mobileqq). Nodes are NOT obfuscated (verified on QQ
 * 9.3.50 / Xiaomi 14, 1200x2670): message bodies are plain TextViews carrying
 * `id/mjn`, so collecting only that id already excludes timestamps, sender
 * nicknames (`id/mjq`) and the full-width system notice strips.
 *
 * The whole app lives under one SplashActivity (fragment architecture), so
 * "are we in a chat window" can only be answered by the tree itself — here, by
 * the chat input box `id/input`. No input box → not a chat → null; input box
 * but no `id/mjn` bodies → empty snapshot (OCR fallback's cue).
 *
 * Sender side: QQ pins the avatar to the outer edge of its own side (others on
 * the left at x≈156/1200 ≈ 13% of width, me on the right at width−156). A long
 * incoming message can push its center past mid-screen, so we compare which
 * edge of the bubble hugs its avatar column instead of using the center point.
 */
class QQAdapter : ChatAppAdapter {
    override val pkg = "com.tencent.mobileqq"
    override val displayName = "QQ"

    override fun findInput(root: AccessibilityNodeInfo): AccessibilityNodeInfo? =
        root.findAccessibilityNodeInfosByViewId("com.tencent.mobileqq:id/input").firstOrNull()

    override fun extract(root: AccessibilityNodeInfo, res: Resources): ChatSnapshot? {
        val width = res.displayMetrics.widthPixels
        // top, left, right, text
        val bubbles = ArrayList<Bubble>()
        var firstBubbleTop = Int.MAX_VALUE
        // Top of the first message row, nickname included: the title fallback must
        // stay above it, or a group member's nickname right under the top bar gets
        // taken for the chat title while QQ re-lays out its list during a scroll.
        var firstContentTop = Int.MAX_VALUE
        var title: String? = null
        var hasInput = false

        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.addLast(root)
        var guard = 0
        while (stack.isNotEmpty() && guard < 5000) {
            guard++
            val node = stack.removeLast()
            val id = node.viewIdResourceName
            val text = node.text?.toString()
            if (id == BUBBLE_ID && !text.isNullOrBlank()) {
                val b = Rect(); node.getBoundsInScreen(b)
                bubbles.add(Bubble(b.top, b.left, b.right, text))
                if (b.top < firstBubbleTop) firstBubbleTop = b.top
            }
            if (id == NICK_ID) {
                val b = Rect(); node.getBoundsInScreen(b)
                if (b.top < firstContentTop) firstContentTop = b.top
            }
            if (!hasInput && id == INPUT_ID) hasInput = true
            if (id == TITLE_ID && title == null) text?.let { if (it.isNotBlank()) title = it }
            for (i in node.childCount - 1 downTo 0) node.getChild(i)?.let { stack.addLast(it) }
        }
        if (bubbles.isEmpty() && !hasInput) return null

        if (title == null) title = findTitleInActionBar(root, minOf(firstBubbleTop, firstContentTop), width, res)
        if (bubbles.isEmpty()) return ChatSnapshot(title, emptyList())

        val avatarEdge = (width * 0.13).toInt()
        bubbles.sortBy { it.top }
        val msgs = bubbles.map { b ->
            val dl = kotlin.math.abs(b.left - avatarEdge)
            val dr = kotlin.math.abs((width - avatarEdge) - b.right)
            Msg(if (dr < dl) "me" else "other", b.text)
        }
        return ChatSnapshot(title, msgs)
    }

    private data class Bubble(val top: Int, val left: Int, val right: Int, val text: String)

    companion object {
        private const val BUBBLE_ID = "com.tencent.mobileqq:id/mjn"
        private const val TITLE_ID = "com.tencent.mobileqq:id/371"
        private const val NICK_ID = "com.tencent.mobileqq:id/mjq"
        private const val INPUT_ID = "com.tencent.mobileqq:id/input"
    }
}

/**
 * Tencent TIM (com.tencent.tim) — the office edition of QQ and, despite sharing
 * the launcher activity name `com.tencent.mobileqq.activity.SplashActivity`, a
 * DIFFERENT codebase: its resource ids are obfuscated by AndResGuard and NOT
 * ONE of QQ's three ids exists here (sampled 2026-10-06, TIM 4.1.0 /
 * OnePlus PJE110, 1080x2376: `mjn`, `mjq` and `371` all absent). So TIM needs
 * its own id table rather than a reused QQAdapter.
 *
 * Sampled structure of one open group chat (class/id/bounds/text LENGTH only —
 * message content was never read):
 * ```
 * RecyclerView
 *   ViewGroup#root                          one message row
 *     FrameLayout#f24 > TextView            time separator ("10:00")
 *     FrameLayout#pt5 > RelativeLayout#80
 *                     > ImageView#82        sender avatar — first message of a
 *                                           run only; later ones collapse to
 *                                           height 1 while staying in the tree
 *     FrameLayout#pyf > TextView#9w          sender nickname (group chats)
 *     LinearLayout#n9e > ... > TextView#9u   the bubble wrapping it (#n9e) and
 *                                           the message body (#9u)
 * ```
 * Collecting only `id/9u` therefore drops nicknames (`9w`), timestamps (`f24`)
 * and the collapsed slivers for free.
 *
 * Side is geometry, the same idea as QQ: incoming bubbles hang off the left
 * gutter (sampled `n9e` left edge 134 of 1080 ≈ 12.4%, right edge ≤ 809) and
 * outgoing ones snap flush right (sampled right edge 1075 = width − 5). See
 * [timSide] for why the right-edge snap has to be tested first.
 */
class TimAdapter : ChatAppAdapter {
    override val pkg = "com.tencent.tim"
    override val displayName = "TIM"

    override fun findInput(root: AccessibilityNodeInfo): AccessibilityNodeInfo? =
        root.findAccessibilityNodeInfosByViewId("com.tencent.tim:id/input").firstOrNull()

    override fun extract(root: AccessibilityNodeInfo, res: Resources): ChatSnapshot? {
        val width = res.displayMetrics.widthPixels
        val bubbles = ArrayList<Bubble>()
        val nickRows = ArrayList<IntArray>()   // top/bottom of each `id/9w` nickname line
        var firstContentTop = Int.MAX_VALUE
        var hasInput = false
        var hasComposer = false

        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.addLast(root)
        var guard = 0
        while (stack.isNotEmpty() && guard < 5000) {
            guard++
            val node = stack.removeLast()
            when (node.viewIdResourceName) {
                BUBBLE_ID -> {
                    val text = node.text?.toString()
                    val b = Rect(); node.getBoundsInScreen(b)
                    // Rows scrolled out of the RecyclerView keep their node but
                    // collapse to a 1px sliver; a real bubble is never degenerate.
                    if (!text.isNullOrBlank() && b.width() > 0 && b.height() > 0) {
                        bubbles.add(Bubble(b.top, b.left, b.right, text))
                        if (b.top < firstContentTop) firstContentTop = b.top
                    }
                }
                NICK_ID -> {
                    val b = Rect(); node.getBoundsInScreen(b)
                    if (b.height() > 0) {
                        if (b.top < firstContentTop) firstContentTop = b.top
                        nickRows.add(intArrayOf(b.top, b.bottom))
                    }
                }
                INPUT_ID -> hasInput = true
                SEND_PLUS_ID -> hasComposer = true
            }
            for (i in node.childCount - 1 downTo 0) node.getChild(i)?.let { stack.addLast(it) }
        }
        // The composer is the proof of "this is a chat window": `id/input` alone
        // is not enough, because an unknown list screen's search box may reuse
        // that id and a misfire there would fire the OCR fallback on a list.
        // Bubbles are proof on their own.
        if (bubbles.isEmpty() && !(hasInput && hasComposer)) return null

        val title = findTitleInActionBar(root, firstContentTop, width, res)
        if (bubbles.isEmpty()) return ChatSnapshot(title, emptyList())

        bubbles.sortBy { it.top }
        // A nickname line is drawn only above SOMEONE ELSE's message (TIM hides it
        // for your own), so the bubble a nick sits directly above is "other". That
        // is proof that beats the geometry, and a group row is exactly where the
        // pinned-edge test has the least to work with.
        val msgs = bubbles.map { b ->
            val nickAbove = nickRows.any { it[1] <= b.top && b.top - it[1] <= NICK_GAP_MAX }
            Msg(if (nickAbove) "other" else timSide(b.left, b.right, width), b.text)
        }
        return ChatSnapshot(title, msgs)
    }

    private data class Bubble(val top: Int, val left: Int, val right: Int, val text: String)

    companion object {
        // Obfuscated by AndResGuard — these names change with the TIM build.
        private const val BUBBLE_ID = "com.tencent.tim:id/9u"
        private const val NICK_ID = "com.tencent.tim:id/9w"
        private const val INPUT_ID = "com.tencent.tim:id/input"
        private const val SEND_PLUS_ID = "com.tencent.tim:id/fun_btn"
        /** How far below a nickname line its bubble may start. */
        private const val NICK_GAP_MAX = 60
    }
}

/**
 * Which side one TIM bubble sits on, from its `id/n9e` bounds.
 *
 * TIM lays a conversation out as two gutters: incoming bubbles are pinned to
 * the left one (sampled `n9e` left edge 134 of 1080 ≈ 12.4%, the avatar column)
 * and outgoing ones are pinned to the right screen edge (sampled right edge
 * 1075 = width − 5). We classify by *which edge is pinned*, not by where the
 * bubble's centre falls: a long incoming paragraph reaches past mid-screen and
 * would be called outgoing, and a long outgoing one starts inside the left
 * gutter and would be called incoming. Only the pinned edge is stable for both.
 *
 * A bubble wide enough to touch both gutters cannot happen under TIM's max
 * bubble width; if it ever does, fall back to the centre.
 *
 * When NEITHER edge lands on its gutter — the node bounds sit inside the bubble
 * and its padding shifts the edge by a few px, which is normal — the nearer
 * gutter decides. The centre test used to decide that case, and a long incoming
 * paragraph whose left edge sat ~30px right of the sampled avatar column was
 * therefore filed as MINE: "left+right past mid-screen" with no pin to contradict
 * it. That is the misread this fallback removes.
 */
internal fun timSide(left: Int, right: Int, width: Int): String {
    val gutter = (width * 0.13).toInt()
    val rightPin = width - (width * 0.005).toInt()
    val tol = (width * 0.01).toInt()
    val atLeft = kotlin.math.abs(left - gutter) <= tol
    val atRight = kotlin.math.abs(right - rightPin) <= tol
    return when {
        atLeft && !atRight -> "other"
        atRight && !atLeft -> "me"
        // Both pinned (a bubble spanning the whole width): use the centre.
        atLeft && atRight -> if (left + right < width) "other" else "me"
        kotlin.math.abs(left - gutter) <= kotlin.math.abs(right - rightPin) -> "other"
        else -> "me"
    }
}

/** Only my own Feishu bubbles carry the sent/read strip. */
private const val FEISHU_READ_STATE_ID = "time_read_state_container_align_bubble"

/** Does this bubble carry the "sent / read" strip that only mine have? */
private fun feishuHasReadState(bubble: AccessibilityNodeInfo): Boolean {
    val stack = ArrayDeque<AccessibilityNodeInfo>()
    stack.addLast(bubble)
    var guard = 0
    while (stack.isNotEmpty() && guard < 400) {
        guard++
        val node = stack.removeLast()
        val id = node.viewIdResourceName ?: ""
        if (id.endsWith(FEISHU_READ_STATE_ID)) return true
        for (i in node.childCount - 1 downTo 0) node.getChild(i)?.let { stack.addLast(it) }
    }
    return false
}

/**
 * Feishu bubble rectangles in SCREEN coordinates, top to bottom, with the side
 * the read-receipt strip implies.
 *
 * Split out of [FeishuAdapter.extract] so the capture service can call it again
 * from inside the screenshot callback: several hundred ms pass between reading
 * the tree and the picture arriving (debounce + overlay hide + the shot itself),
 * and a list that scrolled in between would make us crop the wrong rows.
 */
internal fun collectFeishuBubbleRects(
    root: AccessibilityNodeInfo,
    res: Resources
): List<BubbleRect> {
    val height = res.displayMetrics.heightPixels
    val topBand = (height * 0.14).toInt()      // action bar + tab row
    val bottomBand = (height * 0.84).toInt()   // input box + keyboard
    val rects = ArrayList<BubbleRect>()
    val stack = ArrayDeque<AccessibilityNodeInfo>()
    stack.addLast(root)
    var guard = 0
    while (stack.isNotEmpty() && guard < 6000) {
        guard++
        val node = stack.removeLast()
        val id = node.viewIdResourceName ?: ""
        if (id.endsWith(":id/bubble_content_container")) {
            val b = Rect(); node.getBoundsInScreen(b)
            if (b.width() > 0 && b.height() > 0 && b.bottom > topBand && b.top < bottomBand) {
                rects.add(BubbleRect(Rect(b), if (feishuHasReadState(node)) "me" else "other"))
            }
        }
        for (i in node.childCount - 1 downTo 0) node.getChild(i)?.let { stack.addLast(it) }
    }
    rects.sortBy { it.rect.top }
    return rects
}

/**
 * Feishu / Lark (com.ss.android.lark). Nodes are not obfuscated, but the message
 * text is DRAWN, not laid out as views (verified 2026-09-21): the tree gives us
 * bubble rectangles and chrome, and almost never a body. So this adapter is a
 * hybrid — it reports what it can read as messages (usually nothing) and always
 * reports the bubble geometry in [ChatSnapshot.bubbleRects] for the service to
 * OCR rect by rect.
 *
 * "In a chat window" = the tree has `id/message`, `id/bubble_content_container`
 * or the `id/kb_rich_text_content` input box.
 *
 * Side: Feishu left-aligns everyone, so geometry says nothing. What does say
 * something is the read-receipt strip (`…time_read_state_container_align_bubble`)
 * that only hangs off MY bubbles — present → "me", absent → "other". Unverified
 * on a real device (see the B-stage report's gaps).
 */
class FeishuAdapter : ChatAppAdapter {
    override val pkg = "com.ss.android.lark"
    override val displayName = "飞书"

    override fun findInput(root: AccessibilityNodeInfo): AccessibilityNodeInfo? =
        root.findAccessibilityNodeInfosByViewId("com.ss.android.lark:id/kb_rich_text_content").firstOrNull()

    override fun extract(root: AccessibilityNodeInfo, res: Resources): ChatSnapshot? {
        val width = res.displayMetrics.widthPixels
        val height = res.displayMetrics.heightPixels
        val topBand = (height * 0.14).toInt()      // action bar + tab row
        val bottomBand = (height * 0.84).toInt()   // input box + keyboard

        var isChat = false
        var title: String? = null
        val items = ArrayList<Triple<Int, Int, String>>() // top, centerX, text
        // Same collection the service re-runs inside the screenshot callback.
        val rects = collectFeishuBubbleRects(root, res)

        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.addLast(root)
        var guard = 0
        while (stack.isNotEmpty() && guard < 6000) {
            guard++
            val node = stack.removeLast()
            val id = node.viewIdResourceName ?: ""
            if (id.endsWith(":id/message") || id.endsWith(":id/bubble_content_container") ||
                id.endsWith(":id/kb_rich_text_content")) isChat = true
            if (id.endsWith(":id/group_name")) node.text?.toString()?.let { if (title == null) title = it }

            val text = node.text?.toString()
            val cls = node.className?.toString()
            if (!text.isNullOrBlank() && cls == "android.widget.TextView" && !isChrome(id) && !looksLikeTimestamp(text)) {
                val b = Rect(); node.getBoundsInScreen(b)
                if (b.top in (topBand + 1) until bottomBand) {
                    items.add(Triple(b.top, b.centerX(), text.trim()))
                }
            }
            for (i in node.childCount - 1 downTo 0) node.getChild(i)?.let { stack.addLast(it) }
        }
        if (!isChat) return null

        if (items.isEmpty()) return ChatSnapshot(title, emptyList(), rects)

        items.sortBy { it.first }
        val msgs = items.map { (_, cx, text) ->
            Msg(if (cx > width / 2) "me" else "other", text)
        }
        return ChatSnapshot(title, msgs, rects)
    }

    /** Non-message UI text to skip: title, sender name, time, system notices,
     *  the input EditText. Bodies have no id (bare TextView) so they pass. */
    private fun isChrome(id: String): Boolean =
        id.endsWith(":id/group_name") ||
            id.endsWith(":id/name_tv") ||
            id.endsWith(":id/date_tv") ||
            id.endsWith(":id/system_label") ||
            id.endsWith(":id/kb_rich_text_content") ||
            id.endsWith(":id/thread_title_tv") ||
            id.endsWith(":id/thread_subtitle_tv")
}

/** Trailing "8:11 上午" / "10:29 下午" / "8:11 AM" stamp X glues onto a message. */
private val X_TAIL_TIME = Regex("""\d{1,2}[:：]\d{2}\s*(上午|下午|AM|PM|am|pm)?$""")

/** X uses "。" as a field separator, so a message can end with a run of them. */
private val X_TRAILING_DOTS = Regex("""。+$""")

/**
 * Split one X DM row's contentDescription into (sender, body).
 *
 * "你：你这个说的就是那个虚拟人物，是吗？。8:11 上午。Read。"
 *      → ("你", "你这个说的就是那个虚拟人物，是吗？")
 * "你：他这个东西开源应该问题不大。。。Read。"
 *      → ("你", "他这个东西开源应该问题不大")
 * "All-In：附加的帖子。。"          → ("All-In", "附加的帖子")
 *
 * The sender is everything before the FIRST separator (full-width "：" in the
 * Chinese UI, ": " as a rough fallback elsewhere); the rest is the body plus
 * chrome — the read receipt, the timestamp, and the "。" gluing them on — which
 * is stripped from the tail in that order. Punctuation the user actually typed
 * ("是吗？") survives. Null when there is no separator or nothing is left.
 */
private fun parseXDesc(desc: String): Pair<String, String>? {
    val full = desc.indexOf('：')
    val half = desc.indexOf(": ")
    val cut: Int
    val skip: Int
    when {
        full >= 0 && (half < 0 || full <= half) -> { cut = full; skip = 1 }
        half >= 0 -> { cut = half; skip = 2 }
        else -> return null
    }
    val sender = desc.substring(0, cut).trim()
    var body = desc.substring(cut + skip).trim()
    for (tail in arrayOf("Read。", "Read", "已读。", "已读")) {
        if (body.endsWith(tail)) { body = body.removeSuffix(tail).trim(); break }
    }
    body = X_TRAILING_DOTS.replace(body, "").trim()
    X_TAIL_TIME.find(body)?.let { body = body.substring(0, it.range.first).trim() }
    body = X_TRAILING_DOTS.replace(body, "").trim()
    if (sender.isEmpty() || body.isEmpty()) return null
    return sender to body
}

/**
 * X / Twitter (com.twitter.android) direct messages. Verified on X 12.25.2 /
 * Xiaomi 14 (1200x2670), Chinese system language.
 *
 * The DM thread is Compose UI: each message is a bare `android.view.View` with
 * NO resource-id, full screen width and empty text — the whole message lives in
 * contentDescription ("All-In：重新写了一个😂。10:29 下午。"). The date divider is a
 * TextView with no "：", so filtering on class + full width + a separator keeps
 * it out. An attachment row ("All-In：附加的帖子。。") nests the quoted post's own
 * TextViews; we only take the row View's own desc, never its children.
 *
 * Every screen runs under the same MainActivity, so "are we in a DM thread" can
 * only be answered by the tree: a thread has the message EditText, the DM list
 * does not. The list's rows look similar but read
 * "All-In, @all_in_2026, 你这个说的就是那…", so ", @" is an extra guard.
 *
 * Side comes from the sender label ("你" / "You"), not geometry — every row is
 * full width no matter who spoke.
 */
class XAdapter : ChatAppAdapter {
    override val pkg = "com.twitter.android"
    override val displayName = "X"

    // X 的 composer 是普通可编辑节点（无稳定 id），通用查找是唯一抓手。
    override fun findInput(root: AccessibilityNodeInfo): AccessibilityNodeInfo? = findEditableNode(root)

    override fun extract(root: AccessibilityNodeInfo, res: Resources): ChatSnapshot? {
        val width = res.displayMetrics.widthPixels
        val rows = ArrayList<Row>()
        var firstRowTop = Int.MAX_VALUE
        var hasInput = false
        // A full-width View whose desc has a separator ("：" / ": ") — the shape
        // of a message row, whether or not parseXDesc could fully parse it.
        var hasMessageRowShape = false
        // A thread with zero messages still carries this placeholder text.
        var hasDmLabel = false
        // DM-list-only signals: the "compose new DM" affordance, or a "聊天/
        // Messages" heading with nothing under it (parsed as an actual row).
        var hasNewDmMarker = false
        var sawListHeading = false

        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.addLast(root)
        var guard = 0
        while (stack.isNotEmpty() && guard < 6000) {
            guard++
            val node = stack.removeLast()
            val cls = node.className?.toString()
            if (!hasInput && (node.isEditable || cls == "android.widget.EditText")) hasInput = true

            val desc = node.contentDescription?.toString()
            if (desc == "新私信" || desc == "New message") hasNewDmMarker = true
            if (cls == "android.view.View" && !desc.isNullOrBlank() && !desc.contains(", @")) {
                val b = Rect(); node.getBoundsInScreen(b)
                if (b.left == 0 && b.right == width) {
                    if (desc.contains('：') || desc.contains(": ")) hasMessageRowShape = true
                    val parsed = parseXDesc(desc)
                    if (parsed != null) {
                        rows.add(Row(b.top, parsed.first, parsed.second))
                        if (b.top < firstRowTop) firstRowTop = b.top
                    }
                }
            }

            if (cls == "android.widget.TextView") {
                val text = node.text?.toString()?.trim()
                if (text == "私信" || text == "Message" || text == "发送私信") hasDmLabel = true
                if (text == "聊天" || text == "Messages") sawListHeading = true
            }
            for (i in node.childCount - 1 downTo 0) node.getChild(i)?.let { stack.addLast(it) }
        }
        // Explicit "this is the DM list, not a thread" signals — checked before
        // the generic rule below so they win even if a search box's EditText
        // would otherwise have counted as "hasInput".
        if (hasNewDmMarker || (sawListHeading && rows.isEmpty())) return null

        // A chat window needs BOTH an input box AND something that only a
        // thread has: an actual message-row shape, or the "私信" placeholder an
        // empty thread shows. A list screen's search box has an EditText too,
        // so hasInput alone used to misfire OCR fallback on the DM list.
        if (!hasInput || !(hasMessageRowShape || hasDmLabel)) return null

        // X left-aligns the thread title (x≈300..443 of 1200), so widen the
        // shared helper's "roughly centered" band for this app.
        val title = findTitleInActionBar(root, firstRowTop, width, res, 0.15, 0.85)
        // In a DM thread but no rows parsed → empty snapshot (OCR fallback cue).
        if (rows.isEmpty()) return ChatSnapshot(title, emptyList())
        rows.sortBy { it.top }
        val msgs = rows.map { Msg(if (it.sender == "你" || it.sender == "You") "me" else "other", it.text) }
        return ChatSnapshot(title, msgs)
    }

    private data class Row(val top: Int, val sender: String, val text: String)
}

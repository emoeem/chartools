package com.jev.probe.capture

import android.content.res.Resources
import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Msg

/**
 * Telegram (org.telegram.messenger).
 *
 * Sampled on Telegram 12.10.1 / OnePlus PJE110, 1080x2376 (2026-10-06). Nothing
 * here has a `resource-id` — Telegram ships without them — so every rule below
 * is written against class, text shape and screen bands, which is what makes it
 * survive a version bump better than an id table would.
 *
 * Tree shape of one open chat:
 * ```
 * RecyclerView
 *   ViewGroup            one message row — ALL of it is in the node's `text`,
 *                        several lines (sender / body / status), no id
 * FrameLayout desc<21>   the floating top bar (it overlays the list, which
 *                        scrolls underneath it) containing two TextViews:
 *                        the chat title and a status line under it
 * EditText               the composer ("输入消息"); its hint is localised
 * ```
 * A row's `text` looks like one of these (real samples):
 * ```
 * 媛媛 王 带有管理员标签：所有者\n然后？\n已收到 于 11:49:26 27514\n
 * UIC\n在撸了已经\n已收到 于 11:50:06 27518\n
 * 那好啊，到时候撸给你\n已发送于 于 11:50:38 27520, 已读\n
 * 哈 哈\n🤔 贴纸\n已收到 于 11:53\n
 * ```
 * So the LAST line is a status line and it is the only side signal there is:
 * rows are full width, so the geometric trick QQ and TIM use cannot work here.
 * Telegram's own Chinese translation has the typo "已发送于 于"; that is why the
 * side test looks for the verb anywhere in the line instead of matching a shape.
 *
 * Sender names: a group row for an incoming message carries the sender on its
 * first line, its own row does not. Telegram shows no sender line in a 1:1
 * chat, so stripping a first line is only safe once something proves the
 * conversation puts names there — see [nameHeadersInUse]. A one-on-one chat's
 * multi-line message must never lose its first line to that rule.
 *
 * Known gaps (honest list, see the task report):
 * - The side test matches localised strings. Only zh and en are covered; in any
 *   other language every incoming row reads as mine.
 * - "Delivered"/"已收到" are Telegram's *received* wording, but English
 *   Telegram is not sampled here, so the en side table is a guess.
 * - A group with exactly one incoming row on screen cannot prove names are in
 *   use, and keeps the sender's name as part of the body.
 */
class TelegramAdapter : ChatAppAdapter {
    override val pkg = "org.telegram.messenger"
    override val displayName = "Telegram"

    // Telegram 的 composer 也是普通可编辑节点（无稳定 id）。
    override fun findInput(root: AccessibilityNodeInfo): AccessibilityNodeInfo? = findEditableNode(root)

    override fun extract(root: AccessibilityNodeInfo, res: Resources): ChatSnapshot? {
        val width = res.displayMetrics.widthPixels
        val height = res.displayMetrics.heightPixels
        // The list search box sits near the top; a composer sits at the bottom.
        // That y-band split is what separates "open chat" from "chat list"
        // without depending on the localised hint text.
        val composerMinY = (height * 0.6).toInt()
        val titleMaxY = (height * TITLE_BAND).toInt()
        val minCenterX = (width * 0.25).toInt()
        val maxCenterX = (width * 0.75).toInt()

        val cells = LinkedHashMap<String, Cell>()
        var hasComposer = false
        var title: String? = null
        var titleTop = Int.MAX_VALUE

        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.addLast(root)
        var guard = 0
        while (stack.isNotEmpty() && guard < 6000) {
            guard++
            val node = stack.removeLast()
            if (node.className?.toString()?.endsWith("EditText") == true) {
                val b = Rect(); node.getBoundsInScreen(b)
                if (b.height() > 0 && b.top >= composerMinY) hasComposer = true
            }
            val text = node.text?.toString()
            if (!text.isNullOrBlank()) {
                val b = Rect(); node.getBoundsInScreen(b)
                if (b.height() > 0) {
                    val parsed = telegramParseCell(text)
                    if (parsed != null) {
                        if (b.width() > width * CELL_MIN_WIDTH) cells["${b.top}|$text"] = Cell(b.top, text, parsed)
                    } else if (b.width() < width * TITLE_MAX_WIDTH &&
                        text.trim().length <= 24 &&
                        b.bottom in 1 until titleMaxY &&
                        b.centerX() in minCenterX..maxCenterX &&
                        b.top < titleTop
                    ) {
                        // Topmost short centred text in the top band. Message
                        // rows are excluded by parseCell, so a row scrolled
                        // behind the floating bar cannot be taken for a title.
                        titleTop = b.top
                        title = text.trim()
                    }
                }
            }
            for (i in node.childCount - 1 downTo 0) node.getChild(i)?.let { stack.addLast(it) }
        }

        // Composer is the proof of "this is a chat window": the chat list has a
        // search box (an EditText too) but it sits at the top, never down here.
        if (cells.isEmpty() && !hasComposer) return null

        val ordered = cells.values.sortedBy { it.top }
        if (ordered.isEmpty()) return ChatSnapshot(title, emptyList())

        val stripNames = telegramNameHeadersInUse(ordered.map { it.parsed }, title)
        val msgs = ordered.map { cell ->
            val lines = cell.parsed.lines
            val body = if (stripNames && cell.parsed.side == "other" && lines.size >= 2) lines.drop(1) else lines
            Msg(cell.parsed.side, body.joinToString("\n"))
        }
        return ChatSnapshot(title, msgs)
    }

    private data class Cell(val top: Int, val text: String, val parsed: TgCell)

    private companion object {
        /** A message row spans the screen; the top bar and composer do not. */
        const val CELL_MIN_WIDTH = 0.5

        /** Telegram's floating top bar is ~12% of the height (sampled 288/2376). */
        const val TITLE_BAND = 0.14

        /** The title TextView is wide — sampled [329,128][887,226] = 0.52W — so
         *  the title bound has to be looser than [CELL_MIN_WIDTH], which only
         *  has to separate a full-width message row from everything else. */
        const val TITLE_MAX_WIDTH = 0.85
    }
}

/** One Telegram message row, decoded. [side] is "me" or "other". */
internal data class TgCell(val side: String, val lines: List<String>)

/** Verbs that appear only in Telegram's own outgoing status lines. */
private val TG_OUT_WORDS = listOf(
    "发送", "已读",
    "Sent", "Sending", "Delivered", "Read", "Seen", "Edited"
)

/** Anything else that can end a row and still be a status line. */
private val TG_STATUS_WORDS = TG_OUT_WORDS + listOf("已收到", "未读", "Received")

private val TG_TIME = Regex("""\d{1,2}[:：]\d{2}""")

/**
 * One Telegram row's accessibility text → side + body lines, or null when this
 * is not a message row at all (date separator, the "unread messages" strip,
 * the composer, the tabs…). The status line is what makes it a message, and it
 * is also the only side signal: rows are full width, so no geometry helps.
 *
 * Real samples (Telegram 12.10.1, zh):
 * ```
 * 媛媛 王 带有管理员标签：所有者\n然后？\n已收到 于 11:49:26 27514\n   → other
 * 那好啊，到时候撸给你\n已发送于 于 11:50:38 27520, 已读\n              → me
 * 哈 哈\n🤔 贴纸\n已收到 于 11:53\n                                    → other
 * ```
 * The "已发送于 于" duplication is Telegram's own translation bug, which is why
 * the side test looks for the verb anywhere in the line rather than a shape.
 */
internal fun telegramParseCell(text: String): TgCell? {
    val lines = text.split('\n').map { it.trim() }.filter { it.isNotEmpty() }
    if (lines.size < 2) return null
    val status = lines.last()
    val isStatus = TG_TIME.containsMatchIn(status) || TG_STATUS_WORDS.any { status.contains(it) }
    if (!isStatus) return null
    val body = lines.dropLast(1)
    if (body.isEmpty()) return null
    val side = if (TG_OUT_WORDS.any { status.contains(it) }) "me" else "other"
    return TgCell(side, body)
}

/**
 * Does this conversation put a sender name on the first line of incoming rows?
 * Two independent proofs, either is enough:
 * - the first line of some incoming row equals the chat title → a one-on-one
 *   chat that names the peer (redundant, but present);
 * - two incoming rows name the same sender → a group chat, where every
 *   incoming row names its sender.
 * With no proof we keep the first line: a mistaken strip silently eats the
 * opening words of a real message, which is worse than keeping a name.
 */
internal fun telegramNameHeadersInUse(cells: List<TgCell>, title: String?): Boolean {
    val firsts = cells.filter { it.side == "other" && it.lines.size >= 2 }.map { it.lines[0] }
    if (firsts.isEmpty()) return false
    if (title != null && firsts.any { it == title }) return true
    return firsts.groupingBy { it }.eachCount().any { it.value >= 2 }
}

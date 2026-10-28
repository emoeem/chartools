package com.jev.probe.capture

import com.jev.probe.core.ocr.OcrLine
import com.jev.probe.core.Msg

/**
 * The text half of both OCR paths: raw recognised lines → messages, which bubble
 * (if any) a line belongs to, and scrubbing the junk apps glue onto a bubble.
 *
 * These are pure functions on purpose. They used to live inside
 * `ChatCaptureService` next to screenshot bookkeeping, retries and threading, which
 * made the one part of the pixel path that is worth reasoning about in isolation
 * the hardest to read.
 */
internal object OcrGrouping {

    /**
     * Side value for an OCR line no pixel bubble covers. Not "other": an unknown
     * side must stay unknown, or a screen full of my own messages reads as an
     * incoming conversation.
     */
    const val SIDE_UNKNOWN = "?"

    private val PURE_TIME = Regex("""\d{1,2}[:：]\d{2}""")
    // 要求时间戳前面有空白：飞书粘连在气泡尾部的回执（「已读 14:32」）带空格，
    // 照剥；真实消息以时间收尾（「会议改到10:30」）没有空格，不能吃掉结尾。
    private val TAIL_TIME = Regex("""\s\d{1,2}[:：]\d{2}$""")

    /**
     * Group recognised lines into messages by vertical gaps: a gap taller than the
     * previous line's height means a new bubble. Timestamps are dropped (the tree
     * path drops them the same way), and each group takes the side of the bubble it
     * overlaps most.
     */
    fun group(lines: List<OcrLine>, boxes: List<WeChatBubbles.Box> = emptyList()): List<Msg> {
        val usable = lines
            .filter { it.text.isNotBlank() && !PURE_TIME.matches(it.text.trim()) }
            .sortedBy { it.bounds.top }
        val out = ArrayList<Msg>()
        val buf = StringBuilder()
        var prev: OcrLine? = null
        var top = 0
        var bottom = 0
        fun flush() {
            if (buf.isEmpty()) return
            out.add(Msg(sideFor(top, bottom, boxes), buf.toString()))
            buf.setLength(0)
        }
        for (l in usable) {
            val p = prev
            if (p != null) {
                val gap = l.bounds.top - p.bounds.bottom
                val lineHeight = maxOf(p.bounds.height(), 1)
                if (gap > lineHeight * 1.2f) flush()
            }
            if (buf.isEmpty()) top = l.bounds.top
            bottom = l.bounds.bottom
            if (buf.isNotEmpty()) buf.append(' ')
            buf.append(l.text.trim())
            prev = l
        }
        flush()
        return out
    }

    /**
     * The bubble with the largest vertical overlap with this group of lines names
     * its side. [SIDE_UNKNOWN] when no bubble covers the lines: the caller then
     * marks the message unknown instead of guessing "other".
     */
    fun sideFor(top: Int, bottom: Int, boxes: List<WeChatBubbles.Box>): String {
        var best: String? = null
        var bestOverlap = 0
        for (b in boxes) {
            val overlap = minOf(bottom, b.bottom) - maxOf(top, b.top)
            if (overlap > bestOverlap) { bestOverlap = overlap; best = b.side }
        }
        return best ?: SIDE_UNKNOWN
    }

    /** Strip the read receipt and the timestamp Feishu glues onto a bubble. */
    fun cleanBubbleText(raw: String): String {
        var t = raw.trim()
        var changed = true
        while (changed && t.isNotEmpty()) {
            changed = false
            for (tail in arrayOf("已读", "未读")) {
                if (t.endsWith(tail)) { t = t.removeSuffix(tail).trim(); changed = true }
            }
            TAIL_TIME.find(t)?.let { t = t.substring(0, it.range.first).trim(); changed = true }
            // 整条只剩一个时间戳（系统时间元素被 OCR 当气泡的残留）照旧清空；
            // 时间粘在正文上（「会议改到10:30」）到不了这里，不吃饭原文。
            if (PURE_TIME.matches(t)) { t = ""; changed = true }
        }
        return t
    }

    /**
     * WeChat's title bar is the widest text near the horizontal centre. A pure
     * timestamp is never a title.
     */
    fun pickTitle(lines: List<OcrLine>, width: Int): String? {
        val minX = width * 0.2f
        val maxX = width * 0.8f
        var best: String? = null
        var bestW = 0
        for (l in lines) {
            val t = l.text.trim()
            if (t.length < 2 || PURE_TIME.matches(t)) continue
            if (l.bounds.centerX() < minX || l.bounds.centerX() > maxX) continue
            val w = l.bounds.width()
            if (w > bestW) { bestW = w; best = t }
        }
        return best
    }
}

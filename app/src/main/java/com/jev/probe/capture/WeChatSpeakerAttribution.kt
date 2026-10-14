package com.jev.probe.capture

import com.jev.probe.capture.ocr.OcrLine
import kotlin.math.abs

/**
 * Attributes incoming WeChat bubbles to a stable speaker name when the group
 * sender label is visible in OCR. This is deliberately independent of OCR and
 * pixel detection so the rules can be fixture-tested.
 */
internal object WeChatSpeakerAttribution {

    data class Label(
        val text: String,
        val left: Int,
        val top: Int,
        val right: Int,
        val bottom: Int,
    )

    private const val MAX_NAME_LENGTH = 24
    private const val MAX_VERTICAL_GAP = 90
    private const val MAX_HORIZONTAL_DELTA = 150
    private const val MAX_INHERIT_GAP = 32

    private val time = Regex("""\d{1,2}[:：]\d{2}""")
    private val uiNoise = setOf(
        "微信", "通讯录", "发现", "我", "聊天", "返回", "更多", "发送",
        "相册", "拍摄", "语音", "表情", "加号", "搜索"
    )

    fun labelsFor(lines: List<OcrLine>, boxes: List<WeChatBubbles.Box>): List<Label> {
        if (lines.isEmpty() || boxes.isEmpty()) return emptyList()
        val out = ArrayList<Label>()
        for (line in lines) {
            val text = line.text.trim()
            if (!isCandidate(text)) continue
            val r = line.bounds
            val nearIncoming = boxes.any { b ->
                b.side == "other" &&
                    r.bottom <= b.top &&
                    b.top - r.bottom in 0..MAX_VERTICAL_GAP &&
                    abs(r.left - b.left) <= MAX_HORIZONTAL_DELTA
            }
            if (nearIncoming) {
                out += Label(text, r.left, r.top, r.right, r.bottom)
            }
        }
        return out
    }

    /**
     * Returns one speaker value per bubble, preserving bubble order.
     *
     * 1:1 without labels stays "other". Once sender labels prove a group,
     * labelled incoming bubbles become member:<name>; an unreadable incoming
     * bubble becomes unknown rather than being silently assigned to somebody.
     */
    fun assign(
        boxes: List<WeChatBubbles.Box>,
        labels: List<Label>,
    ): List<String> {
        if (boxes.isEmpty()) return emptyList()

        val ordered = boxes.sortedBy { it.top }
        val assignments = MutableList(ordered.size) { "unknown" }
        val labelsSorted = labels.sortedBy { it.top }
        val labelledNames = labelsSorted.map(::normalize).filter { it.isNotEmpty() }.distinct()
        val groupProven = labelledNames.isNotEmpty()

        var lastMember: String? = null
        var lastBubbleBottom = Int.MIN_VALUE

        ordered.forEachIndexed { index, box ->
            if (box.side == "me") {
                assignments[index] = "me"
                lastBubbleBottom = box.bottom
                return@forEachIndexed
            }

            val candidates = labelsSorted
                .filter { it.bottom <= box.top && box.top - it.bottom in 0..MAX_VERTICAL_GAP }
                .sortedBy { box.top - it.bottom }

            val chosen = candidates.firstOrNull { abs(it.left - box.left) <= MAX_HORIZONTAL_DELTA }
            if (chosen != null) {
                val name = normalize(chosen)
                assignments[index] = if (name.isNotEmpty()) "member:$name" else "unknown"
                if (name.isNotEmpty()) lastMember = name
            } else if (!groupProven) {
                assignments[index] = "other"
            } else {
                val gap = box.top - lastBubbleBottom
                assignments[index] = if (lastMember != null && gap in 0..MAX_INHERIT_GAP) {
                    "member:$lastMember"
                } else {
                    "unknown"
                }
            }
            lastBubbleBottom = box.bottom
        }
        return assignments
    }

    private fun isCandidate(text: String): Boolean {
        if (text.isEmpty() || text.length > MAX_NAME_LENGTH) return false
        if (time.matches(text)) return false
        if (text in uiNoise) return false
        if (text.any { it == '\n' || it == '\r' }) return false
        if (text.length > 12 && text.count { it in "，。！？,.!?;；" } >= 1) return false
        return true
    }

    private fun normalize(label: Label): String =
        label.text.trim().replace(Regex("\\s+"), " ").take(MAX_NAME_LENGTH)
}

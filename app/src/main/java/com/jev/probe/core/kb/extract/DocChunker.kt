package com.jev.probe.core.kb.extract

/**
 * Splits extracted text into the chunks that become knowledge notes.
 *
 * Paragraphs are the unit: a chunk never starts or ends in the middle of one
 * unless that single paragraph is longer than the whole budget, in which case it
 * is broken at a sentence end if there is one near the boundary and hard-wrapped
 * otherwise. A chunk is therefore always ≤ [maxChars] characters, which is what
 * the knowledge base and the analysis prompt rely on.
 */
internal object DocChunker {

    /** Sentence enders, CJK and Latin, used to find a polite break point. */
    private const val SENTENCE_END = "。！？!?；;.\n"

    fun split(text: String, maxChars: Int): List<String> {
        if (maxChars <= 0) return emptyList()
        val out = ArrayList<String>()
        val current = StringBuilder()

        fun flush() {
            val s = current.toString().trim()
            if (s.isNotEmpty()) out.add(s)
            current.setLength(0)
        }

        for (rawParagraph in text.split('\n')) {
            val paragraph = rawParagraph.trim()
            if (paragraph.isEmpty()) continue
            if (paragraph.length > maxChars) {
                flush()
                out.addAll(hardWrap(paragraph, maxChars))
                continue
            }
            if (current.isEmpty()) {
                current.append(paragraph)
            } else if (current.length + 1 + paragraph.length <= maxChars) {
                current.append('\n').append(paragraph)
            } else {
                flush()
                current.append(paragraph)
            }
        }
        flush()
        return out
    }

    /** Break one over-long paragraph into pieces of at most [maxChars]. */
    private fun hardWrap(paragraph: String, maxChars: Int): List<String> {
        val out = ArrayList<String>()
        var start = 0
        while (start < paragraph.length) {
            var end = minOf(start + maxChars, paragraph.length)
            if (end < paragraph.length) {
                val cut = breakPoint(paragraph, start, end, maxChars)
                if (cut > start) end = cut
            }
            val piece = paragraph.substring(start, end).trim()
            if (piece.isNotEmpty()) out.add(piece)
            start = end
        }
        return out
    }

    /**
     * A break at the latest sentence end in the last quarter of the window, or
     * at the last space, so a Latin word is not cut in half. Falls back to the
     * hard boundary when the window holds neither.
     */
    private fun breakPoint(s: String, start: Int, end: Int, maxChars: Int): Int {
        val floor = start + (maxChars * 3) / 4
        for (i in end - 1 downTo floor) {
            if (SENTENCE_END.indexOf(s[i]) >= 0) return i + 1
        }
        for (i in end - 1 downTo floor) {
            if (s[i] == ' ' || s[i] == '\t') return i + 1
        }
        return end
    }
}

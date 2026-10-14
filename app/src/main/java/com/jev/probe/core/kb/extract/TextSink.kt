package com.jev.probe.core.kb.extract

/**
 * Collects extracted text with the two things every extractor needs: a hard
 * character ceiling, and whitespace that reads like paragraphs.
 *
 * A run of whitespace collapses to one space and a run of line breaks collapses
 * to one newline, so a DOCX full of `<w:p></w:p>` gaps, or an EPUB with pretty
 * printed indentation, does not turn into a document that is mostly blank lines.
 * One `\n` therefore *is* a paragraph boundary — which is exactly what
 * [DocChunker] splits on.
 */
internal class TextSink(private val limit: Int) {

    private val sb = StringBuilder()
    private var stopped = false

    /** True once more text arrived after [limit] was reached. */
    var truncated: Boolean = false
        private set

    val length: Int get() = sb.length

    fun append(s: CharSequence?) {
        if (s == null || s.isEmpty()) return
        if (stopped) {
            if (s.isNotBlank()) truncated = true
            return
        }
        val room = limit - sb.length
        if (room <= 0) {
            stopped = true
            if (s.isNotBlank()) truncated = true
            return
        }
        if (s.length <= room) {
            sb.append(s)
        } else {
            sb.append(s, 0, room)
            stopped = true
            truncated = true
        }
    }

    /**
     * Appends XML/markup text, collapsing every whitespace run to a single
     * space. Source indentation ("\n      ") is layout, not prose, and turning it
     * into real newlines would fill the document with blank paragraphs. An
     * explicit structural break is expressed with [newline] instead.
     */
    fun appendFlow(s: CharSequence?) {
        if (s == null || s.isNullOrEmpty()) return
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c.isWhitespace()) {
                var j = i
                while (j < s.length && s[j].isWhitespace()) j++
                space()
                i = j
            } else {
                var j = i
                while (j < s.length && !s[j].isWhitespace()) j++
                append(s.subSequence(i, j))
                i = j
            }
        }
    }

    /** A single space, never doubled. */
    fun space() {
        if (sb.isEmpty() || sb.last().isWhitespace()) return
        append(" ")
    }

    /** A single newline, never doubled, and never preceded by a dangling space. */
    fun newline() {
        zapTrailingSpace()
        if (sb.isEmpty() || sb.last() == '\n') return
        append("\n")
    }

    /** Marks the end of a block, leaving a blank line between blocks. */
    fun paragraph() {
        newline()
    }

    /** Drops a separator space left dangling at the end of a line. */
    fun zapTrailingSpace() {
        while (sb.isNotEmpty() && sb.last() == ' ') sb.setLength(sb.length - 1)
    }

    /** The text collected so far, trailing whitespace removed. */
    override fun toString(): String = sb.toString().trim()
}

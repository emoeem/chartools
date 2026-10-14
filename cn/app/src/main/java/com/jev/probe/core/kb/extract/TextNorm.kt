package com.jev.probe.core.kb.extract

import java.text.Normalizer

/**
 * Repairs the two things extractors do to Chinese text that make it
 * *unretrievable* rather than merely ugly.
 *
 * Retrieval tokenises Han characters into overlapping bigrams ([com.jev.probe.core.retrieve.LexicalSearch]),
 * which needs the characters to be adjacent **and** to be ordinary ideographs.
 * Both extractors violate that:
 *
 * 1. **The OCR path (ML Kit) can return one space between every Han character**
 *    — `这 篇 教 程`. Every bigram is then split, so a note recovered from a
 *    scan cannot be matched by any query, no matter how well it was recognised.
 * 2. **PDF text layers sometimes map glyphs to Kangxi radicals** (`U+2F79 ⽹`)
 *    or CJK Compatibility Ideographs instead of the ordinary character
 *    (`U+7F51 网`). Radicals fall outside every range the tokeniser treats as
 *    Han, so `⽹调` never matches a query containing `网调`.
 *
 * Only those two repairs happen here. Full-width *punctuation* is left alone:
 * it is not part of any bigram, so folding it to ASCII would only make Chinese
 * prose look wrong in the knowledge list.
 *
 * Measured on the 27-document sample library this was written for: missing the
 * radical repair left 32,354 characters unmatchable before the OCR fix was even
 * applied, and the OCR spacing affected all seven scanned documents.
 */
internal object TextNorm {

    /** Consecutive-run collapse only ever looks at these three. Newlines are structure. */
    private fun isSpaceRun(ch: Char): Boolean = ch == ' ' || ch == '\t' || ch == '\u3000'

    private fun isHan(ch: Char): Boolean =
        ch.code in 0x4E00..0x9FFF ||     // CJK unified ideographs
            ch.code in 0x3400..0x4DBF || // extension A
            ch.code in 0xF900..0xFAFF    // compatibility ideographs

    /**
     * Characters that carry a canonical form and are not themselves usable:
     * Kangxi radicals, CJK radical supplements, compatibility ideographs, and
     * full-width latin letters and digits.
     */
    private fun needsFold(ch: Char): Boolean {
        val c = ch.code
        return c in 0x2E80..0x2EFF || c in 0x2F00..0x2FDF || c in 0xF900..0xFAFF ||
            c in 0xFF10..0xFF19 || c in 0xFF21..0xFF3A || c in 0xFF41..0xFF5A
    }

    /**
     * Fold compatibility forms to the characters people actually type, then close
     * the gaps OCR leaves between Han characters. In that order: a Kangxi radical
     * is not Han, so `⽹ 调` only becomes collapsible once `⽹` is `网`.
     */
    fun canonical(text: String): String = despaceHan(foldCompat(text))

    private fun foldCompat(text: String): String {
        var needed = false
        for (ch in text) if (needsFold(ch)) { needed = true; break }
        if (!needed) return text
        val out = StringBuilder(text.length)
        for (ch in text) {
            // Per character, not per string: NFKC on a whole document would also
            // rewrite the punctuation this deliberately leaves alone.
            if (needsFold(ch)) {
                out.append(Normalizer.normalize(ch.toString(), Normalizer.Form.NFKC))
            } else {
                out.append(ch)
            }
        }
        return out.toString()
    }

    private fun despaceHan(text: String): String {
        val out = StringBuilder(text.length)
        var i = 0
        while (i < text.length) {
            val ch = text[i]
            if (isSpaceRun(ch)) {
                var j = i
                while (j < text.length && isSpaceRun(text[j])) j++
                // Drop the run only when it sits between two Han characters. A
                // space after a latin word or before a newline is real layout.
                val drop = out.isNotEmpty() && j < text.length && isHan(out.last()) && isHan(text[j])
                if (!drop) out.append(text, i, j)
                i = j
            } else {
                out.append(ch)
                i++
            }
        }
        return if (out.length == text.length) text else out.toString()
    }
}

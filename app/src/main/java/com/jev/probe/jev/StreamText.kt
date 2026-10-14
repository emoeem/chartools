package com.jev.probe.jev

import org.json.JSONObject

/**
 * Makes an opt-in streaming reply watchable.
 *
 * Two shapes have to be unwrapped before a human sees anything:
 *
 * 1. **Transport.** Each SSE `data:` payload is an OpenAI-style envelope —
 *    `{"choices":[{"delta":{"content":"你"}}]}` — so [delta] pulls the sentence
 *    fragment out of it. DashScope's compatible mode and DeepSeek both use this
 *    shape; a payload carrying no content (the final `finish_reason` chunk) yields
 *    null so the caller does not have to special-case it.
 * 2. **Format.** The reply prompt asks for a JSON array of
 *    `{"strategy":"safe","text":"…"}` objects, so the *accumulated* text is JSON.
 *    Showing that verbatim would put `[{"strategy":"safe","text":"` on the card,
 *    so [visible] returns just the `text` values, decoded, as plain text.
 *
 * Both run on every partial chunk, so both must tolerate input that stops in the
 * middle of a string, an escape sequence or a key name. Neither throws — a
 * half-finished sentence on the card beats a crash in the middle of a reply.
 */
internal object StreamText {

    /** The content fragment in one SSE payload, or null when the chunk carries none. */
    fun delta(data: String): String? {
        val trimmed = data.trim()
        if (trimmed.isEmpty()) return null
        return try {
            val choices = JSONObject(trimmed).optJSONArray("choices") ?: return null
            val first = choices.optJSONObject(0) ?: return null
            val delta = first.optJSONObject("delta") ?: first.optJSONObject("message")
            delta?.optString("content")?.takeIf { it.isNotEmpty() }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * The readable part of an accumulated (possibly incomplete) reply: every
     * `"text"` value found so far, on its own line.
     *
     * Falls back to the raw text when no `"text"` field has appeared yet, so a
     * model that ignores the JSON format and streams prose still previews.
     */
    fun visible(raw: String): String {
        val parts = ArrayList<String>()
        var i = 0
        var sawTextField = false
        while (true) {
            val key = raw.indexOf("\"text\"", i)
            if (key < 0) break
            val colon = raw.indexOf(':', key + 6)
            if (colon < 0) break
            var q = colon + 1
            while (q < raw.length && raw[q].isWhitespace()) q++
            if (q >= raw.length || raw[q] != '"') { i = colon + 1; continue }
            sawTextField = true
            val (text, next, closed) = readString(raw, q + 1)
            if (text.isNotEmpty()) parts.add(text)
            if (!closed) break
            i = next
        }
        if (sawTextField) return parts.joinToString("\n")
        return raw.substringAfter('[', raw)
            .trimStart(' ', '\n', '\r', '\t', '{', '"', ',', '[', ']')
    }

    /**
     * Reads one JSON string body starting after its opening quote.
     * Returns the decoded text, where scanning stopped, and whether it was closed.
     */
    private fun readString(raw: String, from: Int): Triple<String, Int, Boolean> {
        val sb = StringBuilder()
        var j = from
        while (j < raw.length) {
            val c = raw[j]
            if (c == '"') return Triple(sb.toString(), j + 1, true)
            if (c != '\\') { sb.append(c); j++; continue }
            // A trailing lone backslash means the escape has not arrived yet.
            if (j + 1 >= raw.length) break
            when (val e = raw[j + 1]) {
                'n' -> sb.append('\n')
                't' -> sb.append('\t')
                'r' -> sb.append('\r')
                'b' -> sb.append('\b')
                'f' -> sb.append('\u000C')
                '"' -> sb.append('"')
                '\\' -> sb.append('\\')
                '/' -> sb.append('/')
                'u' -> {
                    if (j + 6 > raw.length) return Triple(sb.toString(), raw.length, false)
                    val code = raw.substring(j + 2, j + 6).toIntOrNull(16)
                        ?: return Triple(sb.toString(), raw.length, false)
                    sb.append(code.toChar())
                    j += 6
                    continue
                }
                else -> sb.append(e)
            }
            j += 2
        }
        return Triple(sb.toString(), raw.length, false)
    }
}

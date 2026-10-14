package com.jev.probe.jev

/**
 * Pulls the first complete top-level JSON object out of a model's reply text.
 *
 * A chat model asked for JSON regularly wraps it in a markdown fence or a
 * sentence ("好的，结果如下：{...}"), so the obvious slice — from the first `{`
 * to the LAST `}` — is wrong: a candidate reply quoted inside the object may
 * itself contain a brace, and that drags the cut past the real end.
 *
 * This scans with brace depth instead, ignoring braces that sit inside string
 * literals. Pure string work on purpose, so it is unit-testable without
 * Android's stubbed org.json.
 */
object JsonSlice {

    /** The first balanced `{...}` block, or null when the text holds none. */
    fun firstObject(text: String): String? {
        var depth = 0
        var start = -1
        var inString = false
        var escaped = false
        for (i in text.indices) {
            val c = text[i]
            if (inString) {
                when {
                    escaped -> escaped = false
                    c == '\\' -> escaped = true
                    c == '"' -> inString = false
                }
                continue
            }
            when (c) {
                '"' -> inString = true
                '{' -> {
                    if (depth == 0) start = i
                    depth++
                }
                '}' -> if (depth > 0) {
                    depth--
                    if (depth == 0 && start >= 0) return text.substring(start, i + 1)
                }
            }
        }
        return null
    }
}

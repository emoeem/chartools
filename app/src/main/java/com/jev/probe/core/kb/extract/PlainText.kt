package com.jev.probe.core.kb.extract

import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

/**
 * Plain text and Markdown.
 *
 * Markdown is read as plain text on purpose: this importer's output is prose fed
 * to a language model, and stripping `**`/`#`/link syntax would cost a
 * dependency (a full CommonMark parser) to remove information rather than add
 * it. The file's own text — heading markers included — is more useful in a note
 * than a rendering of it.
 *
 * Encoding is the one real decision. A UTF-8 BOM is honoured, and text that is
 * *not* valid UTF-8 is re-decoded as GBK, because a `.txt` a Chinese user saved
 * from a Windows editor or pasted out of a chat app is very often GBK, and
 * decoding those bytes as UTF-8 produces a note full of replacement characters.
 */
internal fun extractPlainText(file: File, limit: Int, sink: TextSink): Boolean {
    val bytes = readCapped(file, limit)
    if (bytes.isEmpty()) return false
    sink.append(decodeTextSmart(bytes))
    return true
}

/** A standalone HTML file, decoded the same way a text file is. */
internal fun extractHtml(file: File, limit: Int, sink: TextSink): Boolean {
    val bytes = readCapped(file, limit)
    if (bytes.isEmpty()) return false
    htmlToText(decodeTextSmart(bytes), sink)
    return true
}

/**
 * Read at most enough bytes for [limit] characters. UTF-8 uses at most 4 bytes
 * per character and GBK at most 2, so 4 × limit is always enough; the sink caps
 * the character count anyway.
 */
private fun readCapped(file: File, limit: Int): ByteArray {
    val cap = if (limit > 0 && limit < Int.MAX_VALUE / 4) limit * 4 else Int.MAX_VALUE
    return runCatching {
        file.inputStream().use { input ->
            val out = java.io.ByteArrayOutputStream()
            val buf = ByteArray(16 * 1024)
            while (out.size() < cap) {
                val want = minOf(buf.size, cap - out.size())
                val n = input.read(buf, 0, want)
                if (n < 0) break
                out.write(buf, 0, n)
            }
            out.toByteArray()
        }
    }.getOrDefault(ByteArray(0))
}

/**
 * Decode a text file: BOM first, then strict UTF-8, then GBK. A file that is
 * valid in neither is decoded as UTF-8 with replacement characters rather than
 * being refused — half a note beats no note.
 */
internal fun decodeTextSmart(bytes: ByteArray): String {
    // UTF-16 BOMs are unambiguous, so they are decided before anything else.
    if (bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte())
        return String(bytes, 2, bytes.size - 2, Charsets.UTF_16LE)
    if (bytes.size >= 2 && bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte())
        return String(bytes, 2, bytes.size - 2, Charsets.UTF_16BE)

    val body = if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() &&
        bytes[2] == 0xBF.toByte()
    ) {
        bytes.copyOfRange(3, bytes.size)
    } else {
        bytes
    }

    strictDecode(body, Charsets.UTF_8)?.let { return it }
    val gbk = runCatching { Charset.forName("GBK") }.getOrNull()
    if (gbk != null) strictDecode(body, gbk)?.let { return it }
    return String(body, Charsets.UTF_8)
}

/** Decode only if the whole input is well formed in [charset]. */
private fun strictDecode(bytes: ByteArray, charset: Charset): String? = try {
    charset.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes))
        .toString()
} catch (_: CharacterCodingException) {
    null
}

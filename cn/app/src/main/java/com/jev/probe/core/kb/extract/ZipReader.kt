package com.jev.probe.core.kb.extract

import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipFile

/**
 * Reading entries out of a ZIP container (DOCX / ODT / EPUB / PPTX / XLSX).
 *
 * `ZipFile` rather than `ZipInputStream`: an EPUB needs entries in an order the
 * archive does not store them in (container.xml → OPF → spine → the XHTML
 * parts), so random access by name is what keeps the code honest. Every call
 * opens the archive, reads one entry and closes — cheap for the handful of
 * entries this importer touches, and it means no archive handle outlives a call.
 */
internal object ZipReader {

    /** Every entry name in the archive. Empty when it is not a readable ZIP. */
    fun names(file: File): Set<String> = runCatching {
        val out = HashSet<String>()
        ZipFile(file).use { zip ->
            val en = zip.entries()
            while (en.hasMoreElements()) out.add(en.nextElement().name)
        }
        out
    }.getOrDefault(emptySet())

    /** One entry's bytes, or null when it is absent or the archive is unreadable. */
    fun bytes(file: File, name: String): ByteArray? {
        if (name.isEmpty()) return null
        return runCatching {
            ZipFile(file).use { zip ->
                val entry = zip.getEntry(name) ?: return@runCatching null
                zip.getInputStream(entry).use { readAll(it) }
            }
        }.getOrNull()
    }

    /** One entry, XML-decoded (BOM aware). Null when the entry is absent. */
    fun text(file: File, name: String): String? = bytes(file, name)?.let { decodeText(it) }
}

/** Read a stream fully, capped so a malformed archive cannot exhaust memory. */
private fun readAll(input: java.io.InputStream, cap: Int = MAX_ENTRY_BYTES): ByteArray {
    val out = ByteArrayOutputStream()
    val buf = ByteArray(16 * 1024)
    while (true) {
        val n = input.read(buf)
        if (n < 0) break
        out.write(buf, 0, n)
        if (out.size() > cap) {
            // Keep what we have; a truncated XML document fails to parse, which
            // the caller reports as "cannot read this file" rather than an OOM.
            break
        }
    }
    return out.toByteArray()
}

/**
 * One archive entry is allowed to be this large. The extracted *text* is capped
 * separately and much lower ([DocImport.MAX_CHARS]); this only exists so a
 * deliberately huge (zip-bomb) entry cannot allocate without bound.
 */
internal const val MAX_ENTRY_BYTES = 64 * 1024 * 1024

/**
 * Decode an XML/text entry. UTF-8 unless a BOM says otherwise.
 *
 * The stream is decoded here rather than handing the raw bytes to the parser:
 * with an explicit `StringReader` the same bytes produce the same text on
 * Android and on the JVM the unit tests run on, with no reliance on the
 * platform default charset.
 */
internal fun decodeText(bytes: ByteArray): String = when {
    bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() &&
        bytes[2] == 0xBF.toByte() -> String(bytes, 3, bytes.size - 3, Charsets.UTF_8)

    bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte() ->
        String(bytes, 2, bytes.size - 2, Charsets.UTF_16LE)

    bytes.size >= 2 && bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte() ->
        String(bytes, 2, bytes.size - 2, Charsets.UTF_16BE)

    else -> String(bytes, Charsets.UTF_8)
}

/**
 * Resolve a ZIP-relative reference (`href`, `Target`) against a directory
 * inside the archive: strips any `#fragment`, percent-decodes, and folds `.`
 * and `..`. A reference that tries to climb above the archive root is clamped
 * back to it, so the result is always an entry name inside the archive.
 *
 * `baseDir` is a directory path with no trailing slash, e.g. `OEBPS` or `ppt`;
 * pass "" for the archive root.
 */
internal fun resolvePath(baseDir: String, href: String): String {
    val noFragment = href.substringBefore('#')
    val decoded = percentDecode(noFragment).replace('\\', '/')
    val joined = when {
        decoded.startsWith("/") -> decoded.substring(1)
        baseDir.isEmpty() -> decoded
        else -> "$baseDir/$decoded"
    }
    val out = ArrayList<String>()
    for (part in joined.split('/')) {
        when (part) {
            "", "." -> Unit
            ".." -> if (out.isNotEmpty()) out.removeAt(out.size - 1)
            else -> out.add(part)
        }
    }
    return out.joinToString("/")
}

private fun percentDecode(s: String): String {
    if ('%' !in s) return s
    val bytes = ByteArrayOutputStream()
    var i = 0
    while (i < s.length) {
        val c = s[i]
        if (c == '%' && i + 2 < s.length) {
            val hi = hex(s[i + 1])
            val lo = hex(s[i + 2])
            if (hi >= 0 && lo >= 0) {
                bytes.write(hi * 16 + lo)
                i += 3
                continue
            }
        }
        bytes.write(c.toString().toByteArray(Charsets.UTF_8))
        i++
    }
    return String(bytes.toByteArray(), Charsets.UTF_8)
}

private fun hex(c: Char): Int = when (c) {
    in '0'..'9' -> c - '0'
    in 'a'..'f' -> c - 'a' + 10
    in 'A'..'F' -> c - 'A' + 10
    else -> -1
}

/** Directory part of an archive path, "" when the entry sits at the root. */
internal fun dirOf(path: String): String {
    val i = path.lastIndexOf('/')
    return if (i < 0) "" else path.substring(0, i)
}

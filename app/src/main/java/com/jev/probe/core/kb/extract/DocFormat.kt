package com.jev.probe.core.kb.extract

import java.io.File
import java.io.RandomAccessFile

/**
 * The document kinds this importer can turn into text. Everything outside this
 * list is refused with one sentence instead of a stack trace.
 *
 * A [DocFormat] says what the *container* is; whether a PDF actually carries a
 * text layer is a separate question answered by extraction (see [DocImport]).
 */
enum class DocFormat {
    PDF,
    DOCX,
    ODT,
    EPUB,
    PPTX,
    XLSX,
    HTML,
    MARKDOWN,
    TEXT,

    /** Legacy OLE/CFB `.doc` / `.xls` / `.ppt` — deliberately not supported. */
    OLD_OFFICE,

    /** Readable file whose kind we could not pin down. */
    UNKNOWN;

    /** True for the formats that are really a ZIP archive with XML inside. */
    val isZipContainer: Boolean
        get() = this == DOCX || this == ODT || this == EPUB || this == PPTX || this == XLSX
}

/**
 * Decide what a picked file actually is.
 *
 * Bytes win over names. A file picked through SAF can arrive with
 * `application/octet-stream` and no extension (cloud providers do this
 * constantly), and a `.docx` that is really a renamed ZIP must still be read as
 * what it is. The order is therefore:
 *
 *  1. magic bytes — PDF, OLE, ZIP. For a ZIP, the *entry names inside it* say
 *     which of DOCX / ODT / EPUB / PPTX / XLSX it is.
 *  2. extension.
 *  3. MIME type.
 *  4. if none of the above decided and the bytes look like text, call it TEXT.
 *
 * Pure `java.io` + `java.util.zip`, so this is fully unit-testable off-device.
 */
internal fun sniffFormat(file: File, displayName: String?, mime: String?): DocFormat {
    val head = readHead(file, 8)

    if (head.startsWith(PDF_MAGIC)) return DocFormat.PDF
    if (head.startsWith(OLE_MAGIC)) return DocFormat.OLD_OFFICE
    if (head.startsWith(ZIP_MAGIC) || head.startsWith(ZIP_MAGIC_EMPTY)) {
        val byEntries = sniffZipEntries(file)
        if (byEntries != null) return byEntries
        // A ZIP we cannot classify. Fall through to the name, then give up.
    }

    byExtension(displayName)?.let { return it }
    byMime(mime)?.let { return it }

    if (looksLikeText(file)) return DocFormat.TEXT
    return DocFormat.UNKNOWN
}

/** Entry names inside a ZIP identify OOXML / ODF / EPUB unambiguously. */
private fun sniffZipEntries(file: File): DocFormat? {
    val names = runCatching { ZipReader.names(file) }.getOrNull() ?: return null
    return when {
        "word/document.xml" in names -> DocFormat.DOCX
        "ppt/presentation.xml" in names -> DocFormat.PPTX
        "xl/workbook.xml" in names -> DocFormat.XLSX
        // EPUB first: an EPUB has META-INF/container.xml and no content.xml,
        // an ODT is the other way round. Checking container.xml first keeps the
        // two from ever being confused.
        "META-INF/container.xml" in names -> DocFormat.EPUB
        "content.xml" in names -> DocFormat.ODT
        else -> null
    }
}

private fun byExtension(displayName: String?): DocFormat? {
    val name = displayName?.trim().orEmpty()
    val ext = name.substringAfterLast('.', "").lowercase()
    if (ext.isEmpty() || ext == name.lowercase()) return null
    return when (ext) {
        "pdf" -> DocFormat.PDF
        "docx", "docm", "dotx" -> DocFormat.DOCX
        "odt" -> DocFormat.ODT
        "epub" -> DocFormat.EPUB
        "pptx" -> DocFormat.PPTX
        "xlsx" -> DocFormat.XLSX
        "html", "htm", "xhtml" -> DocFormat.HTML
        "md", "markdown", "mdown" -> DocFormat.MARKDOWN
        "txt", "text", "log", "csv", "tsv", "json", "xml", "yaml", "yml" -> DocFormat.TEXT
        "doc", "xls", "ppt", "dot" -> DocFormat.OLD_OFFICE
        else -> null
    }
}

private fun byMime(mime: String?): DocFormat? = when (mime?.trim()?.lowercase()) {
    "application/pdf" -> DocFormat.PDF
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" -> DocFormat.DOCX
    "application/vnd.oasis.opendocument.text" -> DocFormat.ODT
    "application/epub+zip" -> DocFormat.EPUB
    "application/vnd.openxmlformats-officedocument.presentationml.presentation" -> DocFormat.PPTX
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" -> DocFormat.XLSX
    "text/html" -> DocFormat.HTML
    "text/markdown" -> DocFormat.MARKDOWN
    "text/plain" -> DocFormat.TEXT
    "application/msword", "application/vnd.ms-excel",
    "application/vnd.ms-powerpoint" -> DocFormat.OLD_OFFICE
    else -> null
}

// ------------------------------------------------------------------- helpers

private val PDF_MAGIC = byteArrayOf(0x25, 0x50, 0x44, 0x46) // "%PDF"
private val ZIP_MAGIC = byteArrayOf(0x50, 0x4B, 0x03, 0x04)
private val ZIP_MAGIC_EMPTY = byteArrayOf(0x50, 0x4B, 0x05, 0x06)

/** OLE compound file header, i.e. the old binary Office formats. */
private val OLE_MAGIC = byteArrayOf(
    0xD0.toByte(), 0xCF.toByte(), 0x11, 0xE0.toByte(),
    0xA1.toByte(), 0xB1.toByte(), 0x1A, 0xE1.toByte()
)

private fun ByteArray.startsWith(prefix: ByteArray): Boolean {
    if (size < prefix.size) return false
    for (i in prefix.indices) if (this[i] != prefix[i]) return false
    return true
}

private fun readHead(file: File, n: Int): ByteArray = runCatching {
    RandomAccessFile(file, "r").use { raf ->
        val len = minOf(n.toLong(), raf.length()).toInt()
        val out = ByteArray(len)
        raf.readFully(out)
        out
    }
}.getOrDefault(ByteArray(0))

/**
 * A cheap "is this a text file" test: no NUL byte, and almost no C0 control
 * characters in the first 8 KiB. Binary formats that reached this point (an
 * unrecognised ZIP, an image) fail it and are refused honestly.
 */
private fun looksLikeText(file: File): Boolean {
    val head = readHead(file, 8192)
    if (head.isEmpty()) return false
    var control = 0
    for (b in head) {
        val v = b.toInt() and 0xFF
        if (v == 0) return false
        if (v < 0x09 || (v in 0x0E..0x1F)) control++
    }
    return control * 20 < head.size
}

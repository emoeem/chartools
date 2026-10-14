package com.jev.probe.core.kb.extract

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Format detection decides which extractor runs, so a wrong answer here is a
 * wrong answer for every file. Every case below is a real file shape: the ZIP
 * containers are identified by the parts inside them, and the old binary Office
 * formats are identified by their OLE header *even when the name lies*, because
 * a `.doc` renamed to `.docx` is a common way for one to arrive.
 */
class DocFormatTest {

    private fun sniff(bytes: ByteArray, name: String?, mime: String? = null): DocFormat =
        sniffFormat(tempFile(bytes, ".bin"), name, mime)

    private fun firstOf(vararg pairs: Pair<String, String>) = zipOf(*pairs)

    @Test
    fun `pdf is recognised by its header`() {
        val bytes = "%PDF-1.7\n".toByteArray() + ByteArray(64)
        assertEquals(DocFormat.PDF, sniff(bytes, "unknown-name"))
    }

    @Test
    fun `old binary office is recognised by its header even when the name lies`() {
        val ole = byteArrayOf(
            0xD0.toByte(), 0xCF.toByte(), 0x11, 0xE0.toByte(),
            0xA1.toByte(), 0xB1.toByte(), 0x1A, 0xE1.toByte()
        ) + ByteArray(1024)
        assertEquals(DocFormat.OLD_OFFICE, sniff(ole, "report.docx"))
        assertEquals(DocFormat.OLD_OFFICE, sniff(ole, "legacy.xls"))
    }

    @Test
    fun `docx is recognised by the part inside the zip`() {
        val zip = firstOf("word/document.xml" to "<w:document/>", "[Content_Types].xml" to "<Types/>")
        assertEquals(DocFormat.DOCX, sniff(zip, "document.bin"))
        assertEquals(DocFormat.DOCX, sniff(zip, null, "application/octet-stream"))
    }

    @Test
    fun `odt is recognised by content xml`() {
        val zip = firstOf("mimetype" to "application/vnd.oasis.opendocument.text", "content.xml" to "<x/>")
        assertEquals(DocFormat.ODT, sniff(zip, "notes.bin"))
    }

    @Test
    fun `epub is recognised by the container and is not mistaken for an odt`() {
        // container.xml is how an EPUB is identified; content.xml is how an ODT
        // is. An odd file can carry both, and the container wins.
        val onlyContainer = firstOf("META-INF/container.xml" to "<container/>")
        assertEquals(DocFormat.EPUB, sniff(onlyContainer, "book.bin"))

        val both = firstOf("META-INF/container.xml" to "<container/>", "content.xml" to "<x/>")
        assertEquals(DocFormat.EPUB, sniff(both, "ambiguous.bin"))
    }

    @Test
    fun `pptx and xlsx are recognised by their parts`() {
        assertEquals(
            DocFormat.PPTX,
            sniff(firstOf("ppt/presentation.xml" to "<p:presentation/>"), "deck.bin")
        )
        assertEquals(
            DocFormat.XLSX,
            sniff(firstOf("xl/workbook.xml" to "<workbook/>"), "book.bin")
        )
    }

    @Test
    fun `a zip that cannot be classified falls back to the file name`() {
        // An unusual OOXML container still has a truthful extension.
        val zip = firstOf("unrelated/part.xml" to "<x/>")
        assertEquals(DocFormat.DOCX, sniff(zip, "Chapter 1.docx"))
        assertEquals(DocFormat.TEXT, sniff(zip, "notes.txt"))
    }

    @Test
    fun `extension detection is case insensitive and needs a real dot`() {
        val text = "hello world, this is prose.\n".toByteArray()
        assertEquals(DocFormat.MARKDOWN, sniff(text, "README.MD"))
        assertEquals(DocFormat.HTML, sniff(text, "page.HTM"))
        assertEquals(DocFormat.TEXT, sniff(text, "no-extension"))
        assertEquals(DocFormat.TEXT, sniff(text, "md"))
    }

    @Test
    fun `mime type is used when the name gives nothing away`() {
        val text = "hello prose\n".toByteArray()
        assertEquals(DocFormat.PDF, sniff(text, "blob", "application/pdf"))
        assertEquals(DocFormat.HTML, sniff(text, "blob", "text/html"))
        assertEquals(DocFormat.TEXT, sniff(text, "blob", "text/plain"))
        // A .doc MIME type is the old binary format, which is refused on purpose.
        assertEquals(DocFormat.OLD_OFFICE, sniff(text, "blob", "application/msword"))
    }

    @Test
    fun `unlabelled prose is treated as text and real binary is refused`() {
        assertEquals(DocFormat.TEXT, sniff("普通的中文文本，没有 BOM。".toByteArray(), null))

        val binary = ByteArray(256) { (it % 251).toByte() }
        binary[10] = 0
        assertEquals(DocFormat.UNKNOWN, sniff(binary, null))
    }

    @Test
    fun `zip containers are flagged for the zip based import path`() {
        for (format in listOf(
            DocFormat.DOCX, DocFormat.ODT, DocFormat.EPUB, DocFormat.PPTX, DocFormat.XLSX
        )) {
            assertEquals(true, format.isZipContainer)
        }
        for (format in listOf(DocFormat.PDF, DocFormat.HTML, DocFormat.TEXT, DocFormat.OLD_OFFICE)) {
            assertEquals(false, format.isZipContainer)
        }
    }
}

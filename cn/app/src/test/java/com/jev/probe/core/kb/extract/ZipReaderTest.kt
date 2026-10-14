package com.jev.probe.core.kb.extract

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Archive plumbing: reading an entry by name, decoding it, and resolving the
 * relative references EPUB and OOXML use to point at each other. These are the
 * parts whose bugs surface as "the import produced nothing" with no error, so
 * each rule gets pinned down here rather than discovered on a device.
 */
class ZipReaderTest {

    @Test
    fun `entries are read by name regardless of their order in the archive`() {
        val bytes = zipOf(
            "zzz/last.xml" to "<a>last</a>",
            "aaa/first.xml" to "<a>first</a>",
            "中文/目录.txt" to "中文内容"
        )
        val file = tempFile(bytes, ".zip")

        assertEquals("<a>first</a>", ZipReader.text(file, "aaa/first.xml"))
        assertEquals("中文内容", ZipReader.text(file, "中文/目录.txt"))
        assertTrue("aaa/first.xml" in ZipReader.names(file))
        assertEquals(3, ZipReader.names(file).size)

        file.delete()
    }

    @Test
    fun `a missing entry is null, not an exception`() {
        val file = tempFile(zipOf("only.xml" to "<x/>"), ".zip")
        assertNull(ZipReader.text(file, "not/here.xml"))
        assertNull(ZipReader.bytes(file, "not/here.xml"))
        file.delete()
    }

    @Test
    fun `a file that is not an archive is null, not a crash`() {
        val file = tempFile("this is not a zip".toByteArray(), ".zip")
        assertTrue(ZipReader.names(file).isEmpty())
        assertNull(ZipReader.text(file, "anything"))
        file.delete()
    }

    @Test
    fun `a utf8 bom is stripped and utf16 is decoded`() {
        val bom = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())
        assertEquals("hello", decodeText(bom + "hello".toByteArray(Charsets.UTF_8)))

        val le = byteArrayOf(0xFF.toByte(), 0xFE.toByte()) + "中文".toByteArray(Charsets.UTF_16LE)
        assertEquals("中文", decodeText(le))

        val be = byteArrayOf(0xFE.toByte(), 0xFF.toByte()) + "中文".toByteArray(Charsets.UTF_16BE)
        assertEquals("中文", decodeText(be))
    }

    @Test
    fun `relative references are resolved against the package directory`() {
        assertEquals("OEBPS/text/ch1.xhtml", resolvePath("OEBPS", "text/ch1.xhtml"))
        assertEquals("text/ch1.xhtml", resolvePath("", "text/ch1.xhtml"))
        assertEquals("OEBPS/ch1.xhtml", resolvePath("OEBPS", "./ch1.xhtml"))
        assertEquals("OEBPS/ch1.xhtml", resolvePath("OEBPS/text", "../ch1.xhtml"))
        assertEquals("ppt/slides/slide1.xml", resolvePath("ppt/slides", "slide1.xml"))
        // An absolute-looking href is still inside the archive.
        assertEquals("OEBPS/ch1.xhtml", resolvePath("OEBPS", "/OEBPS/ch1.xhtml"))
    }

    @Test
    fun `fragments are dropped and percent escapes are decoded`() {
        assertEquals("OEBPS/ch1.xhtml", resolvePath("OEBPS", "ch1.xhtml#section-2"))
        assertEquals("OEBPS/我的 文件.xhtml", resolvePath("OEBPS", "%E6%88%91%E7%9A%84%20%E6%96%87%E4%BB%B6.xhtml"))
        // A stray percent is literal text, not a half decoded escape.
        assertEquals("OEBPS/100%.xhtml", resolvePath("OEBPS", "100%.xhtml"))
    }

    @Test
    fun `a reference can never climb out of the archive`() {
        assertEquals("ch1.xhtml", resolvePath("OEBPS", "../../ch1.xhtml"))
        assertEquals("etc/passwd", resolvePath("OEBPS", "../../../etc/./passwd"))
        assertFalse(resolvePath("OEBPS", "../../../../secret").startsWith(".."))
    }

    @Test
    fun `backslashes and doubled separators are normalised`() {
        assertEquals("OEBPS/text/ch1.xhtml", resolvePath("OEBPS", "text\\ch1.xhtml"))
        assertEquals("OEBPS/text/ch1.xhtml", resolvePath("OEBPS//text", "../text//ch1.xhtml"))
    }

    @Test
    fun `the directory of a path is its parent`() {
        assertEquals("OEBPS", dirOf("OEBPS/content.opf"))
        assertEquals("", dirOf("content.opf"))
        assertEquals("a/b", dirOf("a/b/c.xml"))
    }
}

package com.jev.probe.core.kb.extract

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.charset.Charset

/**
 * HTML and plain text. The HTML test pins down the part that matters: markup
 * structure becomes paragraph breaks while inline tags do not, and script and
 * style contents never reach the note. The text tests cover the encoding
 * decision, which for a Chinese user's `.txt` file is the difference between a
 * readable note and a page of replacement characters.
 */
class HtmlPlainTest {

    @Test
    fun `html turns block elements into paragraphs and keeps inline text joined`() {
        val html = """
            <html><head><title>Page title</title><style>p{color:red}</style></head>
            <body>
              <h1>Heading</h1>
              <p>One <b>two</b> three</p>
              <div>Second block</div>
              <ul><li>first item</li><li>second item</li></ul>
              <script>doSomething();</script>
            </body></html>
        """.trimIndent()

        val sink = TextSink(10_000)
        htmlToText(html, sink)
        val text = sink.toString()

        assertEquals("Heading\nOne two three\nSecond block\nfirst item\nsecond item", text)
        assertFalse(text.contains("doSomething"))
        assertFalse(text.contains("Page title"))
        assertFalse(text.contains("color:red"))
    }

    @Test
    fun `html turns br into a line break and keeps image alt text`() {
        val html = "<body><p>line one<br>line two</p><p><img alt=\"a chart\">after</p></body>"
        val sink = TextSink(10_000)
        htmlToText(html, sink)
        assertEquals("line one\nline two\na chart after", sink.toString())
    }

    @Test
    fun `html that is not well formed is still read`() {
        // A picked .html file is frequently not XML; this must not end the parse.
        val html = "<html><body><p>before<br>after</p><p>unclosed"
        val sink = TextSink(10_000)
        htmlToText(html, sink)
        assertEquals("before\nafter\nunclosed", sink.toString())
    }

    @Test
    fun `plain text keeps its own line structure`() {
        val file = tempFile("第一行\n第二行\n\n第四行".toByteArray(Charsets.UTF_8), ".txt")
        val sink = TextSink(10_000)
        assertTrue(extractPlainText(file, 10_000, sink))
        // The blank line is preserved by the extractor; the chunker is what
        // collapses it into a paragraph boundary.
        assertEquals("第一行\n第二行\n\n第四行", sink.toString())
        file.delete()
    }

    @Test
    fun `markdown is imported as its own text`() {
        val file = tempFile("# Title\n\nSome **bold** prose.".toByteArray(Charsets.UTF_8), ".md")
        val sink = TextSink(10_000)
        assertTrue(extractPlainText(file, 10_000, sink))
        assertEquals("# Title\n\nSome **bold** prose.", sink.toString())
        file.delete()
    }

    @Test
    fun `a utf8 bom is stripped from a text file`() {
        val bytes = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) +
            "中文内容".toByteArray(Charsets.UTF_8)
        val file = tempFile(bytes, ".txt")
        val sink = TextSink(10_000)
        extractPlainText(file, 10_000, sink)
        assertEquals("中文内容", sink.toString())
        file.delete()
    }

    @Test
    fun `gbk text is decoded instead of turning into replacement characters`() {
        // What a Chinese user's .txt is very often saved as on Windows.
        val original = "这是一段 GBK 编码的中文文本。"
        val bytes = original.toByteArray(Charset.forName("GBK"))
        val file = tempFile(bytes, ".txt")
        val sink = TextSink(10_000)
        assertTrue(extractPlainText(file, 10_000, sink))

        val text = sink.toString()
        assertEquals(original, text)
        assertFalse("no replacement characters", text.contains('\uFFFD'))
        file.delete()
    }

    @Test
    fun `utf16 text with a bom is decoded`() {
        val le = byteArrayOf(0xFF.toByte(), 0xFE.toByte()) + "小端".toByteArray(Charsets.UTF_16LE)
        assertEquals("小端", decodeTextSmart(le))
        val be = byteArrayOf(0xFE.toByte(), 0xFF.toByte()) + "大端".toByteArray(Charsets.UTF_16BE)
        assertEquals("大端", decodeTextSmart(be))
    }

    @Test
    fun `an empty file extracts nothing and is not an error worth a crash`() {
        val file = tempFile(ByteArray(0), ".txt")
        val sink = TextSink(10_000)
        assertFalse(extractPlainText(file, 10_000, sink))
        file.delete()
    }

    @Test
    fun `a standalone html file goes through the same html reader`() {
        val file = tempFile("<html><body><p>hi</p></body></html>".toByteArray(Charsets.UTF_8), ".html")
        val sink = TextSink(10_000)
        assertTrue(extractHtml(file, 10_000, sink))
        assertEquals("hi", sink.toString())
        file.delete()
    }

    // ------------------------------------------------------------- TextSink

    @Test
    fun `the sink stops at its ceiling and reports the truncation`() {
        val sink = TextSink(10)
        sink.append("0123456789")
        assertEquals(10, sink.length)
        assertFalse(sink.truncated)

        sink.append("more")
        assertTrue(sink.truncated)
        assertEquals(10, sink.length)
        assertEquals("0123456789", sink.toString())
    }

    @Test
    fun `whitespace only overflow is not counted as lost text`() {
        val sink = TextSink(4)
        sink.append("abcd")
        sink.append("   \n")
        assertFalse(sink.truncated)
    }

    @Test
    fun `the sink collapses whitespace runs and never doubles a separator`() {
        val sink = TextSink(1000)
        sink.appendFlow("  one   two ")
        sink.newline()
        sink.newline()
        sink.appendFlow("three")
        sink.space()
        sink.space()
        sink.appendFlow("four")
        assertEquals("one two\nthree four", sink.toString())
    }
}

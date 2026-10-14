package com.jev.probe.core.kb.extract

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ODT and EPUB — the two formats whose text is not where a naive reader would
 * look for it. An ODT hides a reviewer's comment inside the paragraph it
 * annotates; an EPUB's reading order is a spine in a manifest, not the order the
 * ZIP stores its chapters.
 */
class OdfEpubTest {

    private val officeNs = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    private val textNs = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    private val tableNs = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"

    // ------------------------------------------------------------------- ODT

    @Test
    fun `odt reads paragraphs, spans, spaces and line breaks`() {
        val content = """
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-content
                xmlns:office="$officeNs" xmlns:text="$textNs" xmlns:table="$tableNs">
              <office:body><office:text>
                <text:p>Hello <text:span>bold</text:span> tail<text:s/>end</text:p>
                <text:p>Second<text:line-break/>line</text:p>
                <text:h>Heading</text:h>
                <table:table-row>
                  <table:table-cell><text:p>cell one</text:p></table:table-cell>
                  <table:table-cell><text:p>cell two</text:p></table:table-cell>
                </table:table-row>
              </office:text></office:body>
            </office:document-content>
        """.trimIndent()

        val text = extractZip(zipOf("content.xml" to content, "mimetype" to ""), ".odt") { file, xml, sink ->
            extractOdt(file, xml, sink)
        }

        // A span joins its sentence, text:s is a space, line-break ends a line,
        // and each table cell stays a paragraph of its own.
        assertEquals(
            "Hello bold tail end\nSecond\nline\nHeading\ncell one\ncell two",
            text
        )
    }

    @Test
    fun `odt skips a reviewer comment even though it sits inside a paragraph`() {
        val content = """
            <office:document-content xmlns:office="$officeNs" xmlns:text="$textNs">
              <office:body><office:text>
                <text:p>Visible<office:annotation><text:p>hidden comment</text:p></office:annotation> tail</text:p>
                <text:p>Next paragraph</text:p>
              </office:text></office:body>
            </office:document-content>
        """.trimIndent()

        val text = extractZip(zipOf("content.xml" to content), ".odt") { file, xml, sink ->
            extractOdt(file, xml, sink)
        }
        assertFalse("the comment must not appear", text.contains("hidden"))
        assertEquals("Visible tail\nNext paragraph", text)
    }

    @Test
    fun `a zip without content xml is reported as unreadable`() {
        val file = tempFile(zipOf("META-INF/manifest.xml" to "<x/>"), ".odt")
        val sink = TextSink(1000)
        assertFalse(extractOdt(file, TEST_XML, sink))
        file.delete()
    }

    // ------------------------------------------------------------------ EPUB

    @Test
    fun `epub reads the spine order and resolves relative chapter paths`() {
        val container = """
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
        """.trimIndent()
        // The spine deliberately lists chapter two first: that is the reading
        // order, while the filenames say otherwise.
        val opf = """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <manifest>
                <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="c2"/>
                <itemref idref="c1"/>
              </spine>
            </package>
        """.trimIndent()
        val page = { heading: String, body: String ->
            """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>$heading</title></head>
            <body><h1>$heading</h1><p>$body</p></body></html>
            """.trimIndent()
        }

        val bytes = zipOf(
            "META-INF/container.xml" to container,
            "OEBPS/content.opf" to opf,
            "OEBPS/text/ch1.xhtml" to page("Chapter one", "First body"),
            "OEBPS/text/ch2.xhtml" to page("Chapter two", "Second body"),
            "OEBPS/nav.xhtml" to page("Navigation", "should not be read")
        )

        val text = extractZip(bytes, ".epub") { file, xml, sink -> extractEpub(file, xml, sink) }

        assertEquals("Chapter two\nSecond body\nChapter one\nFirst body", text)
        assertFalse("the nav document is not part of the spine", text.contains("should not be read"))
    }

    @Test
    fun `epub falls back to content documents when the spine is empty`() {
        val container = """
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles><rootfile full-path="book.opf"/></rootfiles>
            </container>
        """.trimIndent()
        val opf = """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest>
            </package>
        """.trimIndent()

        val bytes = zipOf(
            "META-INF/container.xml" to container,
            "book.opf" to opf,
            // slide10 style ordering: the ordering test must be numeric.
            "c1.xhtml" to "<html><body><p>one</p></body></html>",
            "c2.xhtml" to "<html><body><p>two</p></body></html>",
            "c10.xhtml" to "<html><body><p>ten</p></body></html>"
        )

        val text = extractZip(bytes, ".epub") { file, xml, sink -> extractEpub(file, xml, sink) }
        assertEquals("one\ntwo\nten", text)
    }

    @Test
    fun `an epub with no package document is reported as unreadable`() {
        val file = tempFile(zipOf("mimetype" to "application/epub+zip"), ".epub")
        val sink = TextSink(1000)
        assertFalse(extractEpub(file, TEST_XML, sink))
        file.delete()
        assertTrue(sink.toString().isEmpty())
    }
}

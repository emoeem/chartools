package com.jev.probe.core.kb.extract

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The OOXML extractors. Each one is written against a part of the file format
 * that is easy to get wrong and invisible when it is: DOCX field codes that are
 * not prose, PPTX slides whose reading order is a relationship graph rather than
 * a filename order, XLSX cells that are indices into a separate part.
 */
class OoxmlTest {

    private val wNs = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private val aNs = "http://schemas.openxmlformats.org/drawingml/2006/main"
    private val pNs = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private val rNs = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    // ------------------------------------------------------------------ DOCX

    @Test
    fun `docx reads runs, breaks paragraphs and skips field codes`() {
        val document = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="$wNs">
              <w:body>
                <w:p><w:r><w:t>Hello </w:t></w:r><w:r><w:t>world</w:t></w:r></w:p>
                <w:p><w:r><w:t>Second</w:t><w:tab/><w:t>tabbed</w:t></w:r></w:p>
                <w:p><w:r><w:t>Field: </w:t><w:instrText>PAGE \* MERGEFORMAT</w:instrText></w:r></w:p>
                <w:p><w:r><w:delText>deleted revision</w:delText><w:t>Kept</w:t></w:r></w:p>
                <w:p/>
              </w:body>
            </w:document>
        """.trimIndent()

        val text = extractZip(zipOf("word/document.xml" to document), ".docx") { file, xml, sink ->
            extractDocx(file, xml, sink)
        }

        // Runs join without a space, a tab is a space, field codes and deleted
        // revisions never appear, and an empty paragraph leaves no gap.
        assertEquals("Hello world\nSecond tabbed\nField:\nKept", text)
    }

    @Test
    fun `docx line breaks stay inside the paragraph`() {
        val document = """
            <w:document xmlns:w="$wNs"><w:body>
              <w:p><w:r><w:t>first</w:t><w:br/><w:t>second</w:t></w:r></w:p>
              <w:p><w:r><w:t>third</w:t></w:r></w:p>
            </w:body></w:document>
        """.trimIndent()

        val text = extractZip(zipOf("word/document.xml" to document), ".docx") { file, xml, sink ->
            extractDocx(file, xml, sink)
        }
        assertEquals("first\nsecond\nthird", text)
    }

    @Test
    fun `a zip without the document part is reported as unreadable`() {
        val file = tempFile(zipOf("word/other.xml" to "<x/>"), ".docx")
        val sink = TextSink(1000)
        assertFalse(extractDocx(file, TEST_XML, sink))
        file.delete()
    }

    // ------------------------------------------------------------------ PPTX

    @Test
    fun `pptx follows the slide order from the presentation, not the filename order`() {
        // Reading order is the opposite of the filenames, and slide3 is not
        // mentioned by number anywhere in the presentation part — so this only
        // passes if the relationship id is resolved through the .rels file. A
        // broken lookup would fall back to slide2, slide3 and read Alpha first.
        val presentation = """
            <p:presentation xmlns:p="$pNs" xmlns:r="$rNs">
              <p:sldIdLst>
                <p:sldId id="256" r:id="rId3"/>
                <p:sldId id="257" r:id="rId2"/>
              </p:sldIdLst>
            </p:presentation>
        """.trimIndent()
        val rels = """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId2" Type="$rNs/slide" Target="slides/slide2.xml"/>
              <Relationship Id="rId3" Type="$rNs/slide" Target="slides/slide3.xml"/>
            </Relationships>
        """.trimIndent()

        val bytes = zipOf(
            "ppt/presentation.xml" to presentation,
            "ppt/_rels/presentation.xml.rels" to rels,
            "ppt/slides/slide2.xml" to slide("Alpha"),
            "ppt/slides/slide3.xml" to slide("Beta", "one more line")
        )

        val text = extractZip(bytes, ".pptx") { file, xml, sink -> extractPptx(file, xml, sink) }
        assertEquals("Beta\none more line\nAlpha", text)
    }

    @Test
    fun `pptx falls back to numeric slide order when the relationship part is missing`() {
        val bytes = zipOf(
            "ppt/presentation.xml" to
                """<p:presentation xmlns:p="$pNs" xmlns:r="$rNs"><p:sldIdLst/></p:presentation>""",
            "ppt/slides/slide1.xml" to slide("One"),
            "ppt/slides/slide2.xml" to slide("Two"),
            "ppt/slides/slide10.xml" to slide("Ten")
        )

        val text = extractZip(bytes, ".pptx") { file, xml, sink -> extractPptx(file, xml, sink) }
        // slide2 sorts before slide10 because the ordering test is numeric.
        assertEquals("One\nTwo\nTen", text)
    }

    @Test
    fun `a relationship file is located by the part file name, not its folder`() {
        // OOXML names this `presentation.xml.rels`, not `presentation.rels`.
        // Getting that wrong silently degrades to filename order, so it is
        // pinned here rather than only through the effect on a deck.
        val rels = """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="slide" Target="slides/slide1.xml"/>
            </Relationships>
        """.trimIndent()
        val file = tempFile(zipOf("ppt/_rels/presentation.xml.rels" to rels), ".pptx")

        assertEquals("ppt/slides/slide1.xml", relsMap(file, "ppt/presentation.xml", TEST_XML)["rId1"])
        assertTrue(
            "the folder-name form is not a file PowerPoint writes",
            relsMap(file, "ppt", TEST_XML).isEmpty()
        )
        file.delete()
    }

    private fun slide(vararg lines: String): String {
        val body = lines.joinToString("") { "<a:p><a:r><a:t>$it</a:t></a:r></a:p>" }
        return """<p:sld xmlns:p="$pNs" xmlns:a="$aNs"><p:cSld><p:spTree><p:sp>""" +
            """<p:txBody>$body</p:txBody></p:sp></p:spTree></p:cSld></p:sld>"""
    }

    // ------------------------------------------------------------------ XLSX

    @Test
    fun `xlsx reads shared strings, inline strings and literal values in row order`() {
        val shared = """
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <si><t>Alpha</t></si>
              <si><r><t>Be</t></r><r><t>ta</t></r></si>
              <si><rPh sb="0" eb="1"><t>phonetic</t></rPh><t>Gamma</t></si>
            </sst>
        """.trimIndent()
        val sheet = """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <sheetData>
                <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
                <row r="2"><c r="A2" t="inlineStr"><is><t>inline text</t></is></c><c r="B2"><v>42</v></c></row>
              </sheetData>
            </worksheet>
        """.trimIndent()
        val workbook = """
            <workbook xmlns="$pNs" xmlns:r="$rNs">
              <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
            </workbook>
        """.trimIndent()
        val rels = """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="$rNs/worksheet" Target="worksheets/sheet1.xml"/>
            </Relationships>
        """.trimIndent()

        val bytes = zipOf(
            "xl/sharedStrings.xml" to shared,
            "xl/workbook.xml" to workbook,
            "xl/_rels/workbook.xml.rels" to rels,
            "xl/worksheets/sheet1.xml" to sheet
        )

        val text = extractZip(bytes, ".xlsx") { file, xml, sink -> extractXlsx(file, xml, sink) }

        // A shared string split across runs is one cell; phonetics are not text;
        // the sheet name is a heading; a row is one line.
        assertEquals("Sheet1\nAlpha Beta\ninline text 42", text)
    }

    @Test
    fun `xlsx lists every sheet in workbook order`() {
        val workbook = """
            <workbook xmlns="$pNs" xmlns:r="$rNs">
              <sheets>
                <sheet name="First" sheetId="1" r:id="rId1"/>
                <sheet name="Second" sheetId="2" r:id="rId2"/>
              </sheets>
            </workbook>
        """.trimIndent()
        val rels = """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="$rNs/worksheet" Target="worksheets/sheet1.xml"/>
              <Relationship Id="rId2" Type="$rNs/worksheet" Target="worksheets/sheet2.xml"/>
            </Relationships>
        """.trimIndent()
        val sheet = { value: String ->
            """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <sheetData><row r="1"><c r="A1"><v>$value</v></c></row></sheetData>
            </worksheet>
            """.trimIndent()
        }

        val bytes = zipOf(
            "xl/workbook.xml" to workbook,
            "xl/_rels/workbook.xml.rels" to rels,
            "xl/worksheets/sheet1.xml" to sheet("10"),
            "xl/worksheets/sheet2.xml" to sheet("20")
        )

        val text = extractZip(bytes, ".xlsx") { file, xml, sink -> extractXlsx(file, xml, sink) }
        assertEquals("First\n10\nSecond\n20", text)
    }

    @Test
    fun `a zip with no sheets is reported as unreadable`() {
        val file = tempFile(zipOf("xl/other.xml" to "<x/>"), ".xlsx")
        val sink = TextSink(1000)
        assertFalse(extractXlsx(file, TEST_XML, sink))
        file.delete()
        assertTrue(sink.toString().isEmpty())
    }
}

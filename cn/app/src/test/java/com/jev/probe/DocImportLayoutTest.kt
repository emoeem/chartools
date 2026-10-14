package com.jev.probe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.kxml2.io.KXmlParser
import org.xmlpull.v1.XmlPullParser
import java.io.File
import java.io.StringReader

/**
 * Structural guard on the document-import screen.
 *
 * The bug this pins down was not cosmetic. The per-file report used to sit
 * *outside* the only scrolling region and grew one line per file with no
 * ceiling; the preview ScrollView carried `layout_weight="1"`, so it absorbed
 * that growth until it was zero pixels tall, and the next thing after it — the
 * "保存到知识库" row — was pushed past the bottom of the screen. Nothing on that
 * screen could scroll to it, so a 20-file import could not be saved at all. The
 * bounds measured on the device were `docStatus = [48,757][1032,2244]` with the
 * save and clear buttons absent from the accessibility tree entirely.
 *
 * The invariant is therefore about containment, not pixels:
 *
 *   - every view the activity fills with unbounded text is inside the ScrollView
 *   - the buttons are outside it, so no amount of text can displace them
 *
 * A layout file is a regular XML document, so this needs no Android runtime —
 * kxml2 is already a test dependency (Android's own parser factory is a stub in
 * a JVM unit test; see [com.jev.probe.core.kb.extract.TEST_XML]).
 */
class DocImportLayoutTest {

    private val layout = listOf(
        File("src/main/res/layout/activity_doc_import.xml"),
        File("../app/src/main/res/layout/activity_doc_import.xml")
    ).first { it.isFile }

    /** Element name of every view that declares [id], with its ancestor names. */
    private fun ancestry(): Map<String, List<String>> {
        val parser = KXmlParser()
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
        parser.setInput(StringReader(layout.readText()))
        val stack = ArrayList<String>()
        val out = HashMap<String, List<String>>()
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            when (event) {
                XmlPullParser.START_TAG -> {
                    stack.add(parser.name)
                    // Namespaces are off, so the attribute name stays the literal
                    // "android:id" rather than being split into uri + local name.
                    val id = parser.getAttributeValue(null, "android:id")
                        ?: parser.getAttributeValue(null, "id")
                    if (id != null) out[id.removePrefix("@+id/")] = ArrayList(stack)
                }
                XmlPullParser.END_TAG -> stack.removeAt(stack.size - 1)
            }
            event = parser.next()
        }
        return out
    }

    private fun insideScrollView(id: String): Boolean {
        val chain = ancestry()[id] ?: error("no view with id $id in $layout")
        return chain.contains("ScrollView")
    }

    @Test
    fun theReportScrollsWithTheContentItDescribes() {
        // The regression: this TextView was a sibling of the ScrollView, not a
        // child, so its growth displaced everything below it.
        assertTrue(
            "docStatus must live inside the ScrollView, or a long report pushes the buttons off screen",
            insideScrollView("docStatus")
        )
    }

    @Test
    fun thePreviewScrolls() {
        assertTrue(insideScrollView("docPreview"))
    }

    @Test
    fun theSaveButtonCannotBeDisplacedByContent() {
        assertFalse(
            "docSave must stay outside the scrolling region so it is always reachable",
            insideScrollView("docSave")
        )
        assertFalse(insideScrollView("docClear"))
    }

    @Test
    fun everyViewTheActivityWritesLongTextIntoIsAccountedFor() {
        // A cheap guard against the screen growing a new unbounded label that
        // nobody thought about: exactly these two ids hold variable-length text.
        val ids = ancestry().keys.filter { it.startsWith("doc") }.sorted()
        assertEquals(
            listOf("docClear", "docPick", "docPreview", "docProgress", "docRoot", "docSave", "docStatus", "docUrl"),
            ids
        )
    }
}

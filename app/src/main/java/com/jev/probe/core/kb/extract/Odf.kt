package com.jev.probe.core.kb.extract

import org.xmlpull.v1.XmlPullParser
import java.io.File

/**
 * ODF text (`.odt`) → prose, from the single `content.xml` part.
 *
 * An ODF document puts everything — including its styles and its comments — in
 * one entry, so this walks `office:document-content/office:body/office:text` and
 * reads the text containers. `<text:p>` and `<text:h>` (heading) are paragraphs;
 * `<text:span>` and `<text:a>` are inline; `<text:s>` is a run of spaces whose
 * count is in `text:c`; `<text:line-break>` and `<text:tab>` speak for
 * themselves. `office:annotation` is a reviewer's comment and is skipped whole,
 * because it sits inside the same paragraph as the text it annotates.
 */

private const val NS_TEXT = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
private const val NS_TABLE = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
private const val NS_OFFICE = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"

internal fun extractOdt(file: File, factory: XmlFactory, sink: TextSink): Boolean {
    val xml = ZipReader.text(file, "content.xml") ?: return false
    val parser = xmlParser(factory, xml)
    var skipDepth = 0
    walkXml(parser) { p ->
        if (skipDepth > 0) {
            when (p.eventType) {
                XmlPullParser.START_TAG -> skipDepth++
                XmlPullParser.END_TAG -> skipDepth--
            }
            return@walkXml
        }
        when (p.eventType) {
            XmlPullParser.START_TAG -> when {
                p.isTag("annotation") && p.nsIn(NS_OFFICE) -> skipDepth = 1
                p.isTag("s") && p.nsIn(NS_TEXT) -> {
                    // text:c is the space count; it is honoured only as "there
                    // is a space here", since a run of them carries no meaning
                    // this importer preserves.
                    sink.space()
                }
                p.isTag("tab") && p.nsIn(NS_TEXT) -> sink.space()
                p.isTag("line-break") && p.nsIn(NS_TEXT) -> sink.newline()
            }
            XmlPullParser.TEXT -> sink.appendFlow(p.text)
            XmlPullParser.END_TAG -> when {
                p.isTag("p", "h") && p.nsIn(NS_TEXT) -> sink.newline()
                p.isTag("table-row") && p.nsIn(NS_TABLE) -> sink.newline()
            }
        }
    }
    return true
}

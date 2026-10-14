package com.jev.probe.core.kb.extract

import android.util.Xml
import org.xmlpull.v1.XmlPullParser
import java.io.Reader
import java.io.StringReader

/**
 * Which pull-parser implementation to use.
 *
 * Production always uses Android's own `android.util.Xml.newPullParser()`, which
 * is the platform's kxml2. Unit tests on the JVM cannot call it (`android.util`
 * is a stub outside an emulator), so they inject kxml2 directly instead. Keeping
 * the choice behind this typealias means the parsing code under test is the same
 * code that ships — only the parser factory differs.
 */
internal typealias XmlFactory = () -> XmlPullParser

/** The production parser: the one bundled with Android. */
internal val AndroidXml: XmlFactory = { Xml.newPullParser() }

/**
 * A pull parser over an in-memory XML string.
 *
 * The document is already decoded text, so there is no BOM, no charset puzzle
 * and no `<?xml ?>` guessing left to do; `setInput` with a null encoding tells
 * the parser to trust the reader.
 */
internal fun xmlParser(factory: XmlFactory, text: String): XmlPullParser =
    factory().apply { setInput(StringReader(text)) }

internal fun xmlParser(factory: XmlFactory, reader: Reader): XmlPullParser =
    factory().apply { setInput(reader) }

/**
 * Walk the document and let [onEvent] decide what to do with each event.
 *
 * Two things every extractor needs are handled here so they cannot be forgotten
 * or got wrong per format:
 *
 *  - `next()` rather than `nextTag()`, because `nextTag()` skips the *text*
 *    events these extractors exist to collect.
 *  - malformed XML ends the walk quietly. A real-world OOXML/ODF/EPUB file is
 *    occasionally truncated, and half a document's text is far better for the
 *    user than an exception that saves nothing. The caller can tell the
 *    difference because the returned flag says whether the document ended
 *    normally.
 */
internal inline fun walkXml(
    parser: XmlPullParser,
    onEvent: (parser: XmlPullParser) -> Unit
): Boolean {
    var event = parser.eventType
    while (event != XmlPullParser.END_DOCUMENT) {
        try {
            when (event) {
                XmlPullParser.START_TAG -> onEvent(parser)
                XmlPullParser.TEXT -> onEvent(parser)
                XmlPullParser.END_TAG -> onEvent(parser)
                else -> Unit
            }
            event = parser.next()
        } catch (_: Exception) {
            return false
        }
    }
    return true
}

/** Local name compared against any of [names] — namespace prefixes ignored. */
internal fun XmlPullParser.isTag(vararg names: String): Boolean {
    val n = name ?: return false
    for (x in names) if (n == x) return true
    return false
}

/** An attribute by local name, prefix-insensitive; null when absent. */
internal fun XmlPullParser.attr(name: String): String? {
    val n = attributeCount
    for (i in 0 until n) {
        if (getAttributeName(i) == name || getAttributeName(i).substringAfterLast(':') == name)
            return getAttributeValue(i)
    }
    return null
}

/**
 * An attribute by namespace URI + local name.
 *
 * Needed because OOXML overloads the local name `id`: `<p:sldId id="256"
 * r:id="rId2"/>` carries both a slide number and a relationship reference under
 * the same local name, and only the relationship one identifies the part. An
 * exact namespace match always wins; an unprefixed attribute (empty namespace,
 * which is never the relationship reference) is only used as a fallback for a
 * parser that was not asked to process namespaces.
 */
internal fun XmlPullParser.attrNs(uri: String, name: String): String? {
    var loose: String? = null
    for (i in 0 until attributeCount) {
        if (getAttributeName(i).substringAfterLast(':') != name) continue
        val ns = getAttributeNamespace(i)
        if (ns == uri) return getAttributeValue(i)
        if (ns.isNullOrEmpty()) loose = getAttributeValue(i)
    }
    return loose
}

/** The current start tag's namespace URI, "" when it has none. */
internal fun XmlPullParser.ns(): String = namespace ?: ""

/**
 * True when the current tag is in one of [uris]. A parser that reports no
 * namespace at all is accepted, so the extractors keep working even if a future
 * platform default stops processing namespaces.
 */
internal fun XmlPullParser.nsIn(vararg uris: String): Boolean {
    val ns = namespace ?: return true
    if (ns.isEmpty()) return true
    for (u in uris) if (ns == u) return true
    return false
}

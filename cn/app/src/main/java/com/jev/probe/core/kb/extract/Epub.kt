package com.jev.probe.core.kb.extract

import org.xmlpull.v1.XmlPullParser
import java.io.File

/**
 * EPUB → prose, in reading order.
 *
 * Reading order is the spine, not the order the ZIP happens to store its parts:
 * `META-INF/container.xml` names the OPF package document, the OPF's `manifest`
 * maps an id to a content document, and its `spine` lists the ids in the order a
 * reader shows them. Walking the archive's `.xhtml` entries "in order" instead
 * would shuffle chapters as soon as a book put its cover or nav last.
 *
 * The content documents themselves are HTML, so they go through [htmlToText].
 */
internal fun extractEpub(file: File, factory: XmlFactory, sink: TextSink): Boolean {
    val opfPath = opfPath(file, factory) ?: return false
    val opf = ZipReader.text(file, opfPath) ?: return false
    val opfDir = dirOf(opfPath)

    val manifest = HashMap<String, String>()
    val spine = ArrayList<String>()
    val parser = xmlParser(factory, opf)
    walkXml(parser) { p ->
        when {
            p.eventType != XmlPullParser.START_TAG -> Unit
            p.isTag("item") -> {
                val id = p.attr("id")
                val href = p.attr("href")
                if (id != null && !href.isNullOrBlank()) {
                    manifest[id] = resolvePath(opfDir, href)
                }
            }
            p.isTag("itemref") -> {
                val idref = p.attr("idref")
                if (idref != null) manifest[idref]?.let { spine.add(it) }
            }
        }
    }

    val parts = if (spine.isNotEmpty()) spine else fallbackParts(file)
    var wrote = false
    for (path in parts) {
        val html = ZipReader.text(file, path) ?: continue
        if (wrote) sink.newline()
        htmlToText(html, sink)
        wrote = true
        // The sink stops accepting text at its own ceiling; there is no point
        // opening further chapters once it has.
        if (sink.truncated) break
    }
    return wrote
}

/** Where the package document lives, per `META-INF/container.xml`. */
private fun opfPath(file: File, factory: XmlFactory): String? {
    val container = ZipReader.text(file, "META-INF/container.xml")
    if (container != null) {
        val parser = xmlParser(factory, container)
        var found: String? = null
        walkXml(parser) { p ->
            if (found == null && p.eventType == XmlPullParser.START_TAG && p.isTag("rootfile")) {
                found = p.attr("full-path")
            }
        }
        val path = found
        if (!path.isNullOrBlank()) {
            val normalised = resolvePath("", path)
            if (normalised.isNotEmpty()) return normalised
        }
    }
    // A hand-made or unusual EPUB: any package document will do.
    return ZipReader.names(file)
        .filter { it.endsWith(".opf") }
        .minByOrNull { it }
}

/** Last resort when the package document has no usable spine. */
private fun fallbackParts(file: File): List<String> =
    ZipReader.names(file)
        .filter {
            val lower = it.lowercase()
            (lower.endsWith(".xhtml") || lower.endsWith(".html") || lower.endsWith(".htm")) &&
                !lower.contains("nav") && !lower.contains("toc")
        }
        .sortedWith(NATURAL)

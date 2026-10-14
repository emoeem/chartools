package com.jev.probe.core.kb.extract

import org.xmlpull.v1.XmlPullParser
import java.io.File

/**
 * Text out of the OOXML family (DOCX / PPTX / XLSX) with nothing but
 * `java.util.zip` and an XML pull parser.
 *
 * The alternative — Apache POI — cannot be deployed on Android without a
 * specially shaded jar plus three global `System.setProperty` StAX overrides and
 * relocations of `javax.xml.stream` and most of `java.awt` (that is precisely
 * what `centic9/poi-on-android` exists to do). For "read the text runs out of
 * one ZIP entry" that machinery costs far more than it returns, so these
 * extractors read the handful of parts that actually carry prose.
 */

private const val NS_W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
private const val NS_M = "http://schemas.openxmlformats.org/officeDocument/2006/math"
private const val NS_A = "http://schemas.openxmlformats.org/drawingml/2006/main"
private const val NS_P = "http://schemas.openxmlformats.org/presentationml/2006/main"
private const val NS_SS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
private const val NS_REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

// ------------------------------------------------------------------- DOCX

/**
 * `word/document.xml` → prose.
 *
 * Text lives in `<w:t>` runs inside `<w:p>` paragraphs. `<w:tab/>` and
 * `<w:br/>` are separate elements with no text of their own, and field
 * instructions (`w:instrText`) and deleted revisions (`w:delText`) are *not*
 * prose, so the `t` element is only trusted inside the WordprocessingML, math
 * and DrawingML namespaces.
 *
 * Returns false when the part is missing, i.e. this is not a readable DOCX.
 */
internal fun extractDocx(file: File, factory: XmlFactory, sink: TextSink): Boolean {
    val xml = ZipReader.text(file, "word/document.xml") ?: return false
    val parser = xmlParser(factory, xml)
    var inText = false
    walkXml(parser) { p ->
        when (p.eventType) {
            XmlPullParser.START_TAG -> when {
                p.isTag("t") && p.nsIn(NS_W, NS_M, NS_A) -> inText = true
                p.isTag("tab") -> sink.space()
                p.isTag("br", "cr") -> sink.newline()
            }
            XmlPullParser.TEXT -> if (inText) sink.appendFlow(p.text)
            XmlPullParser.END_TAG -> when {
                p.isTag("t") -> inText = false
                p.isTag("p") -> sink.newline()
            }
        }
    }
    return true
}

// ------------------------------------------------------------------- PPTX

/**
 * Slides in presentation order → their text frames.
 *
 * Reading order is *not* the order of the entries in the ZIP; it is the order of
 * `<p:sldId>` in `ppt/presentation.xml`, each pointing at a slide through a
 * relationship id. If the relationship part is missing (a hand-built file), the
 * slides are taken in numeric `slideN.xml` order instead, which in practice is
 * the same thing.
 */
internal fun extractPptx(file: File, factory: XmlFactory, sink: TextSink): Boolean {
    val presentation = ZipReader.text(file, "ppt/presentation.xml") ?: return false
    val rels = relsMap(file, "ppt/presentation.xml", factory)
    val slides = ArrayList<String>()
    val parser = xmlParser(factory, presentation)
    walkXml(parser) { p ->
        if (p.eventType == XmlPullParser.START_TAG && p.isTag("sldId")) {
            val rid = p.attrNs(NS_REL, "id")
            val path = rid?.let { rels[it] }
            if (path != null && path.endsWith(".xml")) slides.add(path)
        }
    }
    val ordered = if (slides.isNotEmpty()) slides else numericSlides(file)
    if (ordered.isEmpty()) return false

    for ((index, path) in ordered.withIndex()) {
        val xml = ZipReader.text(file, path) ?: continue
        if (index > 0) sink.newline()
        val slide = xmlParser(factory, xml)
        var inText = false
        walkXml(slide) { p ->
            when (p.eventType) {
                XmlPullParser.START_TAG -> when {
                    p.isTag("t") && p.nsIn(NS_A) -> inText = true
                    p.isTag("br") -> sink.newline()
                }
                XmlPullParser.TEXT -> if (inText) sink.appendFlow(p.text)
                XmlPullParser.END_TAG -> when {
                    p.isTag("t") -> inText = false
                    // A DrawingML paragraph is a visual line; a shape is a block.
                    p.isTag("p") -> sink.newline()
                    p.isTag("txBody") -> sink.newline()
                }
            }
        }
    }
    return true
}

private fun numericSlides(file: File): List<String> =
    ZipReader.names(file)
        .filter { it.startsWith("ppt/slides/slide") && it.endsWith(".xml") }
        .sortedWith(NATURAL)

// ------------------------------------------------------------------- XLSX

/**
 * Every sheet, in workbook order, as tab-free rows.
 *
 * A cell holds either an index into `xl/sharedStrings.xml` (`t="s"`), an inline
 * string (`t="inlineStr"`), or a literal value in `<v>` — a formula's cached
 * result, for instance. All three are read; a sheet contains no prose, so this
 * output is closer to a table dump than to a document, and it is capped like
 * everything else.
 */
internal fun extractXlsx(file: File, factory: XmlFactory, sink: TextSink): Boolean {
    val shared = ZipReader.text(file, "xl/sharedStrings.xml")
        ?.let { sharedStrings(it, factory) } ?: emptyList()
    val sheets = sheetRefs(file, factory)
    if (sheets.isEmpty()) return false

    for ((index, sheet) in sheets.withIndex()) {
        val xml = ZipReader.text(file, sheet.target) ?: continue
        if (index > 0) sink.newline()
        if (!sheet.name.isNullOrBlank()) {
            sink.append(sheet.name)
            sink.newline()
        }
        val parser = xmlParser(factory, xml)
        var cellType: String? = null
        var inValue = false
        var inInlineItem = false
        var inInlineText = false
        walkXml(parser) { p ->
            when (p.eventType) {
                XmlPullParser.START_TAG -> when {
                    p.isTag("c") -> {
                        cellType = p.attr("t")
                        inValue = false
                        inInlineText = false
                    }
                    p.isTag("is") -> inInlineItem = true
                    p.isTag("v") -> inValue = true
                    p.isTag("t") && inInlineItem -> inInlineText = true
                }
                XmlPullParser.TEXT -> {
                    if (inValue) {
                        val raw = p.text?.trim().orEmpty()
                        if (raw.isNotEmpty()) {
                            if (cellType == "s") {
                                val i = raw.toIntOrNull()
                                sink.append(if (i != null && i in shared.indices) shared[i] else "")
                            } else {
                                sink.append(raw)
                            }
                        }
                    } else if (inInlineText) {
                        sink.appendFlow(p.text)
                    }
                }
                XmlPullParser.END_TAG -> when {
                    p.isTag("t") -> inInlineText = false
                    p.isTag("v") -> inValue = false
                    p.isTag("is") -> inInlineItem = false
                    // One space per cell keeps a row readable without inventing
                    // column alignment the text cannot carry anyway.
                    p.isTag("c") -> {
                        cellType = null
                        sink.space()
                    }
                    p.isTag("row") -> {
                        sink.zapTrailingSpace()
                        sink.newline()
                    }
                }
            }
        }
    }
    return true
}

private data class SheetRef(val name: String?, val target: String)

/**
 * The sheets in workbook order, resolved through `xl/_rels/workbook.xml.rels`.
 * Falls back to numeric `sheetN.xml` order when `xl/workbook.xml` is absent.
 */
private fun sheetRefs(file: File, factory: XmlFactory): List<SheetRef> {
    val workbook = ZipReader.text(file, "xl/workbook.xml")
    if (workbook != null) {
        val rels = relsMap(file, "xl/workbook.xml", factory)
        val out = ArrayList<SheetRef>()
        val parser = xmlParser(factory, workbook)
        walkXml(parser) { p ->
            if (p.eventType == XmlPullParser.START_TAG && p.isTag("sheet")) {
                val target = p.attrNs(NS_REL, "id")?.let { rels[it] }
                if (target != null && target.endsWith(".xml"))
                    out.add(SheetRef(p.attr("name"), target))
            }
        }
        if (out.isNotEmpty()) return out
    }
    return ZipReader.names(file)
        .filter { it.startsWith("xl/worksheets/") && it.endsWith(".xml") }
        .sortedWith(NATURAL)
        .map { SheetRef(null, it) }
}

/** `sharedStrings.xml` → the string each `t="s"` cell indexes. */
private fun sharedStrings(xml: String, factory: XmlFactory): List<String> {
    val out = ArrayList<String>()
    val parser = xmlParser(factory, xml)
    val current = StringBuilder()
    var inItem = false
    var inText = false
    // A phonetic hint (<rPh>) also contains <t>, and is a pronunciation guide
    // rather than the cell's text, so it is skipped.
    var inPhonetic = false
    walkXml(parser) { p ->
        when (p.eventType) {
            XmlPullParser.START_TAG -> when {
                p.isTag("si") -> {
                    inItem = true
                    current.setLength(0)
                }
                p.isTag("rPh") -> inPhonetic = true
                p.isTag("t") && inItem && !inPhonetic -> inText = true
            }
            XmlPullParser.TEXT -> if (inText) current.append(p.text)
            XmlPullParser.END_TAG -> when {
                p.isTag("t") -> inText = false
                p.isTag("rPh") -> inPhonetic = false
                p.isTag("si") -> {
                    if (inItem) out.add(current.toString())
                    inItem = false
                }
            }
        }
    }
    return out
}

// --------------------------------------------------------------- shared bits

/**
 * `id → archive path` from a part's relationship file.
 *
 * The relationship file for `ppt/presentation.xml` is not
 * `ppt/_rels/presentation.rels` but `ppt/_rels/presentation.xml.rels`: the part's
 * *file name* is repeated, which is why this takes the part path rather than its
 * directory. Targets are relative to the part's own folder, so they are folded
 * against that folder to become archive paths.
 */
internal fun relsMap(file: File, partPath: String, factory: XmlFactory): Map<String, String> {
    val dir = dirOf(partPath)
    val leaf = partPath.substringAfterLast('/')
    val path = if (dir.isEmpty()) "_rels/$leaf.rels" else "$dir/_rels/$leaf.rels"
    val xml = ZipReader.text(file, path) ?: return emptyMap()
    val out = HashMap<String, String>()
    val parser = xmlParser(factory, xml)
    walkXml(parser) { p ->
        if (p.eventType == XmlPullParser.START_TAG && p.isTag("Relationship")) {
            val id = p.attr("Id")
            val target = p.attr("Target")
            if (id != null && target != null && target.isNotBlank()) {
                out[id] = resolvePath(dir, target)
            }
        }
    }
    return out
}

/** Ordering for `slide2.xml` < `slide10.xml`, which a plain string sort inverts. */
internal val NATURAL: Comparator<String> = Comparator { a, b -> naturalCompare(a, b) }

private fun naturalCompare(a: String, b: String): Int {
    var i = 0
    var j = 0
    while (i < a.length && j < b.length) {
        val ca = a[i]
        val cb = b[j]
        if (ca.isDigit() && cb.isDigit()) {
            var x = 0L
            var y = 0L
            while (i < a.length && a[i].isDigit()) {
                x = x * 10 + (a[i] - '0')
                i++
            }
            while (j < b.length && b[j].isDigit()) {
                y = y * 10 + (b[j] - '0')
                j++
            }
            if (x != y) return if (x < y) -1 else 1
        } else {
            if (ca != cb) return if (ca < cb) -1 else 1
            i++
            j++
        }
    }
    return (a.length - i) - (b.length - j)
}

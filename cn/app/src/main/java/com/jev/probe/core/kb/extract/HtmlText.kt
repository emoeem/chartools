package com.jev.probe.core.kb.extract

import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.nodes.Node
import org.jsoup.nodes.TextNode

/**
 * HTML/XHTML → prose, via jsoup.
 *
 * jsoup rather than the XML pull parser, for two reasons: a standalone `.html`
 * file the user picked is frequently not well-formed XML and would end the pull
 * parse at the first stray `<br>`, and EPUB content documents are HTML in all but
 * name. One tested path serves both.
 *
 * Block elements end a paragraph; inline elements do not, so `<b>` inside a
 * sentence never splits it. `script`/`style`/`head` are dropped: markup is not
 * prose.
 */
internal fun htmlToText(html: String, sink: TextSink) {
    val doc = Jsoup.parse(html)
    doc.select("script, style, noscript, head, meta, link, title").remove()
    val root = doc.body() ?: doc
    walkHtml(root, sink)
}

private fun walkHtml(node: Node, sink: TextSink) {
    for (child in node.childNodes()) {
        when (child) {
            is TextNode -> sink.appendFlow(child.text())
            is Element -> {
                val tag = child.tagName().lowercase()
                if (tag == "br") {
                    sink.newline()
                    continue
                }
                // An image with alt text still carries meaning.
                if (tag == "img") {
                    val alt = child.attr("alt")
                    if (alt.isNotBlank()) {
                        sink.space()
                        sink.appendFlow(alt)
                        sink.space()
                    }
                    continue
                }
                walkHtml(child, sink)
                if (tag in BLOCK_TAGS) sink.newline()
            }
            else -> Unit
        }
    }
}

private val BLOCK_TAGS = hashSetOf(
    "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol",
    "tr", "td", "th", "table", "thead", "tbody", "blockquote", "pre",
    "section", "article", "aside", "header", "footer", "nav", "main",
    "figure", "figcaption", "dl", "dt", "dd", "hr", "form", "body"
)

package com.jev.probe.core.kb.extract

import org.kxml2.io.KXmlParser
import org.xmlpull.v1.XmlPullParser
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * Shared scaffolding for the extractor tests.
 *
 * The parser factory matters: Android's `Xml.newPullParser()` is a stub in a JVM
 * unit test, so the tests inject kxml2 directly — the same parser Android's own
 * factory returns, configured the way Android configures it (namespaces on).
 * That means the tests exercise the real parsing code, not a mock of it, and the
 * only thing that differs between test and device is who constructs the parser.
 */
internal val TEST_XML: XmlFactory = {
    KXmlParser().apply { setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true) }
}

/** Build a ZIP archive in memory, entries in the order given. */
internal fun zipOf(vararg entries: Pair<String, String>): ByteArray {
    val out = ByteArrayOutputStream()
    ZipOutputStream(out).use { zip ->
        for ((name, body) in entries) {
            zip.putNextEntry(ZipEntry(name))
            zip.write(body.toByteArray(Charsets.UTF_8))
            zip.closeEntry()
        }
    }
    return out.toByteArray()
}

/** A real file on disk, which is what every extractor takes. */
internal fun tempFile(bytes: ByteArray, suffix: String): File {
    val file = File.createTempFile("doc-import-test", suffix)
    file.writeBytes(bytes)
    file.deleteOnExit()
    return file
}

internal fun extractWith(
    bytes: ByteArray,
    suffix: String,
    limit: Int = 100_000,
    block: (File, TextSink) -> Boolean
): String {
    val file = tempFile(bytes, suffix)
    val sink = TextSink(limit)
    block(file, sink)
    file.delete()
    return sink.toString()
}

/** Run one of the pull-parser extractors and hand back the text it produced. */
internal fun extractZip(
    bytes: ByteArray,
    suffix: String,
    block: (File, XmlFactory, TextSink) -> Boolean
): String = extractWith(bytes, suffix) { file, sink -> block(file, TEST_XML, sink) }

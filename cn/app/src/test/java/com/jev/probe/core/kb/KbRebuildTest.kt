package com.jev.probe.core.kb

import com.jev.probe.core.kb.extract.DocChunker
import com.jev.probe.core.kb.extract.DocImport
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * Rebuilds `notes.json` from text that was extracted outside the app.
 *
 * Not a test in the usual sense — it is a build step that has to run inside the
 * JVM so that it can call the app's **own** [DocChunker] and [DocImport] naming
 * rather than a copy of them. A copy would drift, and the knowledge base would
 * stop looking like something the importer produced.
 *
 * It is off unless `app/build/scratch/BUILD_KB` exists, so a normal
 * `testDebugUnitTest` run never touches the filesystem beyond reading. Create
 * the marker, run this class, delete the marker.
 *
 * Input : `app/build/scratch/kb_src/<display name>.txt` — produced by
 *         `app/build/scratch/kb_prepare.py`, which canonicalises characters and
 *         removes whole documents that are near-copies of a document already
 *         kept. Both steps have to happen before chunking: near-copies wrapped
 *         at different widths yield *different* chunks out of identical prose,
 *         so nothing at this level can spot them.
 * Output: `app/build/scratch/kb_rebuilt.json`
 */
class KbRebuildTest {

    @Test
    fun rebuild() {
        val scratch = File("build/scratch")
        val src = File(scratch, "kb_src")
        val marker = File(scratch, "BUILD_KB")
        assumeTrue("set $marker to run", marker.exists())
        assumeTrue("put extracted text in $src", src.isDirectory)

        val files = src.listFiles { f -> f.isFile && f.name.endsWith(".txt") }
            ?.sortedBy { it.name } ?: emptyList()
        assumeTrue("no .txt files in $src", files.isNotEmpty())

        val out = JSONArray()
        val seen = HashSet<String>(1 shl 16)
        var total = 0
        var dropped = 0
        val perFile = ArrayList<String>()

        for (f in files) {
            val display = f.name.removeSuffix(".txt")
            val body = f.readText(Charsets.UTF_8)
            if (body.isBlank()) continue
            val all = DocChunker.split(body, DocImport.CHUNK_CHARS)
            if (all.isEmpty()) continue
            val chunks = if (all.size > DocImport.MAX_CHUNKS) all.subList(0, DocImport.MAX_CHUNKS) else all
            val tags = JSONArray(DocImport.chunkTags(display))
            var kept = 0
            chunks.forEachIndexed { i, chunk ->
                // Verbatim duplicates are dropped here rather than at save time so
                // that re-running this rebuild is idempotent.
                if (seen.add(chunk)) {
                    out.put(
                        JSONObject()
                            .put("id", KbStore.newId())
                            .put("title", DocImport.chunkTitle(display, i + 1, chunks.size))
                            .put("content", chunk)
                            .put("tags", JSONArray(DocImport.chunkTags(display)))
                            .put("alwaysOn", false)
                            .put("enabled", true)
                            .put("updatedAt", System.currentTimeMillis())
                            .put("type", "note")
                    )
                    total++
                    kept++
                } else {
                    dropped++
                }
            }
            perFile.add("$kept/${chunks.size}\t${body.length}\t$display")
        }

        File(scratch, "kb_rebuilt.json").writeText(out.toString(), Charsets.UTF_8)
        File(scratch, "kb_rebuild_report.txt").writeText(
            buildString {
                appendLine("files=${files.size} notes=$total dropped_duplicates=$dropped")
                appendLine("chunkChars=${DocImport.CHUNK_CHARS} maxChunks=${DocImport.MAX_CHUNKS}")
                appendLine("kept/raw\tchars\tsource")
                perFile.forEach { appendLine(it) }
            },
            Charsets.UTF_8
        )

        assertTrue("rebuilt nothing", total > 0)
    }
}

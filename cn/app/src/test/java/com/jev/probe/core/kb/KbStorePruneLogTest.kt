package com.jev.probe.core.kb

import android.content.Context
import android.content.ContextWrapper
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class KbStorePruneLogTest {

    private class TestContext(private val dir: File) : ContextWrapper(null) {
        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = dir
    }

    private fun store(): Pair<KbStore, File> {
        val dir = Files.createTempDirectory("jev-kb-prune-").toFile()
        return KbStore.get(TestContext(dir)) to dir
    }

    private fun entry(side: String, text: String, ts: Long) =
        LogEntry(side, text, ts, "com.tencent.mm")

    @Test
    fun pruneOneDayDropsOnlyOlderEntries() {
        val now = 10L * 86_400_000L
        val (store, dir) = store()
        try {
            val id = "prune-" + System.nanoTime()
            store.appendLog(
                id,
                listOf(
                    entry("other", "old", now - 2L * 86_400_000L),
                    entry("me", "new", now - 1L * 3_600_000L)
                ),
                screenBatch = false
            )
            assertEquals(1, store.pruneLog(id, 1, now))
            assertEquals(listOf("new"), store.recentLog(id, 10).map { it.text })
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun sevenThirtyAndNinetyDayRetentionUseTheSameCutoffRule() {
        val now = 100L * 86_400_000L
        val cases = listOf(7, 30, 90)
        val (store, dir) = store()
        try {
            for (days in cases) {
                val id = "prune-" + days + "-" + System.nanoTime()
                store.appendLog(
                    id,
                    listOf(
                        entry("other", "old-" + days, now - (days + 1L) * 86_400_000L),
                        entry("me", "new-" + days, now - (days - 1L).coerceAtLeast(1) * 86_400_000L)
                    ),
                    screenBatch = false
                )
                assertEquals(1, store.pruneLog(id, days, now))
                assertEquals(
                    listOf("new-" + days),
                    store.recentLog(id, 10).map { it.text }
                )
            }
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun permanentRetentionAndNonPositiveDaysKeepEverything() {
        val now = 20L * 86_400_000L
        val (store, dir) = store()
        try {
            for (days in listOf(0, -1)) {
                val id = "prune-permanent-" + days + "-" + System.nanoTime()
                store.appendLog(
                    id,
                    listOf(entry("other", "very-old", 1L)),
                    screenBatch = false
                )
                assertEquals(0, store.pruneLog(id, days, now))
                assertEquals(1, store.logSize(id))
            }
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun pruningAgainIsIdempotent() {
        val now = 50L * 86_400_000L
        val (store, dir) = store()
        try {
            val id = "prune-idempotent-" + System.nanoTime()
            store.appendLog(
                id,
                listOf(entry("other", "old", now - 10L * 86_400_000L)),
                screenBatch = false
            )
            assertEquals(1, store.pruneLog(id, 7, now))
            assertEquals(0, store.pruneLog(id, 7, now))
            assertTrue(store.recentLog(id, 10).isEmpty())
        } finally {
            dir.deleteRecursively()
        }
    }
}

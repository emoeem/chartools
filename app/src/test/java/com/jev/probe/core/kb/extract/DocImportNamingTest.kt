package com.jev.probe.core.kb.extract

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The one part of [DocImport] that can be tested off-device: the names it gives
 * the notes it creates. These strings are what the user sees in the knowledge
 * list, so the exact shape matters — a chunk has to say which file it came from
 * and where it sits in that file, or a hundred imported chunks are unreadable.
 */
class DocImportNamingTest {

    @Test
    fun `a chunk is titled with its file and its position`() {
        assertEquals("年报.pdf (1/3)", DocImport.chunkTitle("年报.pdf", 1, 3))
        assertEquals("Chapter 1.docx (12/40)", DocImport.chunkTitle("Chapter 1.docx", 12, 40))
    }

    @Test
    fun `a single chunk still carries its position`() {
        assertEquals("notes.md (1/1)", DocImport.chunkTitle("notes.md", 1, 1))
    }

    @Test
    fun `the file name is a tag so a file can be found as a group`() {
        assertEquals(listOf("文档导入", "book.epub"), DocImport.chunkTags("book.epub"))
        // Nothing else is smuggled into the tags: the knowledge screen splits
        // them on commas, so a comma in a file name would become two tags.
        assertEquals(listOf("文档导入", "a,b.txt"), DocImport.chunkTags("a,b.txt"))
    }

    @Test
    fun `the active persona topic rides along as a tag`() {
        // 「在设置里选了网调人设 → 导入的文件 → 以后只按网调检索」这条链就是靠
        // 这个标签闭合的：导入的当下就把主题写进去，用户不用事后一条条补标签。
        assertEquals(listOf("文档导入", "book.epub", "网调"), DocImport.chunkTags("book.epub", "网调"))
        // 空主题逐字退回老行为，不多写空标签（空标签会让每条笔记都算"主题命中"）。
        assertEquals(listOf("文档导入", "book.epub"), DocImport.chunkTags("book.epub", ""))
        assertEquals(listOf("文档导入", "book.epub"), DocImport.chunkTags("book.epub", "   "))
    }

    @Test
    fun `the importer states the limits it enforces`() {
        // These are user-visible promises quoted in the report and the screen.
        // CHUNK_CHARS is deliberately about half of what it once was: a chunk
        // becomes one note, and the note budget is shared with the retrieved
        // conversation, so 1200-character chunks meant a single hit crowded out
        // everything else. See the constant's comment in DocImport.
        assertEquals(600, DocImport.CHUNK_CHARS)
        assertEquals(2_000_000, DocImport.MAX_CHARS)
        assertEquals(2000, DocImport.MAX_CHUNKS)
    }
}

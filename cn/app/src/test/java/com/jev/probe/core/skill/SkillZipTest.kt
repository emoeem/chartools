package com.jev.probe.core.skill

import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The zip guards. A skill archive is untrusted input — it arrives from whatever
 * the user downloaded — so entry names are checked before anything is written:
 * an escaping `../` must not be able to drop a file outside the skill directory.
 */
class SkillZipTest {

    @get:Rule val tmp = TemporaryFolder()

    private fun zipOf(vararg entries: Pair<String, String>): ByteArray =
        zipOfBytes(*entries.map { it.first to it.second.toByteArray(Charsets.UTF_8) }.toTypedArray())

    private fun zipOfBytes(vararg entries: Pair<String, ByteArray>): ByteArray {
        val bos = ByteArrayOutputStream()
        ZipOutputStream(bos).use { zip ->
            for ((name, body) in entries) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(body)
                zip.closeEntry()
            }
        }
        return bos.toByteArray()
    }

    @Test
    fun safeNames() {
        assertTrue(SkillZip.safeEntryName("SKILL.md"))
        assertTrue(SkillZip.safeEntryName("my-skill/references/a.md"))
        assertTrue(SkillZip.safeEntryName("a..b/c.md"))
    }

    @Test
    fun unsafeNames() {
        assertFalse(SkillZip.safeEntryName(""))
        assertFalse(SkillZip.safeEntryName("   "))
        assertFalse(SkillZip.safeEntryName("/etc/passwd"))
        assertFalse(SkillZip.safeEntryName("\\windows\\x"))
        assertFalse(SkillZip.safeEntryName("C:/x.txt"))
        assertFalse(SkillZip.safeEntryName("../evil.txt"))
        assertFalse(SkillZip.safeEntryName("a/../../b.txt"))
        assertFalse(SkillZip.safeEntryName("a/b/.."))
        assertFalse(SkillZip.safeEntryName("a\u0000b"))
    }

    @Test
    fun extractsANestedSkillIntact() {
        val into = tmp.newFolder("stage")
        val n = SkillZip.extract(
            zipOf(
                "my-skill/SKILL.md" to "---\nname: a-b\ndescription: 写周报时使用\n---\nbody",
                "my-skill/references/notes.md" to "hello"
            ).inputStream(),
            into
        )
        assertEquals(2, n)
        assertEquals("hello", File(into, "my-skill/references/notes.md").readText())
        assertTrue(File(into, "my-skill/SKILL.md").isFile)
    }

    @Test
    fun directoryEntriesAreSkippedNotCounted() {
        val into = tmp.newFolder("stage")
        val n = SkillZip.extract(
            zipOf("d/" to "", "d/SKILL.md" to "x").inputStream(),
            into
        )
        assertEquals(1, n)
    }

    @Test(expected = IllegalArgumentException::class)
    fun aTraversingEntryIsRefused() {
        val into = tmp.newFolder("stage")
        SkillZip.extract(zipOf("../evil.txt" to "boom").inputStream(), into)
    }

    @Test
    fun aTraversingEntryWritesNothingOutside() {
        val into = tmp.newFolder("stage")
        val outside = File(into.parentFile, "evil.txt")
        runCatching { SkillZip.extract(zipOf("../evil.txt" to "boom").inputStream(), into) }
        assertFalse("不得在目标目录之外落文件", outside.exists())
    }

    @Test(expected = IllegalStateException::class)
    fun anOversizedSingleFileIsRefused() {
        val into = tmp.newFolder("stage")
        val big = ByteArray((SkillZip.MAX_FILE_BYTES + 1024).toInt())
        SkillZip.extract(zipOfBytes("big.bin" to big).inputStream(), into)
    }
}

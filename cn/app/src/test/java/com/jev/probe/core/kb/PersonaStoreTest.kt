package com.jev.probe.core.kb

import android.content.Context
import android.content.ContextWrapper
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * 人设库要挡住的是「用户写的东西没了」这一类失败，所以测的重点不是 CRUD，
 * 是三条**约定**：
 *
 * 1. 首装播种一次，删光了不会再长回来（否则用户删一张、重启又出现）。
 * 2. 导入**永不覆盖**同名条目（同名不同文 → 另存 `名字(导入)`）。
 * 3. 文件读不出来时先备份再放行，不静默清空用户的库。
 */
class PersonaStoreTest {

    private class TestContext(private val dir: File) : ContextWrapper(null) {
        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = dir
    }

    private fun store(): Pair<PersonaStore, File> {
        val dir = Files.createTempDirectory("jev-persona-").toFile()
        return PersonaStore.create(TestContext(dir)) to dir
    }

    private fun <T> withStore(block: (PersonaStore, File) -> T) {
        val (s, dir) = store()
        try {
            block(s, dir)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun firstReadSeedsTheBuiltInTemplatesOnce() = withStore { store, dir ->
        val first = store.list()
        assertEquals(PersonaPresets.ALL.size, first.size)
        assertEquals(PersonaPresets.ALL.map { it.first }, first.map { it.name })
        assertTrue(first.all { it.builtin })
        // 播种确实落了盘，而不是每次读都现造：第二次读回的 id 必须一样。
        assertTrue(File(dir, "kb/personas.json").isFile)
        assertEquals(first.map { it.id }, store.list().map { it.id })
    }

    @Test
    fun deletingEveryProfileDoesNotResurrectThem() = withStore { store, _ ->
        store.list().forEach { assertTrue(store.delete(it.id)) }
        assertEquals(emptyList<PersonaProfile>(), store.list())
    }

    @Test
    fun saveCreatesThenUpdatesInPlace() = withStore { store, _ ->
        val created = store.save("销售·跟单", "称呼：王总\n主题：销售")
        assertNotNull(created)
        val afterCreate = store.list()
        assertTrue(afterCreate.any { it.name == "销售·跟单" })

        val updated = store.save("销售·跟单（改）", "称呼：老王\n主题：销售\n语气：短句", created!!.id)
        assertEquals(created.id, updated?.id)
        assertEquals(PersonaPresets.ALL.size + 1, store.list().size)
        val back = store.get(created.id)
        assertEquals("销售·跟单（改）", back?.name)
        assertTrue(back!!.body.contains("称呼：老王"))
        // 自建的那条不是 builtin，改名也不会被内置模板的标记污染。
        assertFalse(back.builtin)
    }

    @Test
    fun blankBodyNeverBecomesAProfile() = withStore { store, _ ->
        val before = store.list().size
        assertNull(store.save("空卡", "   \n  "))
        assertNull(store.save("不存在", "称呼：x", "psn-missing"))
        assertEquals(before, store.list().size)
    }

    @Test
    fun activeOfMatchesTheLiveTextAndGivesUpOnFreeText() = withStore { store, _ ->
        val daily = store.list().first { it.name == "日常" }
        assertEquals(daily.id, store.activeOf("\n" + daily.body + "  ")?.id)
        assertNull(store.activeOf("称呼：我自己随手写的"))
        assertNull(store.activeOf(""))
    }

    @Test
    fun importRenamesInsteadOfOverwritingTheSameName() = withStore { store, _ ->
        val original = store.list().first { it.name == "销售·跟单" }
        val result = store.importJson(
            """[{"name":"销售·跟单","body":"称呼：完全不同的内容"}]"""
        )
        assertTrue(result.describe(), result.ok)
        assertEquals(1, result.added)
        assertEquals(1, result.renamed)
        // 原文一字未动，新内容另起一条带后缀的。
        assertEquals(original.body, store.get(original.id)?.body)
        assertTrue(store.list().any { it.name == "销售·跟单(导入)" && it.body.contains("完全不同的内容") })
    }

    @Test
    fun importingTheSameTextTwiceIsSkippedNotDuplicated() = withStore { store, _ ->
        val exported = store.exportJson()
        val again = store.importJson(exported)
        assertEquals(0, again.added)
        assertEquals(PersonaPresets.ALL.size, again.skipped)
        assertEquals(PersonaPresets.ALL.size, store.list().size)
    }

    @Test
    fun aBarePersonaCardIsAcceptedAsPlainText() = withStore { store, _ ->
        val result = store.importJson("称呼：老王\n关系：客户\n主题：销售")
        assertEquals(1, result.added)
        // 没给名字时用第一行的键名当名字，不要整段塞进标题。
        assertTrue(store.list().any { it.name == "称呼" })
    }

    @Test
    fun anEmptyButValidJsonSaysNobodyWasImported() = withStore { store, _ ->
        val before = store.list()
        val result = store.importJson("""{"version":1,"items":[]}""")
        assertFalse(result.ok)
        assertTrue(result.describe().isNotBlank())
        assertEquals(before.size, store.list().size)
    }

    @Test
    fun exportRoundTripsIntoAnotherLibrary() {
        val (a, dirA) = store()
        val (b, dirB) = store()
        try {
            a.save("客服", "称呼：您\n关系：客服和客户\n语气：客气、简短")
            // 模拟「另一台机器 / 空库」：先把 b 自己的播种条目清掉，否则同名同文
            // 会被正确判成「已有一模一样的一条」而跳过 —— 那是另一条用例在管的。
            b.list().forEach { b.delete(it.id) }
            val result = b.importJson(a.exportJson())
            assertEquals(a.list().size, result.added)
            assertEquals(a.list().map { it.name }, b.list().map { it.name })
            assertEquals(a.list().map { it.body }, b.list().map { it.body })
        } finally {
            dirA.deleteRecursively(); dirB.deleteRecursively()
        }
    }

    @Test
    fun aCorruptFileIsBackedUpAndTheLibraryStaysUsable() = withStore { store, dir ->
        val f = File(dir, "kb/personas.json")
        f.parentFile?.mkdirs()
        f.writeText("这不是 JSON {{{", Charsets.UTF_8)

        assertTrue(store.list().isEmpty())
        assertNotNull("损坏必须留下可见的说明", store.lastProblem)
        val backups = File(dir, "kb").listFiles { file -> file.name.startsWith("personas.corrupt-") }
        assertTrue("原文件必须先备份", backups != null && backups.isNotEmpty())
        // 备份过了就允许继续写，否则用户从此存不进任何人设。
        assertNotNull(store.save("新的人设", "称呼：你\n语气：随便"))
    }

    @Test
    fun restoreBringsBackOnlyTheMissingBuiltIns() = withStore { store, _ ->
        val daily = store.list().first { it.name == "日常" }
        store.delete(daily.id)
        store.save("自建的一条", "称呼：你")
        assertEquals(1, store.restoreBuiltins())
        assertEquals(0, store.restoreBuiltins())
        assertTrue(store.list().any { it.name == "日常" && it.builtin })
        assertTrue(store.list().any { it.name == "自建的一条" })
    }

    @Test
    fun duplicateNumbersTheCopiesInsteadOfColliding() = withStore { store, _ ->
        val src = store.list().first { it.name == "日常" }
        val one = store.duplicate(src.id)
        val two = store.duplicate(src.id)
        assertEquals("日常 副本", one?.name)
        assertEquals("日常 副本 2", two?.name)
        assertEquals(src.body, one?.body)
    }
}

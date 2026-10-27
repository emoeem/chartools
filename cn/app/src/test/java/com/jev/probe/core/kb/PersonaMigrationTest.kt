package com.jev.probe.core.kb

import android.content.Context
import android.content.ContextWrapper
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * v2 迁移与两个台账（`seeded[]` / `removed[]`）的回归锁。
 *
 * 这一层的失败**没有报错**：迁移把用户的库写空、或者把删掉的预设每次启动都长回来，
 * App 照常运行，用户只会觉得「人设怎么老丢」。所以每条约定都有一个用例盯着：
 *
 * 1. v1 文件升级后**条数不变**，原有条目能读出来，原文件先备份；
 * 2. 升级前就删掉的预设，升级后**不许复活**（v1 里删掉的人设连名字都没留下，
 *    所以迁移时把全部内置 key 一次性记进 `seeded[]` —— 这是 v1 的唯一解）；
 * 3. 之后新增的预设，**只补进没播过也没被删过**的库，且只补一次；
 * 4. 坏 JSON 只备份、**绝不清空**原文件；
 * 5. 热度打点只有一个入口，且「最新」排序不被套用污染（`touch` 不动 `updatedAt`）。
 */
class PersonaMigrationTest {

    private class TestContext(private val dir: File) : ContextWrapper(null) {
        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = dir
    }

    private fun withDir(block: (File) -> Unit) {
        val dir = Files.createTempDirectory("jev-persona-mig-").toFile()
        try {
            block(dir)
        } finally {
            dir.deleteRecursively()
        }
    }

    private fun store(dir: File) = PersonaStore.create(TestContext(dir))

    private fun kbFile(dir: File) = File(dir, "kb/personas.json")

    private fun writeRaw(dir: File, text: String) {
        val f = kbFile(dir)
        f.parentFile?.mkdirs()
        f.writeText(text, Charsets.UTF_8)
    }

    /** 一条 items 的 JSON。正文里的换行用 `\n`（JSON 转义），所以放在 raw string 里正好。 */
    private fun item(
        id: String,
        name: String,
        body: String,
        key: String = "",
        builtin: Boolean = false,
        used: Int = 0,
        updatedAt: Long = 1L
    ): String = """{"id":"$id","name":"$name","body":"$body","updatedAt":$updatedAt,""" +
        """"builtin":$builtin,"usedCount":$used,"presetKey":"$key"}"""

    private fun v2(seeded: List<String>, removed: List<String>, items: List<String>): String =
        """{"version":2,"seeded":[${seeded.joinToString(",") { "\"$it\"" }}],""" +
            """"removed":[${removed.joinToString(",") { "\"$it\"" }}],""" +
            """"items":[${items.joinToString(",")}]}"""

    // ---------------------------------------------------------------- 迁移

    @Test
    fun aV1FileIsMigratedWithEveryEntryKeptAndBackedUp() = withDir { dir ->
        writeRaw(
            dir,
            """{"version":1,"items":[""" +
                item("psn-a", "日常", "称呼：用平时的叫法\\n关系：朋友", builtin = true, updatedAt = 111L) + "," +
                item("psn-b", "我的专家", "称呼：老王\\n语气：短句", updatedAt = 222L) +
                "]}"
        )

        val items = store(dir).list()

        // ① 条数一条不少，内容一字不改。
        assertEquals(2, items.size)
        assertEquals(listOf("日常", "我的专家"), items.map { it.name })
        assertEquals("称呼：老王\n语气：短句", items.first { it.name == "我的专家" }.body)
        // ② 新字段全部落到默认值（org.json 不会套 data class 默认值，必须显式兜底）。
        val mine = items.first { it.name == "我的专家" }
        assertNull(mine.avatar)
        assertNull(mine.description)
        assertNull(mine.category)
        assertEquals(emptyList<String>(), mine.tags)
        assertEquals(emptyList<String>(), mine.skillRefs)
        assertEquals(0, mine.usedCount)
        assertEquals("", mine.presetKey)
        // ③ 内置那条按名字反推出稳定的 presetKey。
        assertEquals("daily.friend", items.first { it.name == "日常" }.presetKey)
        // ④ 原文件先备份，再原子写。
        val backups = File(dir, "kb").listFiles { f -> f.name.startsWith("personas.v1-") }
        assertTrue("迁移前必须先备份 v1 原文件", backups != null && backups.isNotEmpty())
        // ⑤ 落盘的是 v2，且台账把 4 张预设全记成「播过」。
        val root = JSONObject(kbFile(dir).readText(Charsets.UTF_8))
        assertEquals(2, root.getInt("version"))
        assertEquals(
            PersonaPresets.PRESETS.map { it.key }.toSet(),
            root.getJSONArray("seeded").let { a -> (0 until a.length()).map { a.getString(it) }.toSet() }
        )
    }

    @Test
    fun aPresetDeletedBeforeTheUpgradeDoesNotComeBack() = withDir { dir ->
        // 老用户：v1 里 4 张预设删到只剩 2 张。被删掉的两张连名字都没留下。
        writeRaw(
            dir,
            """{"version":1,"items":[""" +
                item("psn-a", "日常", "称呼：用平时的叫法", builtin = true) + "," +
                item("psn-b", "网调·我是主", "称呼：主人", builtin = true) +
                "]}"
        )

        store(dir).list()
        // 迁移不许把它们当「新预设」补回来 —— 那是升级把用户的删除撤销了。
        val after = store(dir).list()
        assertEquals(listOf("日常", "网调·我是主"), after.map { it.name })
    }

    @Test
    fun aVersionlessFileIsTreatedAsV1AndMigrated() = withDir { dir ->
        // 手工拼的裸数组（导入工具/更老的版本可能给这种）。
        writeRaw(dir, """[${item("psn-x", "自建", "称呼：你")}]""")

        val items = store(dir).list()
        assertEquals(1, items.size)
        assertEquals(2, JSONObject(kbFile(dir).readText(Charsets.UTF_8)).getInt("version"))
    }

    // ---------------------------------------------------------------- 台账

    @Test
    fun aNewPresetReachesAnOldLibraryExactlyOnce() = withDir { dir ->
        val seeded = listOf("roleplay.dom", "roleplay.sub", "daily.friend")
        writeRaw(
            dir,
            v2(
                seeded = seeded,
                removed = emptyList(),
                items = listOf(
                    item("psn-a", "网调·我是主", "称呼：主人", key = "roleplay.dom", builtin = true),
                    item("psn-b", "网调·我是奴", "称呼：小狗", key = "roleplay.sub", builtin = true),
                    item("psn-c", "日常", "称呼：你", key = "daily.friend", builtin = true)
                )
            )
        )

        val first = store(dir).list()
        assertEquals(PersonaPresets.PRESETS.size, first.size)
        assertTrue("缺的那张预设要补进来", first.any { it.presetKey == "sales.followup" })
        // 只补一次：再读不回重。
        assertEquals(PersonaPresets.PRESETS.size, store(dir).list().size)
        assertEquals(PersonaPresets.PRESETS.size, first.map { it.id }.toSet().size)
    }

    @Test
    fun aDeletedPresetIsNotToppedUpBecauseOfItsTombstone() = withDir { dir ->
        writeRaw(
            dir,
            v2(
                seeded = listOf("roleplay.dom"),
                removed = listOf("daily.friend", "sales.followup"),
                items = listOf(item("psn-a", "网调·我是主", "称呼：主人", key = "roleplay.dom", builtin = true))
            )
        )

        val items = store(dir).list()
        // 既没播过（不在 seeded）又被删过（在 removed）→ 不补。
        assertFalse(items.any { it.presetKey == "daily.friend" })
        assertFalse(items.any { it.presetKey == "sales.followup" })
        // 没播过、也没删过的，照补。
        assertTrue(items.any { it.presetKey == "roleplay.sub" })
    }

    @Test
    fun deletingAPresetLeavesATombstoneAndTheNextRestartHonoursIt() = withDir { dir ->
        val first = store(dir)
        val daily = first.list().first { it.name == "日常" }
        assertTrue(first.delete(daily.id))

        val (seeded, removed) = first.ledger()
        assertTrue("播过的台账不会因为删除而消失", seeded.contains("daily.friend"))
        assertTrue("墓碑要记下这张是用户主动删的", removed.contains("daily.friend"))

        // 模拟重启：仍在，且不会被 topUp 带回来。
        val after = store(dir).list()
        assertFalse(after.any { it.name == "日常" })

        // 「恢复内置模板」是明确的反悔，要放行。
        assertEquals(1, store(dir).restoreBuiltins())
        assertTrue(store(dir).list().any { it.name == "日常" })
        assertFalse("恢复后墓碑要撤销", store(dir).ledger().second.contains("daily.friend"))
    }

    // ------------------------------------------------------- 热度 / 编辑

    @Test
    fun touchCountsUsageWithoutTouchingTheEditTime() = withDir { dir ->
        val s = store(dir)
        val target = s.list().first { it.name == "日常" }
        val before = target.updatedAt

        assertEquals(1, s.touch(target.id)?.usedCount)
        assertEquals(2, s.touch(target.id)?.usedCount)
        // 进程重启后仍然是 2：热度是持久化的，不是内存里的计数器。
        val reloaded = store(dir).get(target.id)
        assertEquals(2, reloaded?.usedCount)
        // 关键：套用**不改** updatedAt，否则「最新」会悄悄变成「最近使用」。
        assertEquals(before, reloaded?.updatedAt)
    }

    @Test
    fun touchingAnUnknownIdChangesNothing() = withDir { dir ->
        val s = store(dir)
        s.list()
        val snapshot = kbFile(dir).readText(Charsets.UTF_8)
        assertNull(s.touch("psn-missing"))
        assertNull(s.touch(""))
        // 没有这个人就不写盘 —— 一个空 id 不该把整库重写一遍。
        assertEquals(snapshot, kbFile(dir).readText(Charsets.UTF_8))
    }

    @Test
    fun touchActiveMatchesByBodyBecauseTheDrafterOnlyHasTheText() = withDir { dir ->
        val s = store(dir)
        val daily = s.list().first { it.name == "日常" }
        assertEquals(1, s.touchActive("  " + daily.body + "\n")?.usedCount)
        assertNull("自由文本不是专家，没有热度可记", s.touchActive("称呼：随手写的"))
    }

    @Test
    fun editingTheBodyKeepsTheBrowsingFields() = withDir { dir ->
        val s = store(dir)
        val before = s.list().first { it.name == "销售·跟单" }
        s.touch(before.id)
        val edited = s.save("销售·跟单（改）", "称呼：王总\n语气：更短", before.id)

        assertNotNull(edited)
        assertEquals(before.id, edited?.id)
        // 编辑正文不该顺手清掉用户填过的分类/简介/头像/热度/预设标识。
        assertEquals(before.category, edited?.category)
        assertEquals(before.avatar, edited?.avatar)
        assertEquals(before.tags, edited?.tags)
        assertEquals(before.presetKey, edited?.presetKey)
        assertEquals(1, edited?.usedCount)
    }

    @Test
    fun duplicatingClearsThePresetKeyAndHeat() = withDir { dir ->
        val s = store(dir)
        val src = s.list().first { it.name == "日常" }
        s.touch(src.id)
        val copy = s.duplicate(src.id)

        assertNotNull(copy)
        assertEquals("", copy?.presetKey)
        assertEquals(0, copy?.usedCount)
        // 浏览层仍然跟着复制（副本是同一张脸的另一个版本）。
        assertEquals(src.avatar, copy?.avatar)
        assertEquals(src.category, copy?.category)
    }

    // ---------------------------------------------------------- 坏文件 / 导入

    @Test
    fun aCorruptFileIsBackedUpAndNeverCleared() = withDir { dir ->
        val garbage = "这不是 JSON {{{ 用户写的三百字人设"
        writeRaw(dir, garbage)

        val s = store(dir)
        assertTrue(s.list().isEmpty())
        assertNotNull("损坏必须留下可见的说明", s.lastProblem)
        // 硬验收：坏文件**不许被清空或覆盖**，原文还在。
        assertEquals(garbage, kbFile(dir).readText(Charsets.UTF_8))
        val backups = File(dir, "kb").listFiles { f -> f.name.startsWith("personas.corrupt-") }
        assertTrue("原文件必须先备份", backups != null && backups.isNotEmpty())
    }

    @Test
    fun exportedBrowsingFieldsComeBackOnImport() = withDir { dir ->
        val a = store(dir)
        val created = a.create(
            name = "售后·自定义",
            body = "称呼：您\n关系：客服和客户\n语气：客气、简短",
            avatar = "🎧",
            description = "售后口径：先接住情绪，再给时限",
            tags = listOf("售后", "口径"),
            category = "客服",
            skillRefs = listOf("skill-a"),
            appPkgs = listOf("com.tencent.mm")
        )
        assertNotNull(created)

        // 另一台机器（空目录）。
        val otherDir = Files.createTempDirectory("jev-persona-import-").toFile()
        try {
            val b = PersonaStore.create(TestContext(otherDir))
            b.list().forEach { b.delete(it.id) }
            val result = b.importJson(a.exportJson())
            assertTrue(result.describe(), result.ok)
            // 导入的是 a 的全库（4 张预设 + 1 条自建），所以按名字取自己那条。
            val back = b.list().first { it.name == "售后·自定义" }
            assertEquals("🎧", back.avatar)
            assertEquals("售后口径：先接住情绪，再给时限", back.description)
            assertEquals(listOf("售后", "口径"), back.tags)
            assertEquals("客服", back.category)
            assertEquals(listOf("skill-a"), back.skillRefs)
            assertEquals(listOf("com.tencent.mm"), back.appPkgs)
            // presetKey / usedCount 是本机台账，不随导出走。
            assertEquals("", back.presetKey)
            assertEquals(0, back.usedCount)
        } finally {
            otherDir.deleteRecursively()
        }
    }

    @Test
    fun aHalfWrittenImportFileDoesNotBlowUp() = withDir { dir ->
        val s = store(dir)
        // 旧版导出的文件：没有 avatar/tags/category，甚至 tags 是个字符串而不是数组。
        val result = s.importJson(
            """[{"name":"旧导出","body":"称呼：你","tags":"不是数组","avatar":null}]"""
        )
        assertTrue(result.describe(), result.ok)
        val back = s.list().first { it.name == "旧导出" }
        assertEquals(emptyList<String>(), back.tags)
        assertNull(back.avatar)
    }
}

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
 * 专家目录（[ExpertPack]，331 位）的**全量**验收。
 *
 * 为什么敢在这里对 331 条逐条断言：目录是脚本从上游生成的，一个键写错、
 * 一句示例丢了，界面**照样能跑** —— 卡片画得出来、点「用」也不报错，只是
 * `PersonaCard` 静默退回自由文本，回复一点没变。这种失败在真机上几乎看不出来，
 * 只有把每一条都喂给 `PersonaCard.parse` 才能发现。
 *
 * 测试读的是**真实的 assets 文件**（不是 fixture）：比的是用户手机上那份。
 */
class ExpertPackTest {

    private fun json(): String {
        // 单测工作目录是 `app/`，与 PurityTest 同一套相对定位。
        val f = File("src/main/assets/kb/experts.json")
        assertTrue("专家目录找不到：${f.absolutePath}", f.isFile)
        return f.readText(Charsets.UTF_8)
    }

    private fun parsed(): ExpertPack.Parsed = ExpertPack.parse(json())

    @Test
    fun everyPackExpertParsesIntoEveryKeyItClaims() {
        val pack = parsed()
        assertTrue("目录解析有问题：${pack.problem}", pack.problem.isBlank())
        assertTrue("目录专家太少：${pack.presets.size}", pack.presets.size >= 300)

        pack.presets.forEach { p ->
            val card = PersonaCard.parse(p.body)
            assertTrue("「${p.name}」没被当成结构化卡，退回了自由文本", card.structured)
            // 认不出的键会静默落进 extra —— 那说明生成的键名和 PersonaCard 不同步。
            assertEquals("「${p.name}」有没被识别的键：${card.extra}", emptyList<String>(), card.extra)
            assertTrue("「${p.name}」缺称呼", card.address.isNotBlank())
            assertTrue("「${p.name}」缺关系", card.relation.isNotBlank())
            assertTrue("「${p.name}」缺语气：${card.tone}", card.tone.length >= 2)
            assertTrue("「${p.name}」缺主题", card.topic.isNotBlank())
            assertTrue("「${p.name}」示例少于 2 句", card.examples.size >= 2)
            // 主题必须是「那件事」而不是人名本身，否则 `TopicScope` 收窄知识库时
            // 会拿一个专有名词去检索，一条都命中不了。
            assertTrue("「${p.name}」的主题和名字一样：${card.topic}", card.topic != p.name)
            assertTrue("「${p.name}」正文过长：${p.body.length}", p.body.length <= 720)
            assertTrue("「${p.name}」标签少于 2 个：${p.tags}", p.tags.size >= 2)
            assertTrue("「${p.name}」分类不在预定义表里：${p.category}", p.category in ExpertPack.CATEGORY_ORDER)
            assertTrue("「${p.name}」key 不是目录前缀：${p.key}", p.key.startsWith("agency."))
        }
        assertEquals(
            "目录里有重复 key",
            pack.presets.size,
            pack.presets.map { it.key }.toSet().size
        )
    }

    /** 分类顺序错了不会报错，只会让 chips 的顺序莫名其妙 —— 所以逐字比。 */
    @Test
    fun theCategoryOrderMatchesTheJsonThatShips() {
        val pack = parsed()
        assertEquals(ExpertPack.CATEGORY_ORDER, pack.meta.categories)
        // 五个老分类必须在最前面：手写的 14 张预设全在它们里面。
        assertEquals(listOf("情感", "销售", "职场", "客服", "日常"), ExpertCatalog.CATEGORIES)
        assertEquals(ExpertCatalog.CATEGORIES, ExpertCatalog.ORDER.take(5))
        assertTrue("目录没能给出比老分类更多的抽屉", ExpertCatalog.ORDER.size > 20)
    }

    @Test
    fun everyPackDivisionCategoryIsActuallyUsed() {
        // 一个 0 条的抽屉只会让用户以为页面坏了。但五个**老分类**不算：情感/职场/日常
        // 归手写那 14 张预设，目录里本来就没有（上游 22 个 division 里没有它们）。
        val legacy = ExpertCatalog.CATEGORIES.toSet()
        val used = parsed().presets.map { it.category }.toSet()
        val empty = ExpertPack.CATEGORY_ORDER.filter { it !in legacy && it !in used }
        assertEquals("这些分类没有任何专家：$empty", emptyList<String>(), empty)
    }

    @Test
    fun aBrokenPackDegradesInsteadOfThrowing() {
        assertFalse(ExpertPack.parse("").ok)
        assertFalse(ExpertPack.parse("{ not json").ok)
        assertFalse(ExpertPack.parse("""{"experts":"nope"}""").ok)
        // 单条坏掉时，其余照常可用 —— 一处 emoji 写错不该让 330 位专家消失。
        val one = ExpertPack.parse(
            """{"categories":["技术工程"],"experts":[
                 {"key":"agency.a","name":"A","emoji":"🧩","category":"技术工程","tags":["a","b"],
                  "description":"d","body":"称呼：你\n关系：r\n语气：t\n主题：x\n示例：\n我：hi\n我：yo"},
                 {"key":"","name":"坏条","body":""}]}"""
        )
        assertEquals(1, one.presets.size)
        assertEquals("A", one.presets[0].name)
        assertTrue(one.problem.contains("1"))
    }

    /**
     * 目录专家的**搜索**能力：`ExpertCatalog.matches` 命中范围是名字/简介/标签/正文。
     *
     * 真机上 `adb input text` 在这台 ColorOS 上落不进输入框（IME 没连上），
     * 所以这条走代码验证：至少保证「搜 API 能搜到 API 测试员」「搜中文能搜到正文里
     * 带这个词的专家」这两件事成立 —— 否则 331 条目录等于没法用。
     */
    @Test
    fun theShelfIsSearchableByNameBlurbTagAndBody() {
        val pack = parsed()
        val shelf = ExpertShelf.merge(emptyList(), pack.presets)

        val api = ExpertCatalog.filter(shelf, null, "API")
        assertTrue("搜 API 应该命中若干位：${api.size}", api.size >= 3)
        assertTrue(api.any { it.name.contains("API") })

        val cn = ExpertCatalog.filter(shelf, null, "数据修复")
        assertTrue("搜中文正文词应该命中", cn.any { it.name.contains("数据修复") })

        // 分类 + 搜索叠加（界面上就是这么用的）。
        val scoped = ExpertCatalog.filter(shelf, "技术工程", "API")
        assertTrue(scoped.isNotEmpty())
        assertTrue(scoped.all { it.category == "技术工程" })

        // 空搜索 = 不筛，并且三种排序都不丢条目。
        assertEquals(shelf.size, ExpertCatalog.filter(shelf, null, "").size)
        ExpertSort.values().forEach { mode ->
            assertEquals(mode.name, shelf.size, ExpertCatalog.sort(shelf, mode).size)
        }
    }

    // ------------------------------------------------------------ 货架拼接

    private fun profile(key: String, name: String, id: String = "uuid-$key") = PersonaProfile(
        id = id, name = name, body = "称呼：你", presetKey = key
    )

    @Test
    fun theLibraryWinsOverTheShelfForTheSamePreset() {
        val pack = listOf(
            PersonaPreset("agency.a", "目录A", "称呼：你", "技术工程", listOf("x", "y"), "d", "🧩"),
            PersonaPreset("agency.b", "目录B", "称呼：你", "技术工程", listOf("x", "y"), "d", "🧩")
        )
        // 用户把 A 加入了库、改名成「我的A」，还把正文改了 —— 目录里那份样品不许覆盖它。
        val mine = listOf(profile("agency.a", "我的A").copy(body = "称呼：老板"))
        val merged = ExpertShelf.merge(mine, pack)

        assertEquals(2, merged.size)
        assertEquals("我的A", merged[0].name)
        assertEquals("称呼：老板", merged[0].body)
        assertFalse(ExpertShelf.isFromPack(merged[0]))
        assertEquals("目录B", merged[1].name)
        assertTrue(ExpertShelf.isFromPack(merged[1]))
        assertEquals("pack:agency.b", merged[1].id)
    }

    @Test
    fun aRenamedExpertIsNotOfferedTwiceUnderItsPresetName() {
        // 改名后 presetKey 仍在，靠名字兜底的那条老规则不能再冒一份同名的出来。
        val pack = listOf(
            PersonaPreset("agency.a", "目录A", "称呼：你", "技术工程", listOf("x", "y"), "d", "🧩")
        )
        val mine = listOf(profile("", "目录A")) // 用户自建，名字撞上了
        assertEquals(1, ExpertShelf.merge(mine, pack).size)
    }

    // ------------------------------------------------------------ 安装落库

    private class TestContext(private val dir: File) : ContextWrapper(null) {
        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = dir
    }

    @Test
    fun installingFromTheShelfWritesOnceAndRemembersIt() {
        val dir = Files.createTempDirectory("jev-pack-").toFile()
        try {
            val store = PersonaStore.create(TestContext(dir))
            val preset = PersonaPreset(
                "agency.a", "目录A", "称呼：你\n关系：r\n语气：t\n主题：x\n示例：\n我：hi",
                "技术工程", listOf("x", "y"), "一句话简介", "🧩"
            )
            val first = store.install(preset)
            assertNotNull(first)
            assertEquals("agency.a", first!!.presetKey)
            assertEquals("技术工程", first.category)
            assertEquals(1, store.list().count { it.presetKey == "agency.a" })

            // 再点一次「加入」不该复制出第二条。
            val second = store.install(preset)
            assertEquals(first.id, second?.id)
            assertEquals(1, store.list().count { it.presetKey == "agency.a" })

            // 台账必须落盘：装过就不再是「新预设」，删掉也不会被 topUp 复活。
            assertTrue(store.ledger().first.contains("agency.a"))
            assertTrue(store.delete(first.id))
            assertNull(store.list().firstOrNull { it.presetKey == "agency.a" })
            // 删掉之后**再点一次加入**应该又能装回来（目录是货架，不是一次性）。
            assertNotNull(store.install(preset))
        } finally {
            dir.deleteRecursively()
        }
    }
}

package com.jev.probe.core.kb

import android.content.Context
import android.content.ContextWrapper
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * S1 的**characterization test**：在动 `PersonaProfile` 的字段之前，先把
 * 「今天的人设库到底是什么样」逐条钉死。
 *
 * 为什么要先有这一层：`personas.json` 的 v2 迁移会重写用户的整个库。迁移写坏
 * 不会抛异常、不会红，只会表现为**用户打开设置页发现人设全没了**——而那时候
 * 备份文件已经躺在 `files/app/kb/` 里没人知道。所以迁移之前必须有一组断言，
 * 描述「迁移不许改变什么」：
 *
 * 1. 出厂的 4 张模板的**名字与顺序**（顺序 = 设置页里的显示顺序）；
 * 2. 首装播种一次、之后再读拿到的还是同一条（id 稳定，不是每次现造）；
 * 3. 每张模板都能被 [PersonaCard] 解析成结构化卡（认不出键 = 静默退回自由文本）；
 * 4. `promptText()` 只由 `body` 决定，**名字进不去**（这是不变量 1 的地基，
 *    之后的头像/简介/标签/分类/热度同理，一旦混进提示词，回复风格会悄悄变）；
 * 5. 删掉一张预设，下次读不会长回来。
 *
 * 这五条在 S1 前后都必须绿。**任何一条变红 = 迁移改变了既有行为**，是回滚信号，
 * 不是「测试要跟着改」的信号。
 */
class PersonaBaselineTest {

    private class TestContext(private val dir: File) : ContextWrapper(null) {
        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = dir
    }

    private fun withDir(block: (File) -> Unit) {
        val dir = Files.createTempDirectory("jev-persona-baseline-").toFile()
        try {
            block(dir)
        } finally {
            dir.deleteRecursively()
        }
    }

    /** 出厂顺序写死在这里：它是产品决定（先亲密模板、后日常、最后销售），不是实现细节。 */
    private val expectedNames = listOf("网调·我是主", "网调·我是奴", "日常", "销售·跟单")

    @Test
    fun theShippedLibraryStartsWithTheseExactPresetsInThisOrder() = withDir { dir ->
        val store = PersonaStore.create(TestContext(dir))
        val items = store.list()

        assertEquals(expectedNames, items.map { it.name })
        assertEquals(PersonaPresets.ALL.size, items.size)
        assertTrue("出厂模板都必须标记 builtin", items.all { it.builtin })
        assertTrue("id 必须是 psn- 前缀", items.all { it.id.startsWith("psn-") })
        assertTrue("正文非空", items.all { it.body.isNotBlank() })
        items.forEach { p ->
            assertNotEquals("updatedAt 必须有真实时间戳", 0L, p.updatedAt)
        }
    }

    @Test
    fun aFreshInstallSeedsOnceAndTheSecondReadKeepsTheSameEntries() = withDir { dir ->
        val first = PersonaStore.create(TestContext(dir)).list()
        // 播种真的落了盘：文件在，且第二次读（新实例 = 模拟重启）拿到的 id 一模一样。
        // 若哪天改成「每次读都现造」，用户对模板的改名/收藏就会每次启动丢失。
        assertTrue(File(dir, "kb/personas.json").isFile)
        val second = PersonaStore.create(TestContext(dir)).list()
        assertEquals(first.map { it.id }, second.map { it.id })
        assertEquals(first.map { it.name }, second.map { it.name })
        assertEquals(first.map { it.body }, second.map { it.body })
    }

    @Test
    fun everyPresetParsesIntoAStructuredCardWithTheKeysItClaims() {
        PersonaPresets.ALL.forEach { (name, body) ->
            val card = PersonaCard.parse(body)
            assertTrue("「$name」退回了自由文本", card.structured)
            assertTrue("「$name」缺称呼", card.address.isNotBlank())
            assertTrue("「$name」缺关系", card.relation.isNotBlank())
            assertTrue("「$name」缺语气", card.tone.isNotBlank())
            assertTrue("「$name」缺主题", card.topic.isNotBlank())
            assertTrue("「$name」缺示例", card.examples.isNotEmpty())
            assertEquals("「$name」有没被认出的键：${card.extra}", emptyList<String>(), card.extra)
        }
    }

    @Test
    fun thePromptTextComesFromTheBodyOnlyAndNeverFromTheName() = withDir { dir ->
        val store = PersonaStore.create(TestContext(dir))
        val marker = "纯浏览层名字不该进提示词"
        store.list().forEach { p ->
            // 名字是浏览层信息（以后还有头像/简介/标签/分类/热度）。
            // 它们一个字节都不许进提示词，否则「改个名字」也会改变回复风格。
            // 注意：不能拿模板原名直接断言「名字不出现在提示词里」——「日常」这张卡的
            // body 里本来就写着「主题：日常」，名字与之重合是数据巧合，不是泄漏。
            // 所以换成一个绝不会出现在正文里的标记名，比的是**改名前后**的提示词。
            val renamed = p.copy(name = marker)
            assertFalse(
                "「${p.name}」的名字泄漏进提示词了",
                renamed.card().promptText().contains(marker)
            )
            assertEquals(
                "改名不许改变提示词",
                p.card().promptText(),
                renamed.card().promptText()
            )
            assertEquals(
                "提示词必须等价于直接解析 body",
                PersonaCard.parse(p.body).promptText(),
                p.card().promptText()
            )
        }
    }

    @Test
    fun deletingOnePresetDoesNotBringItBackOnTheNextRead() = withDir { dir ->
        val store = PersonaStore.create(TestContext(dir))
        val daily = store.list().first { it.name == "日常" }
        assertTrue(store.delete(daily.id))

        // 模拟重启：新实例读同一个目录。
        val after = PersonaStore.create(TestContext(dir)).list()
        assertEquals(expectedNames - "日常", after.map { it.name })
    }
}

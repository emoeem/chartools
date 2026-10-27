package com.jev.probe.core.kb

import com.jev.probe.core.Prefs
import com.jev.probe.jev.ReplyPrompt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized
import java.io.File
import java.nio.file.Files

/**
 * **「任意一位专家点『用』之后，下一次起草的提示词里真的带上了它」** —— 331 条全覆盖。
 *
 * ## 为什么这条测试比 `ExpertPackTest` 更关键
 *
 * `ExpertPackTest` 证明的是「目录里每一份 body 都能解析成结构化卡」。那只覆盖了
 * 链条的第一段。用户真正抱怨的那句话是「我点了『用』，回复一点没变」—— 它可能断在
 * 后面任何一段：
 *
 * ```
 * install 落库 → touch 记热度 → Prefs.style 换成 body → PersonaCard.parse
 *              → promptText() → ReplyPrompt.styleBlock() → 起草提示词
 * ```
 *
 * 所以这里每一例都把整条链走完，并且**读盘**（`PersonaStore.create` 重新构造一个实例）
 * 而不是信内存：内存里对、盘上没写，正是上一轮真机抓到的那个 `seeded` 回归的形状。
 *
 * ## 这一条用什么当「特征句」
 *
 * 用 `主题：X` 里的 X。理由：它由 body 决定、每条专家都不同、并且 `promptText()`
 * 会把它**逐字**写进提示词（`PersonaCard.promptText()` 的 `主题：` 行）。所以
 * 「提示词里出现了 X」等价于「这位专家的 body 真的进了提示词」。
 *
 * ## 元数据负向断言为什么不是 `contains(description)`
 *
 * 因为会**假失败**：331 份 body 里有 302 份把 description 的前缀写进了 `情境` 行
 * （生成器干的），所以「description 不出现在提示词里」在字面上是假的 —— 但那是
 * **body 自己写的内容**，不是浏览层字段泄漏。真正要守的不变量是「**换掉元数据，
 * 提示词逐字不变**」，这里用哨兵值来验：
 * 把 avatar/description/tags/category/usedCount 全换成 `ZZ_*` 哨兵，`promptText()`
 * 必须**逐字相同**，且提示词里不许出现任何一个哨兵。
 */
@RunWith(Parameterized::class)
class ExpertApplyEndToEndTest(private val case: Case) {

    /** 参数化名字用这个包装：`data class` 的 `toString()` 会把整段 body 印进用例名。 */
    class Case(val preset: PersonaPreset) {
        override fun toString(): String = preset.name
    }

    companion object {

        /** 读的是**真实的 assets 文件**（用户手机上那一份），不是 fixture。 */
        private val pack: List<PersonaPreset> by lazy {
            val f = File("src/main/assets/kb/experts.json")
            assertTrue("专家目录找不到：${f.absolutePath}", f.isFile)
            val parsed = ExpertPack.parse(f.readText(Charsets.UTF_8))
            assertTrue("目录解析失败：${parsed.problem}", parsed.problem.isBlank())
            parsed.presets
        }

        @JvmStatic
        @Parameterized.Parameters(name = "{index}: {0}")
        fun data(): List<Array<Any>> = pack.map { arrayOf(Case(it)) }
    }

    private fun withStore(block: (File, ExpertTestContext) -> Unit) {
        val dir = Files.createTempDirectory("jev-expert-e2e-").toFile()
        try {
            block(dir, ExpertTestContext(dir))
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun applyingThisExpertReachesTheDraftPrompt() {
        val preset = case.preset
        val tag = "「${preset.name}」"

        withStore { _, ctx ->
            val prefs = Prefs(ctx, "expert-e2e")
            val store = PersonaStore.create(ctx)

            // 0) 前提：body 是卡的全部输入，它不能是空的（空的 install 也不该发生）。
            assertTrue("$tag body 为空", preset.body.isNotBlank())
            // 切换前：没有专家生效，提示词里没有这段人设。
            assertEquals("$tag 切换前 styleBlock 不该有人设段", "", ReplyPrompt.styleBlock(prefs.style))

            // 1) 点「用」的第一段：install 落库，且派生路径带全了浏览层。
            val installed = store.install(preset)
            assertNotNull("$tag install 返回 null（没落库）", installed)
            installed!!
            assertEquals("$tag 落了库但 presetKey 没种上", preset.key, installed.presetKey)
            assertEquals("$tag 落的 body 和目录不一致", preset.body.trim(), installed.body)
            assertEquals("$tag 头像没带过来", preset.avatar, installed.avatar)
            assertEquals("$tag 简介没带过来", preset.description, installed.description)
            assertEquals("$tag 标签没带过来", preset.tags, installed.tags)
            assertEquals("$tag 分类没带过来", preset.category, installed.category)

            // 2) 读盘：换一个 store 实例（= App 重启），条目还在。
            val onDisk = PersonaStore.create(ctx).list().firstOrNull { it.presetKey == preset.key }
            assertNotNull("$tag 重启后库里找不到", onDisk)
            onDisk!!
            assertEquals("$tag 重启后 body 变了", installed.body, onDisk.body)
            assertEquals("$tag 重启后分类丢了", preset.category, onDisk.category)

            // 3) touch：热度 +1 且落盘（内存里对、盘上没写是这个项目踩过的真 bug）。
            val touched = PersonaStore.create(ctx).touch(onDisk.id)
            assertNotNull("$tag touch 返回 null", touched)
            assertEquals("$tag 用过一次热度不是 1", 1, touched!!.usedCount)
            val afterTouch = PersonaStore.create(ctx).get(onDisk.id)
            assertNotNull("$tag touch 后条目消失了", afterTouch)
            assertEquals("$tag 热度没落盘", 1, afterTouch!!.usedCount)
            // touch 不许污染「最新」排序（`updatedAt` 是「最近编辑」）。
            assertEquals("$tag touch 改了 updatedAt，『最新』会变成『最近使用』", onDisk.updatedAt, afterTouch.updatedAt)

            // 4) seeded 台账含这个 key 且落盘；装过就该把墓碑划掉。
            val fresh = PersonaStore.create(ctx)
            val (seeded, removed) = fresh.ledger()
            assertTrue("$tag 没记进 seeded 台账（下次启动会重复播种）", preset.key in seeded)
            assertFalse("$tag 装回来了但 removed 墓碑没划掉", preset.key in removed)

            // 5) 切 reply_style —— 唯一真源换成了这位专家的 body。
            prefs.style = touched.body
            assertEquals("$tag Prefs.style 没读回刚写进去的 body", touched.body, prefs.style)
            assertEquals("$tag 换了 body 但 activeOf 认不出这位专家", onDisk.id, fresh.activeOf(prefs.style)?.id)

            // 6) 下一次起草真正读到的卡：解析得出来、提示词非空、带上了这位专家的特征。
            val card = PersonaCard.parse(prefs.style)
            assertTrue("$tag 切过去之后解析成了自由文本", card.structured)
            val prompt = card.promptText()
            assertTrue("$tag promptText 为空", prompt.isNotBlank())
            assertTrue("$tag 主题「${card.topic}」没进提示词", prompt.contains("主题：${card.topic}"))
            assertTrue("$tag 称呼没进提示词", prompt.contains("称呼：${card.address}"))
            assertTrue("$tag 语气没进提示词", prompt.contains("语气：${card.tone}"))

            // 特征句必须来自 body 本身，而不是我们另造的东西。
            // 比对的是「body 声明的那个值」，不是字面子串：331 份里有 2 份写成
            // `主题： iOS`（冒号后带空格），而 `PersonaCard` 按声明会 trim，
            // 用 `contains` 会假失败。
            val declaredTopic = Regex("主题：\\s*([^\\n]*)").find(preset.body)
                ?.groupValues?.get(1)?.trim()
            assertEquals("$tag 提示词里的主题不是 body 声明的那个", declaredTopic, card.topic)

            // 7) 这段确实进了起草提示词（styleBlock 是唯一入口），且和「没选专家」不同。
            val block = ReplyPrompt.styleBlock(prompt, card.registerOpen)
            assertNotEquals("$tag styleBlock 和没有专家时一模一样", ReplyPrompt.styleBlock(""), block)
            assertTrue("$tag styleBlock 没带上卡", block.contains("<persona_card>"))
            assertTrue("$tag styleBlock 没带主题", block.contains("主题：${card.topic}"))

            // 8) 元数据一个字节都不许进提示词：换成哨兵，提示词必须逐字不变。
            val ghost = touched.copy(
                avatar = "ZZ_AVATAR",
                description = "ZZ_BLURB",
                tags = listOf("ZZ_TAG"),
                category = "ZZ_CATEGORY",
                usedCount = 9999
            )
            assertEquals(
                "$tag 改了浏览层字段，提示词跟着变了（元数据泄漏进 promptText）",
                prompt,
                PersonaCard.parse(ghost.body).promptText()
            )
            listOf("ZZ_AVATAR", "ZZ_BLURB", "ZZ_TAG", "ZZ_CATEGORY", "9999").forEach { sentinel ->
                assertFalse("$tag 提示词里出现了浏览层哨兵 $sentinel", prompt.contains(sentinel))
            }
        }
    }
}

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
import java.io.File
import java.nio.file.Files

/**
 * 专家切换的**状态语义**：换人不能有残留，没选专家时提示词一个字节都不许多。
 *
 * 为什么不放在 [ExpertApplyEndToEndTest] 里：那个类是 `Parameterized`，JUnit 会让
 * **每一个** `@Test` 都跟着 331 个参数各跑一遍。原本 331 例 + 2 个用例被跑成了
 * 331×3 = 993 次（多出来的 662 次是纯重复）。要的是「331 例全量」+「这 2 条各跑一次」，
 * 所以拆成两个类：一个按参数展开，一个只跑一次。
 */
class ExpertApplySwitchTest {

    private val pack: List<PersonaPreset> by lazy {
        val f = File("src/main/assets/kb/experts.json")
        assertTrue("专家目录找不到：${f.absolutePath}", f.isFile)
        val parsed = ExpertPack.parse(f.readText(Charsets.UTF_8))
        assertTrue("目录解析失败：${parsed.problem}", parsed.problem.isBlank())
        parsed.presets
    }

    private fun withStore(block: (ExpertTestContext) -> Unit) {
        val dir = Files.createTempDirectory("jev-expert-switch-").toFile()
        try {
            block(ExpertTestContext(dir))
        } finally {
            dir.deleteRecursively()
        }
    }

    /**
     * 换专家不能有残留：A → B 之后，B 的提示词里不能再出现 A 的主题。
     *
     * 这条抓的是「切换只改了缓存键、提示词还留着上一位」那一类问题 —— 当前实现里
     * 只有一条 `Prefs.style`，所以它在**代码上**不该发生；写出来是为了让它
     * **永远不可能**悄悄发生（比如以后有人给 `PersonaCard` 或提示词加静态缓存）。
     *
     * 选参数时要求「互相不包含对方主题」：否则子串巧合会让 `assertFalse` 失去意义。
     */
    @Test
    fun switchingFromOneExpertToAnotherLeavesNoResidue() {
        val a = pack.first()
        val aTopic = PersonaCard.parse(a.body).topic
        val b = pack.firstOrNull { candidate ->
            val bTopic = PersonaCard.parse(candidate.body).topic
            candidate.key != a.key &&
                !candidate.body.contains(aTopic) &&
                !a.body.contains(bTopic) &&
                bTopic != aTopic
        } ?: throw AssertionError("目录里找不到一对互相不包含对方主题的专家，这条断言无法成立")
        val bTopic = PersonaCard.parse(b.body).topic
        assertNotEquals("用来对比的两位专家主题相同", aTopic, bTopic)

        withStore { ctx ->
            val prefs = Prefs(ctx, "expert-switch")
            val store = PersonaStore.create(ctx)

            val pa = store.install(a)!!
            prefs.style = pa.body
            val promptA = PersonaCard.parse(prefs.style).promptText()
            assertTrue("A 的提示词里没有 A 的主题", promptA.contains("主题：$aTopic"))

            val pb = store.install(b)!!
            prefs.style = pb.body
            val promptB = PersonaCard.parse(prefs.style).promptText()
            assertTrue("B 的提示词里没有 B 的主题", promptB.contains("主题：$bTopic"))
            assertFalse("换成 B 之后 A 的主题还留在提示词里：$promptB", promptB.contains("主题：$aTopic"))

            // 两位都还在库里，谁也不覆盖谁。
            val reloaded = PersonaStore.create(ctx)
            assertEquals("两位专家没有都留在库里", 1, reloaded.list().count { it.presetKey == a.key })
            assertEquals("两位专家没有都留在库里", 1, reloaded.list().count { it.presetKey == b.key })
            val stillA = reloaded.activeOf(pa.body)
            assertNotNull("A 的正文在库里找不到了（被 B 覆盖了？）", stillA)
            assertEquals("A 的正文被 B 覆盖了", a.body.trim(), stillA!!.body)
        }
    }

    /** 「没选专家」时必须和加专家库之前一模一样：空块、零字节。 */
    @Test
    fun anEmptyStyleStillProducesNoPersonaBlock() {
        withStore { ctx ->
            val prefs = Prefs(ctx, "expert-empty")
            assertEquals("", prefs.style)
            assertEquals("", ReplyPrompt.styleBlock(prefs.style))
            assertNull("空 style 不该匹上任何专家", PersonaStore.create(ctx).activeOf(prefs.style))
        }
    }
}

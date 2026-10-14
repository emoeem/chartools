package com.jev.probe.core.skill

import com.jev.probe.core.Intensity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * 「狗头军师真的起作用了吗」的注入层验证（用户 2026-10-07 提问）。
 *
 * 用打包进 assets 的真技能 + 真文件，跑 app 真实的匹配链路：
 * [SkillMatcher.match]（正文 L2 何时进）→ [SkillResources.select]（参考文件
 * L3 挑哪几篇）。场景写的是真实聊天里会出现的话，不是为匹配度身定造的关键词
 * 堆——每一句都是人会说出来的。
 *
 * 三个结论要能从用例名直接读出来：
 *  - 冲突/暧昧场景命中（目录里的关键词在真实对话里出现两次以上就够）
 *  - 命中后参考资料真的选得出对应篇章（不是空转）
 *  - 纯网调场景（另一个知识域）可以不命中——技能有自己的边界，那是领域卡的地盘
 */
class SkillHitProbeTest {

    private val skillDir = listOf("src/main/assets", "app/src/main/assets")
        .map { File("$it/skills/goutoujunshi") }
        .firstOrNull { it.isDirectory }
        ?: throw AssertionError("assets 里没有狗头军师技能包")

    private val skill = run {
        val parsed = SkillMd.parse(File(skillDir, "SKILL.md").readText(Charsets.UTF_8))!!
        Skill(frontmatter = parsed.first, body = parsed.second, dir = skillDir, enabled = true)
    }

    private fun hit(query: String): SkillHit? = SkillMatcher.match(query, listOf(skill))

    @Test
    fun aConflictConversationPullsTheSkillIn() {
        val hit = hit("她又跟我吵架了，说我根本不在乎她，每次都是这样，再吵下去真的会分手")
        assertNotNull("冲突场景应命中狗头军师", hit)
        assertTrue(hit!!.body.contains("狗头军师"))
    }

    @Test
    fun aFlirtyChatAboutConversationSkillsPullsItIn() {
        val hit = hit("你最近跟我聊天特别会接话，是不是有什么技巧，教教我暧昧怎么推进")
        assertNotNull("暧昧/接话场景应命中", hit)
    }

    @Test
    fun anOffDomainWangdiaoSceneMayMissAndThatIsFine() {
        // 网调是另一个知识域（领域卡的领地）；这里只断言「不崩、返回或返回空都合法」，
        // 并打印实际行为留档。
        val hit = hit("先生我准备好了，可以开始了吗，今天的任务是什么")
        println("SKILLPROBE 网调场景命中=${hit != null} score=${hit?.score}")
    }

    @Test
    fun aHitAlsoSelectsRelevantReferenceChapters() {
        val hit = hit("我们又吵架了，她很生气，冷战三天了，怎么修复关系")
        assertNotNull(hit)
        val extra = SkillResources.select(
            "我们又吵架了，她很生气，冷战三天了，怎么修复关系", skill)
        assertTrue("命中后应挑出参考资料", extra.isNotEmpty())
        assertTrue(extra, extra.contains("【参考："))
        println("SKILLPROBE 选中参考 = " + Regex("【参考：([^】]+)】").findAll(extra)
            .map { it.groupValues[1] }.toList())
    }

    @Test
    fun theSkillBodyCarriesTheAdaptationPreamble() {
        // 改写说明必须还在正文里：不让模型向用户发问卷/要求建档是硬规矩。
        assertTrue(skill.body.contains("在本应用里怎么用"))
        assertTrue(skill.body.contains("不要让用户填问卷"))
    }

    @Test
    fun theIntensityEnumStaysAlignedWithLabels() {
        // 防呆：档位枚举和标签一一对应（OverlayController 的 pill 直接用 label）。
        assertEquals(4, Intensity.entries.size)
        assertEquals("自动", Intensity.AUTO.label)
    }
}

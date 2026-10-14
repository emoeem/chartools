package com.jev.probe.core.skill

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * L3 层：命中技能后从资源文件里再挑几篇。这是狗头军师语料（references/ 下
 * 40+ 篇）真正到达提示词的通道——只注入 SKILL.md、资源躺在磁盘上等于没带。
 * 这里钉住：匹配要两个词以上才算命中、只挑 markdown、预算封顶、没命中就空串。
 */
class SkillResourcesTest {

    private var lastDir: File? = null

    private fun skillWith(vararg refs: Pair<String, String>): Skill {
        val dir = File.createTempFile("skillres", "").let { f ->
            f.delete(); f.mkdirs().let { f }
        }!!
        lastDir = dir
        refs.forEach { (name, content) ->
            val f = File(dir, name)
            f.parentFile.mkdirs()
            f.writeText(content, Charsets.UTF_8)
        }
        return Skill(
            frontmatter = SkillFrontmatter(name = "goutoujunshi", description = "测试用"),
            body = "SKILL BODY",
            dir = dir,
            enabled = true
        )
    }

    @org.junit.After
    fun cleanup() {
        lastDir?.deleteRecursively()
    }

    private val conflict = "references/knowledge/07-沟通冲突与修复.md" to
        "吵架之后不要急着讲道理。对方冷战时先修复情绪：承认具体的事，给出修复尝试，" +
        "再确认对方有没有接住。修复的关键不是你修没修，是对方收没收到。"
    private val topics = "references/practical/巧妙接话技巧：让沟通更流畅的实用指南.md" to
        "接话的底层逻辑是先接住对方话头再顺势推进。日常闲聊里用追问和共鸣让对话更流畅。"

    @Test
    fun picksTheReferenceTheConversationIsAbout() {
        val s = skillWith(conflict, topics)
        val extra = SkillResources.select("对方在跟我吵架冷战，怎么修复情绪", s)
        assertTrue(extra, extra.contains("【参考：07-沟通冲突与修复】"))
        assertFalse(extra, extra.contains("巧妙接话技巧"))
        assertTrue(extra, extra.contains("修复尝试"))
    }

    @Test
    fun aSingleSharedWordIsNotAHit() {
        // 与 SkillMatcher 同一纪律：一个词是巧合。聊「今晚吃什么」里有个"话"字
        // 不该把接话指南带进来。
        val s = skillWith(conflict, topics)
        assertEquals("", SkillResources.select("今天晚饭吃什么话梅", s))
    }

    @Test
    fun nonMarkdownFilesNeverRideAlong() {
        val s = skillWith(
            conflict,
            "SOURCE.txt" to "goutoujunshi https://github.com/...",
            "LICENSE" to "MIT License")
        val extra = SkillResources.select("吵架冷战修复情绪", s)
        assertFalse(extra, extra.contains("github.com"))
        assertFalse(extra, extra.contains("MIT License"))
    }

    @Test
    fun budgetCapsTheInjection() {
        val long = "references/knowledge/03-依恋理论与情绪调节.md" to
            "依恋理论讲焦虑型和回避型。" + "冷战时回避型会筑墙，焦虑型会追问。".repeat(300)
        val s = skillWith(long)
        val extra = SkillResources.select("焦虑型和回避型的依恋冷战筑墙", s, budgetChars = 500)
        // 单篇超预算时截断到剩余预算，而不是整篇丢掉。
        assertTrue(extra.isNotEmpty())
        assertTrue("预算封顶：${extra.length}", extra.length <= 500 + 20)
    }

    @Test
    fun maxFilesCapsTheCount() {
        val s = skillWith(
            conflict,
            topics,
            "references/practical/万能夸人的话术技巧.md" to "夸人要夸具体行为，对方帮你整理了会议纪要，就夸细心靠谱。",
            "references/knowledge/08-同意边界性与亲密.md" to "亲密行为要确认同意，边界和安全词在开始之前说清楚。")
        // 每篇都要和查询共享两个以上词才可能入选（MIN_TERMS 纪律），
        // 所以这条查询把四篇的主题词都放进去了。
        val extra = SkillResources.select("夸人具体、接话流畅、吵架修复、同意边界", s, maxFiles = 2)
        assertEquals(2, Regex("【参考：").findAll(extra).count())
    }

    @Test
    fun noResourcesOrBlankQueryMeansEmpty() {
        val bare = skillWith()
        assertEquals("", SkillResources.select("随便什么对话", bare))
        val s = skillWith(conflict)
        assertEquals("", SkillResources.select("", s))
        assertEquals("", SkillResources.select("吵架冷战修复", s, maxFiles = 0))
    }

    @Test
    fun theBundledPackShipsAParsableSkillAndItsCorpus() {
        // 打包进 assets 的狗头军师必须：frontmatter 可解析、name 与目录一致
        // （SkillStore.list 会因不一致静默跳过）、references 完整在包里。
        val md = listOf("src/main/assets", "app/src/main/assets")
            .map { File("$it/skills/goutoujunshi/SKILL.md") }
            .firstOrNull { it.isFile } ?: throw AssertionError("内置技能包 SKILL.md 不在 assets 里")
        val parsed = SkillMd.parse(md.readText(Charsets.UTF_8))
            ?: throw AssertionError("内置技能包的 frontmatter 解析失败")
        assertEquals("goutoujunshi", parsed.first.name)
        assertEquals("MIT", parsed.first.license)
        assertTrue(parsed.second.length > 1000)
        val refs = File(md.parent, "references").walkTopDown().filter { it.isFile && it.extension == "md" }.count()
        assertTrue("references 应有 40+ 篇，实际 $refs", refs >= 40)
    }
}

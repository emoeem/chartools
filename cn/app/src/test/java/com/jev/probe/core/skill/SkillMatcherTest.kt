package com.jev.probe.core.skill

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Which skill gets pulled into a round.
 *
 * This app has no tool calling on the reply route, so the "@-mention the skill"
 * decision the reference agents leave to the model has to be made here. The
 * asymmetry tested below is deliberate: missing a skill costs nothing, pulling
 * in the wrong instructions does.
 */
class SkillMatcherTest {

    private fun skill(name: String, description: String, body: String = "BODY-$name") = Skill(
        frontmatter = SkillFrontmatter(name = name, description = description),
        body = body,
        dir = File("/tmp/$name"),
        enabled = true
    )

    private val translate = skill("translate-zh-en", "把一段话翻译成英文时使用。用户需要中译英时用它。")
    private val weekly = skill("weekly-report", "写周报时使用。汇总本周工作，列出下周计划。")
    private val emoji = skill("emoji-style", "回复里多用表情符号时使用。")

    @Test
    fun picksTheSkillTheConversationIsAbout() {
        val hit = SkillMatcher.match("帮我翻译这段话", listOf(weekly, translate, emoji))
        assertTrue(hit != null)
        assertEquals("translate-zh-en", hit!!.ref.name)
        assertEquals("BODY-translate-zh-en", hit.body)
        assertTrue(hit.score > 0.0)
    }

    @Test
    fun picksADifferentSkillForADifferentTopic() {
        // A whole conversation about the topic, which is what the haystack
        // really is (title + the last few messages), not a two-word probe.
        val hit = SkillMatcher.match("帮我写周报，汇总本周工作，列出下周计划", listOf(translate, weekly, emoji))
        assertEquals("weekly-report", hit?.ref?.name)
    }

    @Test
    fun oneSharedBigramIsNotEnough() {
        // Deliberately strict: "周报" alone does not pull in the weekly-report
        // skill, because the body is instructions that would then ride along on
        // every round that happens to mention the word once.
        assertNull(SkillMatcher.match("这周的周报要怎么写", listOf(translate, weekly, emoji)))
    }

    @Test
    fun anUnrelatedTurnMatchesNothing() {
        assertNull(SkillMatcher.match("今天晚饭吃什么", listOf(translate, weekly, emoji)))
    }

    @Test
    fun blankQueryAndEmptyCorpusMatchNothing() {
        assertNull(SkillMatcher.match("", listOf(translate)))
        assertNull(SkillMatcher.match("帮我翻译这段话", emptyList()))
    }

    // ---------- catalogue ----------

    @Test
    fun catalogueIsTheXmlShapeTheReferenceImplementationUses() {
        val cat = SkillMatcher.catalogue(
            listOf(SkillRef("translate-zh-en", "把一段话翻译成英文"), SkillRef("weekly-report", "写周报"))
        )
        assertTrue(cat.startsWith("<available_skills>"))
        assertTrue(cat.endsWith("</available_skills>"))
        assertTrue(cat.contains("<skill name=\"translate-zh-en\">"))
        assertTrue(cat.contains("<description>把一段话翻译成英文</description>"))
    }

    @Test
    fun catalogueEscapesMarkup() {
        val cat = SkillMatcher.catalogue(listOf(SkillRef("a-b", "use <this> & \"that\"")))
        assertTrue(cat.contains("use &lt;this&gt; &amp; &quot;that&quot;"))
    }

    @Test
    fun catalogueHonoursTheBudget() {
        val many = (1..200).map { SkillRef("skill-$it", "说明 $it ".repeat(20)) }
        val cat = SkillMatcher.catalogue(many)
        assertTrue("封顶后不得超过预算太多", cat.length <= SkillMatcher.CATALOGUE_BUDGET + 64)
        assertTrue(cat.contains("skill-1"))
    }

    @Test
    fun emptyCatalogueIsEmptyString() {
        assertEquals("", SkillMatcher.catalogue(emptyList()))
    }

    @Test
    fun aBlankDescriptionStillRendersButIsFlaggedUpstream() {
        // SkillMd refuses an empty description, so SkillStore never yields one;
        // the catalogue simply renders whatever refs it is handed.
        val cat = SkillMatcher.catalogue(listOf(SkillRef("a-b", "")))
        assertTrue(cat.contains("a-b"))
    }
}

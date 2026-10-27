package com.jev.probe.ui

import com.jev.probe.core.kb.PersonaProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 卡面文案的单元测试。
 *
 * 这一层坏了不会报错：简介为空 → 卡片上出现一片空白；正文第一行是 `称呼：小明`
 * → 卡面直接显示「称呼：小明」这种键名；「用过 0 次」→ 一行没意义的噪音。
 * 全都是「看起来有点怪但没人报 bug」的那类问题，所以只能用测试钉住。
 */
class ExpertCardTest {

    private fun p(
        name: String = "跟单",
        body: String = "称呼：王总\n语气：短句",
        avatar: String? = null,
        description: String? = null,
        tags: List<String> = emptyList(),
        category: String? = null,
        used: Int = 0,
        builtin: Boolean = false
    ) = PersonaProfile(
        id = "psn-1", name = name, body = body, avatar = avatar,
        description = description, tags = tags, category = category,
        usedCount = used, builtin = builtin
    )

    @Test
    fun aMissingAvatarFallsBackToThePlaceholder() {
        assertEquals(ExpertCard.FALLBACK_AVATAR, ExpertCard.of(p()).avatar)
        assertEquals("🖤", ExpertCard.of(p(avatar = "🖤")).avatar)
        // 空白字符串等于没设：不该在卡面留一个空位。
        assertEquals(ExpertCard.FALLBACK_AVATAR, ExpertCard.of(p(avatar = "   ")).avatar)
    }

    @Test
    fun theBlurbPrefersTheDescription() {
        val c = ExpertCard.of(p(description = "先结论后理由"))
        assertEquals("先结论后理由", c.blurb)
    }

    @Test
    fun withoutADescriptionTheFirstBodyLineIsUsedAndItsKeyStripped() {
        // 卡面上冒出「称呼：」是噪音，而它在正文里是必须的键。
        assertEquals("王总", ExpertCard.of(p()).blurb)
        assertEquals("我们是朋友", ExpertCard.of(p(body = "我们是朋友")).blurb)
        // 长行要截断，且截断有省略号 —— 否则一张卡会被撑成五行。
        val long = "称呼：" + "很".repeat(80)
        val blurb = ExpertCard.blurbOf(p(body = long))
        assertTrue(blurb.length <= ExpertCard.MAX_BLURB)
        assertTrue(blurb.endsWith("…"))
    }

    @Test
    fun tagsAreTrimmedCappedAndBlanksDropped() {
        val c = ExpertCard.of(p(tags = listOf(" 跟单 ", "", "方案", "不催", "第四个")))
        assertEquals(listOf("跟单", "方案", "不催"), c.tags)
        assertTrue(c.hasTags)
        assertFalse(ExpertCard.of(p()).hasTags)
    }

    @Test
    fun usageReadsAsSentencesNotRawNumbers() {
        assertEquals("未使用", ExpertCard.of(p(used = 0)).usage)
        assertEquals("用过 1 次", ExpertCard.of(p(used = 1)).usage)
        assertEquals("用过 12 次", ExpertCard.of(p(used = 12)).usage)
    }

    @Test
    fun theCategoryIsEmptyStringWhenUnsetSoFiltersCanCompare() {
        assertEquals("", ExpertCard.of(p()).category)
        assertEquals("销售", ExpertCard.of(p(category = " 销售 ")).category)
    }

    @Test
    fun theBadgeMarksBuiltInPresets() {
        assertTrue(ExpertCard.of(p(builtin = true)).builtin)
        assertFalse(ExpertCard.of(p(builtin = false)).builtin)
    }
}

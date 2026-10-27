package com.jev.probe.core.kb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 专家库浏览层的纯函数测试。
 *
 * 这些规则全部**没有报错可查**：排序排错了，用户只会觉得「推荐莫名其妙」；
 * 搜索漏了简介，用户只会觉得「我明明写了」。所以每一条都要有断言，
 * 而不是靠真机点两下看一眼。
 */
class ExpertCatalogTest {

    private fun p(
        name: String,
        body: String = "称呼：你",
        category: String? = null,
        tags: List<String> = emptyList(),
        description: String? = null,
        builtin: Boolean = false,
        used: Int = 0,
        updatedAt: Long = 1L
    ) = PersonaProfile(
        id = "psn-$name",
        name = name,
        body = body,
        updatedAt = updatedAt,
        builtin = builtin,
        description = description,
        tags = tags,
        category = category,
        usedCount = used
    )

    private val sample = listOf(
        p("主位", category = "情感", builtin = true, used = 0, updatedAt = 10L),
        p("臣位", category = "情感", builtin = true, used = 0, updatedAt = 20L),
        p("跟单", category = "销售", builtin = true, used = 5, updatedAt = 30L),
        p("我的客服", category = "客服", used = 1, updatedAt = 40L),
        p("草稿", category = null, updatedAt = 50L)
    )

    // ---------------------------------------------------------------- 分类

    @Test
    fun categoriesFollowThePredefinedOrderThenCustomThenUncategorized() {
        val items = sample + p("自建分类", category = "塔罗")
        assertEquals(
            listOf("情感", "销售", "客服", "塔罗", ExpertCatalog.UNCATEGORIZED),
            ExpertCatalog.categories(items)
        )
    }

    @Test
    fun categoriesNeverListAnEmptyBucket() {
        // 只有一张没分类的卡：不许冒出「情感/销售/…」七个空抽屉。
        assertEquals(
            listOf(ExpertCatalog.UNCATEGORIZED),
            ExpertCatalog.categories(listOf(p("孤零零")))
        )
        assertEquals(emptyList<String>(), ExpertCatalog.categories(emptyList()))
    }

    @Test
    fun filterByCategoryKeepsOnlyThatBucket() {
        val hits = ExpertCatalog.filter(sample, category = "情感")
        assertEquals(listOf("主位", "臣位"), hits.map { it.name })
        // null / 空 / 「全部」都是不筛。
        assertEquals(sample.size, ExpertCatalog.filter(sample, null).size)
        assertEquals(sample.size, ExpertCatalog.filter(sample, "").size)
        assertEquals(sample.size, ExpertCatalog.filter(sample, ExpertCatalog.ALL).size)
    }

    @Test
    fun filterUncategorizedReturnsOnlyTheBlankOnes() {
        val hits = ExpertCatalog.filter(sample, category = ExpertCatalog.UNCATEGORIZED)
        assertEquals(listOf("草稿"), hits.map { it.name })
    }

    // ---------------------------------------------------------------- 搜索

    @Test
    fun searchLooksAtNameDescriptionTagsAndBody() {
        val items = listOf(
            p("甲", body = "称呼：王总\n主题：销售跟单"),
            p("乙", description = "售后口径"),
            p("丙", tags = listOf("跟单", "方案")),
            p("丁", body = "称呼：你")
        )
        assertEquals(listOf("甲"), ExpertCatalog.filter(items, null, "王总").map { it.name })
        assertEquals(listOf("乙"), ExpertCatalog.filter(items, null, "售后").map { it.name })
        // 「跟单」同时命中甲的正文（销售跟单）和丙的标签 —— 搜索是并集。
        assertEquals(listOf("甲", "丙"), ExpertCatalog.filter(items, null, "跟单").map { it.name })
    }

    @Test
    fun searchIgnoresCaseAndSurroundingSpaces() {
        val items = listOf(p("Funnel", description = "Sales follow-up"))
        assertEquals(1, ExpertCatalog.filter(items, null, "  funnel ").size)
        assertEquals(1, ExpertCatalog.filter(items, null, "SALES").size)
        assertEquals(0, ExpertCatalog.filter(items, null, "不存在").size)
        // 空关键词 = 不筛，不是「什么都搜不到」。
        assertEquals(1, ExpertCatalog.filter(items, null, "   ").size)
    }

    // ---------------------------------------------------------------- 排序

    @Test
    fun comprehensiveLetsOneUseOvertakeABuiltIn() {
        // 综合分 = usedCount×3 + (builtin ? 2 : 0)
        assertEquals(2, ExpertCatalog.score(p("内置", builtin = true)))
        assertEquals(3, ExpertCatalog.score(p("用过一次", used = 1)))
        val ranked = ExpertCatalog.sort(
            listOf(
                p("没人用过的内置", builtin = true),
                p("刚用过的自建", used = 1)
            ),
            ExpertSort.COMPREHENSIVE
        )
        assertEquals(listOf("刚用过的自建", "没人用过的内置"), ranked.map { it.name })
    }

    @Test
    fun hottestSortsByUsageAndFallsBackToTheNewest() {
        val ranked = ExpertCatalog.sort(sample, ExpertSort.HOTTEST)
        assertEquals("跟单", ranked.first().name)          // used=5
        assertEquals("我的客服", ranked[1].name)            // used=1
        // 都没用过的那几张按「最近编辑」排：草稿(50) > 臣位(20) > 主位(10)
        assertEquals(listOf("草稿", "臣位", "主位"), ranked.drop(2).map { it.name })
    }

    @Test
    fun newestSortsByEditedTimeNotByUsage() {
        val ranked = ExpertCatalog.sort(sample, ExpertSort.NEWEST)
        // 草稿最近编辑(50)，尽管一次都没用过；跟单用得最多但编辑于 30。
        assertEquals(listOf("草稿", "我的客服", "跟单", "臣位", "主位"), ranked.map { it.name })
    }

    @Test
    fun tiesFallBackToNameSoTheOrderIsDeterministic() {
        // 用 ASCII 名字：中文按码位比较（乙 U+4E59 < 甲 U+7532），拿它当预期
        // 只会把「排序规则」写成「Unicode 冷知识」。
        val b = p("expert-b", builtin = true, used = 1, updatedAt = 7L)
        val a = p("expert-a", builtin = true, used = 1, updatedAt = 7L)
        listOf(ExpertSort.COMPREHENSIVE, ExpertSort.HOTTEST, ExpertSort.NEWEST).forEach { mode ->
            assertEquals(
                mode.label,
                listOf("expert-a", "expert-b"),
                ExpertCatalog.sort(listOf(b, a), mode).map { it.name }
            )
        }
    }

    // ------------------------------------------------------------ 组合 / 纯度

    @Test
    fun browseComposesFilterThenSort() {
        val items = sample + p("我的销售", category = "销售", used = 9, updatedAt = 60L)
        val shown = ExpertCatalog.browse(items, category = "销售", query = "", mode = ExpertSort.HOTTEST)
        assertEquals(listOf("我的销售", "跟单"), shown.map { it.name })
        // 搜索和分类是「且」的关系。
        assertEquals(1, ExpertCatalog.browse(items, "销售", "跟单").size)
    }

    @Test
    fun sortDoesNotMutateTheInputOrder() {
        val before = sample.map { it.name }
        ExpertCatalog.sort(sample, ExpertSort.NEWEST)
        assertEquals(before, sample.map { it.name })
    }

    @Test
    fun anUnknownSortLabelFallsBackToComprehensive() {
        assertEquals(ExpertSort.COMPREHENSIVE, ExpertSort.ofLabel("按颜值"))
        assertEquals(ExpertSort.HOTTEST, ExpertSort.ofLabel("最热"))
        assertFalse(ExpertCatalog.sort(sample, ExpertSort.ofLabel("按颜值")).isEmpty())
        assertTrue(ExpertCatalog.score(p("负数热度", used = -5)) >= 0)
    }
}

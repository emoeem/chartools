package com.jev.probe.core.kb

/**
 * 专家库的排序方式。「综合 / 最热 / 最新」就是界面上那三个 tab。
 *
 * 放在这里而不是界面层，是因为排序规则要被单测钉住 —— 「最热」排错了不会报错，
 * 只会让用户觉得「这个 App 的推荐莫名其妙」。
 */
enum class ExpertSort(val label: String) {
    /** 精选优先，但**用得多能顶上来**：`usedCount * 3 + (builtin ? 2 : 0)`。 */
    COMPREHENSIVE("综合"),

    /** 只看套用次数。 */
    HOTTEST("最热"),

    /** 只看最近编辑时间（`updatedAt`），不是最近使用 —— 见 [PersonaStore.touch]。 */
    NEWEST("最新");

    companion object {
        fun ofLabel(label: String): ExpertSort =
            values().firstOrNull { it.label == label.trim() } ?: COMPREHENSIVE
    }
}

/**
 * 专家库的**纯函数**浏览层：分类、搜索、排序。
 *
 * 为什么单独一个文件、且**不 import 任何 android.***：这三件事全是
 * `List<PersonaProfile> → List<PersonaProfile>`，没有一行需要 `Context`。
 * 把它们留在 Activity 里，就只能靠「跑起来看一眼」验证；独立出来之后，
 * 「综合排序凭什么是这个顺序」「搜『跟单』能不能搜到 `sales.followup`」
 * 都能用 JVM 单测钉死。S5 还要把它搬去 `global/` 复用，那里更不能有 Android 依赖。
 *
 * 全部函数**不改入参**、返回新列表（`sortedWith` 本身返回新 list）。
 */
object ExpertCatalog {

    /** 内置分类的**固定顺序**（界面 tab 的顺序）。用户自建的分类排在后面。 */
    val CATEGORIES: List<String> = listOf("情感", "销售", "职场", "客服", "日常")

    /**
     * 全部分类的展示顺序 = 五个老分类 + 专家目录的 22 个 division。
     *
     * 老分类必须在前：手写那 14 张预设全在它们里面，而目录的 331 位专家一个都不在。
     * 让「技术工程」排到「情感」前面，老用户会以为自己的卡没了。
     */
    val ORDER: List<String> = CATEGORIES + ExpertPack.CATEGORY_ORDER.filter { it !in CATEGORIES }

    /** 没有分类的条目归到这里（只在真有这种条目时出现）。 */
    const val UNCATEGORIZED: String = "未分类"

    /** 「全部」不是分类，是「不筛」，单独给一个常量避免各处写字面量写错。 */
    const val ALL: String = "全部"

    /**
     * 当前库里真实存在的分类，按 [CATEGORIES] 的顺序排；不在预定义表里的自定义分类
     * 按名字排在后面；有未分类条目时最后追加 [UNCATEGORIZED]。
     *
     * 刻意**不返回空分类**：点开一个 0 条的抽屉只会让用户以为页面坏了。
     */
    fun categories(items: List<PersonaProfile>): List<String> {
        val present = items.map { it.categoryOrBlank }.toSet()
        val out = ArrayList<String>()
        ORDER.forEach { if (it in present) out += it }
        present.filter { it.isNotBlank() && it !in ORDER }
            .sorted()
            .forEach { out += it }
        if (present.any { it.isBlank() }) out += UNCATEGORIZED
        return out
    }

    /**
     * 按分类 + 关键词筛。
     *
     * @param category null / 空 / [ALL] 都表示不筛；[UNCATEGORIZED] 筛没有分类的条目。
     * @param query 去首尾空白、忽略大小写；空 = 不筛。命中范围是**名字、简介、标签、
     *   正文** —— 正文也算，因为用户往往记得的是「那张写着『跪好，等我』的卡」。
     */
    fun filter(
        items: List<PersonaProfile>,
        category: String? = null,
        query: String = ""
    ): List<PersonaProfile> {
        val cat = category?.trim().orEmpty()
        val q = query.trim()
        return items.filter { p ->
            val catOk = when {
                cat.isEmpty() || cat == ALL -> true
                cat == UNCATEGORIZED -> p.categoryOrBlank.isBlank()
                else -> p.categoryOrBlank.equals(cat, ignoreCase = true)
            }
            catOk && matches(p, q)
        }
    }

    /** 单个条目是否命中关键词。`query` 为空恒为 true。 */
    fun matches(p: PersonaProfile, query: String): Boolean {
        val q = query.trim()
        if (q.isEmpty()) return true
        if (p.name.contains(q, ignoreCase = true)) return true
        if (p.description?.contains(q, ignoreCase = true) == true) return true
        if (p.tags.any { it.contains(q, ignoreCase = true) }) return true
        return p.body.contains(q, ignoreCase = true)
    }

    /**
     * 综合分。规则写死在这里，就是为了能被断言：
     * 一次套用值 3 分，内置预设额外 2 分 —— 也就是「用了一次的自建专家」
     * 会和「从没被用过的内置预设」打平、再用一次就反超。
     */
    fun score(p: PersonaProfile): Int = p.usedCount.coerceAtLeast(0) * 3 + if (p.builtin) 2 else 0

    /** 排序。三种模式的主键不同，**副键统一**（最近编辑 → 名字），保证结果确定可比。 */
    fun sort(items: List<PersonaProfile>, mode: ExpertSort = ExpertSort.COMPREHENSIVE): List<PersonaProfile> {
        val byName = compareBy<PersonaProfile> { it.name }
        val byRecent = compareByDescending<PersonaProfile> { it.updatedAt }
        val byUsage = compareByDescending<PersonaProfile> { it.usedCount }
        val byScore = compareByDescending<PersonaProfile> { score(it) }
        return items.sortedWith(
            when (mode) {
                ExpertSort.COMPREHENSIVE -> byScore.then(byRecent).then(byName)
                ExpertSort.HOTTEST -> byUsage.then(byRecent).then(byName)
                ExpertSort.NEWEST -> byRecent.then(byUsage).then(byName)
            }
        )
    }

    /** 界面用的组合动作：先筛后排。分开调用两次也行，但界面上永远是这个顺序。 */
    fun browse(
        items: List<PersonaProfile>,
        category: String? = null,
        query: String = "",
        mode: ExpertSort = ExpertSort.COMPREHENSIVE
    ): List<PersonaProfile> = sort(filter(items, category, query), mode)
}

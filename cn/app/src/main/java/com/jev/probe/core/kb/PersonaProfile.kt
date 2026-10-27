package com.jev.probe.core.kb

/**
 * 纯数据层：**不 import android.***。
 *
 * 从 `PersonaStore.kt` 里拆出来的理由是 S5 的复用目标：`global/` 那个工程
 * （出海版）也要有「专家」这个概念，而 `PersonaStore` 本体绑定在
 * `Context` / `filesDir` 上，搬不过去。把 [PersonaProfile] 单独放一个文件，
 * 它就能被两边同时 import —— 数据形状一份，存取实现各写各的。
 *
 * 这条约束靠 CI 的一行检查兜着：这个文件里不许出现 `import android.`。
 */

/**
 * 一条**有名字的人设** —— 也就是专家库里的一个「专家」。
 *
 * 和 [PersonaCard] 的分工：卡是「这一份人设被怎么理解」（解析结果，不可持久化），
 * 这里是人设**本身**（用户写下的那段原文 + 它的名字 + 浏览层信息）。一份人设可以
 * 被改名、复制、导出、删掉，卡不会跟着存 —— 卡每次都由 [body] 现算。
 *
 * ## 两组字段，一条铁律
 *
 * - **行为层**：[body]。它是唯一进 `promptText()` 的东西，因为它就是卡的全部输入。
 * - **浏览层**：[name]、[avatar]、[description]、[tags]、[category]、[usedCount]、
 *   [presetKey]、[skillRefs]、[appPkgs]。这些只被界面、检索、排序、装配读，
 *   **一个字节都不进提示词**。铁律的理由很具体：如果简介混进提示词，用户改一句
 *   简介就会改变回复风格，而这件事没有任何报错可查。
 *
 *   例外只有一处：[body] 里如果写了「主题：网调」，那是用户**在正文里**声明的，
 *   照旧进提示词 —— 那是他写的人设内容，不是这里加的元数据。
 *
 * ## 新增字段为什么都带默认值
 *
 * v1 的 `personas.json` 只有 `id/name/body/updatedAt/builtin`。工程用的是
 * `org.json` 而不是 kotlinx.serialization，**反序列化不会套用 data class 的默认值**，
 * 所以兼容性靠两件事：这里的默认值（Kotlin 侧构造）+ [PersonaStore] 里显式的
 * `optXXX` 兜底（JSON 侧读取）。两者都写，v1 文件才真的能被读成 v2 对象。
 *
 * [builtin] 只标「这条来自内置预设」，用来给「恢复内置模板」判断哪些已经在了；
 * 内置条和用户自建的条**完全平等**：可以改、可以改名、可以删。模板是起点，不是枷锁。
 */
data class PersonaProfile(
    val id: String,
    val name: String,
    /**
     * 人设原文，逐字保存（含换行）。这就是 `Prefs.style` 里会出现的那些字节 ——
     * 中间不做任何规范化，否则「套用 → 保存 → 回头再套用」会悄悄变形。
     */
    val body: String,
    val updatedAt: Long = System.currentTimeMillis(),
    val builtin: Boolean = false,
    /** 浏览层：一个 emoji（专家卡左上角）。**不进提示词。** */
    val avatar: String? = null,
    /** 浏览层：卡片上那一行简介。**不进提示词。** */
    val description: String? = null,
    /** 浏览层：卡片下方的标签（2–3 个最合适）。**不进提示词。** */
    val tags: List<String> = emptyList(),
    /** 浏览层：分类抽屉。空 = 未分类。**不进提示词。** */
    val category: String? = null,
    /** 浏览层 + 排序：被套用过几次（「最热」排序的唯一数据源）。**不进提示词。** */
    val usedCount: Int = 0,
    /**
     * 内置预设的**稳定标识**（如 `daily.friend`），用户改名不变；用户自建/复制出来的为空串。
     *
     * 存在的唯一理由：`seeded[]` / `removed[]` 台账要认得出「这条是不是那张预设」。
     * 只按名字认的话，用户把「日常」改成「闲聊」之后台账就失联了 —— 下次启动会
     * 复活一份和它并排的重名副本。
     */
    val presetKey: String = "",
    /**
     * 行为层（S4 灰度）：这个专家只用这些技能。空 = 沿用全局 enabled（今天的行为）。
     * 改的是**装配**，不是文本，所以它不进提示词本身。
     */
    val skillRefs: List<String> = emptyList(),
    /** 行为层（S4 灰度）：这个专家只在这些 App 里出现。空 = 全部已适配 App。 */
    val appPkgs: List<String> = emptyList()
) {
    /** 现算的结构化卡；认不出键时退回自由文本，与手写人设完全同一套规则。 */
    fun card(): PersonaCard = PersonaCard.parse(body)

    /** 有没有可展示的简介（界面用，避免到处写 `?: ""` 判空）。 */
    val hasBlurb: Boolean get() = !description.isNullOrBlank()

    /** 分类的空值归一到「未分类」用的空串，排序/筛选都不必再判 null。 */
    val categoryOrBlank: String get() = category?.trim().orEmpty()
}

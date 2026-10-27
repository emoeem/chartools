package com.jev.probe.core.kb

/**
 * 专家 ↔ 技能 / App 的绑定规则（S4，灰度，默认关）。
 *
 * 拆成纯函数放在这里，而不是直接写进 `ContextBuilder` 的装配流程里，理由和
 * [ExpertCatalog] 一样：这段逻辑决定**哪些技能会进提示词**，也就是决定回复
 * 内容；而它一旦错，表现只是「回复风格悄悄变了」—— 没有异常、没有崩溃。
 * 纯函数才能用 JVM 单测把「开关关着 = 一个字节都不变」钉死。
 */
object ExpertBinding {

    /**
     * 允许进入本轮提示词的技能名。
     *
     * 三条规则，按顺序：
     * 1. 开关关着 → 原样返回（**这是灰度开关的意义：关闭路径与今天逐字相同**）；
     * 2. 专家没写 `skillRefs` → 原样返回（空 = 沿用全局 enabled，不是「一个都不要」）；
     * 3. 否则只留点名的那几个，且**只认真实存在的**（专家引用了已删除的技能时，
     *    静默不生效，而不是把整轮技能清空）。
     */
    fun allowedSkillNames(
        enabled: Boolean,
        refs: List<String>,
        available: List<String>
    ): List<String> {
        if (!enabled) return available
        val wanted = refs.map { it.trim() }.filter { it.isNotEmpty() }.toSet()
        if (wanted.isEmpty()) return available
        return available.filter { it in wanted }
    }

    /**
     * 专家声明的 App 只允许落在**已适配**的包里。
     *
     * 为什么要筛：`appPkgs` 是可导入的字段（别人给你的专家包可能写着任意包名），
     * 而一个没适配的包名意味着「这个专家永远不会出现」。筛掉比留着好 ——
     * 留着不会让功能变强，只会让用户以为设置没保存。
     */
    fun sanitizeAppPkgs(requested: List<String>, known: Set<String>): List<String> =
        requested.map { it.trim() }.filter { it.isNotEmpty() && it in known }.distinct()
}

package com.jev.probe.core.kb

/**
 * 设置页「人设」区那几行回显的文案。
 *
 * 为什么单独放一层：人设卡认不出键的时候是**静默**退回自由文本的 —— 用户把
 * 「主题」写成「话题方向」，界面上看不出任何差别，只有回复悄悄变回通用腔调。
 * 所以设置页必须把「我到底认出了什么、这轮会用哪些笔记」直接摊开写给人看。
 * 这段判词是产品判断（什么算识别成功、什么算没收窄），放在核心层才测得住。
 */
object PersonaStatus {

    /**
     * 一行说明卡被怎么理解。
     *
     * 三种状态各自要能一眼分开：空的 / 没认出键的（灰色警告）/ 认出键的（逐项列出来）。
     */
    fun line(card: PersonaCard): String {
        if (!card.hasContent()) return "现在是空的 —— 回复不会带任何人设，只用默认风格。"
        if (!card.structured) {
            return "⚠ 没认出任何键，只会当成一段普通文本塞进提示词：" +
                "语气也许有变化，但主题、硬边界、语域都不会生效。"
        }
        val parts = ArrayList<String>()
        if (card.address.isNotBlank()) parts.add("称呼「${card.address}」")
        if (card.relation.isNotBlank()) parts.add("关系")
        if (card.topic.isNotBlank()) parts.add("主题「${card.topic}」")
        if (card.tone.isNotBlank()) parts.add("语气")
        if (card.scene.isNotBlank()) parts.add("情境")
        if (card.registerOpen) parts.add("语域已放开")
        if (card.boundaries.isNotEmpty()) parts.add("硬边界 " + card.boundaries.joinToString("、"))
        if (card.safeword.isNotBlank()) parts.add("安全词")
        if (card.examples.isNotEmpty()) parts.add("示例 ${card.examples.size} 句")
        return "已识别：" + parts.joinToString(" · ")
    }

    /**
     * 一行说明知识库这轮取哪些笔记。
     *
     * @param scope   [TopicScope.scopeOf] 的结果。
     * @param alwaysOn 常驻笔记条数（它们不参与检索，每轮都带）。
     */
    fun scopeLine(scope: TopicScope.Scope, alwaysOn: Int): String {
        val base = when {
            scope.topic.isBlank() ->
                "知识库：${scope.total} 条参与检索（人设没写「主题」，所以不按主题收窄）"
            scope.active ->
                "知识库：主题「${scope.topic}」命中 ${scope.matched} 条，只从这 ${scope.matched} 条里挑" +
                    "（共 ${scope.total} 条）"
            else ->
                "知识库：主题「${scope.topic}」还没有笔记标过它，这轮仍按全部 ${scope.total} 条检索" +
                    "（在知识库页可以一键补标签）"
        }
        return if (alwaysOn > 0) "$base；另有 $alwaysOn 条常驻每轮都带。" else "$base。"
    }
}

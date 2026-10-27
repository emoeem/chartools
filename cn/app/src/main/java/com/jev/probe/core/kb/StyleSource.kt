package com.jev.probe.core.kb

/**
 * 「哪段正文真的进了提示词」的唯一判定处。
 *
 * 起草（`ReplyClient.draftAsk`）和复查（`ReplyClient.review`）以前各自写了一遍
 * `ctx?.contact?.persona ?: style`。两处是会漂的：谁改一处忘了另一处，复查就会
 * 拿着一张和起草不同的人设卡去判第 3、5 条标准（「有没有和已知的称呼/边界冲突」）。
 * 现在两处都走这里。
 *
 * ## 优先级不改，但要说出来
 *
 * 优先级是产品的：**联系人自己的专用人设压过 `Prefs.style`（也就是专家正文）**。
 * 这没错——用户给某个具体的人写过脾气、边界，那句话比任何模板都更懂这个人。
 *
 * 代价是：用户在专家库点了 331 位里的任何一位，只要那个聊天写过专用人设，提示词
 * 一个字节都不变，而界面上原本没有任何东西告诉他。这跟「点了用却没反应」在体感上
 * 是同一件事，所以 [Resolution.shadowed] 要被界面读出来，照着事实说话。
 *
 * ## 为什么不 trim 专家正文
 *
 * 只有联系人那句会被 `trim()`（和以前逐字一致），专家正文原样透传。目录里有正文
 * 带前导/尾随空格，trim 一下提示词就变了，而「换了风格、回复一字不差」这种回归
 * 最难查——它不是报错，是静默等价。
 */
object StyleSource {

    /** 提示词里那张人设卡的来源。 */
    enum class From {
        /** 两边都空：没有人设，提示词里不带这一段。 */
        NONE,

        /** 用的是 [com.jev.probe.core.Prefs.style]，也就是当前生效的专家正文。 */
        EXPERT,

        /** 用的是这个聊天的联系人专用人设。 */
        CONTACT
    }

    data class Resolution(
        /** 真正进提示词的文本。专家正文原样（不 trim），联系人那句已 trim。 */
        val text: String,
        val from: From,
        /** 被联系人专用人设盖住的专家正文；没被盖住时为空串。 */
        val shadowedExpert: String = ""
    ) {
        /** 用户点过专家，但这个聊天里它没生效。界面用它决定要不要多讲一句。 */
        val shadowed: Boolean get() = from == From.CONTACT && shadowedExpert.isNotBlank()
    }

    /**
     * @param expert 当前生效的原文（`Prefs.style`）
     * @param contactPersona 这个聊天的联系人专用人设，可空
     */
    fun resolve(expert: String, contactPersona: String?): Resolution {
        val fromContact = contactPersona?.trim()?.takeUnless { it.isBlank() }
        if (fromContact != null) return Resolution(fromContact, From.CONTACT, expert)
        // 空串也原样返回：以前 `?: style` 就是这个行为，换成 "" 会让一个
        // 只有空白的 style 从「原样进 PersonaCard」变成「空」，属于没人要求的变化。
        return Resolution(expert, if (expert.isEmpty()) From.NONE else From.EXPERT)
    }
}

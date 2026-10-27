package com.jev.probe.ui

import com.jev.probe.core.kb.PersonaProfile

/**
 * 专家卡上要显示的**那几个字**，从 [PersonaProfile] 算出来。
 *
 * 为什么单独一个纯数据类、而不是直接在 Adapter 里 `p.name` / `p.description`
 * 拼字符串：卡面文案是**用户唯一看得见的东西**，而它最容易悄悄坏 ——
 * 「简介为空」时卡片会不会变成一片空白、「正文第一行是 `称呼：小明`」时会不会
 * 把键名当简介贴上去、「用过 0 次」会不会显示成「用过 0 次」这种噪音。
 * 这些都能用 JVM 单测钉住，不需要 Robolectric、不需要真机。
 *
 * 这个文件**不 import android.***：S5 要把它搬进纯 Kotlin 层给 `global/` 复用。
 */
data class ExpertCard(
    val id: String,
    val name: String,
    /** 一个 emoji；用户没设时用 [FALLBACK_AVATAR]。 */
    val avatar: String,
    /** 一行简介：有 description 用它，否则拿正文第一行。 */
    val blurb: String,
    /** 卡面最多 [MAX_TAGS] 个。 */
    val tags: List<String>,
    /** 「用过 3 次」/「未使用」。 */
    val usage: String,
    /** 空串 = 未分类。 */
    val category: String,
    val builtin: Boolean
) {
    val hasTags: Boolean get() = tags.isNotEmpty()

    companion object {
        /** 没设头像时的占位。用 emoji 而不是图片资源：没有图片加载库，也不想为这个加依赖。 */
        const val FALLBACK_AVATAR: String = "🧩"

        const val MAX_TAGS: Int = 3

        /** 卡片两行文本的宽度上限（按字符数粗算，中文一个字一格）。 */
        const val MAX_BLURB: Int = 46

        fun of(p: PersonaProfile): ExpertCard = ExpertCard(
            id = p.id,
            name = p.name,
            avatar = p.avatar?.trim()?.takeIf { it.isNotEmpty() } ?: FALLBACK_AVATAR,
            blurb = blurbOf(p),
            tags = p.tags.map { it.trim() }.filter { it.isNotEmpty() }.take(MAX_TAGS),
            usage = usageOf(p.usedCount),
            category = p.categoryOrBlank,
            builtin = p.builtin
        )

        /**
         * 简介：用户写了就用用户的；没写就拿正文第一行，并**剥掉键名**
         * （`称呼：小明` → `小明`）—— 卡面上冒出「称呼：」三个字是噪音，
         * 而在正文里它是必要的键。
         */
        fun blurbOf(p: PersonaProfile): String {
            val given = p.description?.trim()
            if (!given.isNullOrEmpty()) return clip(given)
            val firstLine = p.body.lineSequence()
                .map { it.trim() }
                .firstOrNull { it.isNotEmpty() }
                .orEmpty()
            return clip(stripKey(firstLine))
        }

        private fun stripKey(line: String): String {
            val sep = line.indexOfFirst { it == '：' || it == ':' }
            // 只在「键名很短」时剥：一行正常的散文里也可能有冒号，剥了就把句子砍成两半。
            if (sep in 1..4) return line.substring(sep + 1).trim()
            return line
        }

        private fun clip(s: String): String =
            if (s.length <= MAX_BLURB) s else s.take(MAX_BLURB - 1) + "…"

        fun usageOf(used: Int): String =
            if (used <= 0) "未使用" else "用过 ${used} 次"
    }
}

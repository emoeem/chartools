package com.jev.probe.core

/**
 * 候选回复的推进档位 —— 分析卡上的一排档位，以及「自动」档根据判断结果的映射。
 *
 * 三档的语义不是"热情程度"，而是候选策略的倾向：收着 ≈ safe（承接确认、不推进），
 * 自然 = 默认三策略不动，加码 ≈ forward（表达感受、发出具体邀请、推进话题）。
 * 起草的 strategy 契约（safe/forward/angle 各一条）不变，档位只调整语气指引与
 * 策略侧重 —— 排序和解析层不用动。
 *
 * 「自动」档的映射全部来自判断层已有输出（[Analysis]），没有新感知能力：
 * 局势偏紧、对方在发泄情绪、此刻不适合给实质 → 收着；双方约好的角色场景且
 * 局势轻松 → 加码；其余 → 自然。宁可保守：自动档错的方向如果是
 * "该收的时候加码"，伤害最大。
 */
enum class Intensity {
    AUTO, SOFT, NATURAL, FORWARD;

    val label: String
        get() = when (this) {
            AUTO -> "自动"
            SOFT -> "收着"
            NATURAL -> "自然"
            FORWARD -> "加码"
        }

    companion object {

        fun from(name: String?): Intensity =
            entries.firstOrNull { it.name == name } ?: AUTO

        /**
         * 「自动」档的判断结果 → 档位映射。判断为 null（会话第一轮、或起草
         * 没等到判断）时退回自然 —— 没有证据就不偏移默认行为。
         */
        fun auto(judgment: Analysis?): Intensity {
            val a = judgment ?: return NATURAL
            val lvl = a.dangerLevel?.score
            if (lvl != null && lvl >= 6) return SOFT
            if (a.trueIntent?.choice == "vent_anger") return SOFT
            a.shouldReplyNow?.let { if (it < 0.5) return SOFT }
            if (a.trueIntent?.choice == "intimate_roleplay" && (lvl == null || lvl <= 3)) return FORWARD
            return NATURAL
        }
    }
}

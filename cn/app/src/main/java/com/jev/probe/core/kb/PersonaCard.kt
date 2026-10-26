package com.jev.probe.core.kb

/**
 * A persona note ([Contact.persona], or the global `Prefs.style` fallback),
 * optionally written as a small key/value card:
 *
 * ```
 * 称呼：先生
 * 关系：主奴
 * 语气：克制、短句，不解释
 * 语域：亲密
 * 硬边界：不要提家人、不要留痕
 * 避谈：稳赚
 * 安全词：红灯
 * 示例：
 * 我：今天想你了
 * 对方：嗯，等着
 * ```
 *
 * Why a card rather than free text: the reply prompt's register bans (no
 * role-play lines, no 「主人」/「爸爸」/「殿下」) exist because an unbanned drafter
 * once answered a flirting thread with "主人不要伤害我？" — see
 * [com.jev.probe.jev.ReplyPrompt]. Those bans must not be liftable by accident,
 * so they go away ONLY when this card carries an explicit `语域`/`register` key
 * that asks for it. Everything the card writes down is also the source of truth
 * for [com.jev.probe.core.safety.SafetyGate]'s hard limits.
 *
 * Backwards compatible by construction: text with no recognised key parses to
 * `structured = false` and [promptText] returns it verbatim — byte-for-byte what
 * the app sent before cards existed.
 *
 * The field set follows the parts of the Character Card V2 spec that map onto
 * this app (description / personality / scenario / example dialogue / boundary
 * instructions). `{{user}}` / `{{char}}` example lines are accepted so a card
 * copied from that ecosystem parses.
 */
data class PersonaCard(
    /** Kept verbatim, so a free-form note round-trips unchanged. */
    val raw: String = "",
    val address: String = "",
    val relation: String = "",
    val tone: String = "",
    val scene: String = "",
    /**
     * 这几段对话在聊什么（「主题：网调」）。
     *
     * 和 [scene] 分开是因为两者要治的病不一样：`情境` 说的是「此刻在什么场合」，
     * `主题` 说的是「这件事整体属于哪一类」。用户的原话是「我现在网调，就需要回复
     * 的内容和网调有关」—— 他缺的正是后者：模型知道对方是谁、语气多克制，但仍然
     * 可能给出一段跟网调无关的通用安慰。`主题` 会逐字进提示词，用来把回复钉在这个
     * 领域上。
     */
    val topic: String = "",
    /** Hard limits, already split and expanded — see [splitBoundaries]. */
    val boundaries: List<String> = emptyList(),
    /**
     * 避谈词：**不许出现在我的回复里**，但和 [boundaries] 是两种东西——
     * 硬边界是「对方一提就停整轮」（SafetyGate 逐字拦对方的消息），避谈只是
     * 约束我方措辞（比如销售的「稳赚」「保证收益」：客户问「能稳赚吗」要照常
     * 回应，只是不许替用户许下这个承诺）。混在一个键里时，避谈词会被当成
     * 硬边界去拦对方——恰好在最需要回复的一轮把候选掐掉。
     */
    val avoid: List<String> = emptyList(),
    val safeword: String = "",
    /**
     * 交通灯里的黄灯：对方打出时要**减速确认**，不是停止——红灯仍然只归
     * [safeword]。2026-10-07 实测聊天记录里对方真实使用了「黄灯哦」，而
     * 「安全词：红灯停、黄灯缓」这种旧写法会把黄灯也当成硬拦截词。
     */
    val yellow: String = "",
    val examples: List<String> = emptyList(),
    val extra: List<String> = emptyList(),
    /**
     * An explicit opt-in to the register the default prompt bans. False for a
     * free-form note: free text may never open it, only a recognised key.
     */
    val registerOpen: Boolean = false,
    /** False for free text: nothing was recognised, so nothing may be lifted. */
    val structured: Boolean = false
) {

    /**
     * What the drafting prompt is handed as the user's persona. Free text comes
     * back verbatim; a card comes back as a delimited block so the model can tell
     * the fields apart.
     */
    fun promptText(): String {
        if (!structured) return raw.trim()
        val sb = StringBuilder("<persona_card>\n")
        if (address.isNotBlank()) sb.append("称呼：").append(address).append('\n')
        if (relation.isNotBlank()) sb.append("关系：").append(relation).append('\n')
        if (tone.isNotBlank()) sb.append("语气：").append(tone).append('\n')
        if (topic.isNotBlank()) {
            sb.append("主题：").append(topic)
                .append("（这段对话整体就在这个领域里：回复要具体到这个语境的规矩、步骤和说法，"
                        + "不要给脱离语境的通用安慰或说明书式的建议）\n")
        }
        if (scene.isNotBlank()) sb.append("情境：").append(scene).append('\n')
        if (registerOpen) sb.append("语域：已按人设卡放开（可在本卡约定范围内使用角色化称呼与描写）\n")
        if (boundaries.isNotEmpty()) {
            sb.append("硬边界（这些内容绝不可以出现在回复里）：")
                .append(boundaries.joinToString("、")).append('\n')
        }
        if (avoid.isNotEmpty()) {
            sb.append("避谈（这些词不要出现在我的回复里，也不许换种说法向对方许诺；")
                .append("对方主动提到时照常回应这件事，只是不替对方展开、不顺着写）：")
                .append(avoid.joinToString("、")).append('\n')
        }
        if (safeword.isNotBlank()) sb.append("安全词：").append(safeword).append('\n')
        if (yellow.isNotBlank()) {
            sb.append("黄灯：").append(yellow)
                .append("（对方打出黄灯时这一轮要先减速确认：接住对方、降低强度、确认状态和边界，")
                .append("不要加码或开启新动作；黄灯不是停止，停止只归安全词）\n")
        }
        if (examples.isNotEmpty()) {
            sb.append("示例（这是我本人真实的说话风格，只学语气和称呼，不是当前对话内容）：\n")
            examples.forEach { sb.append(it).append('\n') }
        }
        if (extra.isNotEmpty()) sb.append("补充：").append(extra.joinToString("；")).append('\n')
        sb.append("</persona_card>")
        return sb.toString()
    }

    /** True when the card carries anything a draft could act on. */
    fun hasContent(): Boolean = structured || raw.isNotBlank()

    companion object {

        /**
         * Recognised keys, normalised (case-folded, `-`/`_`/spaces removed). Both
         * Chinese and English spellings so a Card V2-style note works unchanged.
         */
        private val KEY_ALIASES: Map<String, String> = listOf(
            "address" to listOf("称呼", "称谓", "address", "title"),
            "relation" to listOf("关系", "身份", "relation", "relationship", "role"),
            "tone" to listOf("语气", "口吻", "风格", "tone", "style"),
            "scene" to listOf("情境", "场景", "设定", "scene", "scenario", "setting"),
            "topic" to listOf("主题", "领域", "话题", "topic", "domain", "subject"),
            "boundaries" to listOf("边界", "硬边界", "底线", "禁忌", "limits", "hardlimits", "limit"),
            "avoid" to listOf("避谈", "回避", "avoid"),
            "safeword" to listOf("安全词", "safeword"),
            "yellow" to listOf("黄灯", "yellow"),
            "extra" to listOf("补充", "其他", "备注", "extra", "note", "notes"),
            // Not a value: the example dialogue is picked up by line prefix below.
            // Listing it here only stops a bare 「示例：」 header from ending up in 补充.
            "examples" to listOf("示例", "例子", "example", "examples"),
            "register" to listOf("语域", "模式", "register", "mode")
        ).flatMap { (field, keys) -> keys.map { norm(it) to field } }.toMap()

        /** A boundary phrase is stripped of these to get a matchable keyword. */
        // "不" sits last on purpose: alternation is tried left to right, so writing
        // it first would strip the "不" off "不要提家人" and leave "要提家人".
        // With it last, the bare negations users actually write ("不提家人",
        // "不聊前任") still reduce to the word the gate has to match.
        private val BOUNDARY_PREFIX = Regex("^(不要|不准|不能|禁止|不许|不想|不接受|别|不)")
        private val BOUNDARY_VERB = Regex("^(叫我|喊我|说|提|碰|发|让|聊|做)")

        private val REGISTER_OFF = listOf("不开", "关闭", "禁用", "关掉", "默认", "off")
        private val REGISTER_ON =
            listOf("亲密", "角色", "扮演", "roleplay", "intimate", "bdsm", "调教", "文爱", "开放", "开启")

        private val EXAMPLE_PREFIX = listOf("我：", "我:", "对方：", "对方:", "他：", "他:", "她：", "她:", "{{user}}", "{{char}}")

        /**
         * Never throws and never returns null: a note that cannot be understood is
         * a free-form note, which is the pre-card behaviour.
         */
        fun parse(raw: String?): PersonaCard {
            val text = raw.orEmpty().replace("\r\n", "\n").replace('\r', '\n')
            if (text.isBlank()) return PersonaCard(raw = text)

            val scalars = HashMap<String, String>()
            val boundaries = ArrayList<String>()
            val avoid = ArrayList<String>()
            val examples = ArrayList<String>()
            val extra = ArrayList<String>()

            for (line in text.split('\n')) {
                val t = line.trim()
                if (t.isEmpty() || t == "---") continue
                if (EXAMPLE_PREFIX.any { t.startsWith(it) }) {
                    examples += t
                    continue
                }
                val cut = splitKeyValue(t)
                if (cut == null) {
                    extra += t
                    continue
                }
                val field = KEY_ALIASES[norm(cut.first)]
                if (field == null) {
                    extra += t
                    continue
                }
                val value = cut.second.trim()
                when (field) {
                    "boundaries" -> boundaries += splitBoundaries(value)
                    "avoid" -> avoid += splitBoundaries(value)
                    "register" -> scalars[field] = value
                    "examples" -> Unit
                    else -> scalars[field] =
                        if (scalars[field].isNullOrBlank()) value else scalars[field] + " " + value
                }
            }

            // A recognised *key* is what makes this a card. Example lines alone are
            // not enough, or a free-form note that happens to contain "我：..." would
            // silently change shape.
            val structured = scalars.isNotEmpty() || boundaries.isNotEmpty() || avoid.isNotEmpty()
            if (!structured) return PersonaCard(raw = text)

            return PersonaCard(
                raw = text,
                address = scalars["address"].orEmpty(),
                relation = scalars["relation"].orEmpty(),
                tone = scalars["tone"].orEmpty(),
                topic = scalars["topic"].orEmpty(),
                scene = scalars["scene"].orEmpty(),
                boundaries = boundaries,
                avoid = avoid,
                safeword = scalars["safeword"].orEmpty(),
                yellow = scalars["yellow"].orEmpty(),
                examples = examples,
                extra = extra,
                registerOpen = registerOpen(scalars["register"].orEmpty()),
                structured = true
            )
        }

        /** `称呼：先生` / `address: sir` — a key must be short and at the line start. */
        private fun splitKeyValue(line: String): Pair<String, String>? {
            val cn = line.indexOf('：')
            val en = line.indexOf(':')
            val at = when {
                cn < 0 -> en
                en < 0 -> cn
                else -> minOf(cn, en)
            }
            if (at <= 0 || at > 12) return null
            val key = line.substring(0, at).trim()
            if (key.isEmpty() || key.any { it == ' ' && key.length > 6 }) return null
            return key to line.substring(at + 1)
        }

        /** Splits a limits line, then expands each phrase down to its keyword. */
        private fun splitBoundaries(value: String): List<String> {
            if (value.isBlank()) return emptyList()
            val out = LinkedHashSet<String>()
            value.split('、', ',', '，', ';', '；', '/', '|', ' ', '\n').forEach { part ->
                val t = part.trim()
                if (t.length < 2) return@forEach
                out += t
                var v = t
                BOUNDARY_PREFIX.find(v)?.let { v = v.removePrefix(it.value); if (v.length >= 2) out += v }
                BOUNDARY_VERB.find(v)?.let { v = v.removePrefix(it.value); if (v.length >= 2) out += v }
            }
            return out.toList()
        }

        /**
         * The explicit switch. Negatives are checked first because Chinese "不开"
         * contains the "开" that would otherwise read as a yes.
         */
        private fun registerOpen(value: String): Boolean {
            val s = value.trim().lowercase()
            if (s.isEmpty()) return false
            if (REGISTER_OFF.any { s.contains(it) }) return false
            if (s == "开" || s == "on" || s == "yes" || s == "true") return true
            return REGISTER_ON.any { s.contains(it) }
        }

        private fun norm(key: String): String =
            key.trim().lowercase().replace("-", "").replace("_", "").replace(" ", "")
    }
}

package com.jev.probe.jev

import com.jev.probe.core.Analysis
import com.jev.probe.core.Intensity
import com.jev.probe.core.kb.ChatContext
import com.jev.probe.core.kb.NOTE_TYPE_STYLE_SAMPLE
import com.jev.probe.core.kb.PersonaCard
import com.jev.probe.core.kb.effectiveRelationship

/**
 * The two prompt blocks that carry knowledge into a reply, pulled out of
 * [ReplyClient] so they are plain string assembly over [ChatContext] — no
 * `Prefs`, no `Context`, no network — and can be asserted in a JVM test.
 *
 * This is the last mile of the Agent Skills layering: the L1 catalogue rides on
 * the system prompt of every round, and an L2 body is quoted here only when the
 * round actually matched that skill.
 */
internal object ReplyPrompt {

    /**
     * A matched skill body is quoted up to this many characters. The
     * specification asks for bodies under ~5k tokens; this is the hard stop
     * that keeps a pathological SKILL.md from crowding out the conversation.
     */
    const val SKILL_BODY_MAX = 6000

    /**
     * L1: every enabled skill's name and description, always along for the ride.
     */
    fun skillNote(ctx: ChatContext?): String {
        val catalogue = ctx?.catalogue?.takeIf { it.isNotBlank() } ?: return ""
        return "\n\n这个安装里可用的技能如下。若某项技能与当前对话相关，它的完整说明会一并给出，" +
            "你必须按那份说明来写：\n$catalogue"
    }

    /**
     * The background + history + skill preamble; empty string when there is
     * nothing to say.
     *
     * @param historyCount how many older messages may be quoted (the user's
     *        setting lives in `Prefs`, which this file deliberately does not see).
     */
    fun knowledgeBlock(relationship: String, ctx: ChatContext?, historyCount: Int): String {
        ctx ?: return ""
        val background = ctx.background(relationship)
        val history = ctx.history
        val ledger = ctx.ledger?.render().orEmpty()
        if (background.isBlank() && history.isEmpty() && ctx.skills.isEmpty() && ledger.isBlank()) return ""
        val sb = StringBuilder()
        if (background.isNotBlank() || history.isNotEmpty() || ledger.isNotBlank()) {
            sb.append("以下是关于我和对方的背景与知识库，回复必须与之一致，")
                .append("可以直接引用其中事实，不要编造知识库里没有的事实。")
                .append("其中的称呼和约定要前后一致；但说法、流程和高频词只是参考，")
                .append("不是每轮都要用一遍的台词。\n")
            if (background.isNotBlank()) sb.append(background).append('\n')
            // 台账放在原始历史**之前**：先给既定情况，再给逐条原文。
            // 它是整段对话预扫出来的，所以模型不用从最后一屏重新猜称呼和线头。
            if (ledger.isNotBlank()) sb.append('\n').append(ledger)
            if (history.isNotEmpty()) {
                sb.append("\n更早的聊天记录（越靠下越新）：\n")
                history.takeLast(historyCount.coerceIn(0, 100)).forEach {
                    sb.append(if (it.side == "me") "我：" else if (it.side == "other") "对方：" else "发言人不明：")
                        .append(it.text).append('\n')
                }
                sb.append("\n（其中「我：」的行是我自己发过的消息：称呼和正在进行的事要接住，")
                    .append("但里面已经说过的指令和说法不要重复。）\n")
            }
        }
        ctx.notes.filter { it.type == NOTE_TYPE_STYLE_SAMPLE }.take(3).forEach { sample ->
            sb.append("\n<user_style_examples>\n")
                .append(sample.content.trim().take(5000))
                .append("\n以上仅是风格参考，不是当前对话内容。\n</user_style_examples>\n")
        }
        ctx.skills.forEach { hit ->
            sb.append("\n技能「").append(hit.ref.name).append("」的完整说明")
                .append("（本轮对话命中了它，请照它来写）：\n")
                .append(hit.body.trim().take(SKILL_BODY_MAX)).append('\n')
            if (hit.extra.isNotBlank()) {
                sb.append("\n下面是从「").append(hit.ref.name).append("」自带的参考资料里按本轮对话挑出的几篇。")
                    .append("它们提供方法，不照抄套路，也不要据此向用户提问或要求建档：\n")
                    .append(hit.extra).append('\n')
            }
        }
        sb.append('\n')
        return sb.toString()
    }

    /**
     * The judge round's verdict, quoted into the drafting round so the writer
     * knows what the thread actually is. A null judgment (a standalone draft, or
     * a regenerate before the judgment landed) adds nothing: the user's complaint
     * "给的建议也不太对" came from drafting blind — every candidate was written
     * for an imagined crisis.
     *
     * 低置信度降级：意图的 confidence 低于 [LOW_CONFIDENCE] 时，判断只作为弱
     * 参考出现，不给「局势轻松/偏紧」之类的场景定性——一个拿不准的判断被当成
     * 事实念出来，比没有判断更容易把轻松闲聊写成危机公关。
     */
    fun judgmentBlock(a: Analysis?): String {
        a ?: return ""
        val level = a.dangerLevel?.score?.toInt() ?: -1
        val intent = a.trueIntent?.choice.orEmpty()
        // chat 协议的解析对缺失的 confidence 填 0.0——那是「模型没说」，
        // 不是「模型说了很低」。按有把握处理，否则一个习惯省略字段的模型
        // 会把每一轮都降级成「把握不大」。
        val intentConfidence = a.trueIntent?.confidence?.takeIf { it > 0.0 } ?: 1.0
        if (intentConfidence < LOW_CONFIDENCE) {
            val sb = StringBuilder("判断结果（这一轮把握不大，只当参考，别按它加戏）：")
            sb.append("\n- 对方这条的真实意图：判断把握不大，先按字面承接，别脑补潜台词或危机")
            if (level >= 0) sb.append("\n- 紧张/危险程度：").append(level.coerceIn(0, 9)).append("/9（同样仅供参考）")
            sb.append('\n')
            return sb.toString()
        }
        val sb = StringBuilder("判断结果（先按它读局势，再写回复）：")
        sb.append("\n- 对方这条的真实意图：").append(intentText(intent))
        if (level >= 0) sb.append("\n- 紧张/危险程度：").append(level.coerceIn(0, 9)).append("/9")
        sb.append("\n- 对方此刻需要的是：").append(needText(a.sheNeeds?.choice.orEmpty()))
        sb.append("\n- 现在最该做的是：").append(actionText(a.bestAction?.choice.orEmpty()))
        a.shouldReplyNow?.let { if (it < 0.5) sb.append("\n- 判断结果认为：现在可以不急着回，或换个方式回应") }
        sb.append('\n')
        if (intent == "intimate_roleplay" && level < 6) {
            sb.append("- 这一场是双方已经约好的角色或亲密互动，不是日常闲聊：接着对方刚给的情境往下写，")
                .append("用联系人设定里的称呼和语气，可以具体、可以带动作和场景描写；")
                .append("不要转成日常寒暄、不要讲道理、不要突然道歉，也不要越过设定里写明的边界。\n")
            sb.append("- 「往下写」是指让这一场往前走一步：回应对方刚说的或刚做的，给出新的具体内容，")
                .append("不是再发一遍指令。同一个指令（跪好、报数、请安这类）一整场只说一次，")
                .append("对方已经在做或做完了的动作不要再命令一遍；")
                .append("对方回答了你的问题就接住那个回答继续，不要跳回新一轮的请示或报数。\n")
            sb.append("- 但对方最近这条如果只是敷衍的一个字（「哦」「嗯」「嗯哪」这类），就不是")
                .append("「接着往下写」的信号：先停下来确认对方怎么了，别再加码。\n")
        } else if (level >= 6) {
            sb.append("- 局势偏紧：先接住情绪、认下具体的事，不要辩解、不要反讽、不要开玩笑。\n")
        } else if (level in 0..2 && intent == "casual_chat") {
            sb.append("- 局势轻松：保持同等轻松的语气，短句就好，不要沉重、不要突然深情、不要道歉。\n")
        }
        sb.append('\n')
        return sb.toString()
    }

    /**
     * 本轮推进档位块（用户在分析卡上选的档位，或「自动」档根据判断结果的映射）。
     *
     * 档位块只在解析结果不是「自然」时才生成：自然就是默认行为，多一句会让
     * 每个默认轮次的提示词都变——所以「自动 + 自然」时返回空串，提示词与没有
     * 这个功能之前逐字节一致。用户手选「加码」但自动判断偏冷时，块内带一句
     * 风险提醒：仍按用户的选择写，但第一条留作承接——不推翻用户，也不装作
     * 没看见信号。
     */
    fun intensityBlock(mode: Intensity, judgment: Analysis?): String {
        val resolved = if (mode == Intensity.AUTO) Intensity.auto(judgment) else mode
        if (resolved == Intensity.NATURAL) return ""
        val sb = StringBuilder("本轮推进档位：").append(resolved.label)
        if (mode == Intensity.AUTO) sb.append("（自动档根据判断结果选定）")
        sb.append("。")
        sb.append(
            when (resolved) {
                Intensity.SOFT ->
                    "以稳妥承接为主：先接住对方刚说的，确认状态或认可感受；" +
                        "不要主动开新话题、不要发出邀约或推进请求、不要加码。"
                Intensity.FORWARD ->
                    "优先给能推进的话：表达感受、发出具体的邀请或推进话题；" +
                        "可以保留一条承接，但至少两条要往前走。"
                else -> ""
            }
        )
        if (mode == Intensity.FORWARD && Intensity.auto(judgment) == Intensity.SOFT) {
            sb.append("注意：对方当前信号偏冷（局势偏紧，或不适合给实质），这时加码有风险——" +
                "仍按这个选择写，但把第一条留作承接。")
        }
        return sb.append('\n').toString()
    }

    /**
     * The user's own tone/persona note, quoted verbatim when set. Lives here
     * rather than in [ReplyClient] so the layering can be asserted.
     *
     * The note sits above the built-in defaults but *below* the bans: a note
     * asking for a playful register must not get role-play lines back. Only the
     * explicit `语域` key of a [com.jev.probe.core.kb.PersonaCard] lifts that, and
     * when it does the wording changes too — the model must not be told a limit
     * is in force when it has just been opened.
     */
    fun styleBlock(style: String, registerOpen: Boolean = false): String {
        val s = style.trim()
        if (s.isEmpty()) return ""
        val lead = if (registerOpen)
            "我的人设卡（比上面的默认风格优先；语域限制已按它放开，安全红线仍然有效）："
        else
            "我想要的语气和人设（比上面的默认风格优先，但硬性禁止仍然有效）："
        return "${lead}\n${s}\n\n"
    }

    /**
     * A soft caution from [com.jev.probe.core.safety.SafetyGate]: the round still
     * drafts, but something in the other side's message deserves care. Blocking
     * instead would be wrong here — refusing to help over an ambiguous word is
     * worse than writing a reply that does not lean into it.
     */
    fun cautionBlock(caution: String): String {
        val c = caution.trim()
        if (c.isEmpty()) return ""
        return "注意（这条消息里有需要留神的信号）：${c}。仍按人设卡写，但不要顺着这些方向推。\n\n"
    }

    /**
     * The drafting system prompt. It lives here rather than in [ReplyClient] so
     * the bans can be asserted: the previous version ordered one candidate to be
     * "简短低姿态", and a partner-relationship thread about flirting came back
     * with a grovelling role-play line ("主人不要伤害我？") — the model did
     * exactly what that instruction asked for.
     *
     * [intensity] 是档位的最终生效值（[Intensity.resolve] 的结果），只影响
     * 策略契约这一句；默认 NATURAL 时 n≥3 的契约逐字与档位功能之前一致
     * （见 `theDefaultRoundKeepsThePromptUnchanged` 的兼容锁）。
     */
    fun systemPrompt(
        n: Int,
        language: String = "follow",
        length: String = "standard",
        registerOpen: Boolean = false,
        intensity: Intensity = Intensity.NATURAL
    ): String =
        "你是即时通讯回复助手，替用户起草能直接发出去的聊天回复。" +
            "只输出一个 JSON 数组，含且仅含 $n 个对象；每个对象必须有 strategy 和 text 两个字段。" +
            strategyRule(n, intensity) +
            "语气必须贴住这段对话真实的氛围和两人的亲密程度：对方在玩笑或打趣就轻松接住，不要突然煽情；" +
            "对方在生气或施压就认真承接，不要插科打诨；对方只是日常闲聊就别上纲上线、别长篇大论。" +
            "每条都必须直接回应对方最近一条消息，不要答非所问。" +
            "对方只回一个字或明显敷衍时（「哦」「嗯」「嗯哪」「呵呵」「啊」「呃」这类），" +
                "不要顺着上一轮继续加码，也不要重复追问同一个问题：先把话头递回去，" +
                "确认对方现在是什么状态（怎么了 / 在想什么 / 还想不想继续），一句就够。" +
            "各条的句式和节奏要彼此不同，不要像同一个模子刻出来的；" +
                "像真人随手打字：不要连环下命令，不要每条都套「命令＋规矩＋下一步」的固定结构，" +
                "也不要把对方刚说过的话原样扔回去纠正。" +
            "输出前自检：哪一条读起来像模板、复读或客服腔，先改掉再输出。" +
            safetyBans() +
            registerBans(registerOpen) +
            languageRule(language) +
            lengthRule(length) +
            "口语、自然、像真人在聊天软件里发消息。不要解释，直接输出 JSON 数组。"

    /**
     * 候选的策略契约。三条规矩：
     *  - n=1 永远只有 safe；
     *  - n=2 只点名两条策略——旧契约无条件要求三种策略「各一个」，两条候选在
     *    算术上就不可满足，模型只能硬凑出第三种或者忽略数量；
     *  - 收着档不强迫推进：旧契约要求一条「forward（推进话题）」，而同一份
     *    提示词的档位块又说「不要邀约、不要加码」——自相矛盾的指令是怪腔的
     *    直接来源之一。收着轮把 forward 重定义为温和确认，标签不变（下游
     *    normalize / 排序 / 卡片标签都认这三个键）。
     * n≥3 且非收着时逐字保留旧句：自动档解析为「自然」的默认轮次，提示词要
     * 和档位功能之前逐字节一致。
     */
    private fun strategyRule(n: Int, intensity: Intensity): String = when {
        n <= 1 -> "strategy 固定为 safe，给出最自然、最贴合当下氛围的一条。"
        intensity == Intensity.SOFT ->
            "策略必须固定且按顺序为：safe（稳妥承接）、" +
                "forward（这一轮不推进，只做温和确认：确认状态、接住情绪、给一句稳住的话，不邀约、不加码）" +
                (if (n >= 3) "、angle（换角度：从对方话里另一个具体的点接话，同样不推进）" else "") +
                "；每种策略恰好一个对象，不能用随机采样制造差异。"
        n >= 3 -> "策略必须固定且按顺序为：safe（稳妥承接）、forward（推进话题）、angle（换角度）；每种策略恰好一个对象，不能用随机采样制造差异。"
        else -> "策略必须固定且按顺序为：safe（稳妥承接）、forward（推进话题）；每种策略恰好一个对象，不能用随机采样制造差异。"
    }

    /**
     * The user half of a draft round, assembled in one place: knowledge first,
     * then the judgment, then the intensity directive, then the safety caution,
     * then the persona card, then the conversation and the ask.
     *
     * Order is the point. The judgment block tells the model which scene this is;
     * the intensity block is an interpretation of that judgment (收着/自然/加码),
     * so it sits right after; the caution block comes after it so a "watch out
     * for this" note cannot be buried; the card comes last of the
     * instruction-like blocks so the user's own wording wins over the generic
     * style rules, while the system prompt's bans still sit above everything.
     *
     * Pure on purpose — no `Prefs`, no network — so the layering is asserted by
     * [ReplyPromptTest] rather than only by reading [com.jev.probe.jev.ReplyClient].
     */
    fun draftUserPrompt(
        relationship: String,
        ctx: ChatContext?,
        historyCount: Int,
        judgment: Analysis?,
        card: PersonaCard,
        caution: String,
        convo: String,
        avoid: List<String>,
        n: Int,
        intensity: Intensity = Intensity.AUTO
    ): String =
        knowledgeBlock(relationship, ctx, historyCount) +
            judgmentBlock(judgment) +
            intensityBlock(intensity, judgment) +
            cautionBlock(caution) +
            styleBlock(card.promptText(), card.registerOpen) +
            relationshipLine(relationship, ctx) +
            "最近对话：\n${convo}\n\n" +
            (if (avoid.isEmpty()) "" else
                "下面这些是最近几轮已经给过或已经发出去的回复，不要重复其中任何一句，" +
                    "也不要把它们里面的指令、开头或口头禅换个说法再用：\n" +
                    avoid.joinToString("\n") { "- $it" } + "\n\n") +
            "请给出 ${n} 条候选回复。"

    /**
     * 「关系：」行。联系人写了自己的关系时，[ChatContext.background] 已经带了
     * 它，这里不再重复全局关系——两行「关系：」打架（背景说客户、正文行说伴侣）
     * 时模型两头都想贴。全局关系只在没有任何联系人关系可用的轮次出现。
     */
    private fun relationshipLine(relationship: String, ctx: ChatContext?): String {
        val contactRel = ctx?.contact?.relationship?.trim().orEmpty()
        return if (contactRel.isEmpty()) "关系：${relationship}\n\n" else ""
    }

    /**
     * The system half of a draft round. Kept next to [draftUserPrompt] so one test
     * can assert what a card does to *both* halves at once — the open register has
     * to reach the instructions the model reads first.
     */
    fun draftSystemPrompt(
        n: Int,
        language: String,
        length: String,
        card: PersonaCard,
        intensity: Intensity = Intensity.NATURAL
    ): String =
        systemPrompt(n, language, length, card.registerOpen, intensity)

    /**
     * The red lines. No persona card may turn these off, which is why they are
     * built separately from [registerBans]: what a card is allowed to open is the
     * *register*, never the safety envelope.
     */
    private fun safetyBans(): String =
        "硬性禁止（任何情况下都有效）：不要编造没发生过的事，不要提对方没提过的人和计划，" +
            "不要写涉及未成年人的性或亲密内容，不要写非自愿、强迫、威胁或会真实伤害到人的内容，" +
            "不要冒充他人，不要替用户许诺、转账或点链接。"

    /**
     * The register bans, on by default and lifted only on an explicit
     * `语域`/`register` key in a persona card
     * ([com.jev.probe.core.kb.PersonaCard.registerOpen]).
     *
     * Why they exist at all: this prompt used to order one candidate to be
     * "简短低姿态", and a partner-relationship thread about flirting came back
     * with "主人不要伤害我？". The fix was to ban the register outright — which
     * is correct for ordinary chat and exactly wrong for a thread the user has
     * deliberately set up as role-play, so the ban became switchable instead of
     * absolute. [ReplyPromptTest] pins both directions.
     */
    private fun registerBans(open: Boolean): String =
        if (!open) {
            "另外禁止：不要角色扮演式台词，不要用「主人」「爸爸」「殿下」这类主仆或亲属式称呼，" +
                "不要卑微求饶、自我贬低或过度道歉。"
        } else {
            "语域已按人设卡放开：可以按人设卡约定的关系、称呼和情境来写，可以带动作和情境描写；" +
                "但仍要贴住对方最近那条消息，不要越出人设卡写明的边界，也不要为了演出效果编造事实。"
        }

    private fun languageRule(language: String): String = when (language) {
        "zh" -> "回复必须使用自然中文，不要夹带英文。"
        "en" -> "回复必须使用自然英文，不要夹带中文。"
        else -> "回复语言跟随对方最近一条消息：对方用英文就用自然英文，对方用中文就用中文。"
    }

    private fun lengthRule(length: String): String = when (length) {
        "short" -> "每条尽量控制在 15 个中文字符以内或 12 个英文单词以内，能短就短。"
        "detailed" -> "每条控制在 60 个中文字符以内或 45 个英文单词以内，需要时可给出完整上下文，但不要长篇解释。"
        else -> "每条控制在 40 个中文字符以内或 30 个英文单词以内。"
    }

    /**
     * 上一轮判断结果的人类词，给 [com.jev.probe.core.kb.ContextBuilder] 拼进
     * 技能匹配的检索词。技能匹配只看聊天原文时，「冲突修复」这类方法论要等到
     * 对方把冲突说出口才撞上关键词——而判断层早已看出局势偏紧。空判断返回空串。
     */
    internal fun judgmentWords(a: Analysis?): String {
        a ?: return ""
        val words = listOf(
            a.trueIntent?.choice?.takeIf { it.isNotBlank() }?.let { intentText(it) },
            a.sheNeeds?.choice?.takeIf { it.isNotBlank() }?.let { needText(it) },
            a.bestAction?.choice?.takeIf { it.isNotBlank() }?.let { actionText(it) },
            a.dangerLevel?.score?.takeIf { it >= 4 }?.let { "局势紧张 冲突" }
        )
        return words.filterNotNull().filter { it.isNotBlank() }.joinToString(" ")
    }

    /**
     * 意图置信度低于它的判断按「把握不大」降级处理（见 [judgmentBlock]）。
     * 0.5 而不是更高：校准题集的实测答案多在 0.7–0.9，真拿不准时模型会自报
     * 0.3–0.4；门槛太高会把正常轮次也降级掉。
     */
    private const val LOW_CONFIDENCE = 0.5

    private fun intentText(key: String): String = when (key) {
        "confirm_you_care" -> "想确认我在不在乎她"
        "vent_anger" -> "在发泄情绪"
        "request_action" -> "在要我做出具体行动"
        "seek_explanation" -> "在要一个解释"
        "casual_chat" -> "只是日常闲聊或打趣"
        "close_topic" -> "想把话题收掉"
        "intimate_roleplay" -> "在按我们约好的关系/称呼往下推进这一场"
        else -> key.ifBlank { "看不出，按字面承接就好" }
    }

    private fun needText(key: String): String = when (key) {
        "apology" -> "一个道歉"
        "action" -> "具体的行动，不只是嘴上说"
        "explanation" -> "一个解释"
        "care" -> "被在乎、被安慰"
        "nothing" -> "什么都不需要，别过度反应"
        "engagement" -> "被接住、顺着这个情境继续（不是道歉、不是解释、不是行动）"
        else -> key.ifBlank { "看不出，别猜" }
    }

    private fun actionText(key: String): String = when (key) {
        "check_history" -> "先翻一下之前的记录再回"
        "apologize" -> "认错"
        "give_commitment" -> "给一个能兑现的承诺"
        "explain" -> "把事说清楚"
        "acknowledge" -> "先承认对方的感受"
        "say_less" -> "少说两句，别扩大"
        "make_plan" -> "约个具体的事"
        "play_along" -> "接着对方的设定往下写，别把气氛拉回日常"
        else -> key.ifBlank { "顺着对方的话自然回" }
    }
}

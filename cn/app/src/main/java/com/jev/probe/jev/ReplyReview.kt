package com.jev.probe.jev

import com.jev.probe.core.Analysis
import com.jev.probe.core.kb.Ledger
import com.jev.probe.core.kb.PersonaCard
import org.json.JSONObject

/**
 * S1 证据复查（wenyi 的 evidence-driven review，搬到回复上）。
 *
 * 为什么需要它：实测结论是「首选候选仍会选错」——Jev 的排序只会在给定的候选里
 * 挑一个最好的，它不会说「这三条其实都站不住」。网调/文爱这种需要连续多轮保持
 * 称呼、情境和边界的场景里，最贵的错误不是排序错了，而是三条里没有一条能发。
 * 复查就是补这一步：逐条带着**理由**核验，站不住的要指出是哪一条标准没满足，
 * 于是调用方可以只重写那几条，而不是把三条全丢掉重来。
 *
 * 设计上是**失败即放行**（fail-open）：任何解析失败、缺项、越界都当作
 * 「保留」。一个抽风的复查模型绝不能把候选删空。
 *
 * 纯字符串装配 + 纯解析，不碰网络，因此能被 JVM 单测直接钉住。
 */
object ReplyReview {
    /** 一条候选的核验结论。 */
    data class Verdict(val index: Int, val keep: Boolean, val reason: String)

    data class Result(val verdicts: List<Verdict>) {
        /** 站不住的那些，按候选顺序。 */
        val rejected: List<Verdict> get() = verdicts.filter { !it.keep }
    }

    /**
     * 六条判定标准。第 3、5 条是台账带来的新能力：复查现在能拿「已明确的边界」
     * 和对不上的称呼当作判据，而不只是「读起来顺不顺」。第 6 条管复读：
     * 每条标准都过的回复仍然可能只是把上一轮的指令再说一遍（2026-10-07 实测
     * 聊天记录里「跪好 / 报数」整场复读），这类候选要重写而不是放行。
     *
     * 第 3、5、6 条要有依据才成立，所以 [user] 必须把人设卡一并给进来 —— 不然
     * 这几条标准只会在要求复查拿一份它从没见过的材料做判断，退化成「读着像不像」。
     */
    fun system(n: Int): String =
        "你是聊天回复的核验助手。用户已经拿到 $n 条候选回复，请逐条核验它们是不是真的能发出去。\n" +
            "只输出一个 JSON 对象，不要解释，不要代码块围栏，格式固定：\n" +
            "{\"verdicts\":[{\"index\":1,\"keep\":true,\"reason\":\"\"}]}\n" +
            "每条候选一个对象，index 从 1 开始，顺序必须与给你的候选一致，一条都不能少。\n" +
            "判定标准，任意一条不满足就 keep=false：\n" +
            "1. 有没有直接回应对方最近那条消息，还是自说自话、答非所问。\n" +
            "2. 有没有贴住这段对话真实的氛围和亲密程度：该轻松时别突然煽情，该认真时别打趣。\n" +
            "3. 有没有和已知的称呼、关系、固定说法冲突。\n" +
            "4. 有没有编造对话里没出现过的事实、人、计划或承诺。\n" +
            "5. 有没有越过已经明确的边界、禁区或安全词。\n" +
            "6. 有没有复读：是不是把这场对话里已经说过的话或已经下过的指令又说了一遍，没有给出新内容。\n" +
            "给了人设卡时，第 3、5 条以人设卡为准（称呼、关系、固定说法、硬边界、安全词都在里面）；" +
            "没给就以对话里已经出现过的东西为准，不要自己脑补对方有什么边界。\n" +
            "keep=false 时 reason 用一句中文说清是上面哪一条出问题、具体错在哪；" +
            "keep=true 时 reason 必须是空字符串。\n" +
            "只看这六条。不要评价文采，不要写改写建议，不要重写候选，不要因为可以更好就判 false。"

    /**
     * 台账放在候选**之前**、判断结果之后：复查要先知道既定情况，才可能看出
     * 候选和称呼/边界冲突 —— 这是复查从「读起来顺不顺」升级成「事实对不对」
     * 的地方。
     *
     * [card] 是同一张人设卡（调用方和起草用的是同一份），紧跟在台账后面：两者
     * 都是「判据」，而候选是「被判断的东西」。**不要**把它拼进 [Ledger] 那种
     * 台账文本里 —— 台账是模型自己写的、会被重建，人设卡是用户逐字写的、
     * 有 `硬边界` 这种逐字匹配的字段，混在一起会让复查分不清哪个是权威。
     */
    fun user(
        relationship: String,
        convo: String,
        judgment: Analysis?,
        ledger: Ledger?,
        candidates: List<String>,
        card: PersonaCard? = null
    ): String {
        val sb = StringBuilder()
        val ledgerText = ledger?.render().orEmpty()
        if (ledgerText.isNotBlank()) sb.append(ledgerText).append('\n')
        val cardText = card?.takeIf { it.hasContent() }?.promptText()?.trim().orEmpty()
        if (cardText.isNotEmpty()) {
            sb.append("对方与我的人设卡（第 3、5 条以它为准）：\n").append(cardText).append("\n\n")
        }
        val judgmentText = ReplyPrompt.judgmentBlock(judgment)
        if (judgmentText.isNotBlank()) sb.append(judgmentText)
        sb.append("关系：").append(relationship).append("\n\n")
        sb.append("最近对话：\n").append(convo.trim()).append("\n\n")
        sb.append("候选回复：\n")
        candidates.forEachIndexed { i, text -> sb.append(i + 1).append(". ").append(text).append('\n') }
        sb.append("\n请逐条核验并输出 JSON。")
        return sb.toString()
    }

    /**
     * Tolerant parse. Read the first `{` to the last `}`; every missing or
     * out-of-range index stays a keep. A malformed answer returns null, which the
     * caller treats as "no review happened" — the ranking stands untouched.
     */
    fun parse(raw: String, n: Int): Result? {
        val text = raw.trim()
        val start = text.indexOf('{')
        val end = text.lastIndexOf('}')
        if (start < 0 || end <= start) return null
        val obj = runCatching { JSONObject(text.substring(start, end + 1)) }.getOrNull() ?: return null
        val arr = obj.optJSONArray("verdicts") ?: return null
        val byIndex = HashMap<Int, Verdict>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val index = o.optInt("index", -1)
            if (index < 1 || index > n) continue
            val keep = o.optBoolean("keep", true)
            val reason = o.optString("reason", "").trim().take(120)
            // 判 false 却没说理由 = 没有证据。按放行处理，否则一条空理由就能
            // 把候选删掉，而用户根本看不到为什么。
            val finalKeep = keep || reason.isEmpty()
            byIndex[index] = Verdict(index, finalKeep, if (finalKeep) "" else reason)
        }
        if (byIndex.isEmpty()) return null
        val verdicts = (1..n).map { byIndex[it] ?: Verdict(it, keep = true, reason = "") }
        return Result(verdicts)
    }
}

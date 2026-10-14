package com.jev.probe.core.safety

import com.jev.probe.core.kb.PersonaCard

/**
 * Thrown instead of calling the model when [SafetyGate] blocks a round. The
 * caller shows [message] verbatim: "no candidates" without a reason is
 * indistinguishable from a broken network, and the user has to be able to tell
 * that the assistant refused on purpose.
 */
class SafetyBlockedException(message: String) : RuntimeException(message)

/**
 * A pre-flight check on what the *other person* just wrote, run before any API
 * call. Three outcomes:
 *
 * - allow (nothing to say),
 * - allow with a [Verdict.caution], which rides into the drafting prompt,
 * - [Verdict.blockReason], which stops the round and is shown to the user.
 *
 * Deliberately conservative where being wrong is expensive and narrow where it
 * is not. "对方才15岁，想玩文爱" must block; a passing "未成年" in a message about
 * a game must not, which is why minor signals block only when the same thread
 * also carries intimate/role-play content. Free-text notes are not scanned —
 * only the hard limits the user wrote into their persona card, because
 * inventing limits for the user would just make the assistant refuse to help.
 */
object SafetyGate {

    /** [blockReason] non-null means do not draft; [caution] non-blank rides in the prompt. */
    data class Verdict(val blockReason: String? = null, val caution: String = "") {
        val blocked: Boolean get() = blockReason != null
    }

    private val ILLEGAL_WORDS = listOf("强奸", "迷奸", "迷药", "下药", "偷拍", "勒索", "拐卖", "未成年性")

    private val SELF_HARM_WORDS = listOf("自杀", "自残", "割腕", "上吊", "跳楼", "安眠药")

    private val MINOR_WORDS = listOf(
        "未成年", "小学生", "初中生", "高中生", "初一", "初二", "初三", "高一", "高二", "高三",
        "未满18", "未满十八", "child", "minor"
    )

    /** A bare age, checked against 18 rather than pattern-matched per age. */
    private val AGE = Regex("(\\d{1,2})\\s*(?:周?岁)")

    private val INTIMATE_WORDS = listOf(
        "文爱", "网调", "调教", "情趣", "主人", "奴隶", "性爱", "性欲", "性感", "性关系",
        "做爱", "上床", "裸", "情色", "色情", "舔", "爱抚", "亲我", "摸我", "睡我", "跪下"
    )

    private val COERCION_WORDS = listOf(
        "强迫", "逼我", "威胁", "不情愿", "不愿意", "不同意", "醉", "喝多", "意识不清"
    )

    /**
     * Where the other person currently is. A scene that happens in a corridor, a
     * stairwell or a car park is not the same as one behind a locked door, and the
     * material in the role-play suite is explicit that planning for "someone walks
     * past" is the dominant's job, not the submissive's.
     */
    private val PLACE_WORDS = listOf(
        "楼道", "走廊", "楼梯", "门外", "门口", "外面", "户外", "室外", "阳台", "天台",
        "公共", "电梯", "停车场", "公园", "街上", "路上", "车里", "公司", "教室", "宿舍"
    )

    /** A boundary that is about *where* she is: only then is a place worth warning about. */
    private val PLACE_BOUNDARY_HINTS = listOf(
        "有人", "别人", "公共", "安全", "露出", "外面", "户外", "楼道", "走廊", "门口", "窗户"
    )

    /**
     * A limit said another way.
     *
     * Boundaries are matched literally against the other side's words, and the
     * settings hint tells the user to write the word itself. That holds right up to
     * the moment the other person paraphrases: "不要留痕" is not matched by "我想把
     * 你刚说的那些录下来，就我自己留着", and the round drafted anyway — every
     * candidate said yes (see `_reports/roleplay-quality_report.md`). So for the
     * families where a paraphrase is easy and the cost of missing it is high, the
     * boundary is also matched against the move it is really about.
     */
    private data class BoundaryKind(val name: String, val hints: List<String>, val reaches: List<String>)

    private val BOUNDARY_KINDS = listOf(
        BoundaryKind(
            name = "留痕",
            hints = listOf("留痕", "留存", "录音", "录像", "拍照", "照片", "截图", "存档", "备份"),
            reaches = listOf(
                "录", "拍", "截图", "照片", "备份", "存档", "保存", "留着", "收好", "私藏", "删掉记录"
            )
        )
    )

    private val SAFEWORD_SPLIT = Regex("[/、,，;；|]+")
    private val WHITESPACE = Regex("\\s+")

    /**
     * The agreed stop words, split on the separators a card actually uses
     * (`红灯/黄灯`, `红灯、黄灯`) and flattened so spacing or punctuation inside a
     * line cannot hide them.
     */
    internal fun safeWords(card: PersonaCard?): List<String> =
        card?.safeword?.trim().orEmpty()
            .split(SAFEWORD_SPLIT)
            .map { flatten(it) }
            .filter { it.isNotBlank() }

    /**
     * The agreed yellow-light words ([PersonaCard.yellow]): a signal to slow down
     * and check in, NOT to stop — red keeps that job. 2026-10-07 实测聊天记录里
     * 对方打出「黄灯哦」之后场景还在继续，这正是黄灯的语义；而旧的
     * 「安全词：红灯停、黄灯缓」写法会把黄灯塞进 [safeWords] 里硬拦整轮。
     */
    internal fun slowWords(card: PersonaCard?): List<String> =
        card?.yellow?.trim().orEmpty()
            .split(SAFEWORD_SPLIT)
            .map { flatten(it) }
            .filter { it.isNotBlank() }

    private fun flatten(text: String): String = text.lowercase().replace(WHITESPACE, "")

    /** A boundary of the given family, plus the paraphrase that reached it. */
    private fun paraphrasedBoundary(lower: String, card: PersonaCard?): Pair<BoundaryKind, String>? {
        val boundaries = card?.boundaries.orEmpty()
        if (boundaries.isEmpty()) return null
        for (boundary in boundaries) {
            val written = boundary.lowercase()
            val kind = BOUNDARY_KINDS.firstOrNull { k -> k.hints.any { written.contains(it) } } ?: continue
            if (kind.reaches.any { lower.contains(it) }) return kind to boundary
        }
        return null
    }

    /**
     * A place worth a caution — but only when the user's own card already says her
     * being somewhere public is a limit. Otherwise this would chirp at every
     * ordinary "我在路上".
     */
    private fun riskyPlace(lower: String, card: PersonaCard?): String? {
        val place = PLACE_WORDS.firstOrNull { lower.contains(it) } ?: return null
        val declared = card?.boundaries.orEmpty().any { b -> PLACE_BOUNDARY_HINTS.any { b.contains(it) } }
        return if (declared) place else null
    }

    /**
     * @param otherLines everything the other side said in the visible window. A
     *        side the capture step could not attribute must be included here too:
     *        "maybe the other person" is not a reason to skip the check.
     */
    fun check(otherLines: List<String>, card: PersonaCard?): Verdict {
        val text = otherLines.filter { it.isNotBlank() }.joinToString("\n")
        if (text.isBlank()) return Verdict()
        val lower = text.lowercase()

        find(lower, ILLEGAL_WORDS)?.let {
            return Verdict(blockReason = "对方这条里有涉嫌违法的内容「${it}」。这类内容我不给候选。")
        }
        find(lower, SELF_HARM_WORDS)?.let {
            return Verdict(
                blockReason = "对方这条里有自伤或自杀的字眼「${it}」。这超出回复助手能处理的范围，" +
                    "我不给候选——先确认对方人是不是安全的。"
            )
        }

        // The stop word the two of them agreed on, before the softer heuristics
        // below. Once it has been said the scene is over: it stays a stop for the
        // rest of the visible window, because "she called it and then the
        // conversation moved on" is exactly the case where a draft does harm.
        val flat = flatten(text)
        safeWords(card).firstOrNull { flat.contains(it) }?.let {
            return Verdict(
                blockReason = "对方这条里出现了你们约好的安全词「${it}」。按约定这一刻要停下来，我不给候选——" +
                    "先确认对方的状态，别再往下推这一场。"
            )
        }

        val minor = find(lower, MINOR_WORDS)
            ?: AGE.find(text)?.takeIf { it.groupValues[1].toInt() < 18 }?.value
        val intimate = find(lower, INTIMATE_WORDS)
        if (minor != null && intimate != null) {
            return Verdict(
                blockReason = "对方这条同时出现了未成年人信号「${minor}」和亲密或角色内容「${intimate}」。" +
                    "涉及未成年人的这类内容我不给候选。"
            )
        }

        // The user's own hard limits, as written in the persona card.
        card?.boundaries?.firstOrNull { it.isNotBlank() && lower.contains(it.lowercase()) }?.let {
            return Verdict(
                blockReason = "对方这条碰到了你写下的硬边界「${it}」。按你的设定我不出候选，" +
                    "你可以自己回，或者去改联系人设定。"
            )
        }

        val cautions = ArrayList<String>()
        // 黄灯：约定里的减速信号。放在 caution 列表第一位——它比地点/换说法提醒
        // 更优先，因为这是双方明说过的约定，而下面的都只是启发式。
        slowWords(card).firstOrNull { flat.contains(it) }?.let {
            cautions += "对方打出了你们约好的黄灯信号「${it}」。按约定这一刻要减速：先接住对方说的，" +
                "降低强度，确认对方的状态和边界；不要加码、不要开启新的动作，也不要当成安全词把这一场直接停掉——" +
                "停止只归红灯。"
        }
        paraphrasedBoundary(lower, card)?.let { (kind, boundary) ->
            cautions += "对方碰到了你写下的硬边界「${boundary}」，只是换了个说法（${kind.name}这一类）。" +
                "这一条在这一点上只能拒绝或者先停下来确认：不要答应、不要给替代方案、不要换话题绕开。"
        }
        riskyPlace(lower, card)?.let { place ->
            cautions += "对方现在人可能在公共或半公共的地方（「${place}」）。先确认环境——有没有别人、" +
                "能不能马上回来——并给她留好退路，再谈指令。"
        }
        minor?.let { cautions += "出现了未成年人信号「${it}」，先确认年龄再往下走" }
        find(lower, COERCION_WORDS)?.let { cautions += "出现了「${it}」，确认这是双方自愿、不是被推着走" }
        return Verdict(caution = cautions.joinToString("；"))
    }

    private fun find(lower: String, words: List<String>): String? = words.firstOrNull { lower.contains(it) }
}

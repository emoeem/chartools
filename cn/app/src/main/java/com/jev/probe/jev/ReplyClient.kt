package com.jev.probe.jev

import com.jev.probe.core.Analysis
import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Intensity
import com.jev.probe.core.Msg
import com.jev.probe.core.Prefs
import com.jev.probe.core.RankedReply
import com.jev.probe.core.kb.ChatContext
import com.jev.probe.core.kb.DomainBrief
import com.jev.probe.core.kb.Ledger
import com.jev.probe.core.kb.LedgerPrompt
import com.jev.probe.core.kb.PersonaCard
import com.jev.probe.core.kb.StyleSource
import com.jev.probe.core.kb.effectiveRelationship
import com.jev.probe.core.safety.SafetyBlockedException
import com.jev.probe.core.safety.SafetyGate
import org.json.JSONArray
import org.json.JSONObject

/**
 * The generative route: any OpenAI-compatible `/chat/completions` endpoint.
 * Drafts the 3 candidate replies, and (D stage) summarizes text. Reads
 * replyBaseUrl / replyKey / replyModel from [Prefs].
 */
class ReplyClient(private val prefs: Prefs) {

    /**
     * [count] varied candidate replies (1..3), in the language of the other
     * person's latest message (English chats get English replies). [avoid] holds
     * replies already shown for this chat ("换一组"), which the model must not repeat.
     *
     * @param ctx D-stage knowledge context. When present its background and
     *        history are prepended to the prompt with an instruction to stay
     *        consistent with them and invent nothing beyond them.
     * @param judgment the judge round's verdict, when it is already known. The
     *        drafter then writes for the actual situation instead of guessing
     *        one — without it a fresh draft has no idea whether the thread is a
     *        fight, a joke or flirting.
     * @param style the user's own tone/persona note (`Prefs.style`).
     * @param scope when given, the request is registered there so an abandoned
     *        round closes its socket instead of waiting out the read timeout.
     */
    fun draft(
        snapshot: ChatSnapshot,
        relationship: String,
        ctx: ChatContext? = null,
        count: Int = 3,
        avoid: List<String> = emptyList(),
        judgment: Analysis? = null,
        style: String = "",
        intensity: Intensity = Intensity.AUTO,
        scope: HttpScope? = null
    ): List<RankedReply> {
        val ask = draftAsk(snapshot, relationship, ctx, count, avoid, judgment, style, intensity)
        return parseN(
            chat(ask.system, ask.user, ask.temperature, scope = scope,
                frequencyPenalty = ask.frequencyPenalty, presencePenalty = ask.presencePenalty),
            ask.count
        )
    }

    /**
     * Streaming variant of [draft] (opt-in; the caller decides whether the switch
     * is on). Same request with `stream=true`, and [onVisible] is handed the
     * *readable* text each time it grows — [StreamText] hides the JSON envelope and
     * the prompt's own array format. Returns exactly what [draft] returns, so the
     * finished stream feeds the same ranking path as a buffered reply.
     *
     * No retry: a half-delivered stream that restarts would repeat itself. The
     * caller falls back to [draft] when this throws.
     */
    fun draftStream(
        snapshot: ChatSnapshot,
        relationship: String,
        ctx: ChatContext? = null,
        count: Int = 3,
        avoid: List<String> = emptyList(),
        judgment: Analysis? = null,
        style: String = "",
        intensity: Intensity = Intensity.AUTO,
        onVisible: (String) -> Unit,
        scope: HttpScope? = null
    ): List<RankedReply> {
        val ask = draftAsk(snapshot, relationship, ctx, count, avoid, judgment, style, intensity)
        val url = prefs.replyEndpoint()
        val raw = StringBuilder()
        var lastShown = ""
        HttpJson.stream(
            url,
            prefs.effectiveReplyKey(),
            chatBody(ask.system, ask.user, ask.temperature, stream = true,
                frequencyPenalty = ask.frequencyPenalty, presencePenalty = ask.presencePenalty),
            Route.REPLY,
            HttpJson.headersFor(url),
            scope
        ) { payload ->
            StreamText.delta(payload)?.let { fragment ->
                raw.append(fragment)
                val visible = StreamText.visible(raw.toString())
                if (visible != lastShown) {
                    lastShown = visible
                    onVisible(visible)
                }
            }
        }
        if (raw.isEmpty()) throw ApiException(Route.REPLY, null, "流式响应没有内容")
        return parseN(raw.toString(), ask.count)
    }

    /** Draft candidates without waiting for Jev judgment. */
    fun draftOnly(
        snapshot: ChatSnapshot,
        relationship: String,
        ctx: ChatContext? = null,
        count: Int = 3,
        avoid: List<String> = emptyList(),
        judgment: Analysis? = null,
        style: String = prefs.style,
        intensity: Intensity = Intensity.AUTO,
        scope: HttpScope? = null
    ): List<RankedReply> =
        draft(snapshot, relationship, ctx, count, avoid, judgment = judgment, style = style,
            intensity = intensity, scope = scope)
            .map { it.copy(ranked = false, prob = 0.0) }

    /** Refine exactly one visible candidate; never regenerates the whole set. */
    fun refine(
        snapshot: ChatSnapshot,
        relationship: String,
        original: String,
        instruction: String,
        ctx: ChatContext? = null,
        style: String = prefs.style,
        scope: HttpScope? = null
    ): RankedReply? {
        val convo = convoLines(snapshot.messages)
        val system = "你是即时通讯回复改写助手。只输出一个 JSON 数组，且只能有一个对象：" +
            "{\"strategy\":\"safe\",\"text\":\"...\"}。" +
            "保持原意和事实，不补造记忆，不解释，不加引号。"
        val user = refineUserPrompt(
            relationship, ctx, prefs.contextHistoryCount, style, instruction, original, convo)
        return parseN(
            chat(system, user, temperature = 0.65, scope = scope,
                frequencyPenalty = prefs.replyFrequencyPenalty,
                presencePenalty = prefs.replyPresencePenalty),
            1
        ).firstOrNull()?.copy(ranked = false, prob = 0.0)
    }

    /**
     * One plain chat round trip for the settings connectivity test. Deliberately
     * NOT [summarize]: the test should exercise the ordinary path, not whatever
     * the summary prompt happens to be.
     */
    fun ping(): String =
        chat("你是连通性测试助手，只按要求回答，不要解释。", "请只回复两个字：收到", temperature = 0.0).trim()

    /** Condense a block of text (used by the D-stage contact auto-summary). */
    fun summarize(text: String): String {
        if (text.isBlank()) return ""
        val sys = "你是中文摘要助手。把给到的聊天记录压缩成不超过 120 字的第三人称要点摘要，" +
            "只保留事实、偏好、承诺和待办，不要评论，不要编造。直接输出摘要正文。"
        return chat(sys, text, temperature = 0.2).trim()
    }

    /**
     * 领域卡预扫：把知识库的均衡采样压成一段设定卡。走生成侧路由（和
     * [summarize] 同一个 key / endpoint / model），因为它是生成任务。
     *
     * 温度 0.3：这活是归纳不是创作，但 0.0 会让它把采样里那段话原样抄回来。
     * 失败一律抛出去 —— 调用方（`KnowledgeActivity`）负责说人话地报错，
     * 绝不能把一段半成品写进知识库。
     */
    fun domainBrief(topic: String, sample: String, scope: HttpScope? = null): String {
        if (sample.isBlank()) return ""
        return chat(
            DomainBrief.SYSTEM,
            DomainBrief.user(topic, sample),
            temperature = 0.3,
            scope = scope
        ).trim()
    }

    /**
     * S1 台账构建：把 [transcript] 这一段记录整理进 [previous] 之后的台账。
     *
     * 走生成侧路由（和 [summarize] 同一个 key / endpoint / model）：它是生成任务，
     * 不是判断任务，放判断路由上会把 Jev 的题集协议和这段自然语言混在一起。
     * 失败一律抛出去，由 [com.jev.probe.core.kb.ContextBuilder] 兜住并保留旧台账 ——
     * 台账永远不能让这一轮分析失败。
     */
    fun rebuildLedger(previous: Ledger?, transcript: String, coveredUntil: Long): Ledger? {
        if (transcript.isBlank()) return null
        val raw = chat(
            LedgerPrompt.system(),
            LedgerPrompt.user(previous?.encode(), transcript),
            temperature = 0.2
        )
        return Ledger.parse(raw, coveredUntil, System.currentTimeMillis())
    }

    /**
     * S1 证据复查：逐条核验候选，见 [ReplyReview]。走**复查路由**
     * ([Prefs.reviewEndpoint] / [Prefs.effectiveReviewKey] / [Prefs.effectiveReviewModel])，
     * 三个字段都留空时它就是回复路由 —— 这是 wenyi 的 per-operation 模型路由，
     * 但没有默认的配置负担。
     *
     * 返回 null 表示「没有复查」：网络失败、返回不可解析，都算，调用方保持排序结果不动。
     */
    fun review(
        relationship: String,
        convo: String,
        ctx: ChatContext?,
        judgment: Analysis?,
        candidates: List<String>,
        scope: HttpScope? = null
    ): ReplyReview.Result? {
        if (candidates.isEmpty()) return null
        // 复查必须拿到和起草**同一张**人设卡：第 3、5 条标准是「有没有和已知的
        // 称呼/边界冲突」，不给它卡，这两条就只能退化成「读着像不像」。
        val rawStyle = StyleSource.resolve(prefs.style, ctx?.contact?.persona).text
        val card = PersonaCard.parse(rawStyle)
        val raw = chatOn(
            prefs.reviewEndpoint(),
            prefs.effectiveReviewKey(),
            prefs.effectiveReviewModel(),
            ReplyReview.system(candidates.size),
            // 关系先过 effectiveRelationship：复查和起草要看到同一段关系
            // （联系人自己的关系压过全局），第 3 条标准才不是各说各话。
            ReplyReview.user(ctx.effectiveRelationship(relationship), convo, judgment, ctx?.ledger, candidates, card),
            temperature = 0.0,
            scope = scope
        )
        return ReplyReview.parse(raw, candidates.size)
    }

    /** One chat-completions round trip; returns the assistant message content. */
    private fun chat(
        system: String,
        user: String,
        temperature: Double,
        scope: HttpScope? = null,
        frequencyPenalty: Double = 0.0,
        presencePenalty: Double = 0.0
    ): String {
        val url = prefs.replyEndpoint()
        return chatOn(url, prefs.effectiveReplyKey(), prefs.replyModel, system, user, temperature, scope,
            frequencyPenalty, presencePenalty)
    }

    /**
     * Same round trip on an explicit route. The S1 review step needs a second
     * route; everything else in this file keeps going through [chat].
     */
    private fun chatOn(
        url: String,
        key: String,
        model: String,
        system: String,
        user: String,
        temperature: Double,
        scope: HttpScope?,
        frequencyPenalty: Double = 0.0,
        presencePenalty: Double = 0.0
    ): String {
        val resp = HttpJson.post(
            url, key,
            chatBody(system, user, temperature, stream = false, model = model,
                frequencyPenalty = frequencyPenalty, presencePenalty = presencePenalty),
            Route.REPLY, HttpJson.headersFor(url), scope)
        return resp.optJSONArray("choices")?.optJSONObject(0)
            ?.optJSONObject("message")?.optString("content") ?: ""
    }

    /**
     * The request body both paths send. Shared so the streaming request can never
     * drift from the buffered one — the only intended difference is `stream`.
     */
    private fun chatBody(
        system: String,
        user: String,
        temperature: Double,
        stream: Boolean,
        model: String = prefs.replyModel,
        frequencyPenalty: Double = 0.0,
        presencePenalty: Double = 0.0
    ): JSONObject = chatRequestBody(
        model, system, user, temperature, stream, frequencyPenalty, presencePenalty
    )

    /** The prompt pair a draft sends, built once and used by both draft paths. */
    private class Ask(
        val system: String,
        val user: String,
        val temperature: Double,
        val count: Int,
        val frequencyPenalty: Double,
        val presencePenalty: Double
    )

    private fun draftAsk(
        snapshot: ChatSnapshot,
        relationship: String,
        ctx: ChatContext?,
        count: Int,
        avoid: List<String>,
        judgment: Analysis?,
        style: String,
        intensity: Intensity
    ): Ask {
        val n = count.coerceIn(1, 3)
        val convo = convoLines(snapshot.messages)
        // The persona note may be a key/value card (PersonaCard). Free text parses to
        // structured = false and comes back verbatim, so this is byte-for-byte the
        // string the app sent before cards existed.
        val rawStyle = StyleSource.resolve(style, ctx?.contact?.persona).text
        val card = PersonaCard.parse(rawStyle)
        // Pre-flight, before anything leaves the device: some rounds this app will not
        // draft for, and the user has to be told which and why. Silently returning no
        // candidates is indistinguishable from a network failure.
        // Only the other side (and anything we could not attribute) is checked: the
        // limits are about what is being asked of the user.
        val verdict = SafetyGate.check(
            snapshot.messages.filter { it.side != "me" }.map { it.text }, card)
        verdict.blockReason?.let { throw SafetyBlockedException(it) }
        // The prompt itself is assembled by ReplyPrompt so the layering can be
        // asserted in a plain unit test, with no Prefs and no server.
        val user = ReplyPrompt.draftUserPrompt(
            relationship, ctx, prefs.contextHistoryCount, judgment,
            card, verdict.caution, convo, avoid, n, intensity)
        // 档位解析一次、两处共用：system 的策略契约和 user 的档位块必须拿到
        // 同一个结果，否则会出现「必须推进」和「不要推进」同场。
        val resolvedIntensity = Intensity.resolve(intensity, judgment)
        return Ask(
            system = ReplyPrompt.draftSystemPrompt(n, prefs.replyLanguage, prefs.replyLength, card, resolvedIntensity),
            user = ReplyPrompt.skillNote(ctx) + user,
            // 用户设的温度就是温度：跨轮 avoid 现在几乎每轮非空，旧的「avoid
            // 非空就 +0.1」等于全局偷偷调参，反重复交给 avoid 文本和复查兜着。
            temperature = prefs.replyTemperature,
            count = n,
            frequencyPenalty = prefs.replyFrequencyPenalty,
            presencePenalty = prefs.replyPresencePenalty
        )
    }

    /** Parse structured strategy candidates, with a tolerant legacy-text fallback. */
    private fun parseN(content: String, n: Int): List<RankedReply> {
        val start = content.indexOf('[')
        val end = content.lastIndexOf(']')
        if (start >= 0 && end > start) {
            try {
                val arr = JSONArray(content.substring(start, end + 1))
                val out = ArrayList<RankedReply>()
                for (i in 0 until arr.length()) {
                    val item = arr.opt(i)
                    if (item is JSONObject) {
                        val text = item.optString("text").trim()
                        if (text.isNotEmpty()) {
                            val strategy = item.optString("strategy", "safe").trim().ifBlank { "safe" }
                            out.add(RankedReply(text, 0.0, strategy, ranked = false))
                        }
                    } else {
                        val text = arr.optString(i).trim()
                        if (text.isNotEmpty()) out.add(RankedReply(text, 0.0, strategyForIndex(out.size), ranked = false))
                    }
                }
                if (out.isNotEmpty()) return normalizeStrategies(out.take(n))
            } catch (_: Exception) { }
        }
        return content.split('\n')
            .map { it.trim().trimStart('-', '*', '1', '2', '3', '.', ' ', '"').trimEnd('"', ',') }
            .filter { it.isNotBlank() && it != "[" && it != "]" }
            .take(n)
            .mapIndexed { i, text -> RankedReply(text, 0.0, strategyForIndex(i), ranked = false) }
    }

    private fun strategyForIndex(i: Int): String = when (i) {
        1 -> "forward"
        2 -> "angle"
        else -> "safe"
    }

    private fun normalizeStrategies(items: List<RankedReply>): List<RankedReply> =
        items.mapIndexed { i, item ->
            val strategy = when (item.strategy) {
                "safe", "forward", "angle" -> item.strategy
                else -> strategyForIndex(i)
            }
            item.copy(strategy = strategy, ranked = false)
        }
}

/**
 * The last [WINDOW] messages as `who：text` lines, for the drafting, refine and
 * review prompts. One shared builder on purpose: this loop used to be written
 * out twice, and the refine copy was assembled from four concatenated string
 * literals (`"$" + "{who}：" + …`), so the model received the placeholder text
 * instead of the conversation.
 *
 * A side the capture step could not read is labelled 发言人不明 — it must never
 * be presented to the model as the other person's message.
 *
 * 20 而不是 10：2026-10-07 用户实测 Telegram 的反馈是「分不清上下文」。写作模型
 * 每轮只看最近 10 条，快节奏聊天里十条之前的设定（时间、任务、约定）全部出窗，
 * 模型只能瞎接。判断层（Jev state）仍是 10 条——那边是校准过的载荷，不在这里动。
 */
internal fun convoLines(messages: List<Msg>): String =
    messages.takeLast(WINDOW).joinToString("\n") {
        val who = when (it.side) {
            "me" -> "我"
            "other" -> "对方"
            else -> "发言人不明"
        }
        "$who：${it.text}"
    }

/**
 * The OpenAI-compatible request body, pure so a JVM test can pin the wire format.
 *
 * The penalties ride along ONLY when non-zero: a zero value is omitted rather
 * than sent as `0`, so the request stays byte-for-byte what it was before this
 * field existed — providers that reject unknown-or-defaulted params keep working.
 */
internal fun chatRequestBody(
    model: String,
    system: String,
    user: String,
    temperature: Double,
    stream: Boolean,
    frequencyPenalty: Double = 0.0,
    presencePenalty: Double = 0.0
): JSONObject {
    val messages = JSONArray()
        .put(JSONObject().put("role", "system").put("content", system))
        .put(JSONObject().put("role", "user").put("content", user))
    return JSONObject()
        .put("model", model)
        .put("messages", messages)
        .put("temperature", temperature)
        .put("stream", stream)
        .apply {
            if (frequencyPenalty != 0.0) put("frequency_penalty", frequencyPenalty)
            if (presencePenalty != 0.0) put("presence_penalty", presencePenalty)
        }
}

/**
 * The refine round's user prompt. Kept apart from the network call so a test can
 * assert on the exact string the model would receive.
 */
internal fun refineUserPrompt(
    relationship: String,
    ctx: ChatContext?,
    historyCount: Int,
    style: String,
    instruction: String,
    original: String,
    convo: String
): String =
    ReplyPrompt.knowledgeBlock(relationship, ctx, historyCount) +
        ReplyPrompt.styleBlock(style) +
        "\n改写要求：" + instruction + "\n原回复：" + original +
        "\n\n最近对话：\n" + convo + "\n不要原样照抄原回复，必须真的改写。"

/** 写作侧可见的对话窗口；判断层不走这里。 */
internal const val WINDOW = 20

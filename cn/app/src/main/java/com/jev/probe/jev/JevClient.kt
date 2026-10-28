package com.jev.probe.jev

import com.jev.probe.core.Analysis
import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Intensity
import com.jev.probe.core.Prefs
import com.jev.probe.core.RankedReply
import com.jev.probe.core.Trace
import com.jev.probe.core.kb.ChatContext
import com.jev.probe.core.kb.NOTE_TYPE_STYLE_SAMPLE
import com.jev.probe.core.kb.StyleSource
import com.jev.probe.core.kb.effectiveRelationship
import java.util.LinkedHashMap

/**
 * Thin facade over the three split clients so callers keep one entry point.
 * Construct with [Prefs] — every route reads its own address / key / model from
 * there, so switching providers in settings takes effect on the next call.
 */
class JevClient(private val prefs: Prefs) {

    private val judgeClient = JudgeClient(prefs)
    private val replyClient = ReplyClient(prefs)

    private val cache = object : LinkedHashMap<String, List<RankedReply>>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, List<RankedReply>>?): Boolean =
            size > CACHE_SIZE
    }

    /**
     * Judgments get their own small LRU. The judge is the slowest call of a round
     * (it is a reasoning prompt), and the same conversation is re-judged whenever
     * a round is re-started — "换一组" asks only for new candidates, but a repeat
     * analysis of an unchanged chat asks the same seven questions again.
     */
    private val judgeCache = object : LinkedHashMap<String, Analysis>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Analysis>?): Boolean =
            size > CACHE_SIZE
    }

    @Synchronized
    private fun cached(key: String): List<RankedReply>? = cache[key]

    @Synchronized
    private fun putCached(key: String, value: List<RankedReply>) {
        cache[key] = value.map { it.copy() }
    }

    @Synchronized
    private fun cachedJudge(key: String): Analysis? = judgeCache[key]

    @Synchronized
    private fun putCachedJudge(key: String, value: Analysis) { judgeCache[key] = value }

    /**
     * The 7 judgment questions. Errors come back inside [Analysis.error].
     *
     * Only successful judgments are cached: a cached transport error would make a
     * one-off network blip stick to the conversation for the rest of the session,
     * so a retry always goes back to the server.
     */
    fun judge(
        snapshot: ChatSnapshot,
        relationship: String,
        ctx: ChatContext? = null,
        scope: HttpScope? = null
    ): Analysis {
        val key = judgeKey(snapshot, relationship, ctx)
        cachedJudge(key)?.let { return it }
        val a = judgeClient.judge(snapshot, relationship, ctx, scope)
        if (a.error == null) putCachedJudge(key, a)
        return a
    }

    /**
     * Draft [count] candidates on the reply route, then rank them on the judge
     * route. A single candidate has nothing to rank, so that round is skipped.
     * [avoid] = replies already shown for this chat (the "换一组" request).
     * [judgment] is the verdict already in hand; the drafter needs it to pick a
     * register (see [ReplyPrompt.judgmentBlock]) and is not itself the ranking.
     */
    fun draftAndRank(
        snapshot: ChatSnapshot,
        relationship: String,
        ctx: ChatContext? = null,
        count: Int = 3,
        avoid: List<String> = emptyList(),
        judgment: Analysis? = null,
        intensity: Intensity = Intensity.AUTO,
        scope: HttpScope? = null
    ): List<RankedReply> {
        val key = cacheKey(snapshot, relationship, ctx, count, avoid, judgment, intensity)
        cached(key)?.let { return it }

        val candidates = replyClient.draft(
            snapshot, relationship, ctx, count, avoid, judgment, prefs.style, intensity, scope)
        if (candidates.size <= 1) {
            val result = candidates.map { it.copy(prob = 1.0, ranked = false) }
            putCached(key, result)
            return result
        }
        val ranked = try {
            judgeClient.rank(snapshot, relationship, candidates.map { it.text }, ctx, scope)
                .mapIndexed { i, r -> r.copy(strategy = candidates.getOrNull(i)?.strategy.orEmpty(), ranked = true) }
        } catch (_: Exception) {
            candidates.map { it.copy(ranked = false) }
        }
        val result = applyReview(snapshot, relationship, ctx, judgment, ranked, scope)
        putCached(key, result)
        return result
    }

    /**
     * 未排序的候选（轮内的"先判后写"路径和「再给 2 条」）。[intensity] 与
     * [draftAndRank] 共享同一份档位语义，进同一份缓存键。
     *
     * [judgment] 是这一轮已经到手的判断结果：首轮起草现在等判断（见
     * `ChatCaptureService` 的 DraftTrigger），带着它写，模型才知道这一场是
     * 吵架、玩笑还是角色扮演；判断路由超时才盲写（null）。
     */
    fun draftOnly(
        snapshot: ChatSnapshot,
        relationship: String,
        ctx: ChatContext?,
        count: Int = 3,
        avoid: List<String> = emptyList(),
        judgment: Analysis? = null,
        intensity: Intensity = Intensity.AUTO,
        scope: HttpScope? = null
    ): List<RankedReply> =
        replyClient.draftOnly(snapshot, relationship, ctx, count, avoid, judgment,
            prefs.style, intensity, scope)

    /**
     * S1 证据复查。默认关（[Prefs.reviewEnabled]）：开着时让模型逐条核验排序
     * 结果，把站不住的那几条重写一次（见 [ReplyReview]）。
     *
     * 三道保险，任何一道不满足就原样返回 [ranked]：
     *  1. 复查失败或不可解析 → [ReplyClient.review] 返回 null；
     *  2. 复查判定全部保留 → 不动，不为「还能更好」白花一次调用；
     *  3. 重写调用失败或条数对不上 → 放弃替换。
     * 也就是说复查只可能改好，不可能改坏，更不可能让候选变少。
     */
    private fun applyReview(
        snapshot: ChatSnapshot,
        relationship: String,
        ctx: ChatContext?,
        judgment: Analysis?,
        ranked: List<RankedReply>,
        scope: HttpScope?
    ): List<RankedReply> {
        if (!prefs.reviewEnabled || ranked.size <= 1) return ranked
        val texts = ranked.map { it.text }
        val review = runCatching {
            replyClient.review(relationship, convoLines(snapshot.messages), ctx, judgment, texts, scope)
        }.onFailure { Trace.log("review failed: ${it.message}") }.getOrNull() ?: return ranked

        val rejected = review.rejected
        if (rejected.isEmpty()) {
            Trace.log("review keep all n=${texts.size}")
            return ranked
        }
        // 把「被判定为」的理由一并塞进 avoid：重写要避开的不只是那几条原文，
        // 还有它们错在哪。这是复查相对排序的全部增量。
        Trace.log("review reject ${rejected.joinToString(",") { it.index.toString() }}")
        val replacements = runCatching {
            replyClient.draft(
                snapshot, relationship, ctx, count = rejected.size,
                avoid = texts + rejected.map { "上一条被判定为：${it.reason}" },
                judgment = judgment, style = prefs.style, scope = scope
            )
        }.onFailure { Trace.log("review rewrite failed: ${it.message}") }.getOrNull()
        if (replacements == null || replacements.size != rejected.size) return ranked

        val atIndex = HashMap<Int, RankedReply>(rejected.size)
        rejected.forEachIndexed { i, v -> atIndex[v.index] = replacements[i] }
        return ranked.mapIndexed { i, original ->
            val note = review.verdicts.getOrNull(i)?.reason.orEmpty()
            val replacement = atIndex[i + 1]
            if (replacement == null) original.copy(reviewNote = note)
            else replacement.copy(
                prob = original.prob, strategy = original.strategy,
                ranked = original.ranked, reviewNote = note
            )
        }
    }

    fun refineReply(
        snapshot: ChatSnapshot,
        relationship: String,
        ctx: ChatContext?,
        original: String,
        instruction: String,
        scope: HttpScope? = null
    ): RankedReply? = replyClient.refine(snapshot, relationship, original, instruction, ctx, prefs.style, scope)

    /**
     * The opt-in streaming draft: same candidates as [draftOnly] (unranked), but
     * [onVisible] receives the readable text as it arrives so the card can fill in
     * while the model is still writing. Deliberately outside the LRU — a cached
     * answer would defeat the point of watching it stream — and the caller keeps
     * [draftOnly] as the fallback when a server does not speak SSE.
     *
     * [judgment] 同 [draftOnly]：判断先行时的流式轮也带着判断写。
     */
    fun draftStream(
        snapshot: ChatSnapshot,
        relationship: String,
        ctx: ChatContext?,
        count: Int = 3,
        avoid: List<String> = emptyList(),
        judgment: Analysis? = null,
        intensity: Intensity = Intensity.AUTO,
        onVisible: (String) -> Unit,
        scope: HttpScope? = null
    ): List<RankedReply> =
        replyClient.draftStream(
            snapshot, relationship, ctx, count, avoid, judgment = judgment,
            style = prefs.style, intensity = intensity, onVisible = onVisible, scope = scope
        ).map { it.copy(ranked = false, prob = 0.0) }

    fun rankOnly(
        snapshot: ChatSnapshot,
        relationship: String,
        ctx: ChatContext?,
        candidates: List<RankedReply>,
        scope: HttpScope? = null
    ): List<RankedReply> {
        if (candidates.size != 3) return candidates.map { it.copy(ranked = false, prob = 0.0) }
        return judgeClient.rank(snapshot, relationship, candidates.map { it.text }, ctx, scope)
            .mapIndexed { i, ranked ->
                ranked.copy(strategy = candidates.getOrNull(i)?.strategy.orEmpty(), ranked = true)
            }
    }

    /**
     * Everything the judge prompt is built from. Same shape as the reply key minus
     * the reply-only inputs (count, avoid, style, params, ledger) plus the judge
     * route's own model and protocol, so switching either provider invalidates it.
     */
    private fun judgeKey(snapshot: ChatSnapshot, relationship: String, ctx: ChatContext?): String =
        ReplyCacheKey.judge(snapshot.title.orEmpty(), snapshot.signature(), relationship,
            prefs.judgeModel, prefs.effectiveJudgeProtocol(), judgeCtxKey(ctx, relationship))

    private fun cacheKey(
        snapshot: ChatSnapshot,
        relationship: String,
        ctx: ChatContext?,
        count: Int,
        avoid: List<String>,
        judgment: Analysis?,
        intensity: Intensity = Intensity.AUTO
    ): String {
        // 键里的 style 必须是**真正进提示词**的那段：联系人写了专用人设时它压过
        // Prefs.style，只锁 prefs.style 的话，改联系人专用人设会同键命中旧人设的
        // 候选（和专家库那次是同一类静默等价）。
        val effectiveStyle = StyleSource.resolve(prefs.style, ctx?.contact?.persona).text
        val ctxKey = replyCtxKey(ctx, relationship)
        // 台账进的是回复提示词，不进 Jev 的 state，所以它只进回复缓存键：
        // 台账一重建，上一轮的候选就必须作废。
        val ledgerKey = ctx?.ledger?.render().orEmpty()
        // 置信度驱动低置信度降级块，shouldReplyNow 驱动「可不急回」附加行——
        // 两个都改提示词，漏了就是判断变了、候选没变。
        val judgmentKey = judgment?.let {
            listOf(
                it.trueIntent?.choice, it.trueIntent?.confidence,
                it.dangerLevel?.score, it.sheNeeds?.choice, it.bestAction?.choice,
                it.shouldReplyNow
            ).joinToString("|")
        }.orEmpty()
        return ReplyCacheKey.reply(
            title = snapshot.title.orEmpty(), signature = snapshot.signature(),
            relationship = relationship, style = effectiveStyle,
            replyModel = prefs.replyModel, count = count, avoid = avoid, ctxKey = ctxKey,
            ledgerKey = ledgerKey, judgmentKey = judgmentKey, intensity = intensity.name,
            params = replyParams())
    }

    /** 采样与开关打包成一个分量：语言 / 长度 / 温度 / 两个惩罚 / 证据复查 + 模型。 */
    private fun replyParams(): String = listOf(
        prefs.replyLanguage, prefs.replyLength, prefs.replyTemperature,
        prefs.replyFrequencyPenalty, prefs.replyPresencePenalty,
        prefs.reviewEnabled, prefs.effectiveReviewModel()
    ).joinToString("|")

    /**
     * 判断侧读的上下文：background + history + skills。风格样本与 L1 技能目录是
     * 写给写手的（见 [replyCtxKey]），判断侧刻意不看——不进判断键，免得换个
     * 技能目录就把判断缓存全作废。
     */
    private fun judgeCtxKey(ctx: ChatContext?, relationship: String): String =
        ctx?.let { ctxKeyBase(it, relationship) }.orEmpty()

    /**
     * 回复侧的上下文 = 判断侧那三样 + 风格样本笔记（`knowledgeBlock` 逐条引用）
     * + 技能 L1 目录（`skillNote` 永远骑在 user prompt 最前面）。后两样谁都进
     * 提示词，谁就得进键。
     */
    private fun replyCtxKey(ctx: ChatContext?, relationship: String): String {
        ctx ?: return ""
        val styleSamples = ctx.notes.filter { it.type == NOTE_TYPE_STYLE_SAMPLE }
            .joinToString("|") { it.id + ":" + it.content }
        return ctxKeyBase(ctx, relationship) + "|" + styleSamples + "|" + ctx.catalogue
    }

    private fun ctxKeyBase(ctx: ChatContext, relationship: String): String =
        ctx.background(relationship) + "|" +
            ctx.history.joinToString("|") { h -> h.side + ":" + h.text } + "|" +
            ctx.skills.joinToString("|") { h -> h.ref.name + ":" + h.body }

    /** Judge + replies, sequential. Used by the settings connectivity test. */
    fun analyze(snapshot: ChatSnapshot, relationship: String, ctx: ChatContext? = null): Analysis {
        val a = judge(snapshot, relationship, ctx)
        if (a.error != null) return a
        val ranked = try { draftAndRank(snapshot, relationship, ctx) } catch (e: Exception) { emptyList() }
        return a.copy(rankedReplies = ranked)
    }

    companion object { private const val CACHE_SIZE = 50 }
}

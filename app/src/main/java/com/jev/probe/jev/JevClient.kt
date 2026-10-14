package com.jev.probe.jev

import com.jev.probe.core.Analysis
import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Intensity
import com.jev.probe.core.Prefs
import com.jev.probe.core.RankedReply
import com.jev.probe.core.Trace
import com.jev.probe.core.kb.ChatContext
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
     * 未排序的候选（轮内的"先写后判"路径和「再给 2 条」）。[intensity] 与
     * [draftAndRank] 共享同一份档位语义，进同一份缓存键。
     */
    fun draftOnly(
        snapshot: ChatSnapshot,
        relationship: String,
        ctx: ChatContext?,
        count: Int = 3,
        avoid: List<String> = emptyList(),
        intensity: Intensity = Intensity.AUTO,
        scope: HttpScope? = null
    ): List<RankedReply> =
        replyClient.draftOnly(snapshot, relationship, ctx, count, avoid, prefs.style, intensity, scope)

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
     */
    fun draftStream(
        snapshot: ChatSnapshot,
        relationship: String,
        ctx: ChatContext?,
        count: Int = 3,
        avoid: List<String> = emptyList(),
        intensity: Intensity = Intensity.AUTO,
        onVisible: (String) -> Unit,
        scope: HttpScope? = null
    ): List<RankedReply> =
        replyClient.draftStream(
            snapshot, relationship, ctx, count, avoid, judgment = null,
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
     * the reply-only inputs (count, avoid, style) plus the judge route's own model
     * and protocol, so switching either provider invalidates it.
     */
    private fun judgeKey(snapshot: ChatSnapshot, relationship: String, ctx: ChatContext?): String =
        listOf(snapshot.signature(), relationship, prefs.judgeModel, prefs.effectiveJudgeProtocol(),
            ctxKey(ctx, relationship)).joinToString("\u001e")

    private fun cacheKey(
        snapshot: ChatSnapshot,
        relationship: String,
        ctx: ChatContext?,
        count: Int,
        avoid: List<String>,
        judgment: Analysis?,
        intensity: Intensity = Intensity.AUTO
    ): String {
        val ctxKey = ctxKey(ctx, relationship)
        // 台账进的是回复提示词，不进 Jev 的 state，所以它只进回复缓存键：
        // 台账一重建，上一轮的候选就必须作废。
        val ledgerKey = ctx?.ledger?.render().orEmpty()
        val judgmentKey = judgment?.let {
            listOf(it.trueIntent?.choice, it.dangerLevel?.score, it.sheNeeds?.choice, it.bestAction?.choice).joinToString("|")
        }.orEmpty()
        return listOf(snapshot.signature(), relationship, prefs.style, prefs.replyModel, count,
            avoid.joinToString("\u001f"), ctxKey, ledgerKey, judgmentKey,
            intensity.name).joinToString("\u001e")
    }

    /** The knowledge/context half of both cache keys: what the model was told. */
    private fun ctxKey(ctx: ChatContext?, relationship: String): String =
        ctx?.let {
            it.background(relationship) + "|" +
                it.history.joinToString("|") { h -> h.side + ":" + h.text } + "|" +
                it.skills.joinToString("|") { h -> h.ref.name + ":" + h.body }
        }.orEmpty()

    /** Judge + replies, sequential. Used by the settings connectivity test. */
    fun analyze(snapshot: ChatSnapshot, relationship: String, ctx: ChatContext? = null): Analysis {
        val a = judge(snapshot, relationship, ctx)
        if (a.error != null) return a
        val ranked = try { draftAndRank(snapshot, relationship, ctx) } catch (e: Exception) { emptyList() }
        return a.copy(rankedReplies = ranked)
    }

    companion object { private const val CACHE_SIZE = 50 }
}

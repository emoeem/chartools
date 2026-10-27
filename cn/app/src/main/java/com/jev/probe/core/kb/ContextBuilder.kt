package com.jev.probe.core.kb

import android.content.Context
import android.util.Log
import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Prefs
import com.jev.probe.core.Trace
import com.jev.probe.core.retrieve.LexicalSearch
import com.jev.probe.core.skill.SkillHit
import com.jev.probe.core.skill.SkillMatcher
import com.jev.probe.core.skill.SkillRef
import com.jev.probe.core.skill.SkillResources
import com.jev.probe.core.skill.SkillStore

/**
 * Turns "what is on screen right now" into the extra context one analysis gets:
 * which contact this is, their older history, and which knowledge notes apply.
 *
 * Deliberately dumb and cheap (v1.3 revision): exact name/alias matching, BM25
 * note matching over character bigrams, a token budget. No embeddings, no
 * auto-created contacts. The only model work it may trigger — history summary
 * and the session ledger — arrives through [HistorySummarizer] /
 * [LedgerRefresher]; pass null and nothing leaves the device. Keeping the port
 * here is what stops core.kb from importing jev (a model client) back.
 */
/** 上一路端口：把一段旧历史压成一句摘要；失败返回 null，调用方自己兜底。 */
fun interface HistorySummarizer {
    fun summarize(transcript: String): String?
}

/** 上一路端口：旧台账 + 新增历史 → 新台账；失败返回 null，沿用旧台账。 */
fun interface LedgerRefresher {
    fun rebuild(previous: Ledger?, transcript: String, coveredUntil: Long): Ledger?
}
object ContextBuilder {

    /**
     * Notes + history together may not exceed this many tokens.
     *
     * Measured on the real imported knowledge base (113 enabled notes, 151,418
     * characters, mean note 1081 characters): a 1500-token budget cannot hold
     * one note *and* one history line at the same time, and because the trim
     * order emptied the history first, the result was 0.9 notes and 0 history
     * lines per analysis. Raising the ceiling is what makes the knowledge base
     * visible to the model at all.
     */
    const val BUDGET_TOKENS = 3000

    /**
     * History is never trimmed below this many lines. The conversation is what
     * the reply is *about*; a knowledge note is background. The old order did
     * the opposite — it dropped every history line before touching a single
     * note, so one imported chapter could silence the whole chat.
     */
    const val MIN_HISTORY = 6

    /** At most this many matched (non-always-on) notes. */
    const val MAX_HIT_NOTES = 5

    /**
     * BM25 score a note must beat to be injected.
     *
     * Low on purpose: it exists to drop the long tail of documents that only
     * share a single common bigram, not to be a relevance judgement — measured on
     * the sample library, scores run 0.1–10, so a "meaningful" threshold would
     * have to be relative to the best hit, and an absolute one here would either
     * kill everything or nothing. The real limit is [MAX_HIT_NOTES].
     */
    private const val MIN_SCORE = 0.15

    /** At most this many few-shot voice samples ride along (see [Note.type]). */
    const val MAX_STYLE_SAMPLES = 3

    /** At most this many pinned ("inject every round") skill bodies ride along. */
    const val MAX_PINNED_SKILLS = 2

    /** Score reported for a pinned skill: not a measurement, just a marker. */
    private const val PINNED_SCORE = 1.0

    /** Only the last few messages are searched for note keywords. */
    private const val MATCH_WINDOW = 30

    /** Identical on-screen copies this short are not worth de-duplicating. */
    private const val DEDUPE_MIN_LEN = 4

    /**
     * Two lines scoring at least this high on [similarity] count as the same
     * message. OCR jitter (one character misread) defeats an exact match, which
     * is how the same line ended up in the history twice.
     */
    private const val DEDUPE_SIMILARITY = 0.8

    /**
     * @param app package name of the foreground chat app (may be blank).
     * @param skillHint 上一轮判断结果的人类词（意图/需要/最该做的事），拼进技能
     *        匹配的检索词。上下文构建先于本轮判断，拿不到本轮的；上一轮的判断
     *        对「该带哪份方法论」是足够好的路标，首轮没有就传空。
     * @return context for this snapshot; every field may be empty, which is the
     *         normal state before the user has built a knowledge base.
     */
    fun build(
        context: Context,
        snapshot: ChatSnapshot,
        app: String,
        prefs: Prefs,
        skillHint: String = "",
        historySummarizer: HistorySummarizer? = null,
        ledgerRefresher: LedgerRefresher? = null
    ): ChatContext {
        val store = KbStore.get(context)
        val title = snapshot.title ?: ""

        // 1. Contact — matched only, never created here.
        val contact = store.findContact(title, app)

        // 2. History — recorded and injected only with the user's opt-in.
        val historyResult = if (prefs.contextEnabled && contact != null)
            historyFor(store, contact, snapshot, app, prefs, historySummarizer, ledgerRefresher) else HistoryResult(emptyList(), null)
        val history = historyResult.recent
        val effectiveContact = if (contact != null && !historyResult.summary.isNullOrBlank())
            contact.copy(autoSummary = historyResult.summary) else contact

        // 3. Notes — always-on ones plus keyword hits. Voice samples travel
        //    separately: they are quoted to the writer as few-shot examples and
        //    are never treated as facts (see ChatContext.background).
        val enabled = store.notes().filter { it.enabled }
        val styleSamples = enabled.filter { it.type == NOTE_TYPE_STYLE_SAMPLE }
            .sortedByDescending { it.updatedAt }.take(MAX_STYLE_SAMPLES)
        val alwaysOn = enabled.filter { it.alwaysOn && it.type != NOTE_TYPE_STYLE_SAMPLE }
        // 人设卡的主题决定哪一批笔记参加检索：选了「网调」人设就该只捞网调的内容，
        // 而不是把装修和带娃的笔记混在一起按 bigram 打分（它们会以纯噪声的形态
        // 挤掉真正相关的段）。主题为空、或没有任何笔记标过这个主题时退回全库 ——
        // 收窄只在真的命中过时才生效，见 [TopicScope.narrow]。
        val pool = enabled.filter { !it.alwaysOn && it.type != NOTE_TYPE_STYLE_SAMPLE }
        val scope = TopicScope.scopeOf(pool, TopicScope.topicOf(prefs))
        val hits = matchNotes(TopicScope.narrow(pool, scope.topic), snapshot)

        // 4. Skills — the catalogue of every enabled skill rides along (L1), and
        //    a body (L2) only when the evidence is clear: either the user pinned
        //    the skill to every round, or the local matcher scores a real hit.
        //    L3 (资源文件) 只在 L2 命中后再按本轮对话挑两三篇。
        // S4 灰度：开关关着就一行都不变（`allowedSkillNames` 会原样返回全量），
        // 打开且当前专家写了 skillRefs 时，才只留它点名的技能。
        val allSkills = SkillStore.get(context).list().filter { it.enabled }
        val boundRefs = if (prefs.expertBindingEnabled)
            PersonaStore.get(context).activeOf(prefs.style)?.skillRefs.orEmpty() else emptyList()
        val allowedNames = ExpertBinding
            .allowedSkillNames(prefs.expertBindingEnabled, boundRefs, allSkills.map { it.name })
            .toSet()
        val skills = allSkills.filter { it.name in allowedNames }
        val hay = haystack(snapshot)
        val skillHay = if (skillHint.isBlank()) hay else "$hay $skillHint"
        val pinned = skills.filter { it.always }.take(MAX_PINNED_SKILLS).map {
            SkillHit(SkillRef(it.name, it.description), it.body, PINNED_SCORE)
        }
        val matched = if (pinned.isNotEmpty()) null else SkillMatcher.match(skillHay, skills)
        val skillHits = (pinned + listOfNotNull(matched)).map { hit ->
            val skill = skills.firstOrNull { it.name == hit.ref.name }
            val extra = if (skill != null) SkillResources.select(skillHay, skill) else ""
            hit.copy(extra = extra)
        }
        val catalogue = SkillMatcher.catalogue(skills.map { SkillRef(it.name, it.description) })

        // 5. Budget: always-on notes are exempt; the rest share BUDGET_TOKENS.
        //    History is trimmed first, but only down to MIN_HISTORY lines; only
        //    after that do whole notes go (never half a note). Anything still
        //    over budget then costs history, oldest line first.
        val trimmedHistory = ArrayList(history)
        val trimmedHits = ArrayList(hits)
        while (cost(trimmedHits, trimmedHistory) > BUDGET_TOKENS && trimmedHistory.size > MIN_HISTORY)
            trimmedHistory.removeAt(0)
        while (cost(trimmedHits, trimmedHistory) > BUDGET_TOKENS && trimmedHits.isNotEmpty())
            trimmedHits.removeAt(trimmedHits.size - 1)
        while (cost(trimmedHits, trimmedHistory) > BUDGET_TOKENS && trimmedHistory.isNotEmpty())
            trimmedHistory.removeAt(0)

        Log.d(TAG, "context: contact=${contact != null} notes=${alwaysOn.size + trimmedHits.size} " +
            "history=${trimmedHistory.size} skills=${skillHits.size} style=${styleSamples.size}")
        Trace.log("ctx contact=${contact != null} notes=${alwaysOn.size + trimmedHits.size} " +
            "history=${trimmedHistory.size} skills=${skillHits.size} cat=${catalogue.length} " +
            "style=${styleSamples.size} ledger=${ledgerSummary(historyResult.ledger)} " +
            "topic=${scope.topic.ifBlank { "-" }} pool=${scope.matched}/${scope.total}" +
            (if (scope.active) " narrowed" else ""))
        return ChatContext(
            effectiveContact, trimmedHistory, alwaysOn + trimmedHits + styleSamples, skillHits,
            catalogue, historyResult.ledger
        )
    }

    /** One Trace-friendly line about the ledger: whether it exists, not its content. */
    private fun ledgerSummary(ledger: Ledger?): String {
        ledger ?: return "none"
        return "yes(t=${ledger.threads.size},b=${ledger.boundaries.size},tm=${ledger.terms.size})"
    }

    /** Everything the conversation currently says, normalised — the text both
     *  notes and skills are matched against. */
    private fun haystack(snapshot: ChatSnapshot): String = buildString {
        append(KbStore.normalizeText(snapshot.title))
        snapshot.messages.takeLast(MATCH_WINDOW).forEach {
            append('\n').append(KbStore.normalizeText(it.text))
        }
    }

    /**
     * Record the visible messages, then read back the recent window minus the
     * copies already on screen. "Already on screen" is a similarity test, not an
     * exact string compare: the same message read twice through OCR differs by a
     * character or two, and an exact match let both copies into the history.
     */
    private data class HistoryResult(
        val recent: List<LogEntry>,
        val summary: String?,
        /** S1 台账；`contextEnabled` 关着时永远是 null。 */
        val ledger: Ledger? = null
    )

    private fun historyFor(
        store: KbStore, contact: Contact, snapshot: ChatSnapshot, app: String,
        prefs: Prefs, historySummarizer: HistorySummarizer?, ledgerRefresher: LedgerRefresher?
    ): HistoryResult {
        val now = System.currentTimeMillis()
        store.appendLog(contact.id, snapshot.messages.map { LogEntry(it.side, it.text, now, app) })
        store.pruneLog(contact.id, prefs.logRetentionDays, now)
        val all = store.recentLog(contact.id, KbStore.MAX_LOG)
        val onScreen = snapshot.messages.filter { it.text.length >= DEDUPE_MIN_LEN }
            .map { it.side to bigrams(it.text) }
        val existing = store.historySummary(contact.id)
        val summary = if (all.size > 60) {
            val old = all.dropLast(20)
            val source = LedgerPolicy.transcript(old)
            if (source.isNotBlank() && historySummarizer != null &&
                store.historySummaryNeedsRefresh(contact.id, old.lastOrNull()?.ts ?: now)
            ) {
                runCatching { historySummarizer.summarize(source)?.take(200) }
                    .getOrNull()?.takeIf { it.isNotBlank() }?.also {
                        store.saveHistorySummary(contact.id, it, old.lastOrNull()?.ts ?: now)
                    } ?: existing
            } else existing
        } else existing
        val visible = all.filter { line ->
            val g = bigrams(line.text)
            onScreen.none { (side, screenGrams) ->
                side == line.side && dice(screenGrams, g) >= DEDUPE_SIMILARITY
            }
        }
        val n = prefs.contextHistoryCount.coerceIn(0, 20)
        return HistoryResult(
            if (n == 0) emptyList() else visible.takeLast(n),
            summary,
            ledgerFor(store, contact, all, prefs, ledgerRefresher)
        )
    }

    /**
     * S1：把整段历史预扫成 [Ledger]（wenyi 的「全书预扫」搬到会话上）。
     *
     * 增量更新：旧台账 + 它还没覆盖到的那部分历史 → 新版台账。这样早期说过的
     * 称呼、边界和线头不会因为滚出注入窗口而丢 —— 而「首选候选仍会选错」的
     * 症状之一正是这个。
     *
     * 三层闸门，缺一个都会让这个功能变得不可接受：
     *  1. [Prefs.ledgerEnabled] 关着就整个不做；
     *  2. `coveredUntil` 没过期就不重建（否则每一条新消息都换一次模型调用）；
     *  3. 构建失败**永远**返回上一版或 null，绝不让台账把这一轮分析带崩。
     */
    private fun ledgerFor(
        store: KbStore,
        contact: Contact,
        all: List<LogEntry>,
        prefs: Prefs,
        ledgerRefresher: LedgerRefresher?
    ): Ledger? {
        if (!prefs.ledgerEnabled || all.isEmpty()) return null
        val lastTs = all.last().ts
        if (!store.ledgerNeedsRefresh(contact.id, lastTs)) return store.ledger(contact.id)
        val previous = store.ledger(contact.id)
        val known = previous?.coveredUntil ?: 0L
        // 第一次整理只喂最近这些；之后每次只喂新增的。历史本身已经被
        // KbStore.MAX_LOG 和 token 预算两道闸限制住了。
        val fresh = LedgerPolicy.freshLines(all, known, LEDGER_MAX_LINES)
        if (fresh.isEmpty()) return previous
        val source = LedgerPolicy.transcript(fresh)
        if (source.isBlank()) return previous
        val built = ledgerRefresher?.let {
            runCatching { it.rebuild(previous, source, lastTs) }
                .onFailure { e -> Trace.log("ledger build failed: ${e.message}") }
                .getOrNull()
        } ?: return previous
        val conflicts = LedgerCheck.conflicts(built)
        if (conflicts.isNotEmpty()) {
            // 台账是增量更新的，最容易出的错是同一个称呼被写成两种 ——
            // 记录下来，这样「角色不一致」有据可查，而不是静默混进提示词。
            conflicts.forEach { Trace.log("ledger conflict: $it") }
        }
        store.saveLedger(contact.id, built)
        return built
    }

    /**
     * Dice coefficient over character bigrams, whitespace ignored: 1.0 for the
     * same text, ~0.9 for the same sentence with one character misread, 0 for
     * unrelated lines. Symmetric and cheap enough for a few hundred short lines.
     */
    internal fun similarity(a: String, b: String): Double = dice(bigrams(a), bigrams(b))

    private fun dice(x: Set<String>, y: Set<String>): Double {
        if (x.isEmpty() || y.isEmpty()) return if (x == y) 1.0 else 0.0
        var shared = 0
        for (g in x) if (g in y) shared++
        return 2.0 * shared / (x.size + y.size)
    }

    private fun bigrams(s: String): Set<String> {
        val t = s.filterNot { it.isWhitespace() }
        if (t.length < 2) return if (t.isEmpty()) emptySet() else setOf(t)
        val out = HashSet<String>(t.length)
        for (i in 0 until t.length - 1) out.add(t.substring(i, i + 2))
        return out
    }

    /**
     * A note matches when any of its tags, or its title, appears in the
     * conversation title or in the last few messages. The best
     * [MAX_HIT_NOTES] by score are injected, in score order.
     */
    internal fun matchNotes(candidates: List<Note>, snapshot: ChatSnapshot): List<Note> {
        if (candidates.isEmpty()) return emptyList()
        val query = haystack(snapshot)
        if (query.isBlank()) return emptyList()

        // Keep title/tags highly visible, but let content participate too. This
        // fixes the old "exact tag/title substring" gate: a note about "周末见面"
        // can now match "这周六要不要见面" without an embedding model.
        val documents = candidates.map { note ->
            buildString {
                append(note.title).append(' ')
                note.tags.forEach { append(it).append(' ') }
                append(note.content)
            }
        }
        val hits = LexicalSearch.search(
            query = query,
            documents = documents,
            k = MAX_HIT_NOTES,
            minScore = MIN_SCORE
        )
        // No second sort. This used to end with `sortedByDescending { updatedAt }`,
        // which threw away the ranking that was just computed and made the result
        // depend on when a note happened to be written — for a library imported in
        // one batch every note shares a timestamp, so it only looked harmless.
        return hits.map { candidates[it.index] }
    }

    private fun cost(notes: List<Note>, history: List<LogEntry>): Int =
        notes.sumOf { estimateTokens(it.title + " " + it.content) + 2 } +
            history.sumOf { estimateTokens(it.text) + 3 }

    private fun estimateTokens(text: String): Int {
        if (text.isBlank()) return 0
        var tokens = 0
        var ascii = 0
        for (c in text) {
            if (c.code < 128) ascii++ else {
                tokens += 1
            }
        }
        return tokens + ((ascii + 3) / 4)
    }

    private const val TAG = "JEVASSIST"

    /** 一次台账整理最多喂多少条历史 —— 控制首次构建的调用体积。 */
    private const val LEDGER_MAX_LINES = 120
}

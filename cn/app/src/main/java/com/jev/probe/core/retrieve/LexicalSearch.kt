package com.jev.probe.core.retrieve

import kotlin.math.ln

/** A document's relevance to a query, best first. */
data class Scored(val index: Int, val score: Double)

/**
 * BM25 over a token stream built for Chinese text.
 *
 * The tokenizer is the whole point here, not the ranking formula. A plain
 * whitespace / `\w+` tokenizer scores every Chinese query at 0.0 and then hands
 * back documents in storage order — which looks like a ranking and is not one.
 * Overlapping Han-character bigrams plus lowercased latin runs measured 4/4
 * correct on a mixed six-document sample where whitespace tokenizing managed
 * 2/4 (and both "hits" were 0.0-score ties broken by document order).
 *
 * No dependency, no model, a few hundred bytes of index: the knowledge base is
 * a handful of notes, so a linear scan is the right shape.
 */
object LexicalSearch {

    /** Standard BM25 saturation / length-normalisation constants. */
    private const val K1 = 1.2
    private const val B = 0.75

    /**
     * Han characters become overlapping bigrams ("知识库" → 知识, 识库); runs of
     * ASCII letters and digits become one lowercased token each; everything else
     * is a separator. A lone Han character produces no bigram, which is why a
     * one-character query matches nothing — one character is not a query.
     */
    fun tokenize(text: String): List<String> {
        val out = ArrayList<String>(text.length / 2 + 4)
        val word = StringBuilder()
        var inWord = false
        var previousHan = false
        var lastHan = ' '

        fun flushWord() {
            if (word.isNotEmpty()) {
                out.add(word.toString())
                word.setLength(0)
            }
            inWord = false
        }

        for (ch in text) {
            when {
                ch.code < 128 && (ch.isLetterOrDigit()) -> {
                    // Only the transition into a latin run flushes; otherwise
                    // every character would be its own token.
                    if (!inWord) { flushWord(); inWord = true }
                    previousHan = false
                    word.append(ch.lowercaseChar())
                }
                isHan(ch) -> {
                    flushWord()
                    if (previousHan) out.add("" + lastHan + ch)
                    lastHan = ch
                    previousHan = true
                }
                else -> {
                    flushWord()
                    previousHan = false
                }
            }
        }
        flushWord()
        return out
    }

    private fun isHan(ch: Char): Boolean =
        ch.code in 0x4E00..0x9FFF ||     // CJK unified ideographs
            ch.code in 0x3400..0x4DBF || // extension A
            ch.code in 0xF900..0xFAFF    // compatibility ideographs

    /**
     * Function characters: pronouns, particles, copulas, common adverbs and
     * conjunctions. A Han bigram that *contains* one of these is not a topic —
     * it is grammar. Measured on the real knowledge base, the winning document
     * for "我其实没做过sp……有点怕" was chosen on `我其` / `其实` / `实没` / `有点`:
     * every one of them either spans a word boundary or is a function word, and
     * none of them says anything about what the sentence is about. Dropping them
     * from the query leaves the terms that carry meaning (`sp`, `楼道`, `加班`).
     *
     * Only the query is filtered, not the documents: a junk bigram sitting in a
     * document can never raise its score unless the query asks for it.
     *
     * Deliberately character-level, not corpus-level. "This bigram is frequent"
     * would also delete rare-but-topical words, and the whole failure above was
     * the opposite — *rare* cross-boundary junk scoring highest because IDF
     * rewards rarity without asking whether a term means anything.
     */
    private const val STOP_CHARS =
        "的了是我你他她它们不在这有就都也吗呢吧啊哦嗯呀哈哇嘛" +
            "和与跟对把被给让从到会要能可什么怎因所以但而且或如" +
            "若虽然却之其没过多着来去做说想还再又才只很太个些样" +
            "谁哪啥得地时候现上下里中前后一二三四五六七八九十"

    private fun isNoise(term: String): Boolean =
        term.length == 2 && isHan(term[0]) && isHan(term[1]) &&
            (term[0] in STOP_CHARS || term[1] in STOP_CHARS)

    /**
     * Rank [documents] against [query]. Only documents scoring above
     * [minScore] are returned, so a caller can ask "does anything match" and a
     * no-match answer is empty rather than a list in storage order.
     */
    fun search(query: String, documents: List<String>, k: Int = 5, minScore: Double = 0.0): List<Scored> {
        if (documents.isEmpty() || k <= 0) return emptyList()
        val raw = tokenize(query).distinct()
        val filtered = raw.filterNot { isNoise(it) }
        // A one- or two-bigram query *is* one word, and the stop test is
        // character-level, so it has false positives on real words that merely
        // contain a function character — 会议 ("meeting") is not grammar just
        // because 会 is also the modal "can". With only one or two bigrams there
        // is no redundancy to fall back on, so keep them; a *long* query that
        // filters down to nothing really is all filler, and no match is right.
        val terms = if (filtered.isEmpty() && raw.size <= 2) raw else filtered
        if (terms.isEmpty()) return emptyList()

        val docs = documents.map { tokenize(it) }
        val n = docs.size
        val lengths = IntArray(n) { docs[it].size }
        val avg = if (lengths.isEmpty()) 0.0 else lengths.sum().toDouble() / n
        if (avg <= 0.0) return emptyList()

        val df = HashMap<String, Int>(terms.size * 2)
        for (term in terms) {
            var seen = 0
            for (d in docs) if (term in d) seen++
            df[term] = seen
        }

        val out = ArrayList<Scored>()
        for (i in 0 until n) {
            if (lengths[i] == 0) continue
            var score = 0.0
            for (term in terms) {
                val tf = docs[i].count { it == term }
                if (tf == 0) continue
                val d = df[term] ?: continue
                val idf = ln(1.0 + (n - d + 0.5) / (d + 0.5))
                val denom = tf + K1 * (1.0 - B + B * lengths[i] / avg)
                score += idf * (tf * (K1 + 1.0)) / denom
            }
            if (score > minScore) out.add(Scored(i, score))
        }
        out.sortWith(compareByDescending<Scored> { it.score }.thenBy { it.index })
        return if (out.size > k) ArrayList(out.subList(0, k)) else out
    }
}

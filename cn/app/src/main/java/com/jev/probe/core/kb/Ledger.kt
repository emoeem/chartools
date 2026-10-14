package com.jev.probe.core.kb

import org.json.JSONArray
import org.json.JSONObject

/**
 * 会话台账（S1，借 wenyi 的「全书预扫 → 章节摘要 + 术语表」思路）。
 *
 * 为什么要有它：注入给回复模型的原始历史是「一堆逐条消息」，模型每一轮都要
 * 从头把这些消息重新理解一遍。消息越长，越靠前的线头越容易被丢掉 —— 实测
 * 的症状就是「首选候选仍会选错」：称呼漂了、上一轮说过的边界忘了、在办的事
 * 接不上。台账把整段对话**预扫**成一份结构化卡片（称呼 / 关系 / 语气基线 /
 * 在办的事 / 已明确的边界 / 固定说法），每轮都注入，模型不用再猜。
 *
 * 与知识库的关系：台账是**从历史推导出来的**，历史本身只在用户打开
 * `Prefs.contextEnabled` 之后才落盘；台账不引入任何新的数据采集。
 *
 * 与硬约束的关系：[boundaries] 是补充，不是豁免。它由模型从聊天记录里读出，
 * 因此 [render] 明确写「台账里的边界是补充，不能取消硬性禁止」，
 * 而 [com.jev.probe.jev.ReplyPrompt] 的 safetyBans 永远在它之上。
 */
data class Ledger(
    /** 双方实际用过的称呼，以及各自怎么自称。 */
    val address: String = "",
    /** 关系现状一句话。 */
    val relation: String = "",
    /** 语气基线一句话。 */
    val tone: String = "",
    /** 还没结束的话题或约定。 */
    val threads: List<String> = emptyList(),
    /** 双方明确说过的限制、禁区、安全词。 */
    val boundaries: List<String> = emptyList(),
    /** 这一场里约定过的说法 / 角色名 / 代号。 */
    val terms: List<LedgerTerm> = emptyList(),
    /** 这份台账整理到的历史最后一条的时间戳；用来判断是否该重建。 */
    val coveredUntil: Long = 0L,
    /** 生成时间，仅用于展示与排错。 */
    val builtAt: Long = 0L
) {

    /** 什么都没有的台账不值得注入，也不值得落盘。 */
    fun isEmpty(): Boolean = address.isBlank() && relation.isBlank() && tone.isBlank() &&
        threads.isEmpty() && boundaries.isEmpty() && terms.isEmpty()

    /**
     * 注入回复提示词的那一段。空台账返回空串 —— 调用方据此整段省略，
     * 而不是塞一个「（无）」进去污染上下文。
     */
    fun render(): String {
        if (isEmpty()) return ""
        val sb = StringBuilder()
        sb.append("【会话台账】（这是已经整理好的既定情况，回复必须与它一致；台账里没有的事不要编）\n")
        if (address.isNotBlank()) sb.append("- 称呼：").append(address).append('\n')
        if (relation.isNotBlank()) sb.append("- 关系：").append(relation).append('\n')
        if (tone.isNotBlank()) sb.append("- 语气基线：").append(tone).append('\n')
        if (threads.isNotEmpty()) sb.append("- 在办的事：").append(threads.joinToString("；")).append('\n')
        if (boundaries.isNotEmpty()) {
            sb.append("- 已经明确的边界：").append(boundaries.joinToString("；")).append('\n')
        }
        if (terms.isNotEmpty()) {
            sb.append("- 固定说法（必须前后一致）：")
                .append(terms.joinToString("；") { "${it.term}=${it.value}" }).append('\n')
        }
        sb.append("- 边界只多不少：这里的边界是补充，取消不了上面的硬性禁止。\n")
        return sb.toString()
    }

    fun toJson(): JSONObject = JSONObject()
        .put("address", address)
        .put("relation", relation)
        .put("tone", tone)
        .put("threads", JSONArray(threads))
        .put("boundaries", JSONArray(boundaries))
        .put("terms", JSONArray().also { arr -> terms.forEach { arr.put(it.toJson()) } })
        .put("coveredUntil", coveredUntil)
        .put("builtAt", builtAt)

    fun encode(): String = toJson().toString()

    companion object {

        /**
         * Tolerant parse: a chat model may wrap the object in a code fence or in
         * prose. Scan to the first `{` and the last `}` rather than trusting the
         * whole string, then read only the fields we know. Anything unusable
         * comes back as an empty field — a partial ledger still helps, and a
         * garbled one must never throw into the capture path.
         */
        fun parse(raw: String, coveredUntil: Long, builtAt: Long): Ledger? {
            val o = firstJsonObject(raw) ?: return null
            return fromJson(o, coveredUntil, builtAt).let { LedgerCheck.sanitize(it) }
                .takeUnless { it.isEmpty() }
        }

        fun fromJson(o: JSONObject, coveredUntil: Long = 0L, builtAt: Long = 0L): Ledger = Ledger(
            address = o.optString("address", "").trim(),
            relation = o.optString("relation", "").trim(),
            tone = o.optString("tone", "").trim(),
            threads = stringList(o.optJSONArray("threads")),
            boundaries = stringList(o.optJSONArray("boundaries")),
            terms = termList(o.optJSONArray("terms")),
            coveredUntil = coveredUntil,
            builtAt = builtAt
        )

        /** Decode a stored ledger; a corrupt file reads as null, never throws. */
        fun decode(json: String?, coveredUntil: Long = 0L): Ledger? {
            val text = json?.trim().orEmpty()
            if (text.isEmpty()) return null
            return runCatching {
                val o = JSONObject(text)
                val l = fromJson(o, o.optLong("coveredUntil", coveredUntil), o.optLong("builtAt", 0L))
                LedgerCheck.sanitize(l).takeUnless { it.isEmpty() }
            }.getOrNull()
        }

        private fun stringList(arr: JSONArray?): List<String> {
            arr ?: return emptyList()
            val out = ArrayList<String>(arr.length())
            for (i in 0 until arr.length()) {
                val s = arr.optString(i, "").trim()
                if (s.isNotEmpty()) out.add(s)
            }
            return out
        }

        private fun termList(arr: JSONArray?): List<LedgerTerm> {
            arr ?: return emptyList()
            val out = ArrayList<LedgerTerm>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val term = o.optString("term", "").trim()
                val value = o.optString("value", "").trim()
                if (term.isNotEmpty() && value.isNotEmpty()) out.add(LedgerTerm(term, value))
            }
            return out
        }

        /**
         * The first balanced `{...}` object in [raw]. Brace counting ignores
         * braces inside string literals so a value like "他说{" does not end the
         * scan early.
         */
        private fun firstJsonObject(raw: String): JSONObject? {
            val start = raw.indexOf('{')
            if (start < 0) return null
            var depth = 0
            var inString = false
            var escaped = false
            for (i in start until raw.length) {
                val c = raw[i]
                when {
                    escaped -> escaped = false
                    c == '\\' && inString -> escaped = true
                    c == '"' -> inString = !inString
                    inString -> Unit
                    c == '{' -> depth++
                    c == '}' -> {
                        depth--
                        if (depth == 0) {
                            return runCatching { JSONObject(raw.substring(start, i + 1)) }.getOrNull()
                        }
                    }
                }
            }
            return null
        }
    }
}

/** One entry of the ledger's glossary: the word, and what it means in this thread. */
data class LedgerTerm(val term: String, val value: String) {
    fun toJson(): JSONObject = JSONObject().put("term", term).put("value", value)
}

/**
 * wenyi 的术语表冲突检测，搬到会话上：台账是**增量**更新的（上一版 + 新记录
 * → 新版本），增量最容易出的事就是同一个词在两轮里被写成两种说法，然后回复
 * 里两种混用 —— 那正是「角色不一致」。这里只做检测与清洗，不改写内容。
 */
object LedgerCheck {

    const val MAX_THREADS = 6
    const val MAX_BOUNDARIES = 6
    const val MAX_TERMS = 12
    const val MAX_LINE = 120
    const val MAX_ITEM = 160

    /**
     * 内部不一致之处，给人看的描述；空列表表示台账自洽。
     * 调用方（[com.jev.probe.core.kb.ContextBuilder]）把它写进 Trace，
     * 让「模型把称呼写漂了」这件事可见，而不是静默混进提示词。
     */
    fun conflicts(l: Ledger): List<String> {
        val out = ArrayList<String>()
        val byTerm = LinkedHashMap<String, MutableList<String>>()
        l.terms.forEach { byTerm.getOrPut(it.term) { ArrayList() }.add(it.value) }
        byTerm.forEach { (term, values) ->
            val distinct = values.distinct()
            if (distinct.size > 1) {
                out.add("术语「${term}」有 ${distinct.size} 种说法：${distinct.joinToString(" / ")}")
            }
        }
        l.terms.forEach { t ->
            if (t.term.contains("称呼") && l.address.isNotBlank() && !l.address.contains(t.value)) {
                out.add("术语「${t.term}」与台账的称呼字段不一致")
            }
        }
        val dupThreads = l.threads.groupingBy { it }.eachCount().filterValues { it > 1 }.keys
        if (dupThreads.isNotEmpty()) out.add("在办的事里有重复条目：${dupThreads.joinToString(" / ")}")
        val dupBounds = l.boundaries.groupingBy { it }.eachCount().filterValues { it > 1 }.keys
        if (dupBounds.isNotEmpty()) out.add("边界里有重复条目：${dupBounds.joinToString(" / ")}")
        return out
    }

    /**
     * Trim to the caps, drop unusable entries, keep the first spelling of a
     * duplicated term. Applied on the way in AND on the way out of storage, so a
     * hand-edited or half-written file cannot push an unbounded block into the
     * prompt.
     */
    fun sanitize(l: Ledger): Ledger {
        val seenTerms = HashSet<String>()
        val terms = ArrayList<LedgerTerm>(MAX_TERMS)
        l.terms.forEach { t ->
            val term = t.term.trim().take(MAX_LINE)
            val value = t.value.trim().take(MAX_ITEM)
            if (term.isEmpty() || value.isEmpty()) return@forEach
            val key = term.lowercase()
            if (!seenTerms.add(key)) return@forEach
            if (terms.size < MAX_TERMS) terms.add(LedgerTerm(term, value))
        }
        return l.copy(
            address = l.address.trim().take(MAX_ITEM),
            relation = l.relation.trim().take(MAX_ITEM),
            tone = l.tone.trim().take(MAX_ITEM),
            threads = clean(l.threads, MAX_THREADS),
            boundaries = clean(l.boundaries, MAX_BOUNDARIES),
            terms = terms
        )
    }

    private fun clean(items: List<String>, max: Int): List<String> {
        val seen = HashSet<String>()
        val out = ArrayList<String>(max)
        items.forEach {
            val s = it.trim().take(MAX_ITEM)
            if (s.isEmpty()) return@forEach
            if (!seen.add(s)) return@forEach
            if (out.size < max) out.add(s)
        }
        return out
    }
}

/**
 * 台账的**增量策略**。从 [ContextBuilder] 里抽出来是因为它是纯函数、能被 JVM
 * 单测钉住，而它决定两件会真出问题的事：
 *
 *  * 还该不该重建 —— 判错成「每轮都重建」就是每来一条消息多一次模型调用；
 *  * 重建时该喂哪一段 —— 喂多了白花钱，喂少了正好丢掉最靠前的线头，
 *    而丢线头正是这个功能要解决的问题本身。
 */
object LedgerPolicy {

    /** 台账还缺 [lastTs] 这段历史吗。coveredUntil 是「已整理到哪」。 */
    fun needsRebuild(coveredUntil: Long, lastTs: Long): Boolean = coveredUntil < lastTs

    /**
     * 重建时要喂给模型的那一段：上次整理之后的新增，末尾截断到 [maxLines]。
     *
     * [coveredUntil] <= 0 表示还没有台账，这时喂全部（历史本身已经被
     * `KbStore.MAX_LOG` 和 token 预算两道闸限制住了）。
     */
    fun freshLines(all: List<LogEntry>, coveredUntil: Long, maxLines: Int): List<LogEntry> =
        (if (coveredUntil <= 0L) all else all.filter { it.ts > coveredUntil }).takeLast(maxLines)

    /**
     * 把历史拼成给模型看的转写文本。和 `ReplyPrompt` 走同一套前缀规则：读不出
     * 归属的那条写「发言人不明」，绝不能默认成对方说的 —— 台账是既定事实，
     * 一条被错认成对方的台词会在之后每一轮里继续错下去。
     */
    fun transcript(lines: List<LogEntry>): String = lines.joinToString("\n") { line ->
        val who = when (line.side) {
            "me" -> "我"
            "other" -> "对方"
            else -> "发言人不明"
        }
        "$who：${line.text}"
    }
}

/**
 * 让模型把一段（或一段增量的）聊天记录整理成台账。纯字符串装配，不碰网络，
 * 于是提示词能在 JVM 单测里断言。
 */
object LedgerPrompt {

    /**
     * 输出格式固定，字段名与 [Ledger] 的 JSON 一一对应。最后三条规则是针对
     * 上一次踩到的坑：模型爱把空字段写成「无」「暂无」，爱把没发生过的事
     * 「合理推断」出来 —— 而台账是会被当成既定事实注入的，编造就直接变成
     * 回复里的假记忆。
     */
    fun system(): String =
        "你是聊天记录的整理助手。把给到的一段聊天记录整理成一份供后续回复使用的「会话台账」。\n" +
            "只输出一个 JSON 对象，不要解释，不要代码块围栏。字段固定为这六个：\n" +
            "{\"address\":\"\",\"relation\":\"\",\"tone\":\"\",\"threads\":[]," +
            "\"boundaries\":[],\"terms\":[{\"term\":\"\",\"value\":\"\"}]}\n" +
            "规则：\n" +
            "- address（称呼）：双方实际用过的称呼，以及各自怎么自称。\n" +
            "- relation（关系）：一句话说清现在是什么关系、进行到哪一步。\n" +
            "- tone（语气基线）：一句话说清两人说话的语气、节奏和亲密程度。\n" +
            "- threads（在办的事）：还没结束的话题或约定，每条一句话，最多 6 条。\n" +
            "- boundaries（边界）：双方明确说过的限制、禁区、安全词、不能碰的话题，最多 6 条。\n" +
            "- terms（固定说法）：这一场里约定过的角色名、代号、专有说法；term 是词，value 是它的含义或用法。最多 12 条。\n" +
            "- 只写记录里真实出现过的东西，不要推断、不要补全、不要写泛泛的好话。\n" +
            "- 空的内容必须是空字符串或空数组，不要写「无」「暂无」「没有」。\n" +
            "- 台账是给回复模型看的，用陈述句，不要写建议、不要写分析、不要评论。"

    /**
     * @param previous 上一版台账的 JSON（可为空）。增量更新：模型拿到旧台账
     *        加新记录，输出**完整**的新台账，旧的线头不会因为滚出窗口而丢。
     */
    fun user(previousJson: String?, transcript: String): String {
        val sb = StringBuilder()
        val prev = previousJson?.trim().orEmpty()
        sb.append(if (prev.isEmpty()) "上一版台账：无（这是第一次整理）\n"
        else "上一版台账（在此基础上补充，不要丢掉仍然有效的条目）：\n${prev}\n")
        sb.append("\n本轮要整理的新增聊天记录（越靠下越新）：\n").append(transcript.trim()).append('\n')
        sb.append("\n请输出更新后的完整台账 JSON。")
        return sb.toString()
    }
}

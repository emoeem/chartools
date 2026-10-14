package com.jev.probe.core.skill

import com.jev.probe.core.retrieve.LexicalSearch

/**
 * Deciding which skills are worth mentioning, and which one's body to pull in.
 *
 * There is no relevance engine anywhere in this ecosystem — Claude Code puts
 * the descriptions in context and lets the model choose; Google's ADK injects an
 * `<available_skills>` block and a `load_skill` tool. This app has no tool
 * calling on the reply route, so the choice has to be made locally: score the
 * conversation against the L1 catalogue with the same BM25 that ranks notes,
 * and pull in at most ONE body when the evidence is clear.
 *
 * Failing to match is cheap (the reply is what it would have been); matching
 * wrongly is not (unrelated instructions ride along), hence [MIN_TERMS]: one
 * shared bigram is a coincidence, two is a topic.
 */
object SkillMatcher {

    /** The specification's own budget for the always-on catalogue. */
    const val CATALOGUE_BUDGET = 1536

    /**
     * Absolute floor on the BM25 score. 0.3 而不是更高的旧值：BM25 的 IDF 随
     * 语料规模缩放，**单个技能**（最常见的安装形态）单文档 idf=ln(4/3)≈0.287，
     * 两个匹配词的得分上限 ≈0.57——旧门槛 0.6 意味着单技能安装几乎永远无法
     * 命中（2026-10-07 探针实测抓到）。特异性的把关在 [MIN_TERMS]（两个不同
     * 的词都出现在描述里），这个门槛只负责把 0 分平局挡在外面。
     */
    const val MIN_SCORE = 0.3

    /** Distinct query tokens that must appear in the winning description. */
    const val MIN_TERMS = 2

    /** The L1 block, XML-shaped exactly like the ADK's, capped and escaped. */
    fun catalogue(skills: List<SkillRef>): String {
        if (skills.isEmpty()) return ""
        val sb = StringBuilder("<available_skills>\n")
        var used = sb.length
        for (s in skills) {
            val entry = "<skill name=\"${escape(s.name)}\">\n" +
                "<description>${escape(s.description.trim())}</description>\n" +
                "</skill>\n"
            if (used + entry.length > CATALOGUE_BUDGET) break
            sb.append(entry)
            used += entry.length
        }
        if (used == "<available_skills>\n".length) return ""
        sb.append("</available_skills>")
        return sb.toString()
    }

    /**
     * The single best skill for this round, or null. [query] is the conversation
     * text (title + the last few messages) — the same haystack notes match on.
     */
    fun match(query: String, skills: List<Skill>): SkillHit? {
        if (query.isBlank() || skills.isEmpty()) return null
        val docs = skills.map { it.name.replace('-', ' ') + " " + it.description }
        val best = LexicalSearch.search(query, docs, k = 1, minScore = MIN_SCORE).firstOrNull() ?: return null
        val skill = skills.getOrNull(best.index) ?: return null
        val docTokens = LexicalSearch.tokenize(docs[best.index]).toHashSet()
        val hits = LexicalSearch.tokenize(query).distinct().count { it in docTokens }
        if (hits < MIN_TERMS) return null
        return SkillHit(SkillRef(skill.name, skill.description), skill.body, best.score)
    }

    private fun escape(s: String): String {
        if (s.none { it == '&' || it == '<' || it == '>' || it == '"' }) return s
        val sb = StringBuilder(s.length + 8)
        for (ch in s) when (ch) {
            '&' -> sb.append("&amp;")
            '<' -> sb.append("&lt;")
            '>' -> sb.append("&gt;")
            '"' -> sb.append("&quot;")
            else -> sb.append(ch)
        }
        return sb.toString()
    }
}

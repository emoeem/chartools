package com.jev.probe.core.skill

import com.jev.probe.core.retrieve.LexicalSearch
import java.io.File

/**
 * L3 层：命中技能后，从它自带的资源文件里按本轮对话**再挑几篇**进来。
 *
 * 为什么要有这一层：狗头军师这类语料是一本「书」（上游 44 份文件，一本 SKILL.md
 * 正文放不下），只把 SKILL.md 注入、references 全部躺在磁盘上，等于买了书不看。
 * yanwai 的做法是按关系身份选 3-5 份；这里没有可依赖的稳定「身份」字段，所以用
 * 同一个 BM25 对资源文件再打一次分——query 是本轮对话（含判断结果的词），文档是
 * 文件名 + 开头一段。两次都是本地打分，不花 token。
 *
 * 纯文件读取 + 打分，不碰 Android 类，JVM 单测可直接钉住。
 */
object SkillResources {

    /** 最多带几篇。多了会稀释 SKILL.md 正文，两三篇刚好。 */
    const val MAX_FILES = 3

    /** 参与匹配的每份文件开头长度：够判断主题，不必读完整篇。 */
    const val MATCH_HEAD = 2000

    /** 单篇注入上限：长文截断在句号附近由调用方处理，这里硬截。 */
    const val PER_FILE_CHARS = 1800

    /** 全部参考资料的总注入预算（字符）。 */
    const val BUDGET_CHARS = 4200

    /** 剩余预算低于这个值就不再塞新的一篇：截不出有意义的开头。 */
    const val MIN_USEFUL_CHARS = 200

    /** 与 [SkillMatcher.MIN_TERMS] 同一纪律：一个词是巧合，两个词是主题。 */
    const val MIN_TERMS = 2

    /**
     * 不能沿用 [SkillMatcher.MIN_SCORE]（0.6）：那个门槛是为几百条笔记的语料库
     * 调的，BM25 的 IDF 随文档数走，两三份资源文件的小语料单文档分数上限就在
     * 0.6 附近甚至更低——照抄会让任何只有一两篇参考的技能永远无法命中。区分度
     * 由 [MIN_TERMS] 承担，这里的门槛只负责把 0 分平局挡在外面。
     */
    const val MIN_SCORE = 0.1

    fun select(
        query: String,
        skill: Skill,
        maxFiles: Int = MAX_FILES,
        budgetChars: Int = BUDGET_CHARS,
        perFileChars: Int = PER_FILE_CHARS
    ): String {
        if (query.isBlank() || maxFiles <= 0 || budgetChars <= 0) return ""
        // 只要 markdown：LICENSE 没有后缀、SOURCE.txt 是元数据，都天然排除。
        val files = skill.resources().filter { it.endsWith(".md") }
        if (files.isEmpty()) return ""

        val heads = files.map { path ->
            val name = path.substringAfterLast('/').removeSuffix(".md")
            val content = runCatching { File(skill.dir, path).readText(Charsets.UTF_8) }.getOrDefault("")
            "$name ${content.take(MATCH_HEAD)}"
        }
        val scored = LexicalSearch.search(query, heads, k = maxFiles, minScore = MIN_SCORE)
            .filter { best ->
                val tokens = LexicalSearch.tokenize(heads[best.index]).toHashSet()
                LexicalSearch.tokenize(query).distinct().count { it in tokens } >= MIN_TERMS
            }
        if (scored.isEmpty()) return ""

        val sb = StringBuilder()
        var used = 0
        for (best in scored) {
            val path = files[best.index]
            val name = path.substringAfterLast('/').removeSuffix(".md")
            val content = runCatching { File(skill.dir, path).readText(Charsets.UTF_8) }
                .getOrDefault("").trim()
            if (content.isBlank()) continue
            val header = "\n【参考：$name】\n"
            val remaining = budgetChars - used
            // 剩余预算放不下一段有意义的开头就停；放得下就截断到剩余——
            // 一篇被截断的参考仍然比整篇被丢掉好。
            if (remaining - header.length < MIN_USEFUL_CHARS) break
            val capped = content.take(minOf(perFileChars, remaining - header.length))
            if (capped.isBlank()) continue
            sb.append(header).append(capped).append('\n')
            used += header.length + capped.length
        }
        return sb.toString()
    }
}

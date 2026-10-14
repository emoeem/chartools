package com.jev.probe.core.kb

import com.jev.probe.core.Prefs

/**
 * 人设主题 ↔ 知识库的联动规则。
 *
 * 用户的诉求原话是「我设置里面先选择人设，比如网调人设，然后这个时候加载我给你的
 * 那些知识库里面的内容」。这句话落到代码里是两件事：
 *
 *  1. 人设卡里的 `主题` 声明**这是哪个领域**（网调 / 装修 / 带娃）；
 *  2. 只有标了这个主题的笔记参与检索 —— 于是**换人设就等于换知识库**。
 *
 * 规则写成一个对象、而不是散在界面里和检索里，是因为界面要**预告**检索会取哪些
 * 笔记（「参与检索 679 / 679 条」）。两边必须是同一条规则，否则预告就是骗人的。
 */
object TopicScope {

    /**
     * 一次作用域判定的结果。
     *
     * @param topic   当前人设卡的主题；空白表示这份人设没有指定领域。
     * @param matched 标签命中主题的笔记数。
     * @param total   候选笔记总数（不含常驻与语气示例，与检索的口径一致）。
     * @param active  收窄**真的生效了**。false 意味着这轮按全库检索，界面必须照实说，
     *                不能让用户以为自己选了主题、实际没生效。
     */
    data class Scope(val topic: String, val matched: Int, val total: Int, val active: Boolean)

    /** 当前人设卡的主题；没填人设、或人设没写 `主题` 键时为空白。 */
    fun topicOf(prefs: Prefs): String = PersonaCard.parse(prefs.style).topic.trim()

    /**
     * 按主题收窄候选笔记。
     *
     * 两条**退回全库**的路，都是有意的：
     *  - `topic` 为空：用户没填人设（也是老行为），知识库照旧全量参与；
     *  - `topic` 非空但一条都没标：用户刚写了个新主题、笔记还没打标，这时收窄只会
     *    让知识库**突然闭嘴** —— 那比"两个领域混着用"更坏。
     * 只有真的命中过，收窄才生效。
     */
    fun narrow(notes: List<Note>, topic: String): List<Note> {
        val hit = tagged(notes, topic)
        return if (hit.isEmpty()) notes else hit
    }

    /** 供界面预告用：收窄后有多少条、总共多少条、收窄到底生没生效。 */
    fun scopeOf(notes: List<Note>, topic: String): Scope {
        val t = topic.trim()
        val matched = tagged(notes, t).size
        return Scope(t, matched, notes.size, active = t.isNotEmpty() && matched > 0)
    }

    private fun tagged(notes: List<Note>, topic: String): List<Note> {
        val t = topic.trim()
        if (t.isEmpty()) return emptyList()
        return notes.filter { n -> n.tags.any { it.trim().equals(t, ignoreCase = true) } }
    }

    /**
     * 给笔记补上主题标签（不重复加、不改动其它标签）。
     *
     * 导入时自动打标用的是它，界面上的「补标」按钮用的也是它 —— 一条已经属于
     * 「网调」的笔记再补一次必须原样返回，否则 repeated 补标会把标签越攒越多。
     */
    fun tagged(note: Note, topic: String): Note {
        val t = topic.trim()
        if (t.isEmpty()) return note
        if (note.tags.any { it.trim().equals(t, ignoreCase = true) }) return note
        return note.copy(tags = note.tags + t)
    }
}

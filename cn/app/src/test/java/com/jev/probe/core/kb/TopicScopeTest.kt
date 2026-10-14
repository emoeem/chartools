package com.jev.probe.core.kb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 人设主题 ↔ 知识库的联动。
 *
 * 这组测试守的是一条**用户看不见**的规则：收窄在什么时候生效、什么时候必须
 * 退回全库。退回的两条路都不是礼貌，是防线 —— 少一条就会让"知识库突然闭嘴"
 * 这种最坏的失败悄悄发生（用户选了主题、笔记还没打标 → 一条笔记都不进提示词，
 * 界面上却什么都没说）。
 */
class TopicScopeTest {

    private fun note(id: String, vararg tags: String) = Note(
        id = id, title = "笔记$id", content = "内容$id", tags = tags.toList()
    )

    @Test
    fun `没有主题时不收窄`() {
        val notes = listOf(note("a", "网调"), note("b", "装修"))
        assertEquals(notes, TopicScope.narrow(notes, ""))
        assertEquals(notes, TopicScope.narrow(notes, "   "))
        val scope = TopicScope.scopeOf(notes, "")
        assertFalse(scope.active)
        assertEquals(2, scope.total)
    }

    @Test
    fun `主题命中时只留标了这个主题的笔记`() {
        val notes = listOf(note("a", "网调"), note("b", "装修"), note("c", "文档导入", "网调"))
        val kept = TopicScope.narrow(notes, "网调")
        assertEquals(listOf("a", "c"), kept.map { it.id })
        val scope = TopicScope.scopeOf(notes, "网调")
        assertTrue(scope.active)
        assertEquals(2, scope.matched)
        assertEquals(3, scope.total)
    }

    /**
     * 最坏的一种失败：用户刚写了「主题：带娃」，笔记还没打标。这时收窄会把整个
     * 知识库关掉 —— 比两个领域混着用坏得多，所以必须退回全库，并且 `active=false`
     * 让界面照实说「这轮仍按全部 N 条检索」。
     */
    @Test
    fun `主题一条都没标过时必须退回全库`() {
        val notes = listOf(note("a", "网调"), note("b"))
        assertEquals(notes, TopicScope.narrow(notes, "带娃"))
        val scope = TopicScope.scopeOf(notes, "带娃")
        assertFalse(scope.active)
        assertEquals(0, scope.matched)
        assertEquals(2, scope.total)
    }

    @Test
    fun `标签匹配忽略大小写和空白`() {
        val notes = listOf(note("a", " BDSM "), note("b", "网调"))
        assertTrue(TopicScope.scopeOf(notes, "bdsm").active)
        assertTrue(TopicScope.scopeOf(notes, "网调").active)
        assertEquals(listOf("a"), TopicScope.narrow(notes, "bdsm").map { it.id })
    }

    @Test
    fun `补标签不重复加也不动其它标签`() {
        val a = note("a", "文档导入", "book.pdf")
        val once = TopicScope.tagged(a, "网调")
        assertEquals(listOf("文档导入", "book.pdf", "网调"), once.tags)
        // 再补一次必须原样返回：那个界面按钮可以连点，标签不能越攒越多。
        assertEquals(once.tags, TopicScope.tagged(once, "网调").tags)
        // 空主题不动任何东西。
        assertEquals(a.tags, TopicScope.tagged(a, "").tags)
    }

    // ------------------------------------------------------------- 回显文案

    @Test
    fun `空人设和没认出键的人设要说成不一样的话`() {
        assertTrue(PersonaStatus.line(PersonaCard.parse("")).contains("空的"))
        // 散文是静默失败：界面上必须有警告，不然用户以为自己的卡生效了。
        val free = PersonaStatus.line(PersonaCard.parse("我们在暧昧期，喜欢互怼"))
        assertTrue(free.startsWith("⚠"))
        val card = PersonaCard.parse("称呼：叫我主人\n主题：网调\n硬边界：家人、前任\n语气：短句")
        val line = PersonaStatus.line(card)
        assertTrue(line.contains("称呼「叫我主人」"))
        assertTrue(line.contains("主题「网调」"))
        assertTrue(line.contains("家人"))
    }

    @Test
    fun `作用域回显的三种状态互不混淆`() {
        val notes = listOf(note("a", "网调"), note("b"))
        val blank = PersonaStatus.scopeLine(TopicScope.scopeOf(notes, ""), 1)
        assertTrue(blank.contains("不按主题收窄"))
        assertTrue(blank.contains("1 条常驻"))

        val active = PersonaStatus.scopeLine(TopicScope.scopeOf(notes, "网调"), 0)
        assertTrue(active.contains("命中 1 条"))
        assertFalse(active.contains("常驻"))

        val fallback = PersonaStatus.scopeLine(TopicScope.scopeOf(notes, "带娃"), 0)
        assertTrue(fallback.contains("仍按全部 2 条检索"))
    }
}

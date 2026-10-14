package com.jev.probe.core.kb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 领域卡这条路的两个失败模式都很安静，所以测试盯住它们：
 *
 * 1. **采样被一份文档吃掉**。用户这套素材里最大的一本书（235,747 字 / 367 段）
 *    占全库一半以上；如果采样按长度或按顺序取，领域卡就只剩那本书的一家之言，
 *    而输出看起来「很正常」。所以这里断言小来源也在采样里出现。
 * 2. **存进去一段空壳**。模型偶尔会回一段「好的，我已归纳」或者干脆空。这种
 *    东西存成常驻笔记会每轮占掉预算，且用户完全看不出来。所以 `note()` 宁可
 *    返回 null。
 *
 * `tools/jev/build_domain_brief.py` 是同一套采样与提示词的离线版。两边必须一起改：
 * 这里断言的常量（`MAX_HAN` / `SAMPLE_CHUNK` / 六段名）就是脚本里写死的那些。
 */
class DomainBriefTest {

    private fun note(
        title: String,
        content: String,
        tags: List<String> = listOf("文档导入", "某来源.pdf"),
        enabled: Boolean = true
    ) = Note(id = title, title = title, content = content, tags = tags, enabled = enabled)

    // ------------------------------------------------------------------ 采样

    @Test
    fun hugeSourceCannotEatTheWholeSample() {
        // 一份 300 段的巨无霸 + 一份 3 段的小文档。
        val big = (1..300).map { note("大书 #$it", "大书正文".repeat(120)) }
        val small = (1..3).map { note("小文 #$it", "小文正文".repeat(120), listOf("文档导入", "小文.pdf")) }
        val sample = DomainBrief.sample(big + small)

        assertTrue("采样里没有大书的来源行", sample.contains("### 来源：某来源.pdf"))
        assertTrue("采样被大书吃光了，小来源没进来", sample.contains("### 来源：小文.pdf"))
        assertTrue("小来源的正文没进采样", sample.contains("小文正文"))
        // 长的那份也不能完全不取样。
        assertTrue(sample.contains("大书正文"))
    }

    @Test
    fun sampleStaysInsideTheBudget() {
        val notes = (1..400).map { note("n$it", "正文".repeat(400)) }
        val sample = DomainBrief.sample(notes, budgetChars = 4_000)
        val chunks = sample.split("\n").count { it.isNotBlank() }
        // 预算按「每段 400 字」折算，所以段数应该停在预算附近而不是 400。
        assertTrue("采样 $chunks 行，预算 4000 字没起作用", chunks <= 14)
    }

    @Test
    fun sampleSkipsDisabledNotesAndFallsBackToTitle() {
        val notes = listOf(
            note("关掉的", "不该出现的内容", enabled = false),
            note("只有标题没标签", "应该出现的内容", tags = emptyList())
        )
        val sample = DomainBrief.sample(notes)
        assertFalse(sample.contains("不该出现的内容"))
        assertTrue(sample.contains("应该出现的内容"))
        // 没有 tags[1] 时来源名退回标题。
        assertTrue(sample.contains("### 来源：只有标题没标签"))
    }

    @Test
    fun emptyCorpusSamplesToEmpty() {
        assertEquals("", DomainBrief.sample(emptyList()))
        assertEquals("", DomainBrief.sample(listOf(note("a", "b", enabled = false))))
    }

    // ------------------------------------------------------------- 收成笔记

    @Test
    fun noteIsAlwaysOnAndTaggedWithItsTopic() {
        val n = DomainBrief.note("角色与关系：主人与奴。\n称呼与语气：乖。", "网调", id = "fixed", now = 42L)
        assertNotNull(n)
        n!!
        assertEquals("fixed", n.id)
        assertEquals("网调领域卡（自动预扫）", n.title)
        assertTrue("领域卡必须是常驻，否则它又要靠 BM25 去猜", n.alwaysOn)
        assertTrue(n.enabled)
        assertEquals(listOf("领域卡", "网调"), n.tags)
        assertEquals("note", n.type)
        assertEquals(42L, n.updatedAt)
    }

    @Test
    fun junkOutputIsRefusedInsteadOfSavedAsAnEmptyShell() {
        assertNull(DomainBrief.note("", "网调"))
        assertNull(DomainBrief.note("   \n  \n", "网调"))
        assertNull(DomainBrief.note("OK, I have summarized the material.", "网调"))
    }

    @Test
    fun markdownDecorationIsStripped() {
        val n = DomainBrief.note(
            "```\n**角色与关系：** 主人与奴。\n**称呼与语气：** 乖。\n```", "网调")
        assertNotNull(n)
        val body = n!!.content
        assertFalse(body.contains("```"))
        assertFalse(body.contains("**"))
        assertTrue(body.contains("角色与关系："))
    }

    @Test
    fun overlongBriefIsCutAtASentenceEnd() {
        // 2000 个汉字，远超 900 上限；每 10 个字一个句号，好让断点有地方可落。
        val sentence = "这是一句话。"
        val raw = sentence.repeat(400)   // 2000 汉字
        val n = DomainBrief.note(raw, "网调")
        assertNotNull(n)
        val body = n!!.content
        assertTrue("裁完还是太长：${DomainBrief.hanCount(body)}", DomainBrief.hanCount(body) <= DomainBrief.MAX_HAN)
        assertTrue("断点没落在句末", body.endsWith("。"))
        // 不能一刀砍掉九成 —— 断点要尽量靠后。
        assertTrue("裁得太狠了：${DomainBrief.hanCount(body)}", DomainBrief.hanCount(body) > DomainBrief.MAX_HAN / 2)
    }

    @Test
    fun normalizeKeepsHanOnlyCountHonest() {
        assertEquals(0, DomainBrief.hanCount("abc 123 !!"))
        assertEquals(3, DomainBrief.hanCount("汉字三 abc"))
    }

    // ------------------------------------------------------------- 提示词

    @Test
    fun promptCarriesTheSixSectionsAndTheCap() {
        val prompt = DomainBrief.user("网调", "素材正文")
        listOf("角色与关系", "称呼与语气", "典型流程", "常用说法", "边界与安全", "不要做什么")
            .forEach { assertTrue("提示词少了「$it」这段", prompt.contains(it)) }
        assertTrue(prompt.contains(DomainBrief.MAX_HAN.toString()))
        assertTrue(prompt.contains("网调"))
        assertTrue("素材没被拼进去", prompt.contains("素材正文"))
        // 系统提示里必须写死「不要编」，因为整条路的可信度就靠这一句。
        assertTrue(DomainBrief.SYSTEM.contains("不要编"))
    }

    @Test
    fun blankTopicFallsBackToTheDefaultInsteadOfProducingAWeirdTitle() {
        assertEquals("网调领域卡（自动预扫）", DomainBrief.title(""))
        assertEquals("网调领域卡（自动预扫）", DomainBrief.title("   "))
        assertEquals("装修领域卡（自动预扫）", DomainBrief.title("装修"))
        assertTrue(DomainBrief.user("", "x").contains("网调"))
    }
}

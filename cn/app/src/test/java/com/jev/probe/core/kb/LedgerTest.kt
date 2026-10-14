package com.jev.probe.core.kb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * S1 会话台账。这里钉的是三件在实况里会真出问题的事：
 *
 *  1. 台账会被**当成既定事实**注入提示词，所以模型编出来的东西必须进不来、
 *     空字段也不能变成「无」；
 *  2. 台账是**增量**重建的（上一版 + 新记录），所以存盘再读回来这一圈不能
 *     把 coveredUntil 弄丢 —— 丢了就会每轮重扫一遍整段历史；
 *  3. [LedgerCheck.conflicts] 只报告不静默改写：称呼漂了这件事要能在 Trace 里
 *     看见，而不是被悄悄抹平。
 */
class LedgerTest {

    private fun ledger(
        address: String = "",
        relation: String = "",
        tone: String = "",
        threads: List<String> = emptyList(),
        boundaries: List<String> = emptyList(),
        terms: List<LedgerTerm> = emptyList()
    ) = Ledger(address, relation, tone, threads, boundaries, terms)

    @Test
    fun anEmptyLedgerRendersNothingSoThePromptIsNotPolluted() {
        assertEquals("", ledger().render())
        assertEquals("", Ledger().render())
        // 一个六个字段全空的答复等于「什么都没整理出来」，不是一份台账。
        assertNull(
            Ledger.parse(
                """{"address":"","relation":"","tone":"","threads":[],"boundaries":[],"terms":[]}""",
                1L, 2L
            )
        )
    }

    @Test
    fun everyFieldReachesTheRenderedBlock() {
        val block = ledger(
            address = "他叫我先生，自称小狗",
            relation = "主奴，已经线下见过两次",
            tone = "短句、命令式、带一点哄",
            threads = listOf("周末的项圈还没挑", "上一条语音还没回"),
            boundaries = listOf("不提家人", "安全词「红灯」"),
            terms = listOf(LedgerTerm("项圈", "上一轮说好要买的那个"))
        ).render()

        assertTrue(block, block.contains("【会话台账】"))
        assertTrue(block, block.contains("- 称呼：他叫我先生，自称小狗"))
        assertTrue(block, block.contains("- 关系：主奴，已经线下见过两次"))
        assertTrue(block, block.contains("- 语气基线：短句、命令式、带一点哄"))
        assertTrue(block, block.contains("- 在办的事：周末的项圈还没挑；上一条语音还没回"))
        assertTrue(block, block.contains("- 已经明确的边界：不提家人；安全词「红灯」"))
        assertTrue(block, block.contains("- 固定说法（必须前后一致）：项圈=上一轮说好要买的那个"))
    }

    /**
     * 台账里的边界是**从聊天记录里读出来的**，不是用户写的硬边界。注入提示词
     * 时它必须自己说清这一点，否则模型会以为「台账里没写」就等于「可以做」。
     */
    @Test
    fun theBoundaryLineSaysItCannotCancelTheHardBans() {
        val block = ledger(boundaries = listOf("不提家人")).render()
        assertTrue(block, block.contains("取消不了上面的硬性禁止"))
        assertTrue(block, block.contains("边界只多不少"))
        assertTrue(block, block.contains("台账里没有的事不要编"))
    }

    @Test
    fun aChattyOrFencedAnswerIsStillParsed() {
        val raw = """
            好的，我整理好了：

            ```json
            {"address":"宝宝","relation":"暧昧期","tone":"互相调侃",
             "threads":["约了周五看展"],"boundaries":[],"terms":[]}
            ```

            需要我再补别的吗？
        """.trimIndent()
        val l = Ledger.parse(raw, 100L, 200L)
        assertNotNull(l)
        assertEquals("宝宝", l!!.address)
        assertEquals("约了周五看展", l.threads.single())
        assertEquals(100L, l.coveredUntil)
        assertEquals(200L, l.builtAt)
    }

    /**
     * 括号计数必须忽略字符串字面量里的花括号，否则一句「他说{别走}」就会让扫描
     * 提前收尾，解析出一个残缺对象。
     */
    @Test
    fun bracesInsideAStringDoNotEndTheScanEarly() {
        val l = Ledger.parse(
            """{"address":"先生","relation":"他说{别走}这句话","tone":"","threads":[],"boundaries":[],"terms":[]}""",
            0L, 0L
        )
        assertNotNull(l)
        assertEquals("他说{别走}这句话", l!!.relation)
    }

    @Test
    fun garbageIsNotALedger() {
        assertNull(Ledger.parse("", 0L, 0L))
        assertNull(Ledger.parse("我无法完成这个请求。", 0L, 0L))
        assertNull(Ledger.parse("[1,2,3]", 0L, 0L))
        assertNull(Ledger.parse("{这不是 JSON}", 0L, 0L))
    }

    @Test
    fun capsApplyAndDuplicatesAreFoldedInsteadOfTrusted() {
        val many = (1..20).map { "事情$it" }
        val l = LedgerCheck.sanitize(
            ledger(
                address = "a".repeat(LedgerCheck.MAX_ITEM + 50),
                threads = many + listOf("事情1", "   ", ""),
                boundaries = (1..20).map { "边界$it" } + listOf("边界1"),
                terms = listOf(
                    LedgerTerm("项圈", "第一次的说法"),
                    LedgerTerm("项圈", "第二次的说法"),
                    LedgerTerm("", "没有词"),
                    LedgerTerm("空值", "   ")
                )
            )
        )
        assertEquals(LedgerCheck.MAX_THREADS, l.threads.size)
        assertEquals(LedgerCheck.MAX_BOUNDARIES, l.boundaries.size)
        assertEquals(LedgerCheck.MAX_ITEM, l.address.length)
        // 同一个词保留**第一次**的说法：静默换成第二种才是「前后不一致」的源头。
        assertEquals(listOf(LedgerTerm("项圈", "第一次的说法")), l.terms)
        assertTrue(l.threads.none { it.isBlank() })
        assertEquals(l.threads.distinct(), l.threads)
    }

    @Test
    fun conflictsAreReportedForTheTraceAndNotSilentlyRewritten() {
        assertTrue(LedgerCheck.conflicts(ledger(address = "先生", terms = listOf(LedgerTerm("项圈", "x")))).isEmpty())

        val drifted = ledger(
            address = "先生",
            threads = listOf("挑项圈", "挑项圈"),
            boundaries = listOf("不提家人", "不提家人"),
            terms = listOf(LedgerTerm("称呼", "主人"))
        )
        val found = LedgerCheck.conflicts(drifted).joinToString("\n")
        assertTrue(found, found.contains("与台账的称呼字段不一致"))
        assertTrue(found, found.contains("在办的事里有重复条目"))
        assertTrue(found, found.contains("边界里有重复条目"))

        val twoSpellings = LedgerCheck.conflicts(
            ledger(terms = listOf(LedgerTerm("代号", "小夜"), LedgerTerm("代号", "夜夜")))
        ).joinToString("\n")
        assertTrue(twoSpellings, twoSpellings.contains("2 种说法"))
    }

    @Test
    fun storageRoundTripKeepsTheTimestamps() {
        val original = LedgerCheck.sanitize(
            ledger(
                address = "先生", relation = "主奴", tone = "命令式",
                threads = listOf("挑项圈"), boundaries = listOf("不提家人"),
                terms = listOf(LedgerTerm("项圈", "要买的那个"))
            ).copy(coveredUntil = 1700000000123L, builtAt = 1700000000999L)
        )
        val back = Ledger.decode(original.encode())
        assertNotNull(back)
        assertEquals(original.address, back!!.address)
        assertEquals(original.threads, back.threads)
        assertEquals(original.boundaries, back.boundaries)
        assertEquals(original.terms, back.terms)
        // coveredUntil 丢了就等于每轮重扫整段历史，这条是「增量」的地基。
        assertEquals(1700000000123L, back.coveredUntil)
        assertEquals(1700000000999L, back.builtAt)
    }

    @Test
    fun aCorruptStoredFileReadsAsNullRatherThanThrowing() {
        assertNull(Ledger.decode(null))
        assertNull(Ledger.decode(""))
        assertNull(Ledger.decode("{半截"))
        assertNull(Ledger.decode("""{"address":"","relation":"","tone":"","threads":[],"boundaries":[],"terms":[]}"""))
    }

    // ---------------------------------------------------------------- the prompt

    @Test
    fun theIncrementalPromptCarriesThePreviousVersionForward() {
        val first = LedgerPrompt.user(null, "对方：在吗")
        assertTrue(first, first.contains("这是第一次整理"))
        assertFalse(first, first.contains("在此基础上补充"))
        assertTrue(first, first.contains("对方：在吗"))

        val previous = ledger(address = "先生").copy(coveredUntil = 5L).encode()
        val next = LedgerPrompt.user(previous, "对方：过来")
        assertTrue(next, next.contains("在此基础上补充"))
        assertTrue(next, next.contains(previous))
        assertTrue(next, next.contains("对方：过来"))
        assertTrue(next, next.endsWith("请输出更新后的完整台账 JSON。"))
    }

    /**
     * 上一次踩到的坑写成了规则：模型爱把空字段写成「无」「暂无」，也爱把没发生
     * 过的事「合理推断」出来 —— 而台账是被当成既定事实注入的。
     */
    @Test
    fun theSystemHalfForbidsInferenceAndPlaceholders() {
        val sys = LedgerPrompt.system()
        assertTrue(sys, sys.contains("不要推断、不要补全"))
        assertTrue(sys, sys.contains("不要写「无」「暂无」「没有」"))
        assertTrue(sys, sys.contains("用陈述句，不要写建议、不要写分析、不要评论"))
        listOf("address", "relation", "tone", "threads", "boundaries", "terms").forEach {
            assertTrue(sys, sys.contains("\"$it\""))
        }
    }

    // --------------------------------------------------- the incremental policy

    private fun line(side: String, text: String, ts: Long) = LogEntry(side, text, ts, "org.telegram.messenger")

    @Test
    fun aLedgerThatAlreadyCoversTheLastMessageIsNotRebuilt() {
        // 判错成「每轮都重建」= 每来一条消息多一次模型调用。这条闸门是成本闸。
        assertFalse(LedgerPolicy.needsRebuild(coveredUntil = 100L, lastTs = 100L))
        assertFalse(LedgerPolicy.needsRebuild(200L, 100L))
        assertTrue(LedgerPolicy.needsRebuild(100L, 200L))
        assertTrue(LedgerPolicy.needsRebuild(0L, 1L))
    }

    @Test
    fun onlyTheLinesAfterTheCoveredPointAreFedBack() {
        val all = listOf(line("other", "在吗", 10L), line("me", "在", 20L), line("other", "红灯", 30L))
        assertEquals(3, LedgerPolicy.freshLines(all, coveredUntil = 0L, maxLines = 120).size)
        val fresh = LedgerPolicy.freshLines(all, coveredUntil = 10L, maxLines = 120)
        // 已整理到 10L：只喂 20L 之后两条，10L 那条不能重复喂。
        assertEquals(listOf("在", "红灯"), fresh.map { it.text })
    }

    @Test
    fun theOldestLinesAreDroppedFirstWhenTheWindowIsFull() {
        val all = (1..10L).map { line("other", "第$it 条", it) }
        val fresh = LedgerPolicy.freshLines(all, coveredUntil = 0L, maxLines = 3)
        // 保留末尾（最新）三条：cut 掉的是最老的线头，不是最新的。
        assertEquals(listOf("第8 条", "第9 条", "第10 条"), fresh.map { it.text })
    }

    /**
     * 读不出归属的那条**不能**默认成对方说的：台账是既定事实，一条被错认成对方
     * 的台词会在之后每一轮继续错下去。这条与 `ReplyPrompt` 的前缀规则一致。
     */
    @Test
    fun anUnknownSideIsNotFedInAsTheOtherPerson() {
        val text = LedgerPolicy.transcript(
            listOf(line("me", "我到了", 1L), line("other", "好", 2L), line("?", "嗯", 3L))
        )
        assertEquals("我：我到了\n对方：好\n发言人不明：嗯", text)
        assertFalse(text, text.contains("对方：嗯"))
    }
}

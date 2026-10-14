package com.jev.probe.jev

import com.jev.probe.core.Analysis
import com.jev.probe.core.Choice
import com.jev.probe.core.Score
import com.jev.probe.core.kb.Ledger
import com.jev.probe.core.kb.PersonaCard
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * S1 证据复查。这里钉的核心是**失败即放行**：复查是排序之后多出来的一步，
 * 它只被允许把站不住的候选改好，绝不允许多删一条。实测里最贵的错误不是
 * 「三条里选错了」，而是「三条里没有一条能发」—— 所以任何解析异常、缺项、
 * 越界、空理由都必须退回「保留」。
 */
class ReplyReviewTest {

    private fun judgment() = Analysis(
        trueIntent = Choice("intimate_roleplay", 0.8, emptyMap()),
        dangerLevel = Score(1.0, 0.9, 9),
        sheNeeds = Choice("engagement", 0.7, emptyMap()),
        shouldReplyNow = null,
        bestAction = Choice("play_along", 0.7, emptyMap()),
        tensionResolved = null, literalQuestion = null,
        rankedReplies = emptyList(), latencyMs = 0
    )

    @Test
    fun aCandidateJudgedFalseWithoutAReasonIsKept() {
        // 没有理由的否决 = 没有证据。一条空理由就能删候选的话，用户根本看不到
        // 为什么少了那一条。
        val r = ReplyReview.parse("""{"verdicts":[{"index":1,"keep":false,"reason":""}]}""", 3)
        assertNotNull(r)
        assertTrue(r!!.rejected.isEmpty())
        assertEquals(3, r.verdicts.size)
        assertTrue(r.verdicts.all { it.keep })
    }

    @Test
    fun aCandidateJudgedFalseWithAReasonIsRejectedAndCarriesIt() {
        val r = ReplyReview.parse(
            """{"verdicts":[
                 {"index":1,"keep":true,"reason":""},
                 {"index":2,"keep":false,"reason":"称呼写成了「主人」，台账里是「先生」"},
                 {"index":3,"keep":true,"reason":""}]}""",
            3
        )
        assertNotNull(r)
        assertEquals(listOf(2), r!!.rejected.map { it.index })
        assertEquals("称呼写成了「主人」，台账里是「先生」", r.verdicts[1].reason)
    }

    @Test
    fun missingAndOutOfRangeIndexesAreKept() {
        val r = ReplyReview.parse(
            """{"verdicts":[{"index":2,"keep":false,"reason":"没接住对方那句"},
                            {"index":9,"keep":false,"reason":"越界"}]}""",
            3
        )
        assertNotNull(r)
        // 1 和 3 没被提到 → 保留；越界的 9 直接丢掉，不能凭空造出第四条。
        assertEquals(3, r!!.verdicts.size)
        assertEquals(listOf(2), r.rejected.map { it.index })
        assertTrue(r.verdicts[0].keep)
        assertTrue(r.verdicts[2].keep)
    }

    @Test
    fun keepTrueAlwaysCarriesAnEmptyReasonSoNoNoteIsShownForKeptItems() {
        // 模型有时会在 keep=true 时也写点好话；那句话不该变成候选下面的「理由」。
        val r = ReplyReview.parse(
            """{"verdicts":[{"index":1,"keep":true,"reason":"这条很好"}]}""", 1
        )
        assertNotNull(r)
        assertEquals("", r!!.verdicts[0].reason)
        assertTrue(r.verdicts[0].keep)
    }

    @Test
    fun aFencedOrChattyAnswerIsStillParsed() {
        val raw = """
            我逐条看了一遍：
            ```json
            {"verdicts":[{"index":1,"keep":false,"reason":"编造了没发生过的约会"}]}
            ```
            以上。
        """.trimIndent()
        val r = ReplyReview.parse(raw, 2)
        assertNotNull(r)
        assertEquals(listOf(1), r!!.rejected.map { it.index })
        assertEquals(2, r.verdicts.size)
    }

    @Test
    fun rubbishMeansNoReviewHappenedRatherThanEverythingRejected() {
        assertNull(ReplyReview.parse("", 3))
        assertNull(ReplyReview.parse("抱歉，我不能判断。", 3))
        assertNull(ReplyReview.parse("{}", 3))
        assertNull(ReplyReview.parse("""{"verdicts":[]}""", 3))
        assertNull(ReplyReview.parse("""{"verdicts":"三条都还行"}""", 3))
        assertNull(ReplyReview.parse("[keep, keep, keep]", 3))
    }

    // ---------------------------------------------------------------- the prompts

    @Test
    fun theSystemHalfStatesAllFiveStandardsAndTheExactCount() {
        val sys = ReplyReview.system(3)
        assertTrue(sys, sys.contains("3 条候选"))
        assertTrue(sys, sys.contains("有没有直接回应对方最近那条消息"))
        assertTrue(sys, sys.contains("氛围和亲密程度"))
        assertTrue(sys, sys.contains("已知的称呼、关系、固定说法"))
        assertTrue(sys, sys.contains("编造对话里没出现过的事实"))
        assertTrue(sys, sys.contains("越过已经明确的边界、禁区或安全词"))
        // 复查最容易越权的地方是「我觉得还能更好」，必须堵死。
        assertTrue(sys, sys.contains("不要因为可以更好就判 false"))
        assertTrue(sys, sys.contains("不要重写候选"))
        assertTrue(sys, sys.contains("一条都不能少"))
    }

    /**
     * 复查必须**先看到台账**才可能发现候选和称呼/边界冲突 —— 这正是它相对
     * 排序的全部增量。所以顺序是台账 → 判断 → 关系 → 对话 → 候选。
     */
    @Test
    fun theLedgerIsGivenBeforeTheCandidates() {
        val user = ReplyReview.user(
            relationship = "主奴",
            convo = "对方：过来",
            judgment = judgment(),
            ledger = Ledger(address = "先生", boundaries = listOf("安全词「红灯」")),
            candidates = listOf("来了", "马上到", "好的主人")
        )
        val at = { s: String -> user.indexOf(s) }
        assertTrue(user, at("会话台账") in 0 until at("称呼：先生"))
        assertTrue(user, at("安全词「红灯」") < at("判断结果"))
        assertTrue(user, at("判断结果") < at("关系：主奴"))
        assertTrue(user, at("关系：主奴") < at("最近对话："))
        assertTrue(user, at("最近对话：") < at("候选回复："))
        assertTrue(user, user.contains("1. 来了"))
        assertTrue(user, user.contains("3. 好的主人"))
        assertTrue(user, user.endsWith("请逐条核验并输出 JSON。"))
    }

    @Test
    fun aMissingLedgerOrJudgmentAddsNothing() {
        val user = ReplyReview.user("朋友", "对方：在吗", null, null, listOf("在的"))
        assertFalse(user, user.contains("会话台账"))
        assertFalse(user, user.contains("判断结果"))
        assertTrue(user, user.contains("关系：朋友"))
        assertTrue(user, user.contains("1. 在的"))
    }

    @Test
    fun rejectedIsExactlyTheFalseVerdicts() {
        val r = ReplyReview.parse(
            """{"verdicts":[{"index":1,"keep":false,"reason":"a"},
                            {"index":2,"keep":true,"reason":""},
                            {"index":3,"keep":false,"reason":"b"}]}""",
            3
        )
        assertNotNull(r)
        assertEquals(listOf(1, 3), r!!.rejected.map { it.index })
        assertEquals(listOf("a", "b"), r.rejected.map { it.reason })
    }

    // ------------------------------------------------------- 人设卡进复查（wenyi #1）

    /**
     * 第 3、5 条标准是「有没有和已知的称呼/边界冲突」「有没有越过已经明确的边界、
     * 禁区或安全词」—— 不给人设卡的话，复查只能拿对话里出现过的东西当判据，
     * 这两条就名存实亡。所以卡必须真的出现在提示词里，而且**逐字**：硬边界是
     * `SafetyGate` 逐字匹配的字段，改一个字就换了一套判据。
     */
    @Test
    fun thePersonaCardIsGivenToTheReviewerVerbatim() {
        val card = PersonaCard.parse(
            """
            称呼：主人
            关系：主奴
            语气：简短、命令式
            语域：亲密
            硬边界：家人、前任
            安全词：红灯
            """.trimIndent()
        )
        val user = ReplyReview.user(
            relationship = "主奴",
            convo = "对方：在吗",
            judgment = null,
            ledger = null,
            candidates = listOf("在"),
            card = card
        )
        assertTrue(user, user.contains("人设卡"))
        assertTrue("硬边界被改写了", user.contains("家人"))
        assertTrue("硬边界被改写了", user.contains("前任"))
        assertTrue("安全词没给到复查", user.contains("红灯"))
        assertTrue("称呼没给到复查", user.contains("主人"))
        // 判据在前、被判断的候选在后。
        assertTrue(user, user.indexOf("人设卡") < user.indexOf("候选回复："))
        assertTrue(user, user.endsWith("请逐条核验并输出 JSON。"))
    }

    /** 没卡时提示词必须和以前逐字一样 —— 这条是 backward-compat 的锁。 */
    @Test
    fun withoutACardNothingIsAdded() {
        val plain = ReplyReview.user("朋友", "对方：在吗", null, null, listOf("在的"))
        val explicitNull = ReplyReview.user(
            "朋友", "对方：在吗", null, null, listOf("在的"), card = null)
        assertEquals(plain, explicitNull)
        assertFalse(plain, plain.contains("人设卡"))
    }

    /** 空卡（自由文本也没写）不该塞一段空标题进去。 */
    @Test
    fun aBlankCardAddsNoHeading() {
        val user = ReplyReview.user(
            "朋友", "对方：在吗", null, null, listOf("在的"), card = PersonaCard.parse(null))
        assertFalse(user, user.contains("人设卡"))
    }

    @Test
    fun theSystemHalfTellsTheReviewerWhatTheCardIsFor() {
        val sys = ReplyReview.system(3)
        assertTrue(sys, sys.contains("人设卡"))
        // 没给卡时必须说清退化成什么，否则模型会自己脑补一套边界。
        assertTrue(sys, sys.contains("不要自己脑补对方有什么边界"))
    }

    /** 第 6 条管复读：内容全对的候选也可能只是把上一轮的指令再说一遍。 */
    @Test
    fun theReviewChecksForRepetitionToo() {
        val sys = ReplyReview.system(3)
        assertTrue(sys, sys.contains("6. 有没有复读"))
        assertTrue(sys, sys.contains("已经说过的话或已经下过的指令"))
        assertTrue(sys, sys.contains("只看这六条"))
    }
}

package com.jev.probe.jev

import com.jev.probe.core.Msg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression for the refine path. The conversation used to reach the model as
 * the literal text `${who}：${it.text}`: the loop was rebuilt inside `refine()`
 * out of four concatenated string literals instead of one template, so `who` and
 * `it.text` were never evaluated and the model got a placeholder line where the
 * latest messages should have been. These assert on the string that is actually
 * assembled, with no Prefs, no Context and no network.
 */
class ReplyClientPromptTest {

    private val convo = convoLines(
        listOf(
            Msg("other", "你昨天说的那家店叫什么"),
            Msg("me", "我想想"),
            Msg("other", "又想不起来了？")
        )
    )

    @Test
    fun theConversationReachesThePromptAsRealText() {
        assertEquals("对方：你昨天说的那家店叫什么\n我：我想想\n对方：又想不起来了？", convo)
    }

    @Test
    fun noTemplatePlaceholderSurvivesIntoTheRefinePrompt() {
        val prompt = refineUserPrompt(
            "女朋友", null, 30, "口语一点", "改短", "在的在的，那家店叫老地方", convo)
        assertTrue(prompt, prompt.contains("老地方"))
        assertTrue(prompt, prompt.contains("又想不起来了？"))
        assertFalse(prompt, prompt.contains("\${who}"))
        assertFalse(prompt, prompt.contains("\${it.text}"))
    }

    @Test
    fun theRefineInstructionAndTheOriginalBothReachThePrompt() {
        val prompt = refineUserPrompt("朋友", null, 30, "", "换轻松一点的语气", "收到，我马上处理", convo)
        assertTrue(prompt, prompt.contains("换轻松一点的语气"))
        assertTrue(prompt, prompt.contains("收到，我马上处理"))
        assertTrue(prompt, prompt.contains("不要原样照抄原回复"))
    }

    @Test
    fun anUnreadableSideIsNeverPresentedAsTheOtherPerson() {
        val unknown = convoLines(listOf(Msg("unknown", "可能是对方说的"), Msg("me", "嗯")))
        assertTrue(unknown, unknown.startsWith("发言人不明："))
        assertFalse(unknown, unknown.contains("对方："))
    }

    @Test
    fun onlyTheLastTwentyMessagesAreQuoted() {
        // 20 而不是 10：用户实测 Telegram 反馈「分不清上下文」——快节奏聊天里
        // 十条之前的设定全部出窗。窗口边界在这里钉死，第 21 条（从尾部数）出窗。
        val many = (1..26).map { Msg("other", "第 ${it} 条") }
        val lines = convoLines(many)
        assertFalse(lines, lines.contains("第 1 条\n"))
        assertFalse(lines, lines.contains("第 6 条\n"))
        assertTrue(lines, lines.startsWith("对方：第 7 条"))
        assertTrue(lines, lines.endsWith("对方：第 26 条"))
        // 恰好 20 条时一条不丢。
        val exact = (1..20).map { Msg("other", "第 ${it} 条") }
        assertTrue(convoLines(exact), convoLines(exact).contains("第 1 条\n"))
    }
}

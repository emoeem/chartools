package com.jev.probe.core.kb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The persona note is the one place a user can aim the assistant, so it has two
 * jobs that pull in opposite directions: carry structure when the user writes
 * structure, and otherwise stay exactly as it was.
 *
 * "Otherwise stay exactly as it was" is the load-bearing half. Every contact note
 * and every global style note written before cards existed is free text, and those
 * still have to reach the prompt verbatim — if a stray colon could turn a note into
 * a card, the wording would silently change for existing users.
 */
class PersonaCardTest {

    @Test
    fun freeTextIsReturnedVerbatim() {
        val note = "我们在暧昧期，喜欢互怼，别太正经"
        val card = PersonaCard.parse(note)
        assertFalse(card.structured)
        assertFalse(card.registerOpen)
        assertEquals(note, card.promptText())
    }

    @Test
    fun freeTextWithAColonButNoKnownKeyIsStillFreeText() {
        // A colon is not what makes a card — a recognised key is. A note like this
        // must not be reformatted into a block, or the prompt changes for no reason.
        val note = "我们：暧昧期，喜欢互怼"
        val card = PersonaCard.parse(note)
        assertFalse(card.structured)
        assertEquals(note, card.promptText())
    }

    @Test
    fun blankInputIsEmptyNotBroken() {
        assertFalse(PersonaCard.parse(null).hasContent())
        assertFalse(PersonaCard.parse("   \n  ").hasContent())
        assertEquals("", PersonaCard.parse(null).promptText())
    }

    @Test
    fun aKeyValueCardCarriesEveryField() {
        val card = PersonaCard.parse(
            """
            称呼：先生
            关系：主奴
            语气：克制，短句，不解释
            情境：书房，晚上
            硬边界：不要提家人、不要留痕
            安全词：红灯
            示例：
            我：今天想你了
            对方：嗯，等着
            """.trimIndent()
        )
        assertTrue(card.structured)
        assertEquals("先生", card.address)
        assertEquals("主奴", card.relation)
        assertEquals("克制，短句，不解释", card.tone)
        assertEquals("书房，晚上", card.scene)
        assertEquals("红灯", card.safeword)
        // The raw phrase is kept AND reduced to the word the gate matches against the
        // other side's text — "不要提家人" alone would never match a real message.
        assertTrue(card.boundaries.toString(), card.boundaries.contains("不要提家人"))
        assertTrue(card.boundaries.toString(), card.boundaries.contains("家人"))
        assertTrue(card.boundaries.toString(), card.boundaries.contains("不要留痕"))
        assertEquals(listOf("我：今天想你了", "对方：嗯，等着"), card.examples)

        val prompt = card.promptText()
        assertTrue(prompt, prompt.startsWith("<persona_card>"))
        assertTrue(prompt, prompt.endsWith("</persona_card>"))
        assertTrue(prompt, prompt.contains("称呼：先生"))
        assertTrue(prompt, prompt.contains("硬边界（这些内容绝不可以出现在回复里）："))
        assertTrue(prompt, prompt.contains("不要提家人"))
        assertTrue(prompt, prompt.contains("不要留痕"))
        // The 「示例：」 header introduces the lines below it; it is not a value, so it
        // must not come back as a 补充 line the model would read as an instruction.
        assertFalse(prompt, prompt.contains("补充：示例"))
        assertTrue(prompt, prompt.contains("我：今天想你了"))
        // The examples are style samples, not conversation: the model must not
        // answer "今天想你了" as if it had just been said.
        assertTrue(prompt, prompt.contains("只学语气和称呼，不是当前对话内容"))
    }

    @Test
    fun englishKeysAndCardV2ExampleLinesAreAccepted() {
        val card = PersonaCard.parse(
            """
            address: sir
            tone: clipped
            語域: roleplay
            示例:
            我：late again
            对方：I noticed
            """.trimIndent()
        )
        // "語域" is the traditional form — not a key this app claims to know, so
        // this card is judged by what it does contain.
        assertTrue(card.structured)
        assertEquals("sir", card.address)
        assertEquals("clipped", card.tone)
        assertFalse(card.registerOpen)
        assertEquals(listOf("我：late again", "对方：I noticed"), card.examples)
    }

    @Test
    fun theRegisterIsOpenedOnlyByAnExplicitKey() {
        // Free text saying "亲密" must NOT open it: that would let an ordinary style
        // note re-enable the 「主人」 register the prompt bans by default.
        val free = PersonaCard.parse("关系很亲密，随便聊")
        assertFalse(free.registerOpen)

        assertTrue(PersonaCard.parse("语域：亲密").registerOpen)
        assertTrue(PersonaCard.parse("register: roleplay").registerOpen)
        assertTrue(PersonaCard.parse("语域：开").registerOpen)
        assertTrue(PersonaCard.parse("mode: intimate").registerOpen)
    }

    @Test
    fun theRegisterStaysShutWhenTheCardSaysSo() {
        // Chinese "不开" contains the "开" that would otherwise read as a yes.
        assertFalse(PersonaCard.parse("语域：不开").registerOpen)
        assertFalse(PersonaCard.parse("语域：关闭").registerOpen)
        assertFalse(PersonaCard.parse("register: off").registerOpen)
        assertFalse(PersonaCard.parse("语域：默认").registerOpen)
    }

    @Test
    fun aLimitPhraseAlsoYieldsItsKeyword() {
        // Users write limits as instructions ("不要叫我主人"), but the gate has to
        // match what the other person actually sends, which is the bare keyword.
        val card = PersonaCard.parse("硬边界：不要叫我主人，不要提分手，不提家人")
        assertTrue(card.boundaries.toString(), card.boundaries.contains("不要叫我主人"))
        assertTrue(card.boundaries.toString(), card.boundaries.contains("主人"))
        assertTrue(card.boundaries.toString(), card.boundaries.contains("分手"))
        assertTrue(card.boundaries.toString(), card.boundaries.contains("家人"))
    }

    @Test
    fun unknownLinesAreKeptAsExtraRatherThanDropped() {
        val card = PersonaCard.parse(
            """
            关系：同事
            她最近在赶一个大项目，别催她
            """.trimIndent()
        )
        assertTrue(card.structured)
        assertEquals("同事", card.relation)
        assertTrue(card.extra.toString(), card.extra.contains("她最近在赶一个大项目，别催她"))
        assertTrue(card.promptText(), card.promptText().contains("她最近在赶一个大项目，别催她"))
    }

    @Test
    fun aUrlIsNotMistakenForAKey() {
        val card = PersonaCard.parse("语气：随便\n头像链接 http://example.com/a.png")
        assertTrue(card.structured)
        assertEquals("随便", card.tone)
        assertTrue(card.extra.toString(), card.extra.any { it.contains("http://example.com") })
    }

    @Test
    fun theYellowLightIsItsOwnFieldNotASafeword() {
        // 2026-10-07 实测聊天记录里对方真实使用了「黄灯哦」；而旧的
        // 「安全词：红灯停、黄灯缓」写法会把黄灯塞进安全词里一起硬拦。黄灯的
        // 语义是减速确认，必须是独立的键。
        val card = PersonaCard.parse("关系：主奴\n语域：亲密\n安全词：红灯\n黄灯：黄灯")
        assertTrue(card.structured)
        assertEquals("红灯", card.safeword)
        assertEquals("黄灯", card.yellow)
        val prompt = card.promptText()
        assertTrue(prompt, prompt.contains("黄灯：黄灯"))
        assertTrue(prompt, prompt.contains("减速确认"))
        // 没写黄灯的卡不得凭空多出黄灯段。
        val bare = PersonaCard.parse("关系：主奴\n安全词：红灯")
        assertFalse(bare.promptText(), bare.promptText().contains("黄灯："))
    }
}

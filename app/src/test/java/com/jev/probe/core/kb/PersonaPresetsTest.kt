package com.jev.probe.core.kb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 模板的全部价值都在「它真的被解析成结构化卡」上。
 *
 * 这一条很容易看起来像废话：模板就是几行字，`PersonaCard` 又是容错的（认不出的
 * 键不报错，直接塞进 `补充`）。两件事叠在一起就意味着 —— 我把 `主题` 写成
 * `主题方向`、把 `硬边界` 写成 `底线要求`，模板照样「能用」，只是 `topic` 空着、
 * `boundaries` 空着，回复一点没变。用户看不见这个失败：他填了人设，回复照旧。
 *
 * 所以这里断言的不是「模板非空」，而是**每一行都被认出来了**（`extra` 必须为空）
 * 且各个键真的落到了对应的字段上。模板以后再加一张，这条测试会替它把关。
 */
class PersonaPresetsTest {

    @Test
    fun everyPresetParsesIntoEveryKeyItClaims() {
        assertTrue(PersonaPresets.ALL.size >= 3)
        PersonaPresets.ALL.forEach { (name, body) ->
            val card = PersonaCard.parse(body)
            assertTrue("「$name」没被当成结构化卡，退回了自由文本", card.structured)
            assertTrue(name, card.hasContent())
            // 关键：没有任何一行落进「补充」。落进去就说明那个键我不认识 ——
            // 而 `PersonaCard` 认不出键时是静默的，只有这条能发现。
            assertEquals("「$name」里有没被识别的键：${card.extra}", emptyList<String>(), card.extra)
            assertTrue("「$name」缺少称呼", card.address.isNotBlank())
            assertTrue("「$name」缺少关系", card.relation.isNotBlank())
            assertTrue("「$name」缺少语气", card.tone.isNotBlank())
            assertTrue("「$name」缺少主题", card.topic.isNotBlank())
            // 硬边界必须拆成闸门能逐字匹配的关键词。写成整句「不要提家人」时
            // 拆出来的仍是「家人」，但若模板写成散文就成了死条目。
            assertTrue("「$name」硬边界没拆出关键词", card.boundaries.isNotEmpty())
            assertTrue("「$name」没有语气样例", card.examples.isNotEmpty())

            val prompt = card.promptText()
            assertTrue(prompt, prompt.contains("主题："))
            assertTrue(prompt, prompt.contains("硬边界"))
        }
    }

    @Test
    fun theRoleplayPresetsOpenTheRegisterAndTheDailyOneDoesNot() {
        val byName = PersonaPresets.ALL.toMap()
        listOf("网调·我是主", "网调·我是奴").forEach { name ->
            val card = PersonaCard.parse(byName.getValue(name))
            assertEquals(name, "网调", card.topic)
            // 「语域：亲密」是放开角色化称呼和情境描写的唯一开关。模板没写这一行，
            // 整张卡就只剩一个拘谨的普通助手。
            assertTrue("「$name」没打开语域", card.registerOpen)
            assertTrue(name, card.safeword.isNotBlank())
            assertFalse("「$name」的硬边界应当只有关键词", card.boundaries.any { it.length > 4 })
        }
        val daily = PersonaCard.parse(byName.getValue("日常"))
        assertEquals("日常", daily.topic)
        // 日常卡故意不写语域：它会放开角色化称呼，普通聊天不该被放开。
        assertFalse(daily.registerOpen)
    }

    @Test
    fun topicIsRenderedIntoThePromptAndKeepsItsDefinition() {
        val card = PersonaCard.parse("主题：网调\n语域：亲密")
        assertTrue(card.structured)
        assertEquals("网调", card.topic)
        val prompt = card.promptText()
        assertTrue(prompt, prompt.contains("主题：网调"))
        // 「主题」不是给模型看的标签，它得说清该怎么用：回复要落在这个领域的
        // 规矩/步骤/说法里，而不是通用安慰。
        assertTrue(prompt, prompt.contains("通用安慰"))
    }

    @Test
    fun topicAcceptsTheOtherSpellings() {
        assertEquals("网调", PersonaCard.parse("领域：网调").topic)
        assertEquals("网调", PersonaCard.parse("topic: 网调").topic)
        assertEquals("网调", PersonaCard.parse("domain：网调").topic)
    }

    @Test
    fun anUnknownTopicSpellingFallsBackToFreeTextInsteadOfGuessing() {
        // 认不出「主题方向」时不能猜成 topic —— 猜错比不认更坏：用户会以为自己
        // 设置生效了。整张卡没有别的键，于是退回自由文本，`topic` 为空。
        val card = PersonaCard.parse("主题方向：网调")
        assertFalse(card.structured)
        assertEquals("", card.topic)
    }

    @Test
    fun theRoleplayPresetsCarryADistinctYellowLight() {
        // 「安全词：红灯停、黄灯缓」的旧写法会把黄灯塞进硬拦截词里。两个网调模板
        // 必须是「红灯归安全词、黄灯独立成键」，且黄灯这个词本身要能被逐字匹配到。
        val byName = PersonaPresets.ALL.toMap()
        listOf("网调·我是主", "网调·我是奴").forEach { name ->
            val card = PersonaCard.parse(byName.getValue(name))
            assertTrue("「$name」没写黄灯", card.yellow.isNotBlank())
            assertTrue("「$name」的黄灯要能匹配对方说的「黄灯」", card.yellow.contains("黄灯"))
            assertFalse("「$name」的黄灯不能混进安全词", card.safeword.contains("黄灯"))
        }
    }
}

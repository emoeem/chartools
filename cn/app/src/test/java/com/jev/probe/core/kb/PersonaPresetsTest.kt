package com.jev.probe.core.kb

import com.jev.probe.core.safety.SafetyGate
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
            // 硬边界/避谈不要求每张都有——日常卡就该一张约束都不带（家人/工作
            // 写成硬边界会拦掉朋友的最普通的话）。各卡的具体约束面由
            // dailyAndSalesPresetsDoNotBlockOrdinaryMentions 和
            // theRoleplayPresetsOpenTheRegisterAndTheDailyOneDoesNot 分别钉。
            assertTrue("「$name」没有语气样例", card.examples.isNotEmpty())

            val prompt = card.promptText()
            assertTrue(prompt, prompt.contains("主题："))
            if (card.boundaries.isNotEmpty()) assertTrue(prompt, prompt.contains("硬边界"))
            if (card.avoid.isNotEmpty()) assertTrue(prompt, prompt.contains("避谈"))
        }
    }

    /**
     * 2026-10-22 修正的回归锁：日常卡的旧写法「硬边界：家人、工作」和销售卡的
     * 「硬边界：稳赚、保证收益」都会在**对方**那条消息里出现这些词时掐掉整轮
     * 候选——朋友说一句「最近工作好累」、客户问一句「能稳赚吗」，恰好是最需要
     * 回复的一轮。这些词现在要么删掉（日常），要么挪进避谈（销售，只约束我方
     * 措辞）。闸门仍然认网调卡的家人/前任——那是真的「对方一提就该停」。
     */
    @Test
    fun dailyAndSalesPresetsDoNotBlockOrdinaryMentions() {
        val byName = PersonaPresets.ALL.toMap()

        val daily = PersonaCard.parse(byName.getValue("日常"))
        assertTrue("日常卡不该再有硬边界", daily.boundaries.isEmpty())
        assertFalse(
            SafetyGate.check(listOf("最近工作好累，家里事也多"), daily).blocked
        )

        val sales = PersonaCard.parse(byName.getValue("销售·跟单"))
        assertTrue("销售卡的稳赚/保证收益应该是避谈不是硬边界", sales.avoid.contains("稳赚"))
        assertTrue(sales.avoid.contains("保证收益"))
        assertTrue("销售卡不该再有硬边界", sales.boundaries.isEmpty())
        assertFalse(
            "客户问收益不该掐掉整轮",
            SafetyGate.check(listOf("这个项目能稳赚吗？保证收益吗"), sales).blocked
        )
        // 避谈真的进提示词：模型被明说这两个词不许出现在回复里。
        assertTrue(sales.promptText(), sales.promptText().contains("避谈"))
        assertTrue(sales.promptText(), sales.promptText().contains("稳赚"))

        val roleplay = PersonaCard.parse(byName.getValue("网调·我是主"))
        assertTrue("网调卡的家人仍是硬边界", roleplay.boundaries.contains("家人"))
        assertTrue(
            "网调场景对方提家人仍然要拦",
            SafetyGate.check(listOf("说起我家人"), roleplay).blocked
        )
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

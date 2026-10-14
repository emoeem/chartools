package com.jev.probe.jev

import com.jev.probe.core.Analysis
import com.jev.probe.core.Intensity
import com.jev.probe.core.Choice
import com.jev.probe.core.Score
import com.jev.probe.core.kb.ChatContext
import com.jev.probe.core.kb.Contact
import com.jev.probe.core.kb.Ledger
import com.jev.probe.core.kb.LogEntry
import com.jev.probe.core.kb.NOTE_TYPE_STYLE_SAMPLE
import com.jev.probe.core.kb.Note
import com.jev.probe.core.kb.PersonaCard
import com.jev.probe.core.skill.SkillHit
import com.jev.probe.core.skill.SkillRef
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The last mile of the skill feature: whatever the matcher decides, it only
 * matters if it reaches the prompt. These assert exactly that, with no Prefs,
 * no Context and no network.
 */
class ReplyPromptTest {

    private fun context(
        notes: List<Note> = emptyList(),
        history: List<LogEntry> = emptyList(),
        skills: List<SkillHit> = emptyList(),
        catalogue: String = ""
    ) = ChatContext(null, history, notes, skills, catalogue)

    private fun hit(name: String = "pirate-signature") = SkillHit(
        SkillRef(name, "让候选回复带上海盗口吻"),
        "每条回复的最后一行必须单独是：——来自加勒比",
        1.0
    )

    @Test
    fun anEmptyContextSaysNothing() {
        assertEquals("", ReplyPrompt.knowledgeBlock("朋友", context(), 30))
        assertEquals("", ReplyPrompt.skillNote(context()))
        assertEquals("", ReplyPrompt.knowledgeBlock("朋友", null, 30))
        assertEquals("", ReplyPrompt.skillNote(null))
    }

    @Test
    fun aMatchedSkillBodyIsQuotedIntoTheUserPrompt() {
        val block = ReplyPrompt.knowledgeBlock("朋友", context(skills = listOf(hit())), 30)
        assertTrue(block, block.contains("技能「pirate-signature」的完整说明"))
        assertTrue(block, block.contains("——来自加勒比"))
    }

    @Test
    fun theCatalogueRidesOnEveryRoundEvenWithNoBody() {
        val ctx = context(catalogue = "<available_skills>\n<skill name=\"pirate-signature\">" +
            "<description>让候选回复带上海盗口吻</description></skill>\n</available_skills>")
        // No skill hit this round: the body must NOT appear...
        val body = ReplyPrompt.knowledgeBlock("朋友", ctx, 30)
        assertFalse(body, body.contains("——来自加勒比"))
        // ...but the catalogue still must.
        val note = ReplyPrompt.skillNote(ctx)
        assertTrue(note, note.contains("<available_skills>"))
        assertTrue(note, note.contains("pirate-signature"))
        assertTrue(note, note.contains("你必须按那份说明来写"))
    }

    @Test
    fun aPathologicalBodyIsTruncatedNotDropped() {
        val huge = "x".repeat(ReplyPrompt.SKILL_BODY_MAX + 500)
        val block = ReplyPrompt.knowledgeBlock(
            "朋友",
            context(skills = listOf(SkillHit(SkillRef("big", "d"), huge, 1.0))),
            30
        )
        assertTrue(block, block.contains("技能「big」的完整说明"))
        assertTrue(block, !block.contains("x".repeat(ReplyPrompt.SKILL_BODY_MAX + 1)))
    }

    @Test
    fun notesAndHistoryStillPrecedeTheSkillBlock() {
        val ctx = context(
            notes = listOf(Note(id = "n1", title = "住址", content = "他住在杭州")),
            history = listOf(LogEntry("other", "在吗", 1L, "com.tencent.tim")),
            skills = listOf(hit())
        )
        val block = ReplyPrompt.knowledgeBlock("朋友", ctx, 30)
        val notesAt = block.indexOf("杭州")
        val historyAt = block.indexOf("在吗")
        val skillAt = block.indexOf("技能「")
        assertTrue(block, notesAt in 0 until historyAt)
        assertTrue(block, historyAt < skillAt)
    }

    @Test
    fun contactBackgroundIsUsedWhenThereIsOne() {
        val ctx = ChatContext(
            Contact(id = "c1", name = "张三", relationship = "同事", notes = "喜欢猫"),
            emptyList(), emptyList(), emptyList(), ""
        )
        val block = ReplyPrompt.knowledgeBlock("同事", ctx, 30)
        assertTrue(block, block.contains("喜欢猫"))
    }

    /**
     * The instruction that produced "主人不要伤害我？" for a flirting thread: the
     * old prompt ordered one candidate to be "简短低姿态", and a model asked for
     * a deferential line on a partner-relationship thread writes one. The ban
     * has to stay in the prompt, and the count has to stay in the JSON contract.
     */
    @Test
    fun theDraftingPromptBansTheGrovellingThatCameBack() {
        val sys = ReplyPrompt.systemPrompt(3)
        assertFalse(sys, sys.contains("低姿态"))
        assertTrue(sys, sys.contains("不要卑微求饶"))
        assertTrue(sys, sys.contains("不要角色扮演式台词"))
        assertTrue(sys, sys.contains("「主人」"))
        assertTrue(sys, sys.contains("3 个对象"))
        // One candidate still has to push the thread forward, just not abjectly.
        assertTrue(sys, sys.contains("推进话题"))
    }

    @Test
    fun theJudgmentReachesTheDraftingPromptWithItsToneAdvice() {
        val light = Analysis(
            trueIntent = Choice("casual_chat", 0.8, emptyMap()),
            dangerLevel = Score(1.0, 0.9, 9),
            sheNeeds = Choice("nothing", 0.6, emptyMap()),
            shouldReplyNow = 0.9,
            bestAction = Choice("make_plan", 0.5, emptyMap()),
            tensionResolved = 0.2, literalQuestion = 0.1,
            rankedReplies = emptyList(), latencyMs = 10
        )
        val block = ReplyPrompt.judgmentBlock(light)
        assertTrue(block, block.contains("日常闲聊或打趣"))
        assertTrue(block, block.contains("1/9"))
        assertTrue(block, block.contains("什么都不需要"))
        assertTrue(block, block.contains("约个具体的事"))
        assertTrue(block, block.contains("局势轻松"))

        val tense = ReplyPrompt.judgmentBlock(light.copy(dangerLevel = Score(9.0, 0.9, 9)))
        assertTrue(tense, tense.contains("局势偏紧"))
        assertFalse(tense, tense.contains("局势轻松"))
    }

    @Test
    fun aMissingJudgmentAddsNothing() {
        assertEquals("", ReplyPrompt.judgmentBlock(null))
    }

    /**
     * The user's own tone note rides above the defaults but the bans still hold —
     * otherwise "playful" quietly re-opens the role-play door.
     */
    @Test
    fun theUserStyleNoteIsQuotedButDoesNotOverrideTheBans() {
        assertEquals("", ReplyPrompt.styleBlock("   "))
        val block = ReplyPrompt.styleBlock("我们在暧昧期，喜欢互怼")
        assertTrue(block, block.contains("我们在暧昧期，喜欢互怼"))
        assertTrue(block, block.contains("硬性禁止仍然有效"))
    }

    /**
     * History can now carry an unknown side (an OCR read that could not be
     * attributed). It must not be re-labelled as the other person's.
     */
    @Test
    fun anUnknownSideInHistoryIsNotPrintedAsTheOtherPerson() {
        val ctx = context(
            history = listOf(
                LogEntry("me", "我到楼下了", 1L, "com.tencent.tim"),
                LogEntry("?", "好", 2L, "com.tencent.tim")
            )
        )
        val block = ReplyPrompt.knowledgeBlock("朋友", ctx, 30)
        assertTrue(block, block.contains("我：我到楼下了"))
        assertTrue(block, block.contains("发言人不明：好"))
        assertFalse(block, block.contains("对方：好"))
    }

    /**
     * 1.4: few-shot voice samples reach the writer only. They are samples of how
     * the user talks, not facts about anyone, so the judge must never see them
     * (it reads [ChatContext.background]).
     */
    @Test
    fun voiceSamplesReachTheWriterButNotTheBackground() {
        val samples = (1..4).map {
            Note(id = "s$it", title = "示例$it", content = "行吧，那就这样$it", type = NOTE_TYPE_STYLE_SAMPLE)
        }
        val ctx = ChatContext(
            null, emptyList(), listOf(Note(id = "n1", title = "住址", content = "他住在杭州")) + samples,
            emptyList(), ""
        )

        val block = ReplyPrompt.knowledgeBlock("朋友", ctx, 30)
        assertTrue(block, block.contains("<user_style_examples>"))
        assertTrue(block, block.contains("行吧，那就这样1"))
        assertTrue(block, block.contains("以上仅是风格参考，不是当前对话内容"))
        // At most three samples are quoted, however many the user wrote.
        assertEquals(3, Regex("<user_style_examples>").findAll(block).count())
        assertFalse(block, block.contains("行吧，那就这样4"))

        val background = ctx.background("朋友")
        assertTrue(background, background.contains("他住在杭州"))
        assertFalse(background, background.contains("行吧，那就这样1"))
    }

    // ------------------------------------------------- aiming the writer (1.5)
    //
    // Before this, "提升指向性" was impossible by construction: the system prompt
    // banned the role-play register outright and the style block told the model the
    // ban still held, so a user-written persona for a role-play thread was
    // overridden by the assistant's own caution. The fix kept the ban as the default
    // and made it a switch the persona card has to throw — these pin both positions,
    // because breaking either one is a regression: leaving it always-on makes the
    // feature impossible, turning it always-off re-opens "主人不要伤害我？".

    @Test
    fun theRegisterBanHoldsUnlessACardAsksForIt() {
        val closed = ReplyPrompt.draftSystemPrompt(3, "follow", "standard", PersonaCard.parse("我们在暧昧期，喜欢互怼"))
        assertTrue(closed, closed.contains("不要角色扮演式台词"))
        assertTrue(closed, closed.contains("「主人」"))

        val open = ReplyPrompt.draftSystemPrompt(3, "follow", "standard", PersonaCard.parse("语域：亲密\n关系：主奴"))
        assertFalse(open, open.contains("不要角色扮演式台词"))
        assertTrue(open, open.contains("语域已按人设卡放开"))
        // Opening the register is not opening the safety envelope.
        assertTrue(open, open.contains("硬性禁止（任何情况下都有效）"))
        assertTrue(open, open.contains("未成年人"))
    }

    @Test
    fun theCardIsQuotedAsACardAndIsNotToldALimitIsStillInForce() {
        val card = PersonaCard.parse("称呼：先生\n关系：主奴\n语域：亲密\n硬边界：不要提家人")
        val block = ReplyPrompt.styleBlock(card.promptText(), card.registerOpen)
        assertTrue(block, block.contains("称呼：先生"))
        assertTrue(block, block.contains("硬边界"))
        assertTrue(block, block.contains("安全红线仍然有效"))
        assertFalse(block, block.contains("但硬性禁止仍然有效"))
    }

    @Test
    fun aFreeTextNoteStillReadsAsBefore() {
        // Byte-for-byte the wording the app sent before cards existed.
        val free = PersonaCard.parse("我们在暧昧期，喜欢互怼")
        assertEquals(
            "我想要的语气和人设（比上面的默认风格优先，但硬性禁止仍然有效）：\n我们在暧昧期，喜欢互怼\n\n",
            ReplyPrompt.styleBlock(free.promptText(), free.registerOpen)
        )
    }

    @Test
    fun anIntimateSceneIsNotReadAsSmallTalk() {
        val a = Analysis(
            trueIntent = Choice("intimate_roleplay", 0.8, emptyMap()),
            dangerLevel = Score(1.0, 0.9, 9),
            sheNeeds = null, shouldReplyNow = null, bestAction = null,
            tensionResolved = null, literalQuestion = null,
            rankedReplies = emptyList(), latencyMs = 0
        )
        val block = ReplyPrompt.judgmentBlock(a)
        assertTrue(block, block.contains("在按我们约好的关系/称呼往下推进这一场"))
        assertTrue(block, block.contains("接着对方刚给的情境往下写"))
        assertFalse(block, block.contains("不要沉重、不要突然深情"))
    }

    @Test
    fun anIntimateSceneCarriesAProgressionRuleNotARitualLoop() {
        // 2026-10-07 实测聊天记录：整场复读「跪好 / 报数 / 请安」，10→0 的倒计时
        // 跑了三遍，最后卡死在「先报规矩」说不清规矩是什么——对方的评语是
        // 「不好玩到爆」。「接着往下写」不定义清楚，模型就会读成「再发一遍指令」，
        // 所以推进的定义必须落在亲密分支里。
        val a = Analysis(
            trueIntent = Choice("intimate_roleplay", 0.8, emptyMap()),
            dangerLevel = Score(1.0, 0.9, 9),
            sheNeeds = null, shouldReplyNow = null, bestAction = null,
            tensionResolved = null, literalQuestion = null,
            rankedReplies = emptyList(), latencyMs = 0
        )
        val block = ReplyPrompt.judgmentBlock(a)
        assertTrue(block, block.contains("往前走一步"))
        assertTrue(block, block.contains("一整场只说一次"))
        assertTrue(block, block.contains("接住那个回答"))
        assertFalse(block, block.contains("局势偏紧"))
    }

    @Test
    fun theSystemPromptFightsTheTemplateCadence() {
        // 同一场实测的另一半：「AI味十足」——每条都是「命令＋规矩＋下一步」的
        // 固定节奏。反模板与自检放在 system 层，任何分支、任何人设卡都绕不开。
        val sys = ReplyPrompt.systemPrompt(3)
        assertTrue(sys, sys.contains("同一个模子"))
        assertTrue(sys, sys.contains("输出前自检"))
        assertTrue(sys, sys.contains("不要连环下命令"))
    }

    @Test
    fun knowledgeAndHistoryCarryTheAntiRepetitionNotes() {
        // 领域卡的「常用说法」把高频词喂进了每一轮；历史里的「我：」行是模型自己
        // 发过的。两处都要注明「参考 ≠ 台词」，否则模型把它们当必背内容复读。
        val ctx = context(
            history = listOf(
                LogEntry("me", "跪好，现在报数", 1L, "com.tencent.tim"),
                LogEntry("other", "10 9 8 7 6 5 4 3 2 1 0", 2L, "com.tencent.tim")
            )
        )
        val block = ReplyPrompt.knowledgeBlock("朋友", ctx, 30)
        assertTrue(block, block.contains("不是每轮都要用一遍的台词"))
        assertTrue(block, block.contains("里面已经说过的指令和说法不要重复"))
    }

    @Test
    fun aMatchedSkillsResourcesRideAlongWithTheirOwnRules() {
        // L3：狗头军师这类语料的 references/*.md 由 SkillResources 按轮挑选，
        // 注入时必须带上「方法 ≠ 套路、不许问卷建档」的使用规则——原文是写给
        // 连续对话机器人的，不重申这三条它就会让用户去填问卷。
        val ctx = context(skills = listOf(
            SkillHit(
                SkillRef("goutoujunshi", "恋爱军师方法论"), "SKILL BODY", 1.0,
                extra = "【参考：07-沟通冲突与修复】\n吵架之后先修复情绪，再分清事实。\n")
        ))
        val block = ReplyPrompt.knowledgeBlock("朋友", ctx, 30)
        assertTrue(block, block.contains("【参考：07-沟通冲突与修复】"))
        assertTrue(block, block.contains("提供方法，不照抄套路"))
        assertTrue(block, block.contains("不要据此向用户提问或要求建档"))
        // 没挑到资源的技能不得多出参考资料段。
        val bare = ReplyPrompt.knowledgeBlock("朋友", context(skills = listOf(hit())), 30)
        assertFalse(bare, bare.contains("【参考："))
    }

    @Test
    fun judgmentWordsHumanizeTheLastVerdictForSkillMatching() {
        val a = Analysis(
            trueIntent = Choice("vent_anger", 0.9, emptyMap()),
            dangerLevel = Score(6.0, 0.9, 9),
            sheNeeds = Choice("care", 0.7, emptyMap()),
            shouldReplyNow = null,
            bestAction = Choice("acknowledge", 0.7, emptyMap()),
            tensionResolved = null, literalQuestion = null,
            rankedReplies = emptyList(), latencyMs = 0
        )
        val words = ReplyPrompt.judgmentWords(a)
        assertTrue(words, words.contains("在发泄情绪"))
        assertTrue(words, words.contains("被在乎、被安慰"))
        assertTrue(words, words.contains("先承认对方的感受"))
        assertTrue(words, words.contains("局势紧张"))
        // 局势不紧时不喊「冲突」，免得每轮都往方法论上撞。
        val calm = a.copy(dangerLevel = Score(1.0, 0.9, 9))
        val calmWords = ReplyPrompt.judgmentWords(calm)
        assertFalse(calmWords, calmWords.contains("局势紧张"))
        assertEquals("", ReplyPrompt.judgmentWords(null))
    }

    @Test
    fun theDefaultRoundKeepsThePromptUnchanged() {
        // 自动档解析成「自然」时必须返回空串——默认轮次的提示词和没有档位
        // 功能之前逐字节一致，这是向后兼容的锁。
        val card = PersonaCard.parse("")
        val bare = ReplyPrompt.draftUserPrompt("朋友", context(), 30, null, card, "", "对方：在吗", emptyList(), 2)
        val withAuto = ReplyPrompt.draftUserPrompt(
            "朋友", context(), 30, null, card, "", "对方：在吗", emptyList(), 2, Intensity.AUTO)
        assertEquals(bare, withAuto)
        assertEquals("", ReplyPrompt.intensityBlock(Intensity.AUTO, null))
        assertEquals("", ReplyPrompt.intensityBlock(Intensity.NATURAL, null))
    }

    @Test
    fun theIntensityBlockSteersTheRound() {
        // 自动档 + 高紧张 → 收着：说明是自动选的，且禁止推进动作。
        val tense = Analysis(
            trueIntent = Choice("vent_anger", 0.9, emptyMap()),
            dangerLevel = Score(7.0, 0.9, 9),
            sheNeeds = null, shouldReplyNow = null, bestAction = null,
            tensionResolved = null, literalQuestion = null,
            rankedReplies = emptyList(), latencyMs = 0
        )
        val soft = ReplyPrompt.intensityBlock(Intensity.AUTO, tense)
        assertTrue(soft, soft.contains("收着"))
        assertTrue(soft, soft.contains("自动档"))
        assertTrue(soft, soft.contains("不要发出邀约"))
        // 手选加码覆盖自动收着：不推翻用户，但第一条留作承接。
        val forward = ReplyPrompt.intensityBlock(Intensity.FORWARD, tense)
        assertTrue(forward, forward.contains("加码"))
        assertTrue(forward, forward.contains("仍按这个选择写"))
        assertTrue(forward, forward.contains("第一条留作承接"))
        // 手选收着：不带加码的风险句。
        val manualSoft = ReplyPrompt.intensityBlock(Intensity.SOFT, tense)
        assertTrue(manualSoft, manualSoft.contains("以稳妥承接为主"))
        assertFalse(manualSoft, manualSoft.contains("仍按这个选择写"))
    }

    @Test
    fun theIntensityBlockSitsBetweenJudgmentAndCaution() {
        // 档位是对判断的解读，紧随其后；caution 在它后面，不能被埋掉。
        val card = PersonaCard.parse("")
        val tense = Analysis(
            trueIntent = Choice("vent_anger", 0.9, emptyMap()),
            dangerLevel = Score(7.0, 0.9, 9),
            sheNeeds = null, shouldReplyNow = null, bestAction = null,
            tensionResolved = null, literalQuestion = null,
            rankedReplies = emptyList(), latencyMs = 0
        )
        val prompt = ReplyPrompt.draftUserPrompt(
            "朋友", null, 30, tense, card, "出现了需要留神的信号", "对方：你怎么这样",
            emptyList(), 3, Intensity.AUTO)
        val at = { s: String -> prompt.indexOf(s) }
        assertTrue(prompt, at("判断结果") in 0 until at("本轮推进档位"))
        assertTrue(prompt, at("本轮推进档位") < at("需要留神的信号"))
        assertTrue(prompt, prompt.contains("请给出 3 条候选回复。"))
    }

    @Test
    fun aFlatReplyIsNotAReasonToPushHarder() {
        // The live run had a partner answer "哦" and then "嗯哪", and all three
        // candidates piled on another order. docx02 puts it plainly: those one-word
        // replies carry very different moods, and misreading one is how a scene gets
        // stuck. The rule lives in the system half so no card can argue it away.
        val sys = ReplyPrompt.systemPrompt(3)
        assertTrue(sys, sys.contains("不要顺着上一轮继续加码"))
        assertTrue(sys, sys.contains("敷衍"))
        // Inside an intimate scene the same exception has to be spelled out, because
        // that branch otherwise says the opposite ("接着对方刚给的情境往下写").
        val a = Analysis(
            trueIntent = Choice("intimate_roleplay", 0.8, emptyMap()),
            dangerLevel = Score(2.0, 0.9, 9),
            sheNeeds = Choice("nothing", 0.6, emptyMap()), shouldReplyNow = null,
            bestAction = Choice("say_less", 0.6, emptyMap()),
            tensionResolved = null, literalQuestion = null,
            rankedReplies = emptyList(), latencyMs = 0
        )
        val block = ReplyPrompt.judgmentBlock(a)
        assertTrue(block, block.contains("先停下来确认对方怎么了"))
        assertTrue(block, block.contains("接着对方刚给的情境往下写"))
    }

    @Test
    fun aRealFightStillOutranksTheScene() {
        // An intimate thread whose danger score is genuinely high must still get the
        // de-escalation advice: the scene reading is not a licence to ignore it.
        val a = Analysis(
            trueIntent = Choice("intimate_roleplay", 0.8, emptyMap()),
            dangerLevel = Score(8.0, 0.9, 9),
            sheNeeds = null, shouldReplyNow = null,
            bestAction = Choice("say_less", 0.6, emptyMap()),
            tensionResolved = null, literalQuestion = null,
            rankedReplies = emptyList(), latencyMs = 0
        )
        val block = ReplyPrompt.judgmentBlock(a)
        assertTrue(block, block.contains("局势偏紧"))
        assertFalse(block, block.contains("接着对方刚给的情境往下写"))
    }

    @Test
    fun theNewJudgeAnswersReadAsSentencesNotKeys() {
        val a = Analysis(
            trueIntent = Choice("intimate_roleplay", 0.8, emptyMap()),
            dangerLevel = Score(1.0, 0.9, 9),
            sheNeeds = Choice("engagement", 0.7, emptyMap()), shouldReplyNow = null,
            bestAction = Choice("play_along", 0.7, emptyMap()),
            tensionResolved = null, literalQuestion = null,
            rankedReplies = emptyList(), latencyMs = 0
        )
        val block = ReplyPrompt.judgmentBlock(a)
        assertTrue(block, block.contains("接着对方的设定往下写"))
        assertTrue(block, block.contains("被接住、顺着这个情境继续"))
        assertFalse(block, block.contains("play_along"))
        assertFalse(block, block.contains("engagement"))
    }

    @Test
    fun theCautionBlockIsEmptyWhenThereIsNothingToSay() {
        assertEquals("", ReplyPrompt.cautionBlock(""))
        assertEquals("", ReplyPrompt.cautionBlock("   "))
        val block = ReplyPrompt.cautionBlock("出现了「威胁」，确认这是双方自愿、不是被推着走")
        assertTrue(block, block.contains("需要留神的信号"))
        assertTrue(block, block.contains("不要顺着这些方向推"))
    }

    @Test
    fun theDraftPromptLayersKnowledgeThenJudgmentThenCard() {
        val card = PersonaCard.parse("称呼：先生\n关系：主奴\n语域：亲密")
        val judgment = Analysis(
            trueIntent = Choice("intimate_roleplay", 0.8, emptyMap()),
            dangerLevel = Score(1.0, 0.9, 9),
            sheNeeds = Choice("engagement", 0.7, emptyMap()), shouldReplyNow = null,
            bestAction = Choice("play_along", 0.7, emptyMap()),
            tensionResolved = null, literalQuestion = null,
            rankedReplies = emptyList(), latencyMs = 0
        )
        val prompt = ReplyPrompt.draftUserPrompt(
            "主奴", context(), 30, judgment, card, "出现了未成年人信号「16岁」，先确认年龄再往下走",
            "对方：过来", emptyList(), 3)

        val at = { s: String -> prompt.indexOf(s) }
        assertTrue(prompt, at("判断结果") in 0 until at("需要留神的信号"))
        assertTrue(prompt, at("需要留神的信号") < at("称呼：先生"))
        assertTrue(prompt, at("称呼：先生") < at("关系：主奴"))
        assertTrue(prompt, at("关系：主奴") < at("最近对话："))
        assertTrue(prompt, prompt.endsWith("请给出 3 条候选回复。"))
    }

    @Test
    fun theAvoidListStillRidesAlongAndCanBeEmpty() {
        val card = PersonaCard.parse("")
        val bare = ReplyPrompt.draftUserPrompt("朋友", context(), 30, null, card, "", "对方：在吗", emptyList(), 2)
        assertFalse(bare, bare.contains("已经给过"))

        val withAvoid = ReplyPrompt.draftUserPrompt(
            "朋友", context(), 30, null, card, "", "对方：在吗", listOf("在的", "怎么了"), 2)
        assertTrue(withAvoid, withAvoid.contains("已经给过"))
        assertTrue(withAvoid, withAvoid.contains("- 在的"))
        assertTrue(withAvoid, withAvoid.contains("- 怎么了"))
    }

    // ------------------------------------------------------- the session ledger (S1)
    //
    // 台账是 S1 的全部主张：整段对话预扫成一份卡片，每轮都带上，称呼、在办的
    // 事、说过的边界就不会因为滚出注入窗口而丢。它必须落在**原始历史之前** ——
    // 先给「既定情况」再给逐条原文，模型才不会从头猜。

    private fun contextWithLedger(
        ledger: Ledger,
        history: List<LogEntry> = emptyList(),
        notes: List<Note> = emptyList()
    ) = ChatContext(null, history, notes, emptyList(), "", ledger)

    @Test
    fun theLedgerIsStatedBeforeTheRawHistory() {
        val ctx = contextWithLedger(
            Ledger(address = "先生", relation = "主奴", boundaries = listOf("不提家人")),
            history = listOf(LogEntry("other", "过来", 1L, "org.telegram.messenger"))
        )
        val prompt = ReplyPrompt.draftUserPrompt(
            "主奴", ctx, 30, null, PersonaCard.parse(""), "", "对方：过来", emptyList(), 3)

        val at = { s: String -> prompt.indexOf(s) }
        assertTrue(prompt, at("【会话台账】") in 0 until at("更早的聊天记录"))
        assertTrue(prompt, at("称呼：先生") < at("更早的聊天记录"))
        assertTrue(prompt, at("更早的聊天记录") < at("对方：过来"))
        assertTrue(prompt, prompt.contains("取消不了上面的硬性禁止"))
    }

    @Test
    fun aLedgerAloneStillProducesTheKnowledgeBlock() {
        // 没有任何笔记、没有被匹配到的技能、历史为 0，台账自己也要能把这一段
        // 撑起来 —— 否则新会话第一轮就白整理了。
        val block = ReplyPrompt.knowledgeBlock("朋友", contextWithLedger(Ledger(tone = "互相调侃，节奏很快")), 30)
        assertTrue(block, block.contains("以下是关于我和对方的背景与知识库"))
        assertTrue(block, block.contains("互相调侃"))
    }

    @Test
    fun aContextWithoutALedgerIsUnchanged() {
        // 回归位：没开台账的会话，提示词里不能多出任何「会话台账」字样。
        val ctx = context(
            notes = listOf(Note(id = "n1", title = "住址", content = "他住在杭州")),
            history = listOf(LogEntry("other", "在吗", 1L, "com.tencent.tim"))
        )
        assertEquals("", ReplyPrompt.knowledgeBlock("朋友", ctx, 30).let {
            if (it.contains("会话台账")) "leaked" else ""
        })
    }

    @Test
    fun anEmptyLedgerAddsNothingToThePrompt() {
        // Ledger() 的 render() 是空串，此时 knowledgeBlock 的早退条件必须照旧成立。
        assertEquals("", ReplyPrompt.knowledgeBlock("朋友", contextWithLedger(Ledger()), 30))
    }

    /**
     * 台账只进**回复**提示词。Jev 的 state（判断）走 [ChatContext.background]，
     * 而 background 不认识 ledger —— 判断结果必须继续只看关系/笔记/摘要，
     * 否则判断会被一份模型自己写的摘要有偏差地带跑。
     */
    @Test
    fun theLedgerDoesNotReachTheBackgroundThatTheJudgeReads() {
        val ctx = contextWithLedger(
            Ledger(address = "先生", relation = "主奴"),
            notes = listOf(Note(id = "n1", title = "住址", content = "他住在杭州"))
        )
        val background = ctx.background("朋友")
        assertTrue(background, background.contains("他住在杭州"))
        assertFalse(background, background.contains("会话台账"))
        assertFalse(background, background.contains("先生"))
    }
}

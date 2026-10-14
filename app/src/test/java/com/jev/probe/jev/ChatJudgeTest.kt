package com.jev.probe.jev

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The chat-mode judgment path: the same 7 questions rendered into one prompt,
 * and a chat model's reply normalized back into the `answers` object the
 * `decisions` protocol returns. This is what makes DeepSeek usable as the
 * judge route, so the normalization edges are worth pinning down.
 */
class ChatJudgeTest {

    private val questions = JevQuestions.judge()

    private fun state() = JSONObject().put("chat", JSONObject()
        .put("relationship", "女朋友")
        .put("latest_from", "other")
        .put("messages", JSONArray()
            .put(JSONObject().put("from", "other").put("text", "你昨天又忘了？"))
            .put(JSONObject().put("from", "me").put("text", "对不起，是我不好"))))

    /** A reply shaped the way DeepSeek answers: fence, prose, all 7 answers. */
    private val deepSeekReply = """
        Sure, here is the judgment:

        ```json
        {
          "answers": {
            "literal_question": {"noul": 0.2, "confidence": 0.8},
            "true_intent": {"choice": "confirm_you_care", "confidence": 0.7,
                            "probabilities": {"confirm_you_care": 0.7, "vent_anger": 0.2, "casual_chat": 0.1}},
            "danger_level": {"score": 4, "confidence": 0.6},
            "should_reply_now": {"noul": false, "confidence": 0.9},
            "she_needs": {"choice": "care", "confidence": 0.55,
                          "probabilities": {"care": 0.55, "apology": 0.45}},
            "best_action": {"choice": "apologize", "confidence": 0.6, "probabilities": {"apologize": 1.0}},
            "tension_resolved": {"noul": "0.15", "confidence": 0.5}
          }
        }
        ```
    """.trimIndent()

    @Test
    fun `prompt carries the conversation and every question`() {
        val prompt = ChatJudge.userPrompt(state(), questions)
        assertTrue(prompt.contains("你昨天又忘了？"))
        assertTrue(prompt.contains("me: 对不起，是我不好"))
        for (id in questions.keys()) assertTrue("missing $id", prompt.contains("id: $id"))
        // The danger scale is spelled out 0..9, which is what keeps a chat model
        // from answering on Jev's own 0..9 scale by accident (or 1..10).
        assertTrue(prompt.contains("0 = Light chat or joking"))
        assertTrue(prompt.contains("9 = Active rupture"))
        assertTrue(prompt.contains("=== ANSWER ==="))
    }

    @Test
    fun `body is a pinned chat turn`() {
        val b = ChatJudge.body("deepseek-chat", state(), questions, jsonMode = true)
        assertEquals("deepseek-chat", b.getString("model"))
        assertEquals(0.0, b.getDouble("temperature"), 0.0)
        assertFalse(b.getBoolean("stream"))
        assertEquals("json_object", b.getJSONObject("response_format").getString("type"))
        val msgs = b.getJSONArray("messages")
        assertEquals(2, msgs.length())
        assertEquals("system", msgs.getJSONObject(0).getString("role"))
        assertTrue(msgs.getJSONObject(1).getString("content").contains("=== QUESTIONS ==="))
    }

    @Test
    fun `body without json mode drops response_format`() {
        val b = ChatJudge.body("deepseek-chat", state(), questions, jsonMode = false)
        assertFalse(b.has("response_format"))
    }

    @Test
    fun `fenced reply normalizes into the decisions answer shape`() {
        val answers = ChatJudge.answersFrom(deepSeekReply, questions)
        assertEquals(questions.keys().asSequence().toSet(), answers.keys().asSequence().toSet())

        val intent = JudgeAnswers.choice(answers.optJSONObject("true_intent"))!!
        assertEquals("confirm_you_care", intent.choice)
        assertEquals(0.7, intent.confidence, 1e-9)
        assertEquals(0.2, intent.probabilities["vent_anger"]!!, 1e-9)

        // The heart of it: level 4 of Jev's ten danger criteria, and the legend
        // is what turns into the "4/9" the overlay prints.
        val danger = JudgeAnswers.score(answers.optJSONObject("danger_level"))!!
        assertEquals(4.0, danger.score, 1e-9)
        assertEquals(9, danger.maxLevel)

        assertEquals(0.2, answers.getJSONObject("literal_question").getDouble("noul"), 1e-9)
        assertEquals(0.0, answers.getJSONObject("should_reply_now").getDouble("noul"), 1e-9)
        assertEquals(0.15, answers.getJSONObject("tension_resolved").getDouble("noul"), 1e-9)
    }

    @Test
    fun `bare answers object without the wrapper is accepted`() {
        val content = """{"true_intent":{"choice":"vent_anger","confidence":0.4}}"""
        val answers = ChatJudge.answersFrom(content, questions)
        assertEquals("vent_anger", answers.getJSONObject("true_intent").getString("choice"))
        assertEquals(1, answers.length())
    }

    @Test
    fun `off-menu choice is left unanswered rather than guessed`() {
        val content = """{"true_intent":{"choice":"be_nice","confidence":0.9}}"""
        val answers = ChatJudge.answersFrom(content, questions)
        assertFalse(answers.has("true_intent"))
        assertNull(JudgeAnswers.choice(answers.optJSONObject("true_intent")))
    }

    @Test
    fun `choice can come from probabilities alone or from echoed option text`() {
        val byProbs = ChatJudge.answersFrom(
            """{"true_intent":{"probabilities":{"vent_anger":0.8,"casual_chat":0.2}}}""", questions)
        assertEquals("vent_anger", byProbs.getJSONObject("true_intent").getString("choice"))

        val byText = ChatJudge.answersFrom(
            """{"true_intent":{"choice":"They want a concrete action, time, deliverable, or commitment from you now, and this is a real ask, not a loyalty test."}}""",
            questions)
        assertEquals("request_action", byText.getJSONObject("true_intent").getString("choice"))
    }

    @Test
    fun `keys are matched case-insensitively and bare values accepted`() {
        val content = """{"Answers":{"True_Intent":{"Choice":"Vent_Anger"},"Should_Reply_Now":true}}"""
        val answers = ChatJudge.answersFrom(content, questions)
        assertEquals("vent_anger", answers.getJSONObject("true_intent").getString("choice"))
        assertEquals(1.0, answers.getJSONObject("should_reply_now").getDouble("noul"), 1e-9)
    }

    @Test
    fun `bare values land in the field their question type expects`() {
        val answers = ChatJudge.answersFrom(
            """{"danger_level":4,"literal_question":"0.2","should_reply_now":"false"}""", questions)
        assertEquals(4.0, JudgeAnswers.score(answers.getJSONObject("danger_level"))!!.score, 1e-9)
        assertEquals(0.2, answers.getJSONObject("literal_question").getDouble("noul"), 1e-9)
        assertEquals(0.0, answers.getJSONObject("should_reply_now").getDouble("noul"), 1e-9)
    }

    @Test
    fun `score accepts echoed criterion text and clamps out-of-range levels`() {
        val echoed = ChatJudge.answersFrom(
            """{"danger_level":{"score":"Active rupture: they said it is over, told you not to reply, deleted you, or are exploding."}}""",
            questions)
        assertEquals(9.0, JudgeAnswers.score(echoed.getJSONObject("danger_level"))!!.score, 1e-9)

        val tooHigh = ChatJudge.answersFrom("""{"danger_level":{"score":42}}""", questions)
        assertEquals(9.0, JudgeAnswers.score(tooHigh.getJSONObject("danger_level"))!!.score, 1e-9)

        val tooLow = ChatJudge.answersFrom("""{"danger_level":{"score":-3}}""", questions)
        assertEquals(0.0, JudgeAnswers.score(tooLow.getJSONObject("danger_level"))!!.score, 1e-9)
    }

    @Test
    fun `noul is clamped to zero and one`() {
        val answers = ChatJudge.answersFrom(
            """{"literal_question":{"noul":1.7},"tension_resolved":{"noul":-0.4},"should_reply_now":{"noul":"yes"}}""",
            questions)
        assertEquals(1.0, answers.getJSONObject("literal_question").getDouble("noul"), 1e-9)
        assertEquals(0.0, answers.getJSONObject("tension_resolved").getDouble("noul"), 1e-9)
        assertEquals(1.0, answers.getJSONObject("should_reply_now").getDouble("noul"), 1e-9)
    }

    @Test
    fun `unanswered questions stay absent so the UI shows them as unanswered`() {
        val answers = ChatJudge.answersFrom("""{"answers":{"true_intent":{"choice":"casual_chat"}}}""", questions)
        assertEquals(1, answers.length())
        assertNull(JudgeAnswers.choice(answers.optJSONObject("she_needs")))
    }

    @Test
    fun `a reply with no json at all fails loudly`() {
        try {
            ChatJudge.answersFrom("I cannot answer that.", questions)
            fail("expected IllegalStateException")
        } catch (e: IllegalStateException) {
            assertTrue(e.message!!.contains("没有返回 JSON"))
        }
    }

    @Test
    fun `contentOf reads the assistant text`() {
        val resp = JSONObject().put("choices", JSONArray().put(JSONObject()
            .put("message", JSONObject().put("content", "  hello  "))))
        assertEquals("hello", ChatJudge.contentOf(resp))
        assertEquals("", ChatJudge.contentOf(JSONObject()))
    }

    @Test
    fun `ranked orders candidates best first`() {
        val ranked = JudgeAnswers.ranked(
            JSONObject().put("probabilities", JSONObject()
                .put("reply_a", 0.1).put("reply_b", 0.8).put("reply_c", 0.1)),
            listOf("A", "B", "C"))
        assertEquals(listOf("B", "A", "C").toSet(), ranked.map { it.text }.toSet())
        assertEquals("B", ranked.first().text)
        assertEquals(0.8, ranked.first().prob, 1e-9)
    }

    @Test
    fun `score without a legend keeps the historical scale of nine`() {
        val s = JudgeAnswers.score(JSONObject().put("score", 3).put("confidence", 0.5))!!
        assertEquals(3.0, s.score, 1e-9)
        assertEquals(9, s.maxLevel)
    }

    /**
     * A side the capture step could not read is not the other person's side. The
     * flat-screen OCR path used to write every line as "other" and this prompt
     * printed anything that was not "me" with an "other:" label — which is how a
     * screen of my own messages was judged (and answered) as an incoming thread.
     */
    @Test
    fun `an unknown speaker is never printed as the other person`() {
        val st = JSONObject().put("chat", JSONObject()
            .put("relationship", "女朋友")
            .put("latest_from", "?")
            .put("sides_unclear", 2)
            .put("note", "OCR 分边：有 2 条认不出左右")
            .put("messages", JSONArray()
                .put(JSONObject().put("from", "me").put("text", "我到楼下了"))
                .put(JSONObject().put("from", "?").put("text", "好"))
                .put(JSONObject().put("from", "?").put("text", "马上"))))

        val prompt = ChatJudge.userPrompt(st, questions)

        assertTrue(prompt, prompt.contains("unknown-speaker: 好"))
        assertTrue(prompt, prompt.contains("unknown-speaker: 马上"))
        assertFalse(prompt, prompt.contains("other: 好"))
        assertFalse(prompt, prompt.contains("other: 马上"))
        // And the judge is told, in words, not to assume.
        assertTrue(prompt, prompt.contains("Do NOT assume they are the other person's"))
        assertTrue(prompt, prompt.contains("NOTE from the capture step: OCR 分边"))
    }

    @Test
    fun `a clean snapshot says nothing about sides`() {
        val prompt = ChatJudge.userPrompt(state(), questions)
        assertFalse(prompt, prompt.contains("unknown-speaker"))
        assertFalse(prompt, prompt.contains("could not be attributed"))
        assertFalse(prompt, prompt.contains("NOTE from the capture step"))
    }
}

package com.jev.probe.jev

import org.json.JSONArray
import org.json.JSONObject

/**
 * The chat-completions flavour of the judge route.
 *
 * The judge route's native protocol is Jev/TypeSafe `decisions`: one POST of
 * `{model, state, questions}` to a Jev-compatible host, answered with
 * `{answers}`. A plain chat model — DeepSeek official, or any OpenAI-compatible
 * host — serves no such endpoint. But that protocol is only a prompt plus a JSON
 * shape, so here the SAME state and the SAME question set are rendered into one
 * chat turn, and the model's JSON is normalized back into the very `answers`
 * object `decisions` would have returned. JudgeClient's parsing and the whole UI
 * are therefore shared, not duplicated.
 *
 * What this is not: Jev is a purpose-trained, calibrated judgment model. Here a
 * general chat model answers the same questions in words, so its probabilities
 * and danger levels are its own estimates. Enough to steer a draft; not the same
 * instrument.
 */
object ChatJudge {

    /**
     * The system message. English because the question set it describes — Jev's
     * instructions and criteria — is English, and Jev was trained on English
     * questions; only the chat text itself stays in its original language.
     */
    private val SYSTEM = """
        You are a strict judgment model for a chat assistant. You never write replies into the conversation and never explain your reasoning.

        Answer the questions about ONE conversation and return EXACTLY ONE JSON object and nothing else: no markdown fence, no sentence before or after it.

        Shape, one entry per question, keyed by the question id:
        {"answers":{
          "<id of a noul question>":{"noul":<0..1>,"confidence":<0..1>},
          "<id of a choice question>":{"choice":"<one listed key>","confidence":<0..1>,"probabilities":{"<listed key>":<0..1>}},
          "<id of a score question>":{"score":<level number>,"confidence":<0..1>}
        }}

        Rules:
        - "noul" is the probability from 0 to 1 that the question's "true" statement holds rather than its "false" statement. Fractions, not percentages.
        - "confidence" is how sure you are of your own answer, 0 to 1.
        - For a choice question, "choice" MUST be one of the listed keys, and "probabilities" must cover those keys and add up to about 1.
        - For a score question, "score" is the level number of the matching criterion: the first criterion listed is 0, the next is 1, and so on.
        - Judge only from the conversation and the background given. Never invent facts that are not there.
        - Follow each question's instructions and criteria literally; they define the right answer.
        - The conversation may be in Chinese. Keep chat text exactly as it is; keep this JSON structure exactly as specified.
    """.trimIndent()

    /** Request body for one judgment turn. */
    fun body(model: String, state: JSONObject, questions: JSONObject, jsonMode: Boolean): JSONObject {
        val messages = JSONArray()
            .put(JSONObject().put("role", "system").put("content", SYSTEM))
            .put(JSONObject().put("role", "user").put("content", userPrompt(state, questions)))
        val b = JSONObject()
            .put("model", model)
            .put("messages", messages)
            .put("temperature", 0.0)
            .put("stream", false)
        // Not every OpenAI-compatible host accepts this field; JudgeClient
        // retries without it when a host rejects the body.
        if (jsonMode) b.put("response_format", JSONObject().put("type", "json_object"))
        return b
    }

    /** The assistant's text out of an OpenAI-compatible response, or "". */
    fun contentOf(resp: JSONObject): String =
        resp.optJSONArray("choices")
            ?.optJSONObject(0)
            ?.optJSONObject("message")
            ?.optString("content")
            ?.trim()
            ?: ""

    /** The user message: the conversation, then the question set, then the ask. */
    fun userPrompt(state: JSONObject, questions: JSONObject): String {
        val sb = StringBuilder()
        sb.append("=== CONVERSATION ===\n")
        state.optJSONObject("chat")?.let { chat ->
            sb.append("Relationship: ").append(chat.optString("relationship")).append('\n')
            sb.append("Messages, oldest first (from=me is me, from=other is the other person; the last line is the latest message):\n")
            appendMessages(sb, chat.optJSONArray("messages"))
            val unclear = chat.optInt("sides_unclear", 0)
            if (unclear > 0) {
                sb.append("NOTE: ").append(unclear)
                    .append(" of the lines above could not be attributed to a speaker; they are marked")
                    .append(" unknown-speaker. Do NOT assume they are the other person's — the capture step")
                    .append(" could not read who said them, and say so if that changes your answer.\n")
            }
            chat.optString("note").takeIf { it.isNotBlank() }?.let {
                sb.append("NOTE from the capture step: ").append(it).append('\n')
            }
        }
        val background = state.optString("background").trim()
        if (background.isNotEmpty()) {
            sb.append("\nBackground (given context, not off-topic):\n").append(background).append('\n')
        }
        val history = state.optJSONArray("history")
        if (history != null && history.length() > 0) {
            sb.append("\nEarlier messages in this same conversation, oldest first:\n")
            appendMessages(sb, history)
        }
        sb.append("\n=== QUESTIONS ===\n")
        for ((n, id) in questions.keys().asSequence().toList().withIndex()) {
            val q = questions.optJSONObject(id) ?: continue
            appendQuestion(sb, n + 1, id, q)
        }
        sb.append("\n=== ANSWER ===\nReturn the JSON object now: an \"answers\" object keyed by the ids above.\n")
        return sb.toString()
    }

    private fun appendMessages(sb: StringBuilder, msgs: JSONArray?) {
        if (msgs == null) return
        for (i in 0 until msgs.length()) {
            val m = msgs.optJSONObject(i) ?: continue
            val label = when (m.optString("from")) {
                "me" -> "me: "
                "other" -> "other: "
                // An unknown side must never be printed as the other person's
                // message: that is how a screen of my own messages became an
                // incoming conversation.
                else -> "unknown-speaker: "
            }
            sb.append(label).append(m.optString("text")).append('\n')
        }
    }

    private fun appendQuestion(sb: StringBuilder, n: Int, id: String, q: JSONObject) {
        sb.append('\n').append(n).append(". id: ").append(id)
            .append("\n   type: ").append(q.optString("type"))
            .append("\n   instructions: ").append(q.optString("instructions")).append('\n')
        when (q.optString("type")) {
            "noul" -> {
                val criteria = q.opt("criteria") as? JSONObject
                sb.append("   true means: ").append(criteria?.optString("true") ?: "").append('\n')
                sb.append("   false means: ").append(criteria?.optString("false") ?: "").append('\n')
            }
            "score" -> {
                val levels = q.opt("criteria") as? JSONArray ?: JSONArray()
                sb.append("   criteria, by level number (0 is the first):\n")
                for (i in 0 until levels.length()) {
                    sb.append("     ").append(i).append(" = ").append(levels.optString(i)).append('\n')
                }
            }
            else -> {
                val options = q.opt("criteria") as? JSONObject
                if (options != null) {
                    sb.append("   options (\"choice\" must be one of these keys):\n")
                    for (k in options.keys()) {
                        sb.append("     ").append(k).append(" = ").append(options.optString(k)).append('\n')
                    }
                }
            }
        }
    }

    /**
     * Normalizes a chat model's reply into the `answers` object JudgeClient
     * parses. Anything the model did not answer, or answered off-menu, is left
     * out rather than guessed at: absent reads as "not answered".
     */
    fun answersFrom(content: String, questions: JSONObject): JSONObject {
        val raw = JsonSlice.firstObject(content)
            ?: throw IllegalStateException("判断接口（聊天模式）没有返回 JSON：${content.take(120)}")
        val parsed = try {
            JSONObject(raw)
        } catch (e: Exception) {
            throw IllegalStateException("判断接口（聊天模式）返回的 JSON 解析失败：${raw.take(120)}")
        }
        // Most models honour the wrapper; a bare answers object is accepted too.
        val answers = raw(parsed, "answers") as? JSONObject ?: parsed
        val out = JSONObject()
        for (id in questions.keys()) {
            val q = questions.optJSONObject(id) ?: continue
            val answer = answerObject(answers, id, q.optString("type")) ?: continue
            val normalized = when (q.optString("type")) {
                "choice" -> normalizeChoice(answer, q)
                "score" -> normalizeScore(answer, q)
                else -> normalizeNoul(answer)
            }
            if (normalized != null) out.put(id, normalized)
        }
        return out
    }

    /** The answer for [id], tolerating a different case or a bare value. */
    private fun answerObject(answers: JSONObject, id: String, type: String): JSONObject? {
        val value = answers.opt(id) ?: answers.keys().asSequence()
            .firstOrNull { it.equals(id, ignoreCase = true) }
            ?.let { answers.opt(it) }
            ?: return null
        if (value is JSONObject) return value
        // Some models answer with the value alone ({"should_reply_now": true},
        // {"danger_level": 4}, {"literal_question": "0.2"}).
        return when (value) {
            is Boolean -> JSONObject().put("noul", if (value) 1.0 else 0.0)
            is Number -> if (type == "score") JSONObject().put("score", value.toDouble())
            else JSONObject().put("noul", value.toDouble())
            is String -> when (type) {
                "score" -> JSONObject().put("score", value)
                "choice" -> JSONObject().put("choice", value)
                else -> JSONObject().put("noul", value)
            }
            else -> null
        }
    }

    /** [key] out of an answer object, tolerating a capitalized spelling. */
    private fun raw(a: JSONObject, key: String): Any? =
        if (a.has(key)) a.opt(key)
        else a.keys().asSequence().firstOrNull { it.equals(key, ignoreCase = true) }
            ?.let { a.opt(it) }

    private fun normalizeChoice(a: JSONObject, q: JSONObject): JSONObject? {
        val options = q.optJSONObject("criteria") ?: return null
        val keys = options.keys().asSequence().toList()
        if (keys.isEmpty()) return null
        val probabilities = LinkedHashMap<String, Double>()
        (raw(a, "probabilities") as? JSONObject)?.let { p ->
            for (rawKey in p.keys()) {
                val key = keys.firstOrNull { it.equals(rawKey, ignoreCase = true) } ?: continue
                probabilities[key] = number(p, rawKey, 0.0).coerceIn(0.0, 1.0)
            }
        }
        val said = (raw(a, "choice") as? String)?.trim().orEmpty()
        val choice = keys.firstOrNull { it.equals(said, ignoreCase = true) }
            // Some models echo the option's text instead of its key.
            ?: keys.firstOrNull { options.optString(it).trim().equals(said, ignoreCase = true) }
            // ...or fill only the probabilities, which still names the winner.
            ?: probabilities.maxByOrNull { it.value }?.key
            ?: return null
        val out = JSONObject().put("choice", choice)
        out.put("confidence", probability(a, "confidence"))
        if (probabilities.isNotEmpty()) {
            out.put("probabilities", JSONObject().also { o -> probabilities.forEach { (k, v) -> o.put(k, v) } })
        }
        return out
    }

    private fun normalizeScore(a: JSONObject, q: JSONObject): JSONObject? {
        val levels = q.optJSONArray("criteria") ?: return null
        val count = levels.length()
        if (count == 0) return null
        // Jev's danger scale is 0..9 for ten criteria, so the level is the
        // 0-based index into them, and the legend below hands JudgeClient the
        // 9 the UI prints as "score/maxLevel".
        val level = when (val r = raw(a, "score")) {
            is Number -> r.toInt()
            is String -> r.trim().toIntOrNull() ?: levelOf(levels, r.trim())
            else -> null
        } ?: return null
        val out = JSONObject().put("score", level.coerceIn(0, count - 1))
        out.put("confidence", probability(a, "confidence"))
        out.put("legend", JSONObject().also { legend ->
            for (i in 0 until count) legend.put(i.toString(), levels.optString(i))
        })
        return out
    }

    private fun normalizeNoul(a: JSONObject): JSONObject? {
        val p = when (val r = raw(a, "noul")) {
            is Number -> r.toDouble()
            is Boolean -> if (r) 1.0 else 0.0
            is String -> r.trim().toDoubleOrNull() ?: when (r.trim().lowercase()) {
                "true", "yes" -> 1.0
                "false", "no" -> 0.0
                else -> return null
            }
            else -> return null
        }
        val out = JSONObject().put("noul", p.coerceIn(0.0, 1.0))
        out.put("confidence", probability(a, "confidence"))
        return out
    }

    /** 0-based level of the criterion whose text was echoed instead of its number. */
    private fun levelOf(levels: JSONArray, text: String): Int? {
        if (text.isBlank()) return null
        for (i in 0 until levels.length()) {
            if (levels.optString(i).trim().equals(text, ignoreCase = true)) return i
        }
        return null
    }

    private fun number(a: JSONObject, key: String, fallback: Double): Double =
        when (val v = raw(a, key)) {
            is Number -> v.toDouble()
            is String -> v.trim().toDoubleOrNull() ?: fallback
            else -> fallback
        }

    private fun probability(a: JSONObject, key: String): Double = number(a, key, 0.0).coerceIn(0.0, 1.0)
}

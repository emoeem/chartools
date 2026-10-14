package com.jev.probe.jev

import android.util.Log
import com.jev.probe.core.Analysis
import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Prefs
import com.jev.probe.core.RankedReply
import com.jev.probe.core.kb.ChatContext
import org.json.JSONObject

/**
 * The Jev judgment route only: the 7 judgment questions in one call, and the
 * ranking question over already-drafted candidates. Reads judgeProvider /
 * judgeBaseUrl / judgeKey / judgeModel from [Prefs]; nothing generative here.
 *
 * Two protocols share this route, chosen by [Prefs.effectiveJudgeProtocol]:
 * the native Jev/TypeSafe `decisions` protocol ([sendDecisions]) and an
 * OpenAI-compatible chat turn over the same question set ([sendChat], see
 * [ChatJudge]) for hosts that serve no judgment model — DeepSeek official.
 * Everything downstream of `answers` is identical for both.
 */
class JudgeClient(private val prefs: Prefs) {

    /**
     * The 7 judgment questions (fast, ~1s). Errors are returned, not thrown.
     *
     * @param ctx D-stage knowledge context; null or empty means the request body
     *        is byte-for-byte what v1.2 sent.
     * @param scope when given, the request is registered there so an abandoned
     *        round can close its socket instead of waiting out the read timeout.
     */
    fun judge(
        snapshot: ChatSnapshot,
        relationship: String,
        ctx: ChatContext? = null,
        scope: HttpScope? = null
    ): Analysis {
        val start = System.currentTimeMillis()
        return try {
            val answers = postJudge(
                snapshot, relationship, ctx,
                JevQuestions.judge(), scope
            )
            Analysis(
                trueIntent = JudgeAnswers.choice(answers.optJSONObject("true_intent")),
                dangerLevel = JudgeAnswers.score(answers.optJSONObject("danger_level")),
                sheNeeds = JudgeAnswers.choice(answers.optJSONObject("she_needs")),
                shouldReplyNow = answers.optJSONObject("should_reply_now")?.optDouble("noul"),
                bestAction = JudgeAnswers.choice(answers.optJSONObject("best_action")),
                tensionResolved = answers.optJSONObject("tension_resolved")?.optDouble("noul"),
                literalQuestion = answers.optJSONObject("literal_question")?.optDouble("noul"),
                rankedReplies = emptyList(),
                latencyMs = System.currentTimeMillis() - start
            )
        } catch (e: Exception) {
            Log.w(TAG, "judge failed: ${e.message}")
            Analysis(null, null, null, null, null, null, null, emptyList(),
                System.currentTimeMillis() - start, error = e.message ?: "判断接口请求失败")
        }
    }

    /** Ask Jev which of the candidate replies is best; throws on failure. */
    fun rank(
        snapshot: ChatSnapshot,
        relationship: String,
        candidates: List<String>,
        ctx: ChatContext? = null,
        scope: HttpScope? = null
    ): List<RankedReply> {
        val questions = JSONObject().put("best_reply",
            JevQuestions.rankQuestion(candidates).getJSONObject("best_reply"))
        val answers = postJudge(snapshot, relationship, ctx, questions, scope)
        return JudgeAnswers.ranked(answers.optJSONObject("best_reply"), candidates)
    }

    /**
     * POST one judgment request in whichever protocol the route speaks, with the
     * knowledge fields when there are any.
     *
     * Defensive retry: whether the live `alpha/decisions` endpoint accepts the
     * new `background` / `history` state fields or rejects unknown ones with a
     * 4xx is not verified against production yet (see the A-stage report). If a
     * request carrying them comes back 4xx, it is sent again once without them,
     * so an unverified field can degrade the analysis but never break it.
     */
    private fun postJudge(
        snapshot: ChatSnapshot,
        relationship: String,
        ctx: ChatContext?,
        questions: JSONObject,
        scope: HttpScope? = null
    ): JSONObject {
        val background = ctx?.background(relationship) ?: ""
        val history = ctx?.history ?: emptyList()
        val enriched = background.isNotBlank() || history.isNotEmpty()
        return try {
            send(JevQuestions.buildState(snapshot, relationship, background, history), questions, scope)
        } catch (e: ApiException) {
            if (enriched && JudgeRetry.shouldDropEnrichment(e.status)) {
                Log.w(TAG, "judge HTTP ${e.status} with background/history; retrying plain")
                send(JevQuestions.buildState(snapshot, relationship), questions, scope)
            } else throw e
        }
    }

    private fun send(state: JSONObject, questions: JSONObject, scope: HttpScope?): JSONObject =
        if (prefs.effectiveJudgeProtocol() == Prefs.PROTO_CHAT) sendChat(state, questions, scope)
        else sendDecisions(state, questions, scope)

    /** Jev/TypeSafe `decisions`: one POST, `answers` straight back. */
    private fun sendDecisions(state: JSONObject, questions: JSONObject, scope: HttpScope?): JSONObject {
        val url = prefs.judgeEndpoint()
        val body = JSONObject()
            .put("model", prefs.judgeModel)
            .put("state", state)
            .put("questions", questions)
        val resp = HttpJson.post(
            url, prefs.judgeKey, body, Route.JUDGE, HttpJson.headersFor(url), scope)
        return resp.optJSONObject("answers") ?: JSONObject()
    }

    /**
     * OpenAI-compatible chat: the question set is rendered into a prompt and the
     * reply normalized back into the decisions answer shape (see [ChatJudge]).
     *
     * `response_format: json_object` is what keeps a chat model from wrapping its
     * answer in prose, but not every OpenAI-compatible host accepts the field. A
     * 400/422 body-shape rejection is therefore retried once without it instead
     * of failing the whole analysis; an auth or server error is not retried.
     */
    private fun sendChat(state: JSONObject, questions: JSONObject, scope: HttpScope?): JSONObject {
        val url = prefs.judgeEndpoint()
        val resp = try {
            HttpJson.post(
                url, prefs.judgeKey, ChatJudge.body(prefs.judgeModel, state, questions, jsonMode = true),
                Route.JUDGE, HttpJson.headersFor(url), scope
            )
        } catch (e: ApiException) {
            if (e.status == 400 || e.status == 422) {
                Log.w(TAG, "judge HTTP ${e.status} with response_format; retrying without it")
                HttpJson.post(
                    url, prefs.judgeKey, ChatJudge.body(prefs.judgeModel, state, questions, jsonMode = false),
                    Route.JUDGE, HttpJson.headersFor(url), scope
                )
            } else throw e
        }
        val content = ChatJudge.contentOf(resp)
        if (content.isBlank()) throw ApiException(Route.JUDGE, null, "聊天模式返回内容为空")
        return ChatJudge.answersFrom(content, questions)
    }

    companion object { private const val TAG = "JEVASSIST" }
}

package com.jev.probe.jev

import com.jev.probe.core.Analysis
import com.jev.probe.core.Choice
import com.jev.probe.core.Score
import com.jev.probe.core.kb.PersonaCard
import com.jev.probe.core.safety.SafetyGate
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The aiming suite: `tools/jev/fixtures/aiming_set.json`, run offline.
 *
 * [PersonaCardTest], [SafetyGateTest] and [ReplyPromptTest] each pin one piece in
 * isolation with hand-written inputs. This one pins the whole chain on the cases
 * the user actually cares about ("有人找我文爱和网调") — card text, the other
 * side's line, the gate verdict and both prompt halves — from a fixture that
 * `tools/jev/eval_aiming.py` also reads when it runs the same cases against a
 * live model. One fixture, two layers: this file is the half that must never
 * depend on the network.
 *
 * The live half needs the two halves *this* file builds, because a live run that
 * assembled its own prompt would silently stop testing the app. So when
 * `-Daiming.dump=<path>` is set the assembled prompts are written there, and the
 * Python script shells out to Gradle with that flag rather than re-deriving them.
 */
class AimingFixtureTest {

    private fun fixture(): JSONObject {
        val candidates = listOf(
            File("../tools/jev/fixtures/aiming_set.json"),
            File("tools/jev/fixtures/aiming_set.json")
        )
        val file = candidates.firstOrNull { it.isFile }
            ?: throw AssertionError("aiming_set.json not found; looked in ${candidates.map { it.absolutePath }}")
        return JSONObject(file.readText(Charsets.UTF_8))
    }

    private fun cases(): List<JSONObject> {
        val arr: JSONArray = fixture().getJSONArray("cases")
        return (0 until arr.length()).map { arr.getJSONObject(it) }
    }

    private fun strings(case: JSONObject, key: String): List<String> =
        case.getJSONObject("expect").optJSONArray(key)?.let { a ->
            (0 until a.length()).map { a.getString(it) }
        } ?: emptyList()

    private fun analysisOf(case: JSONObject): Analysis? {
        val j = case.optJSONObject("judgment") ?: return null
        return Analysis(
            trueIntent = j.optString("intent").takeIf { it.isNotBlank() }
                ?.let { Choice(it, 0.8, emptyMap()) },
            dangerLevel = j.optString("danger").takeIf { it.isNotBlank() }
                ?.let { Score(it.toDouble(), 0.9, 9) },
            sheNeeds = j.optString("needs").takeIf { it.isNotBlank() }
                ?.let { Choice(it, 0.7, emptyMap()) },
            shouldReplyNow = null,
            bestAction = j.optString("action").takeIf { it.isNotBlank() }
                ?.let { Choice(it, 0.7, emptyMap()) },
            tensionResolved = null,
            literalQuestion = null,
            rankedReplies = emptyList(),
            latencyMs = 0
        )
    }

    private fun threadOf(case: JSONObject): List<String> {
        val arr = case.optJSONArray("thread") ?: return emptyList()
        return (0 until arr.length()).map { arr.getString(it) }
    }

    /** The other side's lines only — the same slice [ReplyClient] hands the gate. */
    private fun otherLines(thread: List<String>): List<String> =
        thread.filter { it.startsWith("对方：") || it.startsWith("对方:") }
            .map { it.substringAfter("：").substringAfter(":") }

    private fun convo(thread: List<String>): String = thread.joinToString("\n")

    private fun name(case: JSONObject): String = case.getString("id")

    @Test
    fun everyCaseMeansWhatItSaysItMeans() {
        val all = cases()
        assertEquals(all.size, all.map { name(it) }.toSet().size)
        assertTrue("fixture should cover more than a couple of cases", all.size >= 8)
        all.forEach { c ->
            assertTrue(name(c), c.getString("why").length > 20)
            val gate = c.getJSONObject("expect").getString("gate")
            assertTrue(name(c), gate in listOf("allow", "caution", "block"))
        }
    }

    @Test
    fun theGateReachesTheVerdictEachCaseDeclares() {
        cases().forEach { c ->
            val card = PersonaCard.parse(c.optString("persona").takeIf { it.isNotBlank() })
            val verdict = SafetyGate.check(otherLines(threadOf(c)), if (card.hasContent()) card else null)
            val expected = c.getJSONObject("expect").getString("gate")
            when (expected) {
                "block" -> {
                    assertTrue(name(c), verdict.blocked)
                    strings(c, "block_contains").forEach {
                        assertTrue(name(c) + ": " + verdict.blockReason, verdict.blockReason!!.contains(it))
                    }
                }
                "caution" -> {
                    assertFalse(name(c), verdict.blocked)
                    assertTrue(name(c), verdict.caution.isNotBlank())
                    strings(c, "caution_contains").forEach {
                        assertTrue(name(c) + ": " + verdict.caution, verdict.caution.contains(it))
                    }
                }
                else -> {
                    assertFalse(name(c) + ": " + verdict.blockReason, verdict.blocked)
                }
            }
        }
    }

    @Test
    fun bothPromptHalvesSayWhatEachCaseDeclares() {
        cases().forEach { c ->
            if (c.getJSONObject("expect").getString("gate") == "block") return@forEach
            val card = PersonaCard.parse(c.optString("persona").takeIf { it.isNotBlank() })
            val verdict = SafetyGate.check(otherLines(threadOf(c)), card)
            val judgment = analysisOf(c)
            val n = 3
            val system = ReplyPrompt.draftSystemPrompt(n, "follow", "standard", card)
            val user = ReplyPrompt.draftUserPrompt(
                c.optString("relationship"), null, 30, judgment, card, verdict.caution,
                convo(threadOf(c)), emptyList(), n
            )

            strings(c, "system_contains").forEach {
                assertTrue("${name(c)} system missing: $it", system.contains(it))
            }
            strings(c, "system_absent").forEach {
                assertFalse("${name(c)} system should not contain: $it", system.contains(it))
            }
            strings(c, "user_contains").forEach {
                assertTrue("${name(c)} user missing: $it", user.contains(it))
            }
            strings(c, "user_absent").forEach {
                assertFalse("${name(c)} user should not contain: $it", user.contains(it))
            }
        }
    }

    /**
     * Only runs when asked. The Python script calls Gradle with `-Daiming.dump=...`
     * and then posts exactly these prompts, so the live layer cannot drift from the
     * app: there is one assembler, and it is Kotlin.
     */
    @Test
    fun dumpTheAssembledPromptsWhenAsked() {
        val out = System.getProperty("aiming.dump")?.trim().orEmpty()
        if (out.isEmpty()) return
        val root = JSONArray()
        cases().forEach { c ->
            val card = PersonaCard.parse(c.optString("persona").takeIf { it.isNotBlank() })
            val verdict = SafetyGate.check(otherLines(threadOf(c)), if (card.hasContent()) card else null)
            val n = 3
            val o = JSONObject()
                .put("id", name(c))
                .put("gate", if (verdict.blocked) "block" else if (verdict.caution.isNotBlank()) "caution" else "allow")
                .put("blockReason", verdict.blockReason ?: JSONObject.NULL)
                .put("caution", verdict.caution)
                .put("expect", c.getJSONObject("expect"))
            if (!verdict.blocked) {
                o.put("system", ReplyPrompt.draftSystemPrompt(n, "follow", "standard", card))
                o.put("user", ReplyPrompt.draftUserPrompt(
                    c.optString("relationship"), null, 30, analysisOf(c), card, verdict.caution,
                    convo(threadOf(c)), emptyList(), n
                ))
            }
            root.put(o)
        }
        val target = File(out)
        target.parentFile?.mkdirs()
        target.writeText(root.toString(2), Charsets.UTF_8)
    }
}

package com.jev.probe.jev

import com.jev.probe.core.Analysis
import com.jev.probe.core.Choice
import com.jev.probe.core.Score
import com.jev.probe.core.kb.ChatContext
import com.jev.probe.core.kb.Ledger
import com.jev.probe.core.kb.LedgerCheck
import com.jev.probe.core.kb.LedgerPrompt
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
 * The role-play suite: `tools/jev/fixtures/roleplay_set.json`, the half that can
 * be asserted without a network.
 *
 * [AimingFixtureTest] answers "is the layering wired right" on one-shot cases.
 * This one answers a different question, on multi-turn cases taken from the
 * circling material in `_reports/roleplay-quality_report.md`: does the chain
 * still know what it is doing two rounds into a scene — when the other side goes
 * quiet, calls the safe word, or asks to keep a recording.
 *
 * Two layers, one fixture, same as the aiming suite:
 *
 *  * offline (this file) — the gate verdict each turn must reach, and what each
 *    prompt half must and must not contain;
 *  * live (`tools/jev/eval_roleplay.py`) — the actual candidates, driven turn by
 *    turn, scored against a rubric. It does not assemble its own prompt: with
 *    `-Droleplay.in` / `-Droleplay.out` set, [replayTheRequestedRoundsWhenAsked]
 *    builds the prompts through the production assembler and the script posts
 *    exactly those.
 *
 * `ChatContext` carries nothing but the ledger, exactly as in [AimingFixtureTest]:
 * the knowledge/skill blocks are empty and the persona card is the only style
 * input, which is what isolates the card's effect. The ledger is the one
 * exception, because S1's whole claim is that it changes what the writer knows —
 * `eval_roleplay.py --ledger` A/Bs exactly this one input.
 */
class RoleplayFixtureTest {

    private fun fixture(): JSONObject {
        val candidates = listOf(
            File("../tools/jev/fixtures/roleplay_set.json"),
            File("tools/jev/fixtures/roleplay_set.json")
        )
        val file = candidates.firstOrNull { it.isFile }
            ?: throw AssertionError("roleplay_set.json not found; looked in ${candidates.map { it.absolutePath }}")
        return JSONObject(file.readText(Charsets.UTF_8))
    }

    private fun cases(): List<JSONObject> {
        val arr: JSONArray = fixture().getJSONArray("cases")
        return (0 until arr.length()).map { arr.getJSONObject(it) }
    }

    private fun turnsOf(case: JSONObject): List<JSONObject> {
        val arr = case.getJSONArray("turns")
        return (0 until arr.length()).map { arr.getJSONObject(it) }
    }

    private fun arr(o: JSONObject, key: String): List<String> =
        o.optJSONArray(key)?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()

    private fun strings(case: JSONObject, key: String): List<String> =
        arr(case.optJSONObject("expect") ?: JSONObject(), key)

    /** The `docx02` / `pdf05` / `xlsx03` keys a prose `source` field points at. */
    private fun sourceKeys(text: String): List<String> =
        Regex("(docx\\d+|pdf\\d+|xlsx\\d+|doc\\d+|xls\\d+)").findAll(text).map { it.value }.toList()

    private fun cardOf(case: JSONObject): PersonaCard =
        PersonaCard.parse(case.optString("persona").takeIf { it.isNotBlank() })

    private fun analysisOf(j: JSONObject?): Analysis? {
        j ?: return null
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

    /**
     * An optional `ledger` object on a case or a replay request. It is the ONE
     * thing the S1 A/B varies, so it has to flow through the production assembler
     * untouched — hence the same sanitize/takeUnless the app applies on the way
     * out of storage.
     */
    private fun ledgerContext(o: JSONObject): ChatContext? {
        val raw = o.optJSONObject("ledger") ?: return null
        val ledger = LedgerCheck.sanitize(Ledger.fromJson(raw)).takeUnless { it.isEmpty() } ?: return null
        return ChatContext(null, emptyList(), emptyList(), emptyList(), "", ledger)
    }

    /** Both prompt halves for one moment of a scene, through production code. */
    private fun promptsFor(case: JSONObject, thread: List<String>): Triple<PersonaCard, SafetyGate.Verdict, Pair<String, String>> {
        val card = cardOf(case)
        val other = thread.filter { it.startsWith("对方：") }.map { it.substringAfter("：") }
        val verdict = SafetyGate.check(other, if (card.hasContent()) card else null)
        val n = 3
        val system = ReplyPrompt.draftSystemPrompt(n, "follow", "standard", card)
        val user = ReplyPrompt.draftUserPrompt(
            case.optString("relationship"), ledgerContext(case), 30,
            analysisOf(case.optJSONObject("judgment")),
            card, verdict.caution, thread.joinToString("\n"), emptyList(), n
        )
        return Triple(card, verdict, system to user)
    }

    /** The thread as it stands after `count` of the fixture's other-side lines. */
    private fun threadUpTo(case: JSONObject, count: Int): List<String> =
        turnsOf(case).take(count).map { "对方：" + it.getString("other") }

    @Test
    fun everyCaseMeansWhatItSaysItMeans() {
        val all = cases()
        assertEquals(all.size, all.map { it.getString("id") }.toSet().size)
        assertTrue("网调场景集不该只有两三条", all.size >= 6)
        val sources = fixture().getJSONObject("sources")
        all.forEach { c ->
            val id = c.getString("id")
            assertTrue("$id: why 太短，用例说不清要测什么", c.getString("why").length > 40)
            // Every case must trace back to material, otherwise it is someone's
            // guess about what good role-play looks like. `source` is prose with
            // file keys inside it ("docx03 §3 开场"), so pull the keys out instead
            // of splitting on spaces and treating every word as a file name.
            val src = c.getString("source")
            assertTrue("$id: source 没写", src.isNotBlank())
            val keys = sourceKeys(src)
            assertTrue("$id: source 没有指向任何素材（写 docxNN / pdfNN / xlsxNN）", keys.isNotEmpty())
            keys.forEach { key ->
                assertTrue("$id: source 里的 $key 不在 sources 表里", sources.has(key))
            }
            val turns = turnsOf(c)
            assertTrue("$id: 至少要两轮", turns.size >= 2)
            turns.forEach { turn ->
                assertTrue("$id: 缺 other", turn.getString("other").isNotBlank())
                assertTrue("$id: 缺 hook", turn.getJSONArray("hook").length() > 0)
                // A hard failure and a soft signal must not be the same word: the
                // hard one fails the run, the soft one is only reported.
                arr(turn, "forbid").forEach { word ->
                    assertFalse("$id: 「$word」同时算硬犯规和软信号，二选一", arr(turn, "forbid_soft").contains(word))
                }
            }
            val gate = c.getJSONObject("expect").getString("gate")
            assertTrue("$id: gate=$gate", gate in listOf("allow", "caution", "block"))
        }

        // And the other way round: material no case uses is either a missing case or
        // a source note that no longer means anything.
        val used = all.flatMap { sourceKeys(it.getString("source")) }.toSet()
        sources.keys().forEach { key ->
            assertTrue("sources 表里的 $key 没有任何用例引用", used.contains(key))
        }
    }

    /**
     * The safe word is the one expectation that reads like a checklist item, and
     * it is the one that was not implemented: `PersonaCard` parsed `安全词` and the
     * prompt printed it, but nothing ever acted on it. The card was decoration at
     * exactly the moment it has to be a switch.
     */
    @Test
    fun theGateReachesTheVerdictEachCaseDeclares() {
        cases().forEach { c ->
            val id = c.getString("id")
            val expect = c.getJSONObject("expect")
            val verdict = promptsFor(c, threadUpTo(c, turnsOf(c).size)).second
            when (expect.getString("gate")) {
                "block" -> {
                    assertTrue("$id: 应该拦下，实际放行", verdict.blocked)
                    strings(c, "block_contains").forEach {
                        assertTrue("$id: ${verdict.blockReason}", verdict.blockReason!!.contains(it))
                    }
                }
                "caution" -> {
                    assertFalse("$id: 不该拦", verdict.blocked)
                    assertTrue("$id: 该给提醒", verdict.caution.isNotBlank())
                    strings(c, "caution_contains").forEach {
                        assertTrue("$id: 提醒里没有「$it」：${verdict.caution}", verdict.caution.contains(it))
                    }
                }
                else -> assertFalse("$id: ${verdict.blockReason}", verdict.blocked)
            }
        }
    }

    /** The safe word must fire on its own turn, not only on the last line of the case. */
    @Test
    fun aSafeWordStopsTheRoundItAppearsIn() {
        cases().forEach { c ->
            val id = c.getString("id")
            turnsOf(c).forEachIndexed { i, turn ->
                val line = turn.getString("other")
                val card = cardOf(c)
                if (!card.safeword.contains(line.trim())) return@forEachIndexed
                val verdict = SafetyGate.check(listOf(line), card)
                assertTrue("$id 第 ${i + 1} 轮：$line 是人设卡里的安全词，必须拦下", verdict.blocked)
            }
        }
    }

    @Test
    fun bothPromptHalvesStillSayWhatEachCaseDeclares() {
        cases().forEach { c ->
            val id = c.getString("id")
            val expect = c.getJSONObject("expect")
            if (expect.getString("gate") == "block") return@forEach
            val (_, verdict, halves) = promptsFor(c, threadUpTo(c, turnsOf(c).size))
            val (system, user) = halves
            strings(c, "system_contains").forEach {
                assertTrue("$id system missing: $it", system.contains(it))
            }
            strings(c, "system_absent").forEach {
                assertFalse("$id system should not contain: $it", system.contains(it))
            }
            strings(c, "user_contains").forEach {
                assertTrue("$id user missing: $it", user.contains(it))
            }
            // A caution that never reaches the drafter is a comment in the source,
            // not a guard: this is what makes the gate's advice count.
            if (verdict.caution.isNotBlank()) {
                assertTrue("$id: 提醒没进提示词：${verdict.caution}", user.contains(verdict.caution))
            }
        }
    }

    /**
     * The live driver's only way to get a prompt. It hands over a batch of rounds
     * — `{id, relationship, persona, judgment, thread}` — and gets back the two
     * halves the app would send, built by [ReplyPrompt] and nothing else.
     *
     * A driver that assembled its own prompt would keep passing after the app's
     * prompt changed underneath it, which is the failure mode this whole fixture
     * is arranged to avoid.
     */
    @Test
    fun replayTheRequestedRoundsWhenAsked() {
        val input = System.getProperty("roleplay.in")?.trim().orEmpty()
        val output = System.getProperty("roleplay.out")?.trim().orEmpty()
        if (input.isEmpty() || output.isEmpty()) return
        val reqs = JSONArray(File(input).readText(Charsets.UTF_8))
        val root = JSONArray()
        for (i in 0 until reqs.length()) {
            val req = reqs.getJSONObject(i)
            val thread = req.optJSONArray("thread")?.let { a ->
                (0 until a.length()).map { a.getString(it) }
            } ?: emptyList()
            val card = PersonaCard.parse(req.optString("persona").takeIf { it.isNotBlank() })
            val other = thread.filter { it.startsWith("对方：") }.map { it.substringAfter("：") }
            val verdict = SafetyGate.check(other, if (card.hasContent()) card else null)
            val n = 3
            val o = JSONObject()
                .put("id", req.getString("id"))
                .put("gate", if (verdict.blocked) "block" else if (verdict.caution.isNotBlank()) "caution" else "allow")
                .put("blockReason", verdict.blockReason ?: JSONObject.NULL)
                .put("caution", verdict.caution)
            if (!verdict.blocked) {
                val ctx = ledgerContext(req)
                o.put("system", ReplyPrompt.draftSystemPrompt(n, "follow", "standard", card))
                o.put(
                    "user",
                    ReplyPrompt.skillNote(ctx) + ReplyPrompt.draftUserPrompt(
                        req.optString("relationship"), ctx, 30,
                        analysisOf(req.optJSONObject("judgment")), card, verdict.caution,
                        thread.joinToString("\n"), emptyList(), n
                    )
                )
            }
            root.put(o)
        }
        val target = File(output)
        target.parentFile?.mkdirs()
        target.writeText(root.toString(2), Charsets.UTF_8)
    }

    /**
     * The ledger half of the S1 A/B. `eval_roleplay.py --ledger` pre-scans each
     * scene into a ledger before the rounds run, and it must not assemble that
     * prompt itself — the ledger prompt has exactly one copy, in [LedgerPrompt].
     *
     * `-Dledger.in`  = `[{id, transcript}]`
     * `-Dledger.out` = `[{id, system, user}]`
     *
     * The built ledger comes back in as a plain `ledger` object on each round
     * request and is re-parsed by [ledgerContext], so the A/B varies one input
     * and nothing else.
     */
    @Test
    fun exportLedgerPromptsWhenAsked() {
        val input = System.getProperty("ledger.in")?.trim().orEmpty()
        val output = System.getProperty("ledger.out")?.trim().orEmpty()
        if (input.isEmpty() || output.isEmpty()) return
        val reqs = JSONArray(File(input).readText(Charsets.UTF_8))
        val root = JSONArray()
        for (i in 0 until reqs.length()) {
            val req = reqs.getJSONObject(i)
            val previous = req.optString("previous").takeIf { it.isNotBlank() }
            root.put(
                JSONObject()
                    .put("id", req.getString("id"))
                    .put("system", LedgerPrompt.system())
                    .put("user", LedgerPrompt.user(previous, req.optString("transcript")))
            )
        }
        val target = File(output)
        target.parentFile?.mkdirs()
        target.writeText(root.toString(2), Charsets.UTF_8)
    }
}

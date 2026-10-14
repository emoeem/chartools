package com.jev.probe.jev

import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Msg
import com.jev.probe.core.kb.ChatContext
import com.jev.probe.core.kb.ContextBuilder
import com.jev.probe.core.kb.KbStore
import com.jev.probe.core.kb.Note
import com.jev.probe.core.kb.NOTE_TYPE_STYLE_SAMPLE
import com.jev.probe.core.kb.PersonaCard
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Test
import java.io.File

/**
 * 「知识库到底有没有进回复」的实况 A/B 的**唯一**出口。
 *
 * 为什么要有它：`ContextBuilder` 决定注不注入，`ReplyPrompt` 决定怎么摆，
 * 这两个都能被单测钉住 —— 但「注入了知识库之后，模型写出来的话有没有变」
 * 谁都没测过。`tools/jev/eval_roleplay.py` 测不了这件事，因为那个 fixture 的
 * `ChatContext` 里**只有台账、没有笔记**（见 `RoleplayFixtureTest` 的类注释）。
 * 于是「知识库有用」一直只是一句设计意图，没有任何实况证据。这个出口补的就是它。
 *
 * 它**不自己拼提示词**：检索走 `ContextBuilder.matchNotes`（app 自己的实现，
 * 不是复制品），拼装走 `ReplyPrompt.draftUserPrompt`。两臂唯一的差别是
 * `ChatContext` 里有没有笔记 —— KB 臂带真机那 684 条里命中的那几条，对照臂是
 * `null`。system 两半逐字相同，所以差异只可能来自知识库。
 *
 *   -Dkbeffect.kb=<notes.json 路径>   真机（或重建）的笔记库
 *   -Dkbeffect.in=<场景集路径>         [{id, relationship, persona, messages:[{side,text}]}]
 *   -Dkbeffect.out=<输出路径>          [{id, arm, system, user, hits:[{title, content}]}]
 *   -Dkbeffect.summary=<notes.json>    可选：只放一条「领域摘要」笔记的库，用来试
 *                                       「预扫成一段摘要」是不是比「塞原始片段」好
 *
 * 前三条属性缺一条就整个跳过：一个静默没跑成的导出会让实况结果看起来像跑过了。
 *
 * 四臂，两两成对回答两个不同的问题：
 *  - `kb` vs `nokb`    —— 知识库那几条笔记进不进提示词，回复变不变
 *  - `kb` vs `nocard`  —— 人设卡在不在（笔记两次都一样），回复变不变
 *  - `summary`         —— 只注入一段领域摘要（取代原始片段）
 */
class KbEffectProbeTest {

    private fun notes(path: String): List<Note> {
        val arr = JSONArray(File(path).readText(Charsets.UTF_8))
        val out = ArrayList<Note>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            if (!o.optBoolean("enabled", true)) continue
            if (o.optString("type", "note") == NOTE_TYPE_STYLE_SAMPLE) continue
            val tags = ArrayList<String>()
            o.optJSONArray("tags")?.let { t -> for (j in 0 until t.length()) tags.add(t.getString(j)) }
            out.add(
                Note(
                    id = o.optString("id"),
                    title = o.optString("title"),
                    content = o.optString("content"),
                    tags = tags,
                    alwaysOn = false,
                    enabled = true,
                    updatedAt = o.optLong("updatedAt"),
                    type = o.optString("type", "note"),
                )
            )
        }
        return out
    }

    @Test
    fun exportTheKbArmWhenAsked() {
        val kbPath = System.getProperty("kbeffect.kb")?.trim().orEmpty()
        val inPath = System.getProperty("kbeffect.in")?.trim().orEmpty()
        val outPath = System.getProperty("kbeffect.out")?.trim().orEmpty()
        if (kbPath.isEmpty() || inPath.isEmpty() || outPath.isEmpty()) return

        val all = notes(kbPath)
        check(all.isNotEmpty()) { "没有可用笔记：$kbPath" }
        val cases = JSONObject(File(inPath).readText(Charsets.UTF_8)).getJSONArray("cases")

        val summaryPath = System.getProperty("kbeffect.summary")?.trim().orEmpty()
        val summaryNote = summaryPath.takeIf { it.isNotEmpty() }?.let { notes(it).firstOrNull() }

        val arms = ArrayList<String>(listOf("kb", "nokb", "nocard"))
        if (summaryNote != null) arms.add("summary")

        val root = JSONArray()
        for (ci in 0 until cases.length()) {
            val c = cases.getJSONObject(ci)
            val id = c.getString("id")
            val relationship = c.optString("relationship")
            val card = PersonaCard.parse(c.optString("persona").takeIf { it.isNotBlank() })
            val msgs = c.getJSONArray("messages")
            val lines = ArrayList<Msg>(msgs.length())
            for (mi in 0 until msgs.length()) {
                val m = msgs.getJSONObject(mi)
                lines.add(Msg(side = m.getString("side"), text = m.getString("text")))
            }
            val snapshot = ChatSnapshot(title = null, messages = lines)

            // 检索走 app 自己的实现。空标题 + 只有对话正文，和生产里一致。
            val hits = ContextBuilder.matchNotes(all, snapshot)
            val convo = lines.joinToString("\n") {
                (if (it.side == "me") "我：" else "对方：") + it.text
            }
            val n = 3

            for (arm in arms) {
                // `nocard` 只换人设卡：笔记、对话、关系全都一样，所以差异只可能来自人设。
                val armCard: PersonaCard = if (arm == "nocard") PersonaCard.parse(null) else card
                val ctx: ChatContext? = when (arm) {
                    "nokb" -> null
                    "summary" -> ChatContext(contact = null, history = emptyList(), notes = listOf(summaryNote!!))
                    else -> ChatContext(contact = null, history = emptyList(), notes = hits)
                }
                val system = ReplyPrompt.draftSystemPrompt(n, "follow", "standard", armCard)
                val user = ReplyPrompt.skillNote(ctx) + ReplyPrompt.draftUserPrompt(
                    relationship, ctx, 30, null, armCard, "", convo, emptyList(), n
                )
                val o = JSONObject()
                    .put("id", id)
                    .put("arm", arm)
                    .put("system", system)
                    .put("user", user)
                val hs = JSONArray()
                when (arm) {
                    "kb", "nocard" -> hits.forEach { h ->
                        hs.put(JSONObject().put("title", h.title).put("content", h.content))
                    }
                    "summary" -> hs.put(
                        JSONObject().put("title", summaryNote!!.title).put("content", summaryNote.content)
                    )
                    else -> {}
                }
                o.put("hits", hs)
                root.put(o)
            }

            // 检索侧的现场也留一份，省得实况报告只敢说「回复变了」而说不清
            // 变的是哪几条笔记。只打标题，不打正文。
            println("KBEFECT $id hits=" + hits.size + " " + hits.joinToString(" | ") { it.title })
        }

        val target = File(outPath)
        target.parentFile?.mkdirs()
        target.writeText(root.toString(2), Charsets.UTF_8)
    }
}

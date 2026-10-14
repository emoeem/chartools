package com.jev.probe.core.kb

import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Msg
import com.jev.probe.core.retrieve.LexicalSearch
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * 电脑侧探针：把真机上真实存下来的 `notes.json` 拉进 JVM，用**应用自己的**
 * [ContextBuilder.matchNotes]（同一份代码，不是复制品）算一遍真实网调对话会命中
 * 哪几条笔记。
 *
 * 为什么要有它：手机上只能看到「有没有带知识库进去」这种是与否，看不到「带错了」。
 * 检索这一步错了，后面提示词、模型、排序再对也白搭 —— 所以先在这里把检索摊开看。
 *
 * 输入是真机产物（`app/build/scratch/device_notes.json`，由
 * `adb shell run-as com.jev.probe cat files/kb/notes.json` 拉下来），仓库里没有，
 * 所以文件不在时**跳过**而不是失败。
 *
 * 结果写到 `build/scratch/kb_probe_out.md`。
 */
class ImportedKbProbeTest {

    /**
     * Which library to probe. `build/scratch/PROBE_KB` holds the path of one
     * JSON file, so the same probe can be pointed at the old device snapshot and
     * at a rebuilt library and the two reports diffed — the before/after is the
     * whole point, and a hardcoded path would have made it a one-shot.
     */
    private fun notesFile(): File {
        val ptr = File("build/scratch/PROBE_KB")
        return if (ptr.isFile) File(ptr.readText().trim()) else File("build/scratch/device_notes.json")
    }

    private val fixtureFile = File("build/scratch/roleplay_set.json")
    private val outFile = File("build/scratch/kb_probe_out.md")

    private fun loadEnabled(): List<Note> {
        val arr = JSONArray(notesFile().readText())
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

    /** 和 [ContextBuilder.matchNotes] 里那份 documents 构造逐字一致。 */
    private fun doc(n: Note): String = buildString {
        append(n.title).append(' ')
        n.tags.forEach { append(it).append(' ') }
        append(n.content)
    }

    /** 对照臂：只留正文，去掉标题和标签。 */
    private fun docContentOnly(n: Note): String = n.content

    private fun snap(lines: List<Pair<String, String>>) = ChatSnapshot(
        title = null,
        messages = lines.map { Msg(side = it.first, text = it.second) },
    )

    /** fixture 里每一轮「对方刚说完」时的快照，和生产里一样带上之前的对话。 */
    private fun turns(): List<Triple<String, String, ChatSnapshot>> {
        if (!fixtureFile.isFile) return emptyList()
        val cases = JSONObject(fixtureFile.readText()).getJSONArray("cases")
        val out = ArrayList<Triple<String, String, ChatSnapshot>>()
        for (ci in 0 until cases.length()) {
            val c = cases.getJSONObject(ci)
            val ts = c.getJSONArray("turns")
            val lines = ArrayList<Pair<String, String>>()
            for (ti in 0 until ts.length()) {
                val other = ts.getJSONObject(ti).getString("other")
                lines.add("other" to other)
                out.add(Triple(c.getString("id"), other, snap(lines)))
                lines.add("me" to "（我的回复）")
            }
        }
        return out
    }

    private fun hay(s: ChatSnapshot): String = buildString {
        s.messages.takeLast(30).forEach { append(KbStore.normalizeText(it.text)).append('\n') }
    }

    @Test
    fun probe() {
        assumeTrue("no notes at ${notesFile().absolutePath}", notesFile().isFile)
        val notes = loadEnabled()
        check(notes.isNotEmpty()) { "notes.json had no enabled notes" }

        val sb = StringBuilder()
        fun p(s: String) = sb.append(s).append('\n')

        val all = notes.map { doc(it) }
        val ts = turns()

        p("# 导入知识库检索探针（电脑侧，用应用自己的 matchNotes）")
        p("")
        p("笔记文件：`${notesFile().absolutePath}`")
        p("启用笔记：**${notes.size}** 条，正文合计 **${notes.sumOf { it.content.length }}** 字")
        p("")

        // ---------- 0. 规模 ----------
        val t0 = System.nanoTime()
        val toks = LexicalSearch.tokenize(all.joinToString("\n"))
        val t1 = System.nanoTime()
        p("## 0. 规模与成本")
        p("")
        p("- 文档数 ${all.size}，文档字符数 ${all.sumOf { it.length }}")
        p("- 整库分词一次 ${(t1 - t0) / 1_000_000} ms / ${toks.size} 个 token")
        p("- 生产里 `LexicalSearch.search` **每次调用都重新分词全部文档**，一次分析调用它两次")
        p("- 结论：**成本不是问题**（十几毫秒），问题在准不准。")
        p("")

        // ---------- 1. 真实场景逐轮命中 ----------
        p("## 1. 真实网调场景：对方每说一句，会注入哪 5 条")
        p("")
        p("对话标题留空，只有正文参与。")
        p("")
        val perTurn = ArrayList<List<Note>>()
        var lastId = ""
        for ((id, other, s) in ts) {
            if (id != lastId) {
                p("### $id")
                p("")
                lastId = id
            }
            val hits = ContextBuilder.matchNotes(notes, s)
            perTurn.add(hits)
            p("对方：`$other`")
            p("")
            if (hits.isEmpty()) p("- ⚠️ **零命中**") else hits.forEach { h ->
                p("- `${h.title.take(46)}`")
            }
            p("")
        }
        p("")

        // ---------- 2. 集中度 ----------
        val tally = HashMap<String, Int>()
        perTurn.forEach { hs -> hs.forEach { tally[it.title] = (tally[it.title] ?: 0) + 1 } }
        val zero = perTurn.count { it.isEmpty() }
        p("## 2. 命中集中度：是不是「问什么都回同样几条」")
        p("")
        p("共 ${perTurn.size} 轮，其中 **$zero 轮零命中**。被命中的不同笔记只有 **${tally.size}** 条（总共 ${notes.size} 条可选）。")
        p("")
        p("| 笔记 | 被命中轮数 |")
        p("| --- | --- |")
        tally.entries.sortedByDescending { it.value }.take(15).forEach { (t, n) ->
            p("| `${t.take(50)}` | $n |")
        }
        p("")

        // ---------- 3. 归因：靠什么词赢的 ----------
        val docTok = all.map { LexicalSearch.tokenize(it).toSet() }
        val df = HashMap<String, Int>()
        docTok.forEach { set -> set.forEach { t -> df[t] = (df[t] ?: 0) + 1 } }
        val n = notes.size
        var sharedTotal = 0
        var commonTotal = 0
        var rareTotal = 0
        val example = StringBuilder()
        for ((i, t) in ts.withIndex()) {
            val q = LexicalSearch.tokenize(hay(t.third)).distinct()
            val top = perTurn[i].firstOrNull() ?: continue
            val idx = notes.indexOf(top)
            if (idx < 0) continue
            val shared = q.filter { it in docTok[idx] }
            val common = shared.filter { (df[it] ?: 0) > n / 2 }
            val rare = shared.filter { (df[it] ?: 0) <= n / 20 }
            sharedTotal += shared.size
            commonTotal += common.size
            rareTotal += rare.size
            if (example.isEmpty() && shared.isNotEmpty()) {
                example.append("- 对方：`${t.second}`\n")
                example.append("- 赢家：`${top.title.take(46)}`，得分最高的那条\n")
                example.append("- 它和这句话共有的词：${shared.take(14).joinToString("、") { "`$it`(" + (df[it] ?: 0) + ")" }}\n")
                example.append("- 其中超过半数笔记都有的「废话词」：${common.take(14).joinToString("、") { "`$it`" }.ifEmpty { "（无）" }}\n")
                example.append("- 真正稀有的判别词：${rare.take(14).joinToString("、") { "`$it`" }.ifEmpty { "**一个都没有**" }}\n")
            }
        }
        val roundsWithHit = perTurn.count { it.isNotEmpty() }
        p("## 3. 归因：它是靠哪些词赢的")
        p("")
        if (roundsWithHit > 0) {
            p("取每轮的第一名，数它和这句话共有的词：")
            p("")
            p("- 平均共有词 **${"%.1f".format(sharedTotal.toDouble() / roundsWithHit)}** 个")
            p("- 其中「超过一半笔记都有」的词平均 **${"%.1f".format(commonTotal.toDouble() / roundsWithHit)}** 个")
            p("- 其中「只有不到 5% 笔记有」的判别词平均 **${"%.1f".format(rareTotal.toDouble() / roundsWithHit)}** 个")
            p("")
            example.toString().let { if (it.isNotEmpty()) { p("一个实例："); p(""); p(it) } }
        }
        p("")

        // ---------- 4. 标签污染对照 ----------
        val tagDf = HashMap<String, Int>()
        notes.forEach { note -> LexicalSearch.tokenize(note.tags.joinToString(" ")).toSet().forEach { tagDf[it] = (tagDf[it] ?: 0) + 1 } }
        p("## 4. 对照：标题+标签 对排名做了什么")
        p("")
        p("导入时每条笔记的 tags 是 `[\"文档导入\", 原文件名]`。`文档导入` 在 ${tagDf["文档导入"] ?: 0}/$n 条里出现，")
        p("文件名里几乎都含「网调」「调教」—— 也就是说**每条笔记天生都带这两个词**。")
        p("")
        p("| | 生产（标题+标签+正文） | 对照（只有正文） |")
        p("| --- | --- | --- |")
        val diffs = ArrayList<String>()
        for ((i, t) in ts.withIndex()) {
            val a = perTurn[i].firstOrNull()
            val b = LexicalSearch.search(hay(t.third), notes.map { docContentOnly(it) }, k = 5, minScore = 0.15)
                .firstOrNull()?.let { notes[it.index] }
            if (a?.title != b?.title) diffs.add("- `|${t.second.take(24)}|` 生产→`${a?.title?.take(30) ?: "零命中"}` / 正文→`${b?.title?.take(30) ?: "零命中"}`")
        }
        p("")
        p("两臂首选不同的轮次：**${diffs.size}/${ts.size}**")
        p("")
        diffs.take(10).forEach { p(it) }
        p("")

        // ---------- 5. 预算：5 条命中最后真进提示词几条 ----------
        // 逐字复刻 ContextBuilder 的 estimateTokens / cost / 两道裁剪循环。
        fun est(text: String): Int {
            if (text.isBlank()) return 0
            var tokens = 0
            var ascii = 0
            for (ch in text) if (ch.code < 128) ascii++ else tokens++
            return tokens + ((ascii + 3) / 4)
        }
        fun cost(ns: List<Note>, hist: List<String>): Int =
            ns.sumOf { est(it.title + " " + it.content) + 2 } + hist.sumOf { est(it) + 3 }

        p("## 5. 预算：命中的 5 条，最后真进提示词几条")
        p("")
        val budget = ContextBuilder.BUDGET_TOKENS
        val floor = ContextBuilder.MIN_HISTORY
        p("`BUDGET_TOKENS = $budget`、`MIN_HISTORY = $floor`（直接读 ContextBuilder 的常量，不复制）。")
        p("裁剪顺序：**历史先降到 $floor 行，然后从末尾丢笔记，最后才动历史**。")
        p("")
        p("| 对方 | 命中条数 | 单条笔记 token | 裁剪前 cost | 裁完 notes | 裁完 history |")
        p("| --- | --- | --- | --- | --- | --- |")
        var hist = ArrayList<String>()
        var lastCase = ""
        var totalAfter = 0
        var rows = 0
        for ((i, t) in ts.withIndex()) {
            if (t.first != lastCase) { hist = ArrayList(); lastCase = t.first }
            hist.add(t.second)
            val hits = perTurn[i]
            val before = cost(hits, hist)
            val th = ArrayList(hist)
            val tn = ArrayList(hits)
            while (cost(tn, th) > budget && th.size > floor) th.removeAt(0)
            while (cost(tn, th) > budget && tn.isNotEmpty()) tn.removeAt(tn.size - 1)
            while (cost(tn, th) > budget && th.isNotEmpty()) th.removeAt(0)
            val avg = if (hits.isEmpty()) 0 else hits.sumOf { est(it.title + " " + it.content) + 2 } / hits.size
            p("| `${t.second.take(18)}` | ${hits.size} | $avg | $before | **${tn.size}** | ${th.size} |")
            totalAfter += tn.size
            rows++
            hist.add("（我的回复）")
        }
        p("")
        p("平均真正进提示词的笔记：**${"%.1f".format(totalAfter.toDouble() / rows.coerceAtLeast(1))}** 条（命中上限写的是 5 条）。")
        p("")

        // ---------- 6. 阈值体检 ----------
        p("## 6. 阈值体检：`minScore = 0.15` 卡掉了什么")
        p("")
        p("| 消息 | 原始最高分 | 过 0.15 的条数 | 不过线时的第一名 |")
        p("| --- | --- | --- | --- |")
        for (q in listOf(
            "我其实没做过sp……有点怕", "……嗯。那你想要我怎么做", "我不想做作业",
            "红灯", "你今天怎么回我这么慢", "你好", "在吗", "我在楼道里了，现在做什么",
        )) {
            val raw = LexicalSearch.search(q, all, k = 1, minScore = 0.0).firstOrNull()
            val pass = LexicalSearch.search(q, all, k = 99, minScore = 0.15).size
            p("| `$q` | ${raw?.let { "%.3f".format(it.score) } ?: "—"} | $pass | ${raw?.let { notes[it.index].title.take(26) } ?: "—"} |")
        }
        p("")

        outFile.parentFile?.mkdirs()
        outFile.writeText(sb.toString())
        println(sb.toString())
    }
}

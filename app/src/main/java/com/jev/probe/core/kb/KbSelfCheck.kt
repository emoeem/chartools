package com.jev.probe.core.kb

import android.content.Context
import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Msg
import com.jev.probe.core.Prefs

/**
 * On-device smoke test for the knowledge-base path, reachable from the settings
 * screen ("自检"). It exercises the parts that are easy to get quietly wrong —
 * name normalization across half/full-width member counts, note keyword hits,
 * and history de-duplication against what is already on screen — then removes
 * everything it created.
 *
 * It runs against the real [KbStore] (temporary note + contact, deleted at the
 * end) but a scratch [Prefs] file, so the user's own contextEnabled setting is
 * never touched.
 */
object KbSelfCheck {

    private const val SCRATCH_PREFS = "jev_kb_selfcheck_scratch"
    private const val BARE = "测试群"
    private const val TITLE = "测试群(12)"
    private const val ALIAS = "测试群（12）"          // full-width parens on purpose
    private const val PADDED = "  测试群  "
    private const val OLD_LINE = "上周说好周五交自检稿"

    /** 自检用的主题名：故意不可能撞上真实知识库里的标签。 */
    private const val TOPIC = "自检主题"

    /** @return a one-line human-readable pass/fail summary. */
    fun run(context: Context): String {
        val failures = ArrayList<String>()

        // 0. Name normalization, checked first and on its own: its patterns are
        //    compiled in KbStore's class initializer, and a pattern the device's
        //    regex engine rejects used to take the whole class (and every
        //    analysis) down with an ExceptionInInitializerError.
        runCatching {
            listOf(TITLE, ALIAS, PADDED, BARE).forEach { raw ->
                val got = KbStore.normalizeName(raw)
                if (got != BARE)
                    failures.add("名称归一化失败：输入 ${raw} 得到 ${got}，应为 ${BARE}")
            }
        }.onFailure {
            failures.add("名称归一化异常：${it.javaClass.simpleName} ${it.message ?: ""}")
        }

        val store = KbStore.get(context)
        val noteId = KbStore.newId()
        val contactId = KbStore.newId()
        val topicNoteId = KbStore.newId()
        val prefs = scratchPrefs(context)
        try {
            prefs.contextEnabled = true
            prefs.contextHistoryCount = 30

            store.saveNote(Note(
                id = noteId,
                title = "自检临时笔记",
                content = "自检用的虚构事实：项目代号叫小蓝。",
                tags = listOf("测试"),
                alwaysOn = false,
                enabled = true
            ))
            store.saveContact(Contact(
                id = contactId,
                name = "自检临时联系人",
                aliases = listOf(ALIAS),
                apps = listOf("com.jev.probe"),
                relationship = "自检用的关系描述"
            ))

            val snapshot = ChatSnapshot(TITLE, listOf(
                Msg("other", "自检消息一：这条够长可以去重"),
                Msg("me", "自检消息二：这条也够长")
            ))

            // 1. contact hit via full-width alias + member-count stripping
            val ctx1 = ContextBuilder.build(context, snapshot, "com.jev.probe", prefs)
            if (ctx1.contact?.id != contactId)
                failures.add("联系人未命中（标题 ${TITLE} 应匹配别名 ${ALIAS}）")

            // 2. note hit via tag "测试" appearing in the conversation title
            if (ctx1.notes.none { it.id == noteId })
                failures.add("笔记未命中（tag=测试 应命中标题 ${TITLE}）")

            // 3. the on-screen messages were recorded but not echoed back as history
            if (ctx1.history.isNotEmpty())
                failures.add("历史去重失败：当屏消息不该出现在注入历史里（${ctx1.history.size} 条）")
            if (store.logSize(contactId) != snapshot.messages.size)
                failures.add("历史落盘条数不对：期望 ${snapshot.messages.size}，实际 ${store.logSize(contactId)}")

            // 4. an older line survives, and re-reading the same screen adds nothing
            //    (screenBatch=false: this is a hand-injected line, not a capture,
            //    so it is not measured against the last screen we recorded)
            store.appendLog(contactId, listOf(
                LogEntry("other", OLD_LINE, System.currentTimeMillis() - 86_400_000L, "com.jev.probe")),
                screenBatch = false)
            val ctx2 = ContextBuilder.build(context, snapshot, "com.jev.probe", prefs)
            if (ctx2.history.size != 1 || ctx2.history.firstOrNull()?.text != OLD_LINE)
                failures.add("历史注入不对：期望仅 1 条旧消息，实际 ${ctx2.history.size} 条")
            if (store.logSize(contactId) != snapshot.messages.size + 1)
                failures.add("重复采集被写了第二遍：${store.logSize(contactId)} 条")

            // 5. background carries the fabricated fact into the prompt
            val background = ctx2.background("默认关系")
            if (!background.contains("小蓝")) failures.add("background 里没有笔记正文")
            if (!background.contains("自检用的关系描述")) failures.add("background 里没有联系人关系")

            // 6. history is off by default (opt-in only)
            prefs.contextEnabled = false
            if (ContextBuilder.build(context, snapshot, "com.jev.probe", prefs).history.isNotEmpty())
                failures.add("contextEnabled=false 时仍注入了历史")

            // 7. 人设卡的主题接管知识库。三种状态都要试，因为收窄有两条"退回全库"
            //    的路（主题为空、主题没有笔记标过），只测命中那一条会把整个后退逻辑
            //    留成没测过的分支 —— 而它恰好是"知识库突然闭嘴"的唯一防线。
            prefs.contextEnabled = true
            store.saveNote(Note(
                id = topicNoteId,
                title = "自检主题笔记",
                content = "自检用的主题内容：自检暗号是青鸟。",
                tags = listOf(TOPIC),
                alwaysOn = false,
                enabled = true
            ))
            prefs.style = "称呼：测试\n主题：$TOPIC"
            val ctx3 = ContextBuilder.build(context, snapshot, "com.jev.probe", prefs)
            if (ctx3.notes.none { it.id == topicNoteId })
                failures.add("人设主题命中失败：标了「$TOPIC」的笔记没进注入")
            if (ctx3.notes.any { it.id == noteId })
                failures.add("人设主题没生效：没标「$TOPIC」的笔记仍被注入")

            prefs.style = "主题：没有笔记标过的主题"
            val ctx4 = ContextBuilder.build(context, snapshot, "com.jev.probe", prefs)
            if (ctx4.notes.none { it.id == noteId })
                failures.add("主题无命中时应退回全库，但笔记不再被注入（知识库被静默关掉了）")

            prefs.style = ""
        } catch (e: Exception) {
            failures.add("异常：${e.javaClass.simpleName} ${e.message ?: ""}")
        } finally {
            runCatching { store.deleteNote(noteId) }
            runCatching { store.deleteNote(topicNoteId) }
            runCatching { store.deleteContact(contactId) }
            runCatching {
                context.getSharedPreferences(SCRATCH_PREFS, Context.MODE_PRIVATE)
                    .edit().clear().commit()
            }
        }
        val counts = store.counts()
        // 报告的是**用户真实的那份设置**（scratch 文件刚被清掉），因为这一行的用处
        // 就是回答「我设的人设到底生效没有」。
        val real = PersonaCard.parse(runCatching { Prefs(context).style }.getOrDefault(""))
        val live = store.notes().filter { it.enabled }
        val pool = live.filter { !it.alwaysOn && it.type != NOTE_TYPE_STYLE_SAMPLE }
        val persona = when {
            !real.hasContent() -> "人设未设置（回复不带人设，知识库也不按主题收窄）"
            !real.structured -> "人设已填但没认出任何键：只当一段文本注入，主题/硬边界/语域都不生效"
            else -> "人设已启用 · 主题「${real.topic.ifBlank { "未填" }}」"
        }
        return if (failures.isEmpty())
            "自检通过：联系人匹配 / 笔记命中 / 历史去重 / 人设主题作用域 / 预算注入都正常。" +
                "$persona。" +
                PersonaStatus.scopeLine(TopicScope.scopeOf(pool, real.topic),
                    live.count { it.alwaysOn && it.type != NOTE_TYPE_STYLE_SAMPLE }) +
                "当前知识库 ${counts.notes} 条笔记、${counts.contacts} 个联系人、${counts.logLines} 条历史。"
        else "自检失败（${failures.size}）：" + failures.joinToString("；")
    }

    /** A [Prefs] bound to a throwaway SharedPreferences file (no migration, no log). */
    private fun scratchPrefs(context: Context): Prefs {
        context.getSharedPreferences(SCRATCH_PREFS, Context.MODE_PRIVATE).edit().clear().commit()
        return Prefs(context, SCRATCH_PREFS)
    }
}

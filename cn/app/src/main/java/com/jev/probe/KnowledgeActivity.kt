package com.jev.probe

import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import com.jev.probe.core.Palette
import com.jev.probe.core.Prefs
import com.jev.probe.core.kb.Contact
import com.jev.probe.core.kb.DomainBrief
import com.jev.probe.core.kb.KbStore
import com.jev.probe.core.kb.NOTE_TYPE_STYLE_SAMPLE
import com.jev.probe.core.kb.Note
import com.jev.probe.core.kb.PersonaCard
import com.jev.probe.core.kb.PersonaPresets
import com.jev.probe.core.kb.PersonaStatus
import com.jev.probe.core.kb.PersonaStore
import com.jev.probe.core.kb.TopicScope
import com.jev.probe.core.skill.Skill
import com.jev.probe.core.skill.SkillMatcher
import com.jev.probe.core.skill.SkillRef
import com.jev.probe.core.skill.SkillStore
import com.jev.probe.jev.ReplyClient
import com.jev.probe.capture.ChatApps
import kotlin.math.roundToInt

/**
 * Knowledge base manager: the notes the assistant may quote, the contacts that
 * tie a conversation title (across apps) to a person, and the skills that can
 * lend it a procedure.
 *
 * Everything shown here lives in the app-private `filesDir/kb` and
 * `filesDir/skills` directories and nowhere else. Plain code-built views, same
 * card/pill vocabulary as [SettingsActivity].
 */
class KnowledgeActivity : AppCompatActivity() {

    private lateinit var store: KbStore
    private lateinit var skills: SkillStore
    private lateinit var container: LinearLayout

    /** 0 = notes, 1 = contacts, 2 = skills. */
    private var tab = 0

    /** The skill zip picker. Read once, on the spot — nothing is persisted. */
    private val pickSkillZip = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri ?: return@registerForActivityResult
        Thread {
            val msg = try {
                val stream = contentResolver.openInputStream(uri)
                if (stream == null) "打不开这个文件" else stream.use { skills.importZip(it) }
            } catch (e: Exception) {
                "导入失败：${e.javaClass.simpleName}"
            }
            runOnUiThread { toast(msg); render() }
        }.start()
    }

    private val accent = Palette.brand()
    private val ink = Color.parseColor("#111827")
    private val sub = Color.parseColor("#6B7280")
    private val pillOff = Color.parseColor("#EEF1F5")
    private val red = Color.parseColor("#DC2626")

    private fun dp(v: Int) = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).roundToInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = KbStore.get(this)
        skills = SkillStore.get(this)
        window.decorView.setBackgroundColor(Color.parseColor("#F2F3F5"))

        val scroll = ScrollView(this)
        container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(22), dp(18), dp(28))
        }
        container.padForSystemBars()   // edge-to-edge: keep the title off the status bar
        scroll.addView(container)
        setContentView(scroll)
        render()
    }

    // --------------------------------------------------------------- screens

    private fun render() {
        container.removeAllViews()
        container.addView(text("知识库与联系人", 24f, ink, bold = true))
        container.addView(text("只存在本机，不上传。分析时按会话标题匹配联系人、按关键词命中笔记，按对话内容决定要不要用某个技能。",
            12f, sub).apply { setPadding(0, dp(6), 0, dp(4)) })
        container.addView(tabs())
        // 导入类动作统一收进「＋ 导入」菜单：按钮不再随功能越加越多
        // （ui-overhaul 考察 P2）。
        if (tab != 1) {
            container.addView(twoButtons("＋ 导入", { showImportMenu() }, null, null))
        }
        when (tab) {
            0 -> renderNotes()
            1 -> renderContacts()
            else -> renderSkills()
        }
    }

    /** 导入菜单：笔记 tab 是文档/文本，技能 tab 是 zip/SKILL.md。 */
    private fun showImportMenu() {
        val items = if (tab == 0)
            arrayOf("从文件导入（PDF / Word / EPUB / 网页…）", "从文本导入")
        else
            arrayOf("导入技能包(.zip)", "粘贴 SKILL.md")
        AlertDialog.Builder(this)
            .setTitle("导入")
            .setItems(items) { _, which ->
                when {
                    tab == 0 && which == 0 -> startActivity(Intent(this, DocImportActivity::class.java))
                    tab == 0 && which == 1 -> importNotesDialog()
                    which == 0 -> pickSkillZip.launch(arrayOf("application/zip", "*/*"))
                    else -> pasteSkillDialog()
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun tabs(): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(12) }
        }
        listOf("笔记", "联系人", "技能").forEachIndexed { i, name ->
            val pill = TextView(this).apply {
                text = name; textSize = 13f; gravity = Gravity.CENTER
                setPadding(dp(18), dp(8), dp(18), dp(8))
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT).apply { rightMargin = dp(8) }
                setTextColor(if (i == tab) Color.WHITE else sub)
                setTypeface(typeface, if (i == tab) Typeface.BOLD else Typeface.NORMAL)
                background = round(dp(9), if (i == tab) accent else pillOff)
                setOnClickListener { tab = i; render() }
            }
            row.addView(pill)
        }
        return row
    }


    // ----------------------------------------------------------------- notes

    private fun renderNotes() {
        val notes = store.notes().sortedByDescending { it.updatedAt }
        container.addView(twoButtons("新建笔记", { editNoteDialog(null) }, null, null))
        container.addView(twoButtons("整库预扫成领域卡（推荐）", { domainBriefDialog() }, null, null))
        container.addView(topicScopeCard(notes))
        if (notes.isEmpty()) {
            container.addView(emptyCard("还没有笔记。写点该记住的事实：习惯、忌口、项目代号、约定过的时间。" +
                "也可以勾「语气示例」，贴上几句你平时真会说的话，助手会照着你的口吻写。"))
            return
        }
        notes.forEach { container.addView(noteRow(it)) }
        container.addView(text("点条目编辑，长按删除。勾了「语气示例」的条目只当写法的样本，不会被当成事实引用；" +
            "其余笔记按 BM25 相关度命中最近 30 条消息后注入。", 11f, sub).apply { setPadding(dp(2), dp(12), 0, 0) })
    }

    /**
     * 人设主题 ↔ 知识库的联动，摊开写给人看，并给出一条补救路径。
     *
     * 这是「我选了网调人设，知识库到底有没有跟着换」这个问题唯一的答案面：
     * 主题为空 → 告诉用户去哪儿写；主题有、但一条笔记都没标 → 一键补标签
     * （否则收窄不会生效，见 [TopicScope.narrow]）；收窄生效 → 报出实际条数。
     */
    private fun topicScopeCard(all: List<Note>): View {
        val topic = TopicScope.topicOf(Prefs(this))
        val pool = all.filter { it.enabled && !it.alwaysOn && it.type != NOTE_TYPE_STYLE_SAMPLE }
        val alwaysOn = all.count { it.alwaysOn && it.type != NOTE_TYPE_STYLE_SAMPLE }
        val scope = TopicScope.scopeOf(pool, topic)
        val c = card()
        c.addView(text(PersonaStatus.scopeLine(scope, alwaysOn), 12f, ink))
        when {
            topic.isBlank() -> c.addView(text("在「设置 → 人设」里写一行「主题：网调」（点模板也行），" +
                "这里就会只按这个主题检索；导入的文件也会自动带上这个标签。",
                11f, sub).apply { setPadding(0, dp(6), 0, 0) })
            scope.active -> c.addView(text("换人设就是换知识库：主题一改，参与检索的笔记跟着换。",
                11f, sub).apply { setPadding(0, dp(6), 0, 0) })
            else -> {
                c.addView(twoButtons("给这 ${scope.total} 条笔记补上「$topic」标签", {
                    confirm("补主题标签", "给没有「$topic」标签的笔记加上这个标签。" +
                        "标签只多不少，其它标签不动。") {
                        val changed = pool.mapNotNull { n ->
                            val t = TopicScope.tagged(n, topic)
                            if (t.tags == n.tags) null else t
                        }
                        Thread {
                            val n = if (changed.isEmpty()) 0 else store.saveNotes(changed)
                            runOnUiThread {
                                toast(if (changed.isEmpty()) "都已经是这个主题了" else "已补 $n 条")
                                render()
                            }
                        }.start()
                    }
                }, null, null))
            }
        }
        return c
    }

    private fun noteRow(n: Note): View {
        val c = card()
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
        }
        val left = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val head = n.title.ifBlank { "（无标题）" } +
            (if (n.type == NOTE_TYPE_STYLE_SAMPLE) "  · 语气示例" else "") +
            (if (n.alwaysOn) "  · 常驻" else "")
        left.addView(text(head, 15f, ink, bold = true))
        left.addView(text(
            if (n.tags.isEmpty()) "无标签" else "标签：" + n.tags.joinToString("、"),
            12f, sub).apply { setPadding(0, dp(3), 0, 0) })
        left.addView(text(n.content.replace("\n", " ").take(46), 12f, sub)
            .apply { setPadding(0, dp(3), 0, 0) })
        row.addView(left)
        row.addView(smallToggle(n.enabled) {
            store.saveNote(n.copy(enabled = !n.enabled)); render()
        })
        c.addView(row)
        c.setOnClickListener { editNoteDialog(n) }
        c.setOnLongClickListener {
            confirm("删除笔记", "删除「${n.title}」？不可恢复。") {
                store.deleteNote(n.id); render()
            }
            true
        }
        return c
    }

    private fun editNoteDialog(existing: Note?) {
        val box = dialogBox()
        val titleEdit = edit(existing?.title ?: "", "标题，例如：口味忌口")
        val contentEdit = edit(existing?.content ?: "", "正文，写清楚事实本身").apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = 4; gravity = Gravity.TOP
        }
        val tagsEdit = edit(existing?.tags?.joinToString("，") ?: "", "逗号分隔，例如：吃饭，周末")
        val styleRow = toggleRow("语气示例（贴几句我平时真会说的话）", existing?.type == NOTE_TYPE_STYLE_SAMPLE)
        val alwaysRow = toggleRow("常驻（每次分析都带上）", existing?.alwaysOn ?: false)
        val enabledRow = toggleRow("启用", existing?.enabled ?: true)
        box.addView(label("标题")); box.addView(titleEdit)
        box.addView(label("正文")); box.addView(contentEdit)
        box.addView(label("标签")); box.addView(tagsEdit)
        box.addView(styleRow)
        box.addView(text("语气示例只当写法的样本（正文里直接写你平时的说法，可以多行），" +
            "不会被当成事实、也不会进判断那一路。最多用 3 条。", 11f, sub))
        box.addView(alwaysRow); box.addView(enabledRow)

        AlertDialog.Builder(this)
            .setTitle(if (existing == null) "新建笔记" else "编辑笔记")
            .setView(wrapScroll(box))
            .setPositiveButton("保存") { _, _ ->
                val title = titleEdit.text.toString().trim()
                val content = contentEdit.text.toString().trim()
                if (title.isBlank() && content.isBlank()) {
                    toast("标题和正文不能都空着"); return@setPositiveButton
                }
                store.saveNote(Note(
                    id = existing?.id ?: KbStore.newId(),
                    title = title,
                    content = content,
                    tags = splitTags(tagsEdit.text.toString()),
                    alwaysOn = (alwaysRow.tag as? Boolean) ?: false,
                    enabled = (enabledRow.tag as? Boolean) ?: true,
                    type = if ((styleRow.tag as? Boolean) == true) NOTE_TYPE_STYLE_SAMPLE else "note"
                ))
                render()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun importNotesDialog() {
        val box = dialogBox()
        box.addView(text("按空行分段，每段第一行当标题，其余当正文。", 12f, sub))
        val input = edit("", "口味忌口\n不吃香菜，海鲜过敏\n\n项目代号\n内部叫小蓝").apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = 8; gravity = Gravity.TOP
        }
        box.addView(input)
        AlertDialog.Builder(this)
            .setTitle("从文本导入")
            .setView(wrapScroll(box))
            .setPositiveButton("导入") { _, _ ->
                val chunks = input.text.toString().split(Regex("\\r?\\n[ \\t]*\\r?\\n"))
                var n = 0
                chunks.forEach { chunk ->
                    val lines = chunk.trim().split("\n").map { it.trim() }.filter { it.isNotEmpty() }
                    if (lines.isNotEmpty()) {
                        store.saveNote(Note(
                            id = KbStore.newId(),
                            title = lines.first(),
                            content = lines.drop(1).joinToString("\n")
                        ))
                        n++
                    }
                }
                toast(if (n == 0) "没解析出内容" else "已导入 $n 条")
                render()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun splitTags(raw: String): List<String> =
        raw.split(",", "，", "、").map { it.trim() }.filter { it.isNotEmpty() }

    /**
     * 整库预扫成一张**领域卡**。这是知识库真正开始起作用的那一步：导入 678 条笔记
     * 之后，靠 BM25 每轮挑 5 段原始片段，实测只比没有笔记好 0.33 分（4.45 vs 4.12，
     * 见 `_reports/kb-effect_report.md`），而把整库先压成一张卡是 4.60、提示词还只有
     * 1/4 长。思路来自 /home/emo/code/wenyi 的「全书预扫 → 注入每批」。
     *
     * 它要花一次真实请求、一段真实额度，所以必须由用户自己点，而且点之前就把「花
     * 什么、换什么」说清楚。生成完是一条常驻笔记，每轮都在，不靠检索去猜该不该带。
     */
    private fun domainBriefDialog() {
        val notes = store.notes().filter { it.enabled }
        if (notes.isEmpty()) { toast("知识库还是空的，先导入文件再预扫"); return }
        val sample = DomainBrief.sample(notes)
        if (sample.isBlank()) { toast("没有可用的笔记正文"); return }

        val box = dialogBox()
        box.addView(text("会把这 ${notes.size} 条笔记（约 ${DomainBrief.hanCount(sample)} 字采样）" +
            "发给助手模型，让它归纳成一张不超过 ${DomainBrief.MAX_HAN} 字的领域卡，存成一条「常驻」笔记。" +
            "之后每次分析都带上它，不再靠检索去猜该不该带。", 12f, sub))
        val topicEdit = edit(
            PersonaCard.parse(Prefs(this).style).topic.ifBlank { DomainBrief.DEFAULT_TOPIC },
            "主题，例如：网调 / 装修 / 带娃")
        box.addView(label("这张卡属于哪个主题"))
        box.addView(topicEdit)
        box.addView(text("一张卡只服务一个主题。要第二个主题，就用第二个主题名再预扫一次。" +
            "同名的卡会被覆盖，不会越攒越多。", 11f, sub))

        AlertDialog.Builder(this)
            .setTitle("整库预扫成领域卡")
            .setView(wrapScroll(box))
            .setPositiveButton("开始预扫") { _, _ ->
                val topic = topicEdit.text.toString().trim().ifBlank { DomainBrief.DEFAULT_TOPIC }
                runDomainBrief(topic, sample)
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun runDomainBrief(topic: String, sample: String) {
        val wait = AlertDialog.Builder(this)
            .setTitle("正在预扫「$topic」")
            .setMessage("模型正在读全部笔记并归纳，通常十几秒。这一步会消耗一次生成额度。")
            .setCancelable(false)
            .create()
        wait.show()
        Thread {
            val outcome = try {
                val text = ReplyClient(Prefs(this)).domainBrief(topic, sample)
                val note = DomainBrief.note(text, topic)
                if (note == null) {
                    "模型没写出可用的内容，知识库没动"
                } else {
                    // 同主题的旧卡就覆盖，别让每次预扫都多留一条常驻笔记。
                    val old = store.notes().firstOrNull {
                        it.alwaysOn && it.title == DomainBrief.title(topic)
                    }
                    store.saveNote(if (old == null) note else note.copy(id = old.id))
                    "领域卡已保存（${DomainBrief.hanCount(note.content)} 字），已设为常驻"
                }
            } catch (e: Exception) {
                "预扫失败：${e.javaClass.simpleName}${e.message?.let { " · " + it.take(80) } ?: ""}"
            }
            runOnUiThread { wait.dismiss(); toast(outcome); render() }
        }.start()
    }

    // -------------------------------------------------------------- contacts

    private fun renderContacts() {
        val contacts = store.contacts().sortedByDescending { it.updatedAt }
        container.addView(twoButtons("新建联系人", { editContactDialog(null) }, null, null))
        if (contacts.isEmpty()) {
            container.addView(emptyCard(
                "还没有联系人。也可以在聊天里长按悬浮球，选「把当前会话存为联系人」。"))
            return
        }
        contacts.forEach { container.addView(contactRow(it)) }
        container.addView(text("点条目编辑，长按删除。会话标题等于名字或任一别名即算命中（忽略大小写与群人数后缀）。",
            11f, sub).apply { setPadding(dp(2), dp(12), 0, 0) })
    }

    private fun contactRow(c0: Contact): View {
        val c = card()
        c.addView(text(c0.name.ifBlank { "（无名）" }, 15f, ink, bold = true))
        if (c0.aliases.isNotEmpty())
            c.addView(text("别名：" + c0.aliases.joinToString("、"), 12f, sub)
                .apply { setPadding(0, dp(3), 0, 0) })
        if (c0.apps.isNotEmpty())
            c.addView(text("来源：" + c0.apps.joinToString("、") { appLabel(it) }, 12f, sub)
                .apply { setPadding(0, dp(3), 0, 0) })
        if (c0.relationship.isNotBlank())
            c.addView(text("关系：" + c0.relationship.replace("\n", " ").take(40), 12f, sub)
                .apply { setPadding(0, dp(3), 0, 0) })
        if (c0.notes.isNotBlank())
            c.addView(text("备注：" + c0.notes.replace("\n", " ").take(40), 12f, sub)
                .apply { setPadding(0, dp(3), 0, 0) })
        if (c0.persona.isNotBlank())
            c.addView(text("人设：" + c0.persona.replace("\n", " ").take(50), 12f, sub)
                .apply { setPadding(0, dp(3), 0, 0) })

        val logN = store.logSize(c0.id)
        val clear = TextView(this).apply {
            text = "清空此人历史（$logN 条）"
            textSize = 12.5f; setTextColor(red); setTypeface(typeface, Typeface.BOLD)
            setPadding(0, dp(10), 0, dp(2))
            setOnClickListener {
                if (logN == 0) { toast("本来就没有历史"); return@setOnClickListener }
                confirm("清空历史", "删掉「${c0.name}」的 $logN 条聊天历史？联系人档案保留。") {
                    store.clearLog(c0.id); render()
                }
            }
        }
        c.addView(clear)
        c.setOnClickListener { editContactDialog(c0) }
        c.setOnLongClickListener {
            confirm("删除联系人", "删除「${c0.name}」及其全部历史？不可恢复。") {
                store.deleteContact(c0.id); render()
            }
            true
        }
        return c
    }

    private fun editContactDialog(existing: Contact?) {
        val box = dialogBox()
        val nameEdit = edit(existing?.name ?: "", "名字，一般就是会话标题")
        val aliasEdit = edit(existing?.aliases?.joinToString("\n") ?: "", "每行一个，例如另一个 App 里的昵称").apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = 3; gravity = Gravity.TOP
        }
        val relEdit = edit(existing?.relationship ?: "", "例如：同事，带我做项目的组长")
        val notesEdit = edit(existing?.notes ?: "", "关于这个人要记住的事").apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = 3; gravity = Gravity.TOP
        }
        val personaEdit = edit(
            existing?.persona ?: "",
            "这个联系人专用的回复人设。写一句话也行；写成下面这种键值卡会更准：" +
                "称呼／关系／语气／语域／主题／情境／硬边界／避谈／安全词／示例。" +
                "「主题」写这段对话整体属于哪一类（例如「网调」），回复会被钉在这个领域里；" +
                "「示例」下面用「我：」开头的行会被当作你的语气样例。" +
                "语域写「亲密」才会放开角色化称呼和情境描写。" +
                "「硬边界」里写下的词会被逐字匹配：对方那条消息里出现这个词就不出候选，" +
                "所以写「家人」比只写「不要提家人」更管用（同义词不会命中）。" +
                "「避谈」只约束我的回复不许出现这些词（如稳赚、保证收益），对方提到照常回，不拦整轮。" +
                "联系人的「关系」这一栏会压过设置页的全局关系描述。留空使用全局人设"
        ).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = 2; gravity = Gravity.TOP
        }
        box.addView(label("名字")); box.addView(nameEdit)
        box.addView(label("别名（每行一个）")); box.addView(aliasEdit)
        box.addView(label("关系")); box.addView(relEdit)
        box.addView(label("备注")); box.addView(notesEdit)
        // 这里写的话会盖过专家库的正文（优先级在 StyleSource）。写在字段旁边，
        // 因为只有在这里决定「要不要写」的人，才需要知道这件事。
        box.addView(label("联系人专用人设（点一下即套用）"))
        box.addView(text("填了这里，专家库套用的正文对这个人就不生效了", 11f, sub).apply {
            setPadding(0, dp(2), 0, dp(4))
        })
        box.addView(personaPresets(personaEdit))
        box.addView(personaEdit)

        AlertDialog.Builder(this)
            .setTitle(if (existing == null) "新建联系人" else "编辑联系人")
            .setView(wrapScroll(box))
            .setPositiveButton("保存") { _, _ ->
                val name = nameEdit.text.toString().trim()
                if (name.isBlank()) { toast("名字不能空"); return@setPositiveButton }
                store.saveContact(Contact(
                    id = existing?.id ?: KbStore.newId(),
                    name = name,
                    aliases = aliasEdit.text.toString().split("\n")
                        .map { it.trim() }.filter { it.isNotEmpty() },
                    apps = existing?.apps ?: emptyList(),
                    relationship = relEdit.text.toString().trim(),
                    notes = notesEdit.text.toString().trim(),
                    persona = personaEdit.text.toString().trim(),
                    autoSummary = existing?.autoSummary ?: ""
                ))
                render()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun appLabel(pkg: String): String = ChatApps.forPackage(pkg)?.displayName ?: pkg

    // ----------------------------------------------------------------- skills

    private fun renderSkills() {
        val list = skills.list().sortedBy { it.name }
        if (skills.find(SkillStore.BUNDLED_PACK) == null) {
            // 一次性引导卡：装了就消失，不占常驻版面。
            val guide = card()
            guide.addView(text("内置技能包：狗头军师", 15f, ink, bold = true))
            guide.addView(text(
                "恋爱/暧昧推进、聊天接话、夸人与情绪价值、冲突修复、高情商拒绝、分手复合等 40+ 篇方法论" +
                    "（MIT，上游 shengjidaguai-china/goutoujunshi）。导入并启用后，每轮回复按对话内容" +
                    "自动带上相关的方法参考，可在下方随时停用。",
                12f, sub).apply { setPadding(0, dp(4), 0, dp(8)) })
            guide.addView(twoButtons("导入并启用", {
                confirm("导入内置技能包",
                    "把随 APK 打包的「狗头军师」方法论导入技能库并启用？可在技能列表随时停用。") {
                    toast(skills.importBundled(this, SkillStore.BUNDLED_PACK, enable = true))
                    render()
                }
            }, null, null))
            container.addView(guide)
        }

        if (list.isEmpty()) {
            container.addView(emptyCard(
                "还没有技能。技能就是一份 SKILL.md 说明书（Anthropic Agent Skills 格式）：" +
                    "开头是 name 和 description，后面写清步骤、规矩和例子。\n\n" +
                    "导入后默认关闭；打开它，当对话真的聊到这件事时，" +
                    "它的正文会连同「按要求写」的指令一起送给回复模型。"))
            return
        }

        val enabled = list.filter { it.enabled }
        list.forEach { container.addView(skillRow(it)) }

        val catalogue = SkillMatcher.catalogue(enabled.map { SkillRef(it.name, it.description) })
        container.addView(text(
            "已启用 ${enabled.size} / ${list.size} 个。技能正文绝不无条件发送——" +
                "每次只在对话命中时带一个（要有两个以上关键词对上才算命中）。",
            11f, sub).apply { setPadding(dp(2), dp(12), 0, 0) })
        if (catalogue.isNotEmpty()) {
            val c = card()
            c.addView(text("随每次回复发送的技能目录（${catalogue.length} / ${SkillMatcher.CATALOGUE_BUDGET} 字符）",
                12f, ink, bold = true))
            c.addView(text(catalogue.lines().joinToString("\n") { it.trim() }.take(600),
                11f, sub).apply { setPadding(0, dp(4), 0, 0) })
            container.addView(c)
        }
    }

    private fun skillRow(s: Skill): View {
        val c = card()
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
        }
        val left = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        left.addView(text(s.name, 15f, ink, bold = true))
        left.addView(text(s.description, 12f, sub).apply { setPadding(0, dp(3), 0, 0) })
        val res = s.resources()
        left.addView(text(
            if (res.isEmpty()) "无附加文件" else "附加文件 ${res.size} 个（${res.take(3).joinToString("、")}" +
                (if (res.size > 3) "…" else "") + "）",
            11f, sub).apply { setPadding(0, dp(3), 0, 0) })
        if (s.always) left.addView(text("每轮都注入正文", 11f, sub).apply { setPadding(0, dp(3), 0, 0) })
        row.addView(left)
        row.addView(smallToggle(s.enabled) { skills.setEnabled(s.name, !s.enabled); render() })
        c.addView(row)
        c.setOnClickListener { showSkill(s) }
        c.setOnLongClickListener {
            confirm("删除技能", "删掉「${s.name}」及其全部文件？不可恢复。") {
                skills.delete(s.name); render()
            }
            true
        }
        return c
    }

    private fun showSkill(s: Skill) {
        val body = if (s.body.isBlank()) "（正文是空的——这份 SKILL.md 只有 frontmatter）" else s.body
        val res = s.resources()
        val msg = StringBuilder()
        msg.append(s.description).append("\n\n")
        msg.append(
            if (s.always) "注入方式：每轮都注入正文（总是注入）——只要这个技能是启用的。\n"
            else "注入方式：这一轮聊到的内容命中它时才注入正文（本机打分，两个词以上才算命中）。\n"
        )
        s.frontmatter.license?.let { msg.append("许可：").append(it).append('\n') }
        s.frontmatter.compatibility?.let { msg.append("适用环境：").append(it).append('\n') }
        s.frontmatter.allowedTools?.let { msg.append("声明可用的工具：").append(it).append('\n') }
        if (s.frontmatter.metadata.isNotEmpty())
            msg.append("元数据：").append(s.frontmatter.metadata.entries.joinToString("、") {
                "${it.key}=${it.value}"
            }).append('\n')
        if (res.isNotEmpty()) msg.append("附加文件：").append(res.joinToString("、")).append('\n')
        msg.append("\n—— 正文 ——\n").append(body.take(1500))
        if (body.length > 1500) msg.append("\n…（已截断）")

        AlertDialog.Builder(this)
            .setTitle(s.name)
            .setMessage(msg)
            .setPositiveButton("关闭", null)
            .setNegativeButton(if (s.always) "取消「总是注入」" else "总是注入") { _, _ ->
                skills.setAlways(s.name, !s.always); render()
            }
            .setNeutralButton(if (s.enabled) "停用" else "启用") { _, _ ->
                skills.setEnabled(s.name, !s.enabled); render()
            }
            .show()
    }

    private fun pasteSkillDialog() {
        val box = dialogBox()
        box.addView(text("把 SKILL.md 的全部内容粘进来（含开头那三行 ---）。", 12f, sub))
        val input = edit("", "---\nname: weekly-report\ndescription: 写周报时使用…\n---\n\n步骤…").apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = 10; gravity = Gravity.TOP
        }
        box.addView(input)
        AlertDialog.Builder(this)
            .setTitle("粘贴 SKILL.md")
            .setView(wrapScroll(box))
            .setPositiveButton("导入") { _, _ ->
                val msg = skills.importSkillMd(input.text.toString())
                toast(msg); render()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    // ----------------------------------------------------------------- atoms

    private fun confirm(title: String, msg: String, onYes: () -> Unit) {
        AlertDialog.Builder(this)
            .setTitle(title).setMessage(msg)
            .setPositiveButton("确定") { _, _ -> onYes() }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun toast(m: String) = Toast.makeText(this, m, Toast.LENGTH_SHORT).show()

    private fun dialogBox() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(20), dp(8), dp(20), dp(4))
    }

    private fun wrapScroll(v: View) = ScrollView(this).apply { addView(v) }

    private fun twoButtons(
        a: String, onA: () -> Unit,
        b: String?, onB: (() -> Unit)?
    ): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(12) }
        }
        row.addView(wideBtn(a, true, onA))
        if (b != null && onB != null) row.addView(wideBtn(b, false, onB))
        return row
    }

    private fun wideBtn(labelText: String, primary: Boolean, onClick: () -> Unit) = TextView(this).apply {
        text = labelText; textSize = 14f; gravity = Gravity.CENTER
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(if (primary) Color.WHITE else accent)
        background = round(dp(11), if (primary) accent else Color.WHITE, stroke = !primary)
        setPadding(dp(12), dp(11), dp(12), dp(11))
        layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            .apply { rightMargin = dp(8) }
        setOnClickListener { onClick() }
    }

    private fun smallToggle(on: Boolean, onClick: () -> Unit) = TextView(this).apply {
        text = if (on) "开" else "关"; textSize = 13f; gravity = Gravity.CENTER
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(if (on) Color.WHITE else sub)
        background = round(dp(10), if (on) accent else Color.parseColor("#E5E7EB"))
        setPadding(dp(16), dp(6), dp(16), dp(6))
        setOnClickListener { onClick() }
    }

    private fun toggleRow(labelText: String, initial: Boolean): LinearLayout {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(12), 0, dp(2)); tag = initial
        }
        val lab = text(labelText, 14f, ink).apply {
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val sw = TextView(this).apply {
            text = if (initial) "开" else "关"; textSize = 13f; gravity = Gravity.CENTER
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(if (initial) Color.WHITE else sub)
            background = round(dp(10), if (initial) accent else Color.parseColor("#E5E7EB"))
            setPadding(dp(18), dp(6), dp(18), dp(6))
        }
        sw.setOnClickListener {
            val now = !((row.tag as? Boolean) ?: true); row.tag = now
            sw.text = if (now) "开" else "关"
            sw.setTextColor(if (now) Color.WHITE else sub)
            sw.background = round(dp(10), if (now) accent else Color.parseColor("#E5E7EB"))
        }
        row.addView(lab); row.addView(sw)
        return row
    }

    private fun emptyCard(msg: String): View = card().apply { addView(text(msg, 13f, sub)) }

    private fun card() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background = round(dp(14), Color.WHITE)
        setPadding(dp(14), dp(12), dp(14), dp(12))
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            .apply { topMargin = dp(10) }
    }

    private fun label(t: String) = text(t, 13f, ink, bold = true).apply { setPadding(0, dp(12), 0, dp(4)) }

    /**
     * 联系人专用人设的快捷入口：点一下把**人设库里那一条**填进 [target]。
     *
     * 以前这里是 [PersonaPresets] 里写死的三张。联系人身上要的往往更具体（「这个
     * 客户要客气，那个可以开玩笑」），所以改成直接读用户自己的库 —— 在设置页攒好
     * 的每一份人设，这里都能一键套到某个人头上，不用重新敲一遍。
     *
     * 读盘放在线程里：这里是对话框构造路径，主线程不能等 IO。库是空的就明说去哪建，
     * 不给一排点不动的东西。
     */
    private fun personaPresets(target: EditText): View {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        }
        val hint = text("人设库：读取中…", 11f, sub).apply { setPadding(0, dp(4), 0, dp(2)) }
        val chips = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        box.addView(hint)
        box.addView(chips)
        Thread {
            val list = runCatching { PersonaStore.get(this).list() }.getOrDefault(emptyList())
            runOnUiThread {
                if (list.isEmpty()) {
                    hint.text = "人设库是空的 —— 先去「设置 → 人设与语气」建一份，这里就能一键套到联系人身上"
                    return@runOnUiThread
                }
                hint.text = "从人设库套用（覆盖下面的专用人设）"
                list.chunked(2).forEach { pair ->
                    val row = LinearLayout(this).apply {
                        orientation = LinearLayout.HORIZONTAL
                        setPadding(0, dp(6), 0, 0)
                    }
                    pair.forEach { p ->
                        row.addView(TextView(this).apply {
                            text = p.name; textSize = 12.5f; gravity = Gravity.CENTER
                            setTypeface(typeface, Typeface.BOLD); setTextColor(accent)
                            background = round(dp(10), Color.WHITE, stroke = true)
                            setPadding(dp(6), dp(8), dp(6), dp(8))
                            layoutParams = LinearLayout.LayoutParams(
                                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
                            ).apply { rightMargin = dp(8) }
                            setOnClickListener {
                                if (target.text.isNullOrBlank()) {
                                    target.setText(p.body)
                                } else {
                                    confirm("套用「${p.name}」", "会用这条覆盖现在写着的联系人专用人设，确定？") {
                                        target.setText(p.body)
                                    }
                                }
                            }
                        })
                    }
                    // 奇数条时补一个占位，否则最后一张会被拉满整行。
                    if (pair.size == 1) {
                        row.addView(View(this).apply {
                            layoutParams = LinearLayout.LayoutParams(0, 1, 1f)
                                .apply { rightMargin = dp(8) }
                        })
                    }
                    chips.addView(row)
                }
            }
        }.start()
        return box
    }

    private fun edit(value: String, hintText: String) = EditText(this).apply {
        setText(value); hint = hintText; textSize = 14f; setTextColor(ink)
        setHintTextColor(Color.parseColor("#9CA3AF"))
        background = round(dp(8), Color.parseColor("#F3F4F6"))
        setPadding(dp(10), dp(10), dp(10), dp(10))
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            .apply { topMargin = dp(2) }
    }

    private fun text(t: String, size: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
        text = t; textSize = size; setTextColor(color)
        if (bold) setTypeface(typeface, Typeface.BOLD)
    }

    private fun round(radius: Int, color: Int, stroke: Boolean = false) = GradientDrawable().apply {
        cornerRadius = radius.toFloat(); setColor(color)
        if (stroke) setStroke(dp(1), accent)
    }
}

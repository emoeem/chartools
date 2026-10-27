package com.jev.probe

import android.content.ClipData
import android.content.ClipboardManager
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.jev.probe.core.Palette
import com.jev.probe.core.Prefs
import com.jev.probe.core.kb.ExpertApply
import com.jev.probe.core.kb.ExpertCatalog
import com.jev.probe.core.kb.ExpertPack
import com.jev.probe.core.kb.ExpertShelf
import com.jev.probe.core.kb.ExpertSort
import com.jev.probe.core.kb.KbStore
import com.jev.probe.core.kb.NOTE_TYPE_STYLE_SAMPLE
import com.jev.probe.core.kb.PersonaCard
import com.jev.probe.core.kb.PersonaPreset
import com.jev.probe.core.kb.PersonaProfile
import com.jev.probe.core.kb.StyleSink
import com.jev.probe.core.kb.PersonaStatus
import com.jev.probe.core.kb.PersonaStore
import com.jev.probe.ui.ExpertAdapter
import com.jev.probe.ui.ExpertCard
import com.jev.probe.ui.card
import com.jev.probe.ui.chip
import com.jev.probe.ui.dp
import com.jev.probe.ui.edit
import com.jev.probe.ui.filterChip
import com.jev.probe.ui.header
import com.jev.probe.ui.label
import com.jev.probe.ui.round
import com.jev.probe.ui.text
import java.util.concurrent.Executors

/**
 * 专家库：浏览 / 搜索 / 分类 / 排序 / 套用 / 自建。
 *
 * ## 它为什么是一个独立页面，而不是设置页的一段
 *
 * 设置页原本内联了整座人设库（约 300 行 + 一组字段），文件涨到 1523 行，
 * 而「浏览器 + 编辑器」和「填参数」是两种节奏：前者要网格、搜索、分类抽屉，
 * 后者要一行一行的输入框。混在一起的结果是两边都别扭。
 *
 * ## 三条不变量（与 `PersonaStore` 的约定，不在这里破例）
 *
 * 1. **`Prefs.style` 是唯一真源。** 这里「用」一个专家 = 把它的 `body` 写进
 *    `Prefs.style`，然后 [PersonaStore.touch] 记一次热度。**不存 activeExpertId** ——
 *    两份「当前生效」必然漂移，而漂移不会报错，只会让回复口径莫名不对。
 * 2. **头像/简介/标签/分类/热度不进提示词。** 它们只在这里被画出来。进提示词的
 *    只有 `body` 解析出的卡（[PersonaCard]）。
 * 3. **专家只能由 [PersonaProfile] 派生。** 这个页面不新增存储，也不缓存副本：
 *    每次进来读一次库，改完再读一次。
 */
class ExpertActivity : AppCompatActivity() {

    private lateinit var prefs: Prefs
    private val store: PersonaStore by lazy { PersonaStore.get(this) }

    /**
     * 「当前生效」的写入口。适配到 `Prefs.style` —— **不引入第二份状态**：
     * 这里只是把同一个 SharedPreferences 属性包成 [StyleSink]，没有任何副本。
     */
    private val styleSink = object : StyleSink {
        override var style: String
            get() = prefs.style
            set(v) {
                prefs.style = v
            }
    }

    private val expertApply: ExpertApply by lazy { ExpertApply(store, styleSink) }
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private val warn = Color.parseColor("#B45309")

    private var items: List<PersonaProfile> = emptyList()
    /** 专家目录（331 位）。只读货架，读一次缓存住，页面里再怎么操作都不重读。 */
    @Volatile
    private var pack: List<PersonaPreset> = emptyList()
    @Volatile
    private var packLoaded = false
    private var category: String? = null
    private var sort: ExpertSort = ExpertSort.COMPREHENSIVE
    private var query: String = ""

    private lateinit var adapter: ExpertAdapter
    private lateinit var categoryRow: LinearLayout
    private lateinit var sortRow: LinearLayout
    private lateinit var statusLine: TextView
    private lateinit var emptyHint: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        prefs = Prefs(this)
        window.decorView.setBackgroundColor(Color.parseColor("#F2F3F5"))

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(22), dp(18), dp(14))
            setBackgroundColor(Color.parseColor("#F2F3F5"))
        }
        root.padForSystemBars()
        setContentView(root)

        // ---- 顶栏：标题 + 导入/导出/更多 ----
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        bar.addView(header("专家库").apply {
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        })
        bar.addView(textButton("导入") { importDialog() })
        bar.addView(textButton("导出") { exportAll() })
        bar.addView(textButton("⋯") { pageMenu() })
        root.addView(bar)
        root.addView(text("331 位专家目录 + 你自建的。点卡片看详情，点「用」立刻切换回复口径。", 12f, Color.parseColor("#6B7280")))

        // ---- 搜索 ----
        val search = edit("", "搜名字、简介、标签或正文").apply {
            setSingleLine(true)
            setPadding(dp(12), dp(9), dp(12), dp(9))
        }
        search.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) {
                query = s?.toString().orEmpty()
                applyFilter()
            }
        })
        root.addView(search.apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(10) }
        })

        // ---- 分类抽屉（横向滚动，和公开页的筛选条同一个手势约定） ----
        categoryRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        root.addView(HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(categoryRow)
            setPadding(0, dp(10), 0, 0)
        })

        // ---- 排序 ----
        sortRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        root.addView(sortRow.apply { setPadding(0, dp(8), 0, 0) })

        statusLine = text("", 11f, Color.parseColor("#6B7280"))
        root.addView(statusLine.apply { setPadding(0, dp(6), 0, dp(6)) })

        // ---- 网格 ----
        adapter = ExpertAdapter(onTap = { showDetail(it) }, onHold = { moreMenu(it) })
        val grid = RecyclerView(this).apply {
            layoutManager = GridLayoutManager(this@ExpertActivity, 2)
            adapter = this@ExpertActivity.adapter
            setHasFixedSize(true)
            setPadding(0, 0, 0, dp(6))
            clipToPadding = false
        }
        root.addView(grid, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f
        ))

        emptyHint = text(
            "这个筛选下没有专家。\n换个分类、清空搜索，或者点下面的「新建专家」。",
            12f, Color.parseColor("#6B7280")
        ).apply {
            gravity = Gravity.CENTER
            visibility = View.GONE
            setPadding(0, dp(24), 0, dp(24))
        }
        root.addView(emptyHint)

        // ---- 新建 ----
        val create = TextView(this).apply {
            text = "＋ 新建专家"
            textSize = 15f
            gravity = Gravity.CENTER
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.WHITE)
            background = round(dp(12), Palette.brand())
            setPadding(dp(16), dp(13), dp(16), dp(13))
            setOnClickListener { editDialog(null) }
        }
        root.addView(create, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply { topMargin = dp(8) })

        reload()
    }

    // ------------------------------------------------------------------ 数据

    private fun reload() {
        worker.execute {
            val mine = runCatching { store.list() }.getOrDefault(emptyList())
            val problem = runCatching { store.lastProblem }.getOrNull()
            if (!packLoaded) {
                // 目录解析失败不算错误：退化成「只有我自己的专家」，页面照常用。
                val json = runCatching {
                    assets.open(ExpertPack.ASSET).bufferedReader(Charsets.UTF_8).use { it.readText() }
                }.getOrNull()
                pack = if (json == null) emptyList() else ExpertPack.parse(json).presets
                packLoaded = true
            }
            val merged = ExpertShelf.merge(mine, pack)
            main.post {
                items = merged
                if (problem != null) toast("⚠ $problem")
                rebuildCategories()
                rebuildSorts()
                applyFilter()
            }
        }
    }

    /** 纯内存重算：搜索框每敲一个字都会走这里，**不许读盘**。 */
    private fun applyFilter() {
        val shown = ExpertCatalog.browse(items, category, query, sort)
        adapter.submitList(shown)
        emptyHint.visibility = if (shown.isEmpty()) View.VISIBLE else View.GONE
        val mine = items.count { !ExpertShelf.isFromPack(it) }
        statusLine.text = when {
            items.isEmpty() -> "库里还没有专家 —— 点「新建专家」，或从右上角「⋯」恢复内置模板。"
            mine == 0 -> "目录 ${items.size} 位专家 · 当前显示 ${shown.size} 个"
            else -> "共 ${items.size} 位（我的 $mine · 目录 ${items.size - mine}）· 当前显示 ${shown.size} 个"
        }
    }

    private fun rebuildCategories() {
        categoryRow.removeAllViews()
        val all = ExpertCatalog.categories(items)
        categoryRow.addView(filterChip("全部", category == null || category == ExpertCatalog.ALL) {
            category = null
            rebuildCategories()
            applyFilter()
        })
        all.forEach { name ->
            categoryRow.addView(filterChip(name, category == name) {
                category = name
                rebuildCategories()
                applyFilter()
            })
        }
    }

    private fun rebuildSorts() {
        sortRow.removeAllViews()
        ExpertSort.values().forEach { mode ->
            sortRow.addView(filterChip(mode.label, sort == mode) {
                sort = mode
                rebuildSorts()
                applyFilter()
            })
        }
    }

    // ------------------------------------------------------------------ 卡片动作

    private fun showDetail(p: PersonaProfile) {
        val card = PersonaCard.parse(p.body)
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(6), dp(16), dp(4))
        }
        box.addView(text(ExpertCard.of(p).avatar + "  " + p.name, 17f, Color.parseColor("#111827"), bold = true))
        val blurb = ExpertCard.of(p).blurb
        if (blurb.isNotBlank()) box.addView(text(blurb, 12f, Color.parseColor("#6B7280")).apply {
            setPadding(0, dp(4), 0, 0)
        })
        box.addView(
            text(
                "分类：" + p.categoryOrBlank.ifBlank { "未分类" } + " · " + ExpertCard.usageOf(p.usedCount),
                11f, Color.parseColor("#6B7280")
            ).apply { setPadding(0, dp(8), 0, 0) }
        )
        if (p.tags.isNotEmpty()) {
            box.addView(text("标签：" + p.tags.joinToString(" / "), 11f, Color.parseColor("#6B7280")))
        }
        box.addView(
            text(
                "识别到的键：" + PersonaStatus.short(card), 11f,
                if (card.hasContent() && !card.structured) warn else Color.parseColor("#6B7280")
            ).apply { setPadding(0, dp(8), 0, 0) }
        )
        box.addView(label("正文"))
        box.addView(text(p.body, 11.5f, Color.parseColor("#111827")))

        val fromPack = ExpertShelf.isFromPack(p)
        val builder = AlertDialog.Builder(this)
            .setTitle(if (fromPack) "专家详情 · 目录" else "专家详情")
            .setView(ScrollView(this).apply { addView(box) })
            .setPositiveButton("用这个专家") { _, _ -> applyExpert(p) }
        if (fromPack) {
            // 目录条目是**货架上的样品**：点「加入」才会变成库里的一条（能改名、能删）。
            // 「用这个专家」也允许，只是它会先把样品落库 —— 否则热度没地方记。
            builder.setNeutralButton("加入我的专家库") { _, _ -> installOnly(p) }
        } else {
            builder.setNeutralButton("编辑") { _, _ -> editDialog(p) }
        }
        builder.setNegativeButton(if (fromPack) "关闭" else "更多") { _, _ ->
            if (!fromPack) moreMenu(p)
        }
        builder.show()
    }

    /** 目录条目 → 它对应的预设。不在目录里（用户自建）返回 null。 */
    private fun presetOf(p: PersonaProfile): PersonaPreset? =
        if (!ExpertShelf.isFromPack(p)) null
        else pack.firstOrNull { ExpertShelf.packId(it.key) == p.id }

    private fun installOnly(p: PersonaProfile) {
        val preset = presetOf(p) ?: run {
            toast("这条不是目录里的专家")
            return
        }
        worker.execute {
            val saved = runCatching { store.install(preset) }.getOrNull()
            main.post {
                toast(if (saved == null) "加入失败（储存空间？）" else "已加入「${saved.name}」，现在能改能删")
                reload()
            }
        }
    }

    /**
     * 套用：把 `body` 写进 `Prefs.style`（唯一真源），并记一次热度。
     *
     * 热度写在 worker 上再 `finish()`：`touch` 要读改写整个 JSON，放在主线程会
     * 顶着一次磁盘写去关页面。
     */
    /**
     * 点「用」。三段顺序与失败语义都在 [ExpertApply] 里，这里只负责线程与提示。
     *
     * 之前的写法是**先把 `prefs.style` 换掉，再在后台 install** —— 磁盘写失败时
     * 设置已经变成新专家、库里却没有这一条，界面照样弹「已套用」。现在落库先做，
     * 失败就原样退回并照实说原因，不再假装成功。
     */
    private fun applyExpert(p: PersonaProfile) {
        val name = p.name
        worker.execute {
            // 目录条目第一次被用时先落库：热度要记在一条真实的库条目上，
            // 否则「最热」对 331 位目录专家永远是 0（货架不记热度）。
            val result = expertApply.apply(p, presetOf(p))
            // 联系人专用人设压过专家正文（优先级在 StyleSource 里，是有意的）。
            // 这一句只讲事实：有 N 个聊天里已经写了专用人设，在那几个聊天里
            // 这次套用不会改变提示词。不讲这句，用户看到的就是「点了没反应」。
            val shadowing = if (result.ok) shadowingContacts() else 0
            main.post {
                if (result.ok) {
                    val notes = listOfNotNull(
                        result.warning.takeIf { it.isNotBlank() },
                        if (shadowing > 0) "${shadowing} 个联系人写了专用人设，那里会盖过它" else null
                    )
                    toast(
                        if (notes.isEmpty()) "已套用「$name」"
                        else "已套用「$name」（${notes.joinToString("；")}）"
                    )
                    setResult(RESULT_OK)
                    finish()
                } else {
                    // 不改 setResult、不 finish：让用户留在专家库，换一位再试。
                    toast(result.problem)
                }
            }
        }
    }

    /**
     * 有多少个联系人在「专用人设」里写了自己的话。
     *
     * 只数不读：这些文本属于具体某个人，套用专家时没有任何理由把它读出来，
     * 更不该出现在 toast 里。读不到（文件坏 / 首次运行）就当 0，不拦套用 ——
     * 这只是句提示，不是前置条件。
     */
    private fun shadowingContacts(): Int = runCatching {
        KbStore.get(this).contacts().count { it.persona.isNotBlank() }
    }.getOrDefault(0)

    private fun moreMenu(p: PersonaProfile) {
        if (ExpertShelf.isFromPack(p)) {
            // 长按目录条目：不能改名/删除（它不是用户的东西），只能加入或复制正文。
            AlertDialog.Builder(this)
                .setTitle(p.name)
                .setItems(arrayOf("加入我的专家库", "复制这段正文")) { _, which ->
                    if (which == 0) installOnly(p) else {
                        copyToClipboard(p.body)
                        toast("正文已复制")
                    }
                }
                .show()
            return
        }
        val actions = arrayOf("重命名", "复制一份", "导出这段正文（复制）", "删除")
        AlertDialog.Builder(this)
            .setTitle(p.name)
            .setItems(actions) { _, which ->
                when (which) {
                    0 -> renameDialog(p)
                    1 -> {
                        val copy = store.duplicate(p.id)
                        toast(if (copy == null) "复制失败" else "已复制成「${copy.name}」")
                        reload()
                    }
                    2 -> {
                        copyToClipboard(store.exportText(p.id))
                        toast("正文已复制，可直接粘到别处")
                    }
                    else -> confirm("删除专家", "删掉「${p.name}」？已经套用到设置里的文本不受影响。") {
                        store.delete(p.id)
                        reload()
                    }
                }
            }
            .show()
    }

    private fun renameDialog(p: PersonaProfile) {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(6), dp(16), dp(4))
        }
        val nameEdit = edit(p.name, "新名字")
        box.addView(nameEdit)
        AlertDialog.Builder(this)
            .setTitle("重命名")
            .setView(box)
            .setPositiveButton("保存") { _, _ ->
                val name = nameEdit.text.toString().trim()
                if (name.isBlank()) {
                    toast("名字不能是空的")
                    return@setPositiveButton
                }
                val saved = store.save(name, p.body, p.id)
                toast(if (saved == null) "改名失败" else "已改名为「$name」")
                reload()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    // ------------------------------------------------------------- 新建 / 编辑

    /**
     * 新建或编辑。正文下面实时回显「认出什么」—— 认不出键是**静默**的：
     * 把「主题」写成「话题方向」，界面看不出差别，只有回复悄悄变回通用腔调。
     */
    private fun editDialog(existing: PersonaProfile?) {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(6), dp(16), dp(4))
        }
        val nameEdit = edit(existing?.name ?: "", "名字，例如：销售·跟单 / 客服 / 甲方")
        val avatarEdit = edit(existing?.avatar ?: "", "一个 emoji，例如 🖤（可留空）")
        val descEdit = edit(existing?.description ?: "", "一句话简介（可留空，会自动取正文第一行）")
        val tagsEdit = edit(existing?.tags?.joinToString("、").orEmpty(), "标签，用、或,分隔（可留空）")
        val catEdit = edit(existing?.category ?: "", "分类：情感/销售/职场/客服/日常，也可以自建")
        val bodyEdit = edit(existing?.body ?: PERSONA_SKELETON, PERSONA_SKELETON).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = 8
            gravity = Gravity.TOP
        }
        val status = text("", 11.5f, Color.parseColor("#6B7280")).apply { setPadding(0, dp(6), 0, 0) }

        fun refresh() {
            val c = PersonaCard.parse(bodyEdit.text.toString())
            status.text = PersonaStatus.line(c)
            status.setTextColor(if (c.hasContent() && !c.structured) warn else Color.parseColor("#6B7280"))
        }
        bodyEdit.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) = refresh()
        })

        box.addView(label("名字")); box.addView(nameEdit)
        box.addView(label("一句话简介")); box.addView(descEdit)
        box.addView(label("头像")); box.addView(avatarEdit)
        box.addView(label("标签")); box.addView(tagsEdit)
        box.addView(label("分类")); box.addView(catEdit)
        box.addView(label("人设原文")); box.addView(bodyEdit)
        box.addView(status)

        val helpers = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(8), 0, 0)
        }
        helpers.addView(chip("插入键骨架", false) {
            if (bodyEdit.text.isNullOrBlank()) bodyEdit.setText(PERSONA_SKELETON)
            else bodyEdit.setText(bodyEdit.text.toString().trimEnd() + "\n" + PERSONA_SKELETON)
        })
        helpers.addView(chip("收进语气示例", false) {
            pullStyleSamples { lines ->
                if (lines == null) {
                    toast("知识库里还没有「语气示例」笔记：知识库 → 新建笔记 → 打开「语气示例」")
                } else {
                    val current = bodyEdit.text?.toString().orEmpty()
                    bodyEdit.setText(
                        if (current.contains("示例")) current.trimEnd() + "\n" + lines
                        else current.trimEnd() + "\n示例：\n" + lines
                    )
                    toast("已把知识库里的语气示例收进这张卡")
                }
            }
        })
        box.addView(helpers)
        refresh()

        AlertDialog.Builder(this)
            .setTitle(if (existing == null) "新建专家" else "编辑专家")
            .setView(ScrollView(this).apply { addView(box) })
            .setPositiveButton("保存") { _, _ ->
                val name = nameEdit.text.toString().trim()
                val body = bodyEdit.text.toString()
                if (body.isBlank()) {
                    toast("人设不能是空的")
                    return@setPositiveButton
                }
                val avatar = avatarEdit.text.toString().trim().ifBlank { null }
                val desc = descEdit.text.toString().trim().ifBlank { null }
                val cat = catEdit.text.toString().trim().ifBlank { null }
                val tags = tagsEdit.text.toString().split('、', ',', '，')
                    .map { it.trim() }.filter { it.isNotEmpty() }

                if (existing == null) {
                    val created = store.create(name, body, avatar, desc, tags, cat)
                    toast(if (created == null) "保存失败：人设库写不进去" else "已创建「${created.name}」")
                } else {
                    val saved = store.save(name, body, existing.id)
                    if (saved == null) {
                        toast("保存失败：人设库写不进去")
                        return@setPositiveButton
                    }
                    store.updateMeta(existing.id, name, avatar, desc, tags, cat)
                    toast("已保存「${saved.name}」")
                }
                reload()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    // ------------------------------------------------------------ 导入 / 导出

    private fun importDialog() {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(6), dp(16), dp(4))
        }
        box.addView(text("粘贴专家：可以是「导出」出来的整段 JSON，也可以直接是一张人设卡的正文（第一行当名字）。", 12f, Color.parseColor("#6B7280")))
        val input = edit("", """{"version":2,"items":[…]} 或 称呼：… 关系：…""").apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = 8
            gravity = Gravity.TOP
        }
        box.addView(input)
        box.addView(chip("从剪贴板粘贴", false) { input.setText(readClipboard()) })
        AlertDialog.Builder(this)
            .setTitle("导入专家")
            .setView(ScrollView(this).apply { addView(box) })
            .setPositiveButton("导入") { _, _ ->
                val result = store.importJson(input.text.toString())
                toast(result.describe())
                reload()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun exportAll() {
        copyToClipboard(store.exportJson())
        toast("已复制 ${items.size} 个专家的 JSON，粘到别的机器「导入」即可")
    }

    private fun pageMenu() {
        val actions = arrayOf("恢复内置模板", "关于专家库")
        AlertDialog.Builder(this)
            .setItems(actions) { _, which ->
                when (which) {
                    0 -> {
                        val added = store.restoreBuiltins()
                        toast(if (added == 0) "内置模板都在库里了" else "补回 $added 张内置模板")
                        reload()
                    }
                    else -> AlertDialog.Builder(this)
                        .setTitle("关于")
                        .setMessage(
                            "专家 = 人设正文（进提示词）+ 头像/简介/标签/分类/热度（只用来浏览）。\n\n" +
                                "「用」= 把正文写进设置里的人设，然后记一次使用次数。\n" +
                                "头像是 emoji，不占图片资源；简介为空时自动取正文第一行。"
                        )
                        .setPositiveButton("知道了", null)
                        .show()
                }
            }
            .show()
    }

    // ---------------------------------------------------------------- 小工具

    private fun textButton(label: String, onClick: () -> Unit) = TextView(this).apply {
        text = label
        textSize = 12.5f
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(Palette.brand())
        setPadding(dp(10), dp(6), 0, dp(6))
        setOnClickListener { onClick() }
    }

    private fun confirm(title: String, msg: String, onYes: () -> Unit) {
        AlertDialog.Builder(this)
            .setTitle(title)
            .setMessage(msg)
            .setPositiveButton("确定") { _, _ -> onYes() }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun pullStyleSamples(onDone: (String?) -> Unit) {
        worker.execute {
            val lines = runCatching {
                KbStore.get(this).notes()
                    .filter { it.enabled && it.type == NOTE_TYPE_STYLE_SAMPLE }
                    .flatMap { it.content.split('\n') }
                    .map { it.trim() }
                    .filter { it.isNotEmpty() }
                    .take(6)
            }.getOrDefault(emptyList())
            main.post { onDone(if (lines.isEmpty()) null else lines.joinToString("\n") { "我：$it" }) }
        }
    }

    private fun copyToClipboard(value: String) {
        val cm = getSystemService(CLIPBOARD_SERVICE) as? ClipboardManager ?: return
        cm.setPrimaryClip(ClipData.newPlainText("jev-expert", value))
    }

    private fun readClipboard(): String {
        val cm = getSystemService(CLIPBOARD_SERVICE) as? ClipboardManager ?: return ""
        return cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString().orEmpty()
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()

    override fun onDestroy() {
        super.onDestroy()
        worker.shutdownNow()
    }

    private companion object {
        /** 新建时的键骨架：这套键不是常识，空框只会让用户写出一段没被识别的散文。 */
        const val PERSONA_SKELETON =
            "称呼：\n关系：\n语气：\n主题：\n情境：\n硬边界：\n避谈：\n示例：\n我："
    }
}

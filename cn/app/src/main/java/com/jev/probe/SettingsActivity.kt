package com.jev.probe

import android.graphics.Bitmap
import android.content.pm.ApplicationInfo
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.jev.probe.bridge.BridgeStore
import com.jev.probe.bridge.HookTargets
import com.jev.probe.core.Analysis
import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Choice
import com.jev.probe.core.Msg
import com.jev.probe.core.Palette
import com.jev.probe.core.Prefs
import com.jev.probe.core.Score
import com.jev.probe.core.kb.KbSelfCheck
import com.jev.probe.core.kb.KbStore
import com.jev.probe.core.kb.NOTE_TYPE_STYLE_SAMPLE
import com.jev.probe.core.kb.Note
import com.jev.probe.core.kb.PersonaCard
import com.jev.probe.core.kb.PersonaProfile
import com.jev.probe.core.kb.PersonaStatus
import com.jev.probe.core.kb.PersonaStore
import com.jev.probe.core.kb.TopicScope
import com.jev.probe.jev.JudgeClient
import com.jev.probe.jev.ReplyClient
import com.jev.probe.jev.VisionClient
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.roundToInt

class SettingsActivity : AppCompatActivity() {

    private lateinit var prefs: Prefs
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private val accent = Palette.brand()
    private val ink = Color.parseColor("#111827")
    private val sub = Color.parseColor("#6B7280")
    private val warn = Color.parseColor("#B45309")
    private val pillOff = Color.parseColor("#EEF1F5")

    /** 参与检索的候选笔记与常驻条数，后台线程载入一次给「人设」区做作用域预告。 */
    private var kbPool: List<Note> = emptyList()
    private var kbAlwaysOn = 0

    /** 回到这个页面时重算人设区（用户可能刚从知识库页补完主题标签）。 */
    private var personaReload: (() -> Unit)? = null

    /**
     * 人设库的界面状态。列表只在内存里，读盘走 [reloadPersonas] —— 输入框每次
     * 打字都会重画列表（要更新「生效中」标记），不能顺手读一次盘。
     */
    private var personaShelf: LinearLayout? = null
    private var personaShelfLine: TextView? = null
    private var personaDraft: EditText? = null
    private var personaKnown: List<PersonaProfile> = emptyList()
    private var personaProblem: String? = null
    private var onPersonaTextChanged: (() -> Unit)? = null

    /** Selected provider index per card, held so Save can read it back. */
    private var judgeProviderIdx = 0

    private fun dp(v: Int) = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).roundToInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        prefs = Prefs(this)
        Log.i(TAG, "settings opened judgeKey.len=${prefs.judgeKey.length}" +
            " replyKey.len=${prefs.replyKey.length} visionKey.len=${prefs.visionKey.length}")
        window.decorView.setBackgroundColor(Color.parseColor("#F2F3F5"))

        val scroll = ScrollView(this)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(22), dp(18), dp(28))
        }
        root.padForSystemBars()   // edge-to-edge: keep the title off the status bar
        scroll.addView(root)

        root.addView(header("设置"))
        prefs.keyStorageError?.let { error ->
            val recoveryCard = card()
            recoveryCard.addView(text(error, 13f, sub))
            recoveryCard.addView(cardBtn("清除本机密钥并重新录入") {
                androidx.appcompat.app.AlertDialog.Builder(this)
                    .setTitle("重新录入 API 密钥")
                    .setMessage("这会清除本机保存的所有 API 密钥，其他设置不会改变。请确认你仍能从服务商处找回密钥。")
                    .setNegativeButton("取消", null)
                    .setPositiveButton("清除并继续") { _, _ ->
                        if (prefs.clearApiKeysForRecovery()) {
                            recreate()
                        } else {
                            Toast.makeText(this, "无法清除密钥，请检查设备存储后重试", Toast.LENGTH_LONG).show()
                        }
                    }
                    .show()
            })
            root.addView(recoveryCard)
        }

        // =================== 接口 ===================
        val connBody = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(foldSection("连接接口（必填）", defaultOpen = true, connBody))

        // --- 判断接口（Jev） ---
        val judgeCard = card()
        judgeCard.addView(cardTitle("判断接口（Jev / 聊天模型）"))
        judgeCard.addView(text("读对方消息、给意图判断和候选排序。必须配置。默认让 Jev 判断模型来答；也可以让 DeepSeek 这类聊天模型用提示词来答。", 12f, sub))

        val judgeBaseEdit = edit(prefs.judgeBaseUrl, Prefs.DEFAULT_JUDGE_BASE_OPENROUTER)
        val judgeModelEdit = edit(prefs.judgeModel, Prefs.DEFAULT_JUDGE_MODEL_OPENROUTER)
        judgeProviderIdx = when (prefs.judgeProvider) {
            Prefs.PROVIDER_OPENROUTER -> 0
            Prefs.PROVIDER_BOCHA -> 1
            Prefs.PROVIDER_TYPESAFE -> 2
            Prefs.PROVIDER_VERCEL -> 3
            Prefs.PROVIDER_ZEN -> 4
            Prefs.PROVIDER_DEEPSEEK -> 5
            Prefs.PROVIDER_CUSTOM -> 6
            else -> 0
        }
        // Bocha promo block — official address + one-tap copy (limited-time free).
        // Shown ONLY when Bocha Jev is the selected provider; picking any other
        // provider hides it. It used to be added unconditionally, which made every
        // tab look like it was still showing Bocha.
        val bochaBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val bochaRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(10), 0, dp(2))
        }
        bochaRow.addView(text("${Prefs.DEFAULT_JUDGE_BASE_BOCHA}（限时免费）", 12.5f, ink).apply {
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        })
        bochaRow.addView(TextView(this).apply {
            text = "复制"; textSize = 13f; gravity = Gravity.CENTER
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(accent); background = round(dp(10), Color.WHITE, stroke = true)
            setPadding(dp(16), dp(6), dp(16), dp(6))
            setOnClickListener {
                val cm = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
                cm.setPrimaryClip(android.content.ClipData.newPlainText(
                    "jev_bocha", Prefs.DEFAULT_JUDGE_BASE_BOCHA))
                Toast.makeText(this@SettingsActivity, "已复制", Toast.LENGTH_SHORT).show()
            }
        })
        bochaBox.addView(bochaRow)
        bochaBox.addView(text("去 jev.bocha.cn 领取限时免费 API Key", 11f, sub))
        bochaBox.visibility = if (judgeProviderIdx == 1) View.VISIBLE else View.GONE

        // How the judge route SPEAKS is a second choice, separate from its
        // address: Jev's question protocol, or one OpenAI chat turn over the same
        // question set. Built before the provider row (which drives it) but added
        // after it, so the presets still read first.
        var judgeProtoChat = prefs.effectiveJudgeProtocol() == Prefs.PROTO_CHAT
        val protoRow = pillRow(
            listOf("Jev 判断协议", "OpenAI 聊天模式"),
            if (judgeProtoChat) 1 else 0
        ) { i -> judgeProtoChat = i == 1 }

        judgeCard.addView(wrappedPills(
            listOf("OpenRouter", "博查 Jev", "TypeSafe 直连", "Vercel", "OpenCode Zen", "DeepSeek 官方", "自定义"), judgeProviderIdx) { idx ->
            judgeProviderIdx = idx
            when (idx) {
                0 -> {
                    judgeBaseEdit.setText(Prefs.DEFAULT_JUDGE_BASE_OPENROUTER)
                    judgeModelEdit.setText(Prefs.DEFAULT_JUDGE_MODEL_OPENROUTER)
                }
                1 -> {
                    judgeBaseEdit.setText(Prefs.DEFAULT_JUDGE_BASE_BOCHA)
                    judgeModelEdit.setText(Prefs.DEFAULT_JUDGE_MODEL_BOCHA)
                }
                2 -> {
                    judgeBaseEdit.setText(Prefs.DEFAULT_JUDGE_BASE_TYPESAFE)
                    judgeModelEdit.setText(Prefs.DEFAULT_JUDGE_MODEL_TYPESAFE)
                }
                3 -> {
                    judgeBaseEdit.setText(Prefs.DEFAULT_JUDGE_BASE_VERCEL)
                    judgeModelEdit.setText(Prefs.DEFAULT_JUDGE_MODEL_VERCEL)
                }
                4 -> {
                    judgeBaseEdit.setText(Prefs.DEFAULT_JUDGE_BASE_ZEN)
                    judgeModelEdit.setText(Prefs.DEFAULT_JUDGE_MODEL_ZEN)
                }
                // DeepSeek serves no Jev judgment model; this preset answers the
                // question set as a chat prompt instead, so it also picks the chat
                // protocol. Its key is a DeepSeek key — paste one in the box below.
                5 -> {
                    judgeBaseEdit.setText(Prefs.DEFAULT_JUDGE_BASE_DEEPSEEK)
                    judgeModelEdit.setText(Prefs.DEFAULT_JUDGE_MODEL_DEEPSEEK)
                }
                // Custom POSTs the box verbatim, so a preset HOST left in the box
                // would hit the API root. Expand it into the full endpoint the
                // preset would have used; anything hand-typed is left alone.
                6 -> judgeBaseEdit.setText(expandJudgeUrl(judgeBaseEdit.text.toString()))
            }
            // A preset speaks the protocol it was built for. Custom keeps whatever
            // the user chose: only they know what is behind that address.
            if (idx in 0..4) protoRow.second(0) else if (idx == 5) protoRow.second(1)
            bochaBox.visibility = if (idx == 1) View.VISIBLE else View.GONE
        })
        judgeCard.addView(protoRow.first)
        judgeCard.addView(text("「Jev 判断协议」把 7 道题发给 Jev 判断模型（TypeSafe 系），答案经过校准；「OpenAI 聊天模式」把同一套题写成提示词发给普通聊天模型（如 DeepSeek），由它自己估概率和危险等级，不如 Jev 准。", 11f, sub))
        judgeCard.addView(label("Base URL"))
        judgeCard.addView(judgeBaseEdit)
        judgeCard.addView(text("OpenRouter 拼 /alpha/decisions；博查 Jev / TypeSafe / Vercel / OpenCode Zen 拼 /v1/systemone；DeepSeek 官方拼 /chat/completions；聊天模式一律拼 /chat/completions；自定义按原样 POST。Vercel 用 AI Gateway 的密钥，OpenCode Zen 用 Zen 的密钥。",
            11f, sub))
        judgeCard.addView(bochaBox)
        judgeCard.addView(label("密钥"))
        judgeCard.addView(edit(prefs.judgeKey, "sk-...", password = true).also { judgeKeyEdit = it })
        judgeCard.addView(label("模型"))
        judgeCard.addView(judgeModelEdit)
        val judgeResult = resultText()
        judgeCard.addView(cardBtn("测试判断") {
            val base = judgeBaseEdit.text.toString().trim()
            val key = judgeKeyEdit.text.toString().trim()
            val model = judgeModelEdit.text.toString().trim()
            if (key.isBlank()) { judgeResult.text = "请先填密钥"; return@cardBtn }
            judgeResult.text = "测试中…"
            // Provider follows the address when it is still a known preset host,
            // so a stale pill selection cannot send a TypeSafe path to OpenRouter.
            val provider = resolveJudgeProvider(judgeProviderIdx, base)
            if (provider == Prefs.PROVIDER_CUSTOM && base.isBlank()) {
                judgeResult.text = "自定义档要填完整 URL（带路径）"; return@cardBtn
            }
            // Custom means we know nothing about the endpoint — guessing a model
            // name here would test something the user never asked for.
            if (provider == Prefs.PROVIDER_CUSTOM && model.isBlank()) {
                judgeResult.text = "请填写模型名"; return@cardBtn
            }
            val probe = draftPrefs(SCRATCH_JUDGE) {
                judgeProvider = provider
                // The pill wins here: the box may hold any address, but which
                // protocol the route speaks is exactly what the user picked.
                judgeProtocol = if (judgeProtoChat) Prefs.PROTO_CHAT else Prefs.PROTO_DECISIONS
                judgeBaseUrl = base.ifBlank { defaultJudgeBase(provider) }
                judgeKey = key
                judgeModel = model.ifBlank { defaultJudgeModel(provider) }
            }
            worker.execute {
                val t0 = System.currentTimeMillis()
                val demo = ChatSnapshot("连通测试", listOf(
                    Msg("other", "在吗？"), Msg("me", "在")))
                val a = JudgeClient(probe).judge(demo, prefs.relationship)
                val ms = System.currentTimeMillis() - t0
                main.post {
                    judgeResult.text = if (a.error != null) "失败（${ms}ms）：${a.error}"
                    else "成功 ${ms}ms · 意图=${a.trueIntent?.choice ?: "?"}" +
                        "（置信 ${pct(a.trueIntent?.confidence)}）"
                }
            }
        })
        judgeCard.addView(judgeResult)
        connBody.addView(judgeCard)

        // --- 回复接口 ---
        val replyCard = card()
        replyCard.addView(cardTitle("回复接口"))
        replyCard.addView(text("生成 3 条候选回复。任何 OpenAI 兼容地址，填到 /v1 为止。", 12f, sub))

        val replyBaseEdit = edit(prefs.replyBaseUrl, Prefs.DEFAULT_REPLY_BASE)
        val replyModelEdit = edit(prefs.replyModel, Prefs.DEFAULT_REPLY_MODEL)
        val replyIdx = when (prefs.replyBaseUrl.trim().trimEnd('/')) {
            Prefs.DEFAULT_REPLY_BASE -> 0
            Prefs.DEEPSEEK_BASE -> 1
            Prefs.DASHSCOPE_BASE -> 2
            else -> 3
        }
        replyCard.addView(pills(
            listOf("OpenRouter", "DeepSeek 官方", "通义兼容", "自定义"), replyIdx) { idx ->
            when (idx) {
                0 -> { replyBaseEdit.setText(Prefs.DEFAULT_REPLY_BASE); replyModelEdit.setText(Prefs.DEFAULT_REPLY_MODEL) }
                1 -> { replyBaseEdit.setText(Prefs.DEEPSEEK_BASE); replyModelEdit.setText(Prefs.DEEPSEEK_MODEL) }
                2 -> { replyBaseEdit.setText(Prefs.DASHSCOPE_BASE); replyModelEdit.setText(Prefs.DASHSCOPE_MODEL) }
            }
        })
        replyCard.addView(label("Base URL"))
        replyCard.addView(replyBaseEdit)
        replyCard.addView(label("密钥"))
        replyCard.addView(edit(prefs.replyKey, "留空则用判断接口密钥", password = true).also { replyKeyEdit = it })
        replyCard.addView(label("模型"))
        replyCard.addView(replyModelEdit)
        val replyResult = resultText()
        replyCard.addView(cardBtn("测试回复") {
            val base = replyBaseEdit.text.toString().trim()
            val model = replyModelEdit.text.toString().trim()
            val probe = draftPrefs(SCRATCH_REPLY) {
                judgeKey = judgeKeyEdit.text.toString().trim()
                replyBaseUrl = base.ifBlank { Prefs.DEFAULT_REPLY_BASE }
                replyKey = replyKeyEdit.text.toString().trim()
                replyModel = model.ifBlank { Prefs.DEFAULT_REPLY_MODEL }
            }
            if (probe.effectiveReplyKey().isBlank()) { replyResult.text = "请先填密钥（或填判断接口密钥）"; return@cardBtn }
            replyResult.text = "测试中…"
            worker.execute {
                val t0 = System.currentTimeMillis()
                var err: String? = null
                val out = try {
                    ReplyClient(probe).ping()
                } catch (e: Exception) { err = e.message; "" }
                val ms = System.currentTimeMillis() - t0
                main.post {
                    replyResult.text = if (err != null) "失败（${ms}ms）：$err"
                    else "成功 ${ms}ms · 返回：${out.replace("\n", " ").take(60)}"
                }
            }
        })
        replyCard.addView(replyResult)
        connBody.addView(replyCard)

        // --- 视觉接口 ---
        val visionCard = card()
        visionCard.addView(cardTitle("视觉接口（OCR 用，可先不填）"))
        visionCard.addView(text("读不到控件树的 App 走截图识别。B 阶段才用到，现在填不填都不影响。", 12f, sub))

        val visionBaseEdit = edit(prefs.visionBaseUrl, Prefs.DEFAULT_VISION_BASE)
        val visionModelEdit = edit(prefs.visionModel, Prefs.DEFAULT_VISION_MODEL)
        val visionIdx = when (prefs.visionBaseUrl.trim().trimEnd('/')) {
            Prefs.DEFAULT_VISION_BASE -> 0
            Prefs.DASHSCOPE_BASE -> 1
            else -> 2
        }
        visionCard.addView(pills(
            listOf("OpenRouter", "通义兼容", "自定义"), visionIdx) { idx ->
            when (idx) {
                0 -> { visionBaseEdit.setText(Prefs.DEFAULT_VISION_BASE); visionModelEdit.setText(Prefs.DEFAULT_VISION_MODEL) }
                1 -> { visionBaseEdit.setText(Prefs.DASHSCOPE_BASE); visionModelEdit.setText(Prefs.DASHSCOPE_VISION_MODEL) }
            }
        })
        visionCard.addView(label("Base URL"))
        visionCard.addView(visionBaseEdit)
        visionCard.addView(label("密钥"))
        visionCard.addView(edit(prefs.visionKey, "留空则用回复接口密钥", password = true).also { visionKeyEdit = it })
        visionCard.addView(label("模型"))
        visionCard.addView(visionModelEdit)
        val visionResult = resultText()
        visionCard.addView(cardBtn("测试视觉") {
            val visionBase = visionBaseEdit.text.toString().trim()
            if (!VisionClient.supportsVision(visionBase.ifBlank { Prefs.DEFAULT_VISION_BASE })) {
                visionResult.text = GUARD_NO_VISION
                return@cardBtn
            }
            val probe = draftPrefs(SCRATCH_VISION) {
                judgeKey = judgeKeyEdit.text.toString().trim()
                replyBaseUrl = replyBaseEdit.text.toString().trim().ifBlank { Prefs.DEFAULT_REPLY_BASE }
                replyKey = replyKeyEdit.text.toString().trim()
                visionBaseUrl = visionBase
                visionKey = visionKeyEdit.text.toString().trim()
                visionModel = visionModelEdit.text.toString().trim().ifBlank { Prefs.DEFAULT_VISION_MODEL }
            }
            if (probe.effectiveVisionKey().isBlank()) { visionResult.text = "请先填密钥（或填回复/判断接口密钥）"; return@cardBtn }
            visionResult.text = "测试中…"
            worker.execute {
                val t0 = System.currentTimeMillis()
                var err: String? = null
                val out = try {
                    VisionClient(probe).ask(whitePixelJpegB64(), "这张图是什么颜色？只回答颜色。")
                } catch (e: Exception) { err = e.message; "" }
                val ms = System.currentTimeMillis() - t0
                main.post {
                    visionResult.text = if (err != null) "失败（${ms}ms）：$err"
                    else "成功 ${ms}ms · 返回：${out.replace("\n", " ").take(60)}"
                }
            }
        })
        visionCard.addView(visionResult)
        connBody.addView(visionCard)

        // =================== 人设 ===================
        // 人设现在是**数据**：库落在 `kb/personas.json`（[PersonaStore]），而「当前
        // 生效的是哪一份」不另存 id —— 它仍然是 `Prefs.style` 里那段文本，靠原文
        // 比对算出来。两边各存一份状态必然漂移，而漂移的表现是「界面说生效的是 A，
        // 实际发出去的是 B」，这种错没有报错可查。
        //
        // 为什么要建库：原来能选的只有写死在 [PersonaPresets] 里的三张，卖货的话术、
        // 客服的口气、和甲方说话的分寸都得每次重敲，关掉页面就没了。现在模板只是
        // 首装时播下的种子，用户可以自建、改名、复制、导出带走。
        val personaBody = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(foldSection("人设与语气", defaultOpen = true, personaBody))
        val personaWrap = card()
        personaWrap.addView(text("人设决定回复的语气、称呼和分寸。下面是一个可以自己攒的库：" +
            "写一份「销售·跟单」，点「用」就切过去，回复的口气立刻跟着变。", 12f, sub))

        val shelfLine = text("人设库：读取中…", 12f, ink)
        val shelfHost = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        personaWrap.addView(shelfLine.apply { setPadding(0, dp(12), 0, dp(2)) })
        personaWrap.addView(shelfHost)
        personaWrap.addView(personaShelfActions())

        personaWrap.addView(label("人设原文（保存时写进设置，也可以直接改）"))
        val styleEdit = edit(prefs.style, "例：网调关系，我定规矩你执行；语气短句、命令式；主题：网调").apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = 5; gravity = Gravity.TOP
        }
        val personaLine = text("", 12f, ink)
        val personaScopeLine = text("知识库：读取中…", 11f, sub)

        fun refreshPersonaStatus() {
            val card = PersonaCard.parse(styleEdit.text.toString())
            personaLine.text = PersonaStatus.line(card)
            personaLine.setTextColor(if (card.hasContent() && !card.structured) warn else ink)
            personaScopeLine.text = PersonaStatus.scopeLine(
                TopicScope.scopeOf(kbPool, card.topic), kbAlwaysOn)
            renderPersonaShelf()
        }

        personaWrap.addView(styleEdit)
        personaWrap.addView(personaLine.apply { setPadding(0, dp(10), 0, 0) })
        personaWrap.addView(personaScopeLine.apply { setPadding(0, dp(5), 0, 0) })
        personaWrap.addView(text("人设卡认这些键：称呼／关系／语气／语域／主题／情境／硬边界／避谈／安全词／示例。" +
            "写「主题」才会把知识库收窄到同一个领域（比如主题：网调 → 只捞标了「网调」的笔记）；" +
            "硬边界写双字关键词（家人、前任），会逐字拦住对方那条消息；" +
            "「避谈」只是不许这些词出现在我的回复里（比如销售的稳赚、保证收益），对方提到照常回，不拦整轮。",
            11f, sub).apply { setPadding(0, dp(8), 0, 0) })
        styleEdit.addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: android.text.Editable?) = refreshPersonaStatus()
        })
        // 库的渲染要知道「现在这段文本对应哪一条」，所以把两个控件交给字段，
        // 由 [renderPersonaShelf] 在任意时刻重画。
        personaShelf = shelfHost
        personaShelfLine = shelfLine
        personaDraft = styleEdit
        onPersonaTextChanged = { refreshPersonaStatus() }
        refreshPersonaStatus()
        reloadPersonas()
        personaBody.addView(personaWrap)

        // 参与检索的笔记要读盘，不能压在输入框的回显路径上：先载入一次，之后
        // 打字只做纯字符串的解析。
        fun loadKbPool() {
            worker.execute {
                val notes = runCatching { KbStore.get(this).notes() }.getOrDefault(emptyList())
                    .filter { it.enabled }
                val pool = notes.filter { !it.alwaysOn && it.type != NOTE_TYPE_STYLE_SAMPLE }
                val on = notes.count { it.alwaysOn && it.type != NOTE_TYPE_STYLE_SAMPLE }
                main.post { kbPool = pool; kbAlwaysOn = on; refreshPersonaStatus() }
            }
        }
        // 用户可能刚在知识库页补完主题标签再回到设置页：数字得跟着走，否则这一区
        // 会一直报着进页面时的旧条数，看着就像"补标签没生效"。人设库同理 ——
        // 用户可能刚加了一条人设又绕回来，列表不能是旧的。
        personaReload = { loadKbPool(); reloadPersonas() }
        loadKbPool()

        // =================== 分析 ===================
        val behaviorBody = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(foldSection("行为与外观", defaultOpen = true, behaviorBody))
        val advancedBody = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(foldSection("高级参数与注入增强", defaultOpen = false, advancedBody))
        val card2 = card()
        card2.addView(label("关系描述（判断与起草都用）"))
        card2.addView(text("联系人里写了自己的关系时，那一轮以联系人的为准，这里只是兜底。", 11f, sub))
        val relEdit = edit(prefs.relationship, Prefs.DEFAULT_REL)
        card2.addView(relEdit)

        card2.addView(label("回复语言"))
        var pickedLanguage = when (prefs.replyLanguage) {
            Prefs.LANG_ZH -> 1
            Prefs.LANG_EN -> 2
            else -> 0
        }
        card2.addView(pills(listOf("跟随对方", "强制中文", "强制英文"), pickedLanguage) { pickedLanguage = it })

        card2.addView(label("回复长度"))
        var pickedLength = when (prefs.replyLength) {
            Prefs.LENGTH_SHORT -> 0
            Prefs.LENGTH_DETAILED -> 2
            else -> 1
        }
        card2.addView(pills(listOf("短", "标准", "详细"), pickedLength) { pickedLength = it })
        card2.addView(label("会话白名单（每行一个关键词，空=所有会话）"))
        val wlEdit = edit(prefs.whitelist.joinToString("\n"), "留空则对所有会话生效").apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE; minLines = 2
        }
        card2.addView(wlEdit)
        val autoRow = toggleRow("对方发消息时自动分析", prefs.autoAnalyze)
        card2.addView(autoRow)
        card2.addView(text("想只对某一个应用关掉自动分析：长按悬浮卡片，选「这个应用不再自动分析」。" +
            "关掉后那个应用里点卡片仍可手动分析。", 11f, sub))
        val streamRow = toggleRow("边生成边显示（流式）", prefs.streamReplies)
        card2.addView(streamRow)
        card2.addView(text("打开后候选回复会随着模型输出逐字出现，不用等整段生成完。" +
            "若服务商或中间代理不支持流式，这一轮会自动退回普通方式，速度略慢一点。", 11f, sub))
        // card2 从这里拆成两张：上面是行为，下面（card2b）全进「高级参数」组。
        val card2b = card()
        card2b.addView(label("高级回复温度"))
        val tempEdit = edit(String.format(java.util.Locale.US, "%.1f", prefs.replyTemperature), "0.0–1.5").apply {
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
        }
        card2b.addView(tempEdit)
        card2b.addView(label("重复惩罚（频率）"))
        val freqPenaltyEdit = edit(
            String.format(java.util.Locale.US, "%.1f", prefs.replyFrequencyPenalty), "-2.0–2.0，0=不启用").apply {
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL or
                InputType.TYPE_NUMBER_FLAG_SIGNED
        }
        card2b.addView(freqPenaltyEdit)
        card2b.addView(label("重复惩罚（新话题）"))
        val presPenaltyEdit = edit(
            String.format(java.util.Locale.US, "%.1f", prefs.replyPresencePenalty), "-2.0–2.0，0=不启用").apply {
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL or
                InputType.TYPE_NUMBER_FLAG_SIGNED
        }
        card2b.addView(presPenaltyEdit)
        card2b.addView(text("两个都保持 0 时不发这两个字段，请求和以前完全一样。调高（如 0.3 / 0.3）能从采样层面" +
            "压住「同一批词翻来覆去用」；只作用于候选回复的生成，摘要、台账、复查不受影响。", 11f, sub))
        card2b.addView(label("请求超时"))
        var pickedTimeout = if (prefs.requestTimeoutSeconds >= 60) 1 else 0
        card2b.addView(pills(listOf("30 秒", "60 秒"), pickedTimeout) { pickedTimeout = it })

        card2b.addView(label("候选回复条数"))
        var pickedCount = prefs.candidateCount
        card2b.addView(pills(listOf("1 条", "2 条", "3 条"), pickedCount - 1) { pickedCount = it + 1 })
        card2b.addView(text("只要 1 条时不做排序，出得更快；不满意可以在卡片里点「换一组」。", 11f, sub))

        // --- OCR 兜底（B 阶段）---
        val ocrFallbackRow = toggleRow("树读不到正文时用 OCR 兜底", prefs.ocrFallback)
        card2b.addView(ocrFallbackRow)
        card2b.addView(text("飞书正文是画上去的，节点树里读不到，这时截一次屏本地识别（不上传）。" +
            "微信不给第三方无障碍树（整棵树只有一个空节点），所以微信一直走这条路：" +
            "截屏 → 按气泡颜色分左右 → 本地 OCR，同样不上传、不点发送。", 11f, sub))
        val ocrAutoRow = toggleRow("OCR 模式自动分析", prefs.ocrAutoAnalyze)
        card2b.addView(ocrAutoRow)
        card2b.addView(label("OCR 轮询间隔"))
        var pickedOcrInterval = when (prefs.ocrPollIntervalSeconds) { 5 -> 1; 10 -> 2; else -> 0 }
        card2b.addView(pills(listOf("3 秒", "5 秒", "10 秒"), pickedOcrInterval) { pickedOcrInterval = it })
        card2b.addView(text("关闭时 OCR 认完只亮悬浮球，点一下再分析。", 11f, sub))

        // --- 知识库 / 关联上下文（D 阶段） ---
        val ctxRow = toggleRow("记录聊天历史（只存本机，用于关联上下文）", prefs.contextEnabled)
        card2b.addView(ctxRow)
        card2b.addView(text("关闭时不写任何聊天内容到磁盘；笔记与联系人匹配仍然照常工作。", 11f, sub))
        card2b.addView(label("注入最近历史条数（0–100）"))
        val ctxCountEdit = edit(prefs.contextHistoryCount.toString(), "30").apply {
            inputType = InputType.TYPE_CLASS_NUMBER
        }
        card2b.addView(ctxCountEdit)
        card2b.addView(label("历史保留天数"))
        var pickedRetention = Prefs.RETENTION_CHOICES.indexOf(prefs.logRetentionDays).coerceAtLeast(0)
        card2b.addView(pills(listOf("永久", "7 天", "30 天", "90 天"), pickedRetention) { pickedRetention = it })
        card2b.addView(text("超期的聊天记录在下次分析时清掉。只动本机 history 文件，不影响笔记和联系人。", 11f, sub))

        // --- S1 会话台账 / 证据复查 ---
        val ledgerRow = toggleRow("会话台账（把整段历史预扫成称呼 / 关系 / 边界卡片）", prefs.ledgerEnabled)
        card2b.addView(ledgerRow)
        card2b.addView(text("只在上面「记录聊天历史」打开后才有数据：台账是从已经存下来的历史整理" +
            "出来的，不额外记录任何东西。整理好之后每轮都带上，称呼、在办的事和已经说过的" +
            "边界不会因为滚出窗口而丢；重建失败时保留上一版，不影响这一轮。", 11f, sub))

        val reviewRow = toggleRow("证据复查（排序后再逐条核验，站不住的重写）", prefs.reviewEnabled)
        card2b.addView(reviewRow)
        card2b.addView(text("比排序多一次模型调用，所以默认关。复查会指出哪条没接住对方、和已知" +
            "称呼或边界冲突、或编造了对话里没有的事实，然后只重写那几条；复查失败时保持排序结果不动。", 11f, sub))
        card2b.addView(label("复查接口（三项都留空＝沿用回复接口）"))
        val reviewBaseEdit = edit(prefs.reviewBaseUrl, "留空沿用回复接口")
        card2b.addView(reviewBaseEdit)
        val reviewModelEdit = edit(prefs.reviewModel, "留空沿用回复模型")
        card2b.addView(reviewModelEdit)
        val reviewKeyEdit = edit(prefs.reviewKey, "留空沿用回复密钥", password = true)
        card2b.addView(reviewKeyEdit)

        card2b.addView(cardBtn("知识库与联系人") {
            startActivity(android.content.Intent(this, KnowledgeActivity::class.java))
        })
        val kbResult = resultText()
        card2b.addView(cardBtn("清空知识库与历史") {
            val c = KbStore.get(this).counts()
            val personas = runCatching { PersonaStore.get(this).count() }.getOrDefault(0)
            androidx.appcompat.app.AlertDialog.Builder(this)
                .setTitle("清空知识库与历史")
                .setMessage("将删除 ${c.notes} 条笔记、${c.contacts} 个联系人、${c.logLines} 条聊天历史，" +
                    "以及 ${personas} 份人设（人设库会回到内置模板）。" +
                    "密钥、白名单等设置不受影响。不可恢复。")
                .setPositiveButton("清空") { _, _ ->
                    KbStore.get(this).clearAll()
                    kbResult.text = "已清空知识库与历史"
                    personaKnown = emptyList()
                    personaProblem = null
                    reloadPersonas()
                }
                .setNegativeButton("取消", null)
                .show()
        })
        // Deliberately low-key: a developer aid, not a user feature.
        card2b.addView(text("自检", 12f, sub).apply {
            setPadding(dp(2), dp(12), dp(8), dp(2))
            setOnClickListener {
                kbResult.text = "自检中…"
                worker.execute {
                    val out = try { KbSelfCheck.run(this@SettingsActivity) }
                    catch (e: Exception) { "自检异常：${e.javaClass.simpleName} ${e.message ?: ""}" }
                    main.post { kbResult.text = out }
                }
            }
        })
        card2b.addView(kbResult)
        behaviorBody.addView(card2)
        advancedBody.addView(card2b)

        // =================== 外观 ===================
        behaviorBody.addView(section("外观"))
        val card3 = card()
        val opacityLabel = label("悬浮窗不透明度：${prefs.overlayOpacity}%")
        card3.addView(opacityLabel)
        card3.addView(text("越低越透，越能看清下面的聊天", 12f, sub))
        val seek = SeekBar(this).apply {
            max = 40; progress = prefs.overlayOpacity - 60  // 60..100
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(sb: SeekBar?, p: Int, u: Boolean) {
                    opacityLabel.text = "悬浮窗不透明度：${p + 60}%"
                }
                override fun onStartTrackingTouch(sb: SeekBar?) {}
                override fun onStopTrackingTouch(sb: SeekBar?) {}
            })
        }
        card3.addView(seek)
        behaviorBody.addView(card3)

        // =================== 注入增强（可选，默认关闭） ===================
        advancedBody.addView(section("注入增强（可选，默认关闭）"))
        val injCard = card()
        injCard.addView(text(
            "不打开这里，App 就是一个纯粹的无障碍助手：读屏幕上的字、把草稿填进输入框，绝不发送。" +
                "\n\n" +
                "打开之后，在装了 Vector/LSPosed 的手机上，本 App 能以模块身份进入目标 App 的进程，" +
                "直接读到聊天窗口里真正的消息（带消息 ID、时间和发送者），而不是靠节点树和 OCR 去猜。" +
                "注入层只读：不发送、不修改、不写入目标 App 的任何数据；只在你正打开的聊天页上、" +
                "每秒一次、只看最近 60 条。读不到、超时或定位不到，立刻回落无障碍路径，" +
                "并把原因写进诊断日志 —— 降级是可见的，不是静默的。" +
                "\n\n" +
                "必须逐 App 单独打开；默认全部关闭。",
            12f, sub))

        val injectStatusViews = ArrayList<Pair<String, TextView>>()
        HookTargets.SCOPED.forEach { pkg ->
            injCard.addView(toggleRow("${appLabel(pkg)}（$pkg）", prefs.injectionEnabled(pkg)) { on ->
                prefs.setInjectionEnabled(pkg, on)
                Toast.makeText(
                    this,
                    if (on) "已开启 $pkg 的注入增强（下次该 App 启动时生效）"
                    else "已关闭 $pkg 的注入增强",
                    Toast.LENGTH_SHORT
                ).show()
            })
            val line = text(injectStatusLine(pkg), 11.5f, sub)
            injectStatusViews.add(pkg to line)
            injCard.addView(line)
        }
        injCard.addView(cardBtn("刷新模块状态") {
            injectStatusViews.forEach { (pkg, tv) -> tv.text = injectStatusLine(pkg) }
        })
        injCard.addView(label("诊断"))
        injCard.addView(toggleRow("注入对拍（写诊断日志）", prefs.compareSources()) { on ->
            prefs.setCompareSources(on)
        })
        injCard.addView(text(
            "同一个聊天页同时用无障碍和注入层各读一遍，把两层的差别写成一行诊断日志 —— " +
                "只记条数和错位位置，不记聊天内容。用来验证注入层读得对不对，不额外调用模型。" +
                "排查完就关掉：开着每次采集会多读一遍屏幕。",
            11.5f, sub
        ))
        injCard.addView(text(
            "没装框架、模块没启用、或者目标 App 没在跑，这里都会显示「未连接」，注入增强不生效 —— " +
                "其余功能完全不受影响。",
            11.5f, sub
        ))

        injCard.addView(label("账号风险（原文）"))
        injCard.addView(text(
            "微信官方协议 8.2.1.4–8.2.1.7 限制未经授权的插件接入、对运行数据和客户端的读取或干预；" +
                "8.5.1 的处理包括功能限制、账号封禁等。不能由“只读、不发消息”推导出不会封号。" +
                "现有 LSPosed 版本同样存在此风险，绘制开关不能消除已注入模块的风险。" +
                "没有可靠材料可给出具体封禁概率，也不能声称一定是高概率。" +
                "\n\n" +
                "若优先保护日常主账号，不建议继续以 LSPosed 注入方式推进此功能。" +
                "\n\n" +
                "同一类风险适用于任何被注入的 App，不止微信。" +
                "\n\n" +
                "（以上为前置评估文档原文；其中「绘制」指把分析直接画进对方气泡里，" +
                "本版本不做这件事，保留原句是为了不改动原文。）",
            12f, sub
        ))
        advancedBody.addView(injCard)

        // =================== 关于与隐私 ===================
        root.addView(section("关于与隐私"))
        val aboutCard = card()
        aboutCard.addView(text(
            "这个 App 会读取你当前聊天窗口的文字，发给你自己配置的模型接口做判断和起草回复。本分支维护者不运营服务器，收不到你的数据。",
            12f, sub))
        aboutCard.addView(cardBtn("隐私政策") { openUrl(PRIVACY_URL) })
        aboutCard.addView(cardBtn("开源仓库") { openUrl(REPO_URL) })
        aboutCard.addView(text(versionLabel(), 11f, sub).apply { setPadding(0, dp(10), 0, dp(2)) })
        root.addView(aboutCard)

        // =================== 保存 ===================
        root.addView(primaryBtn("保存全部设置") {
            if (prefs.keyStorageError != null) {
                Toast.makeText(this, "请先恢复无法读取的密钥，再保存设置", Toast.LENGTH_LONG).show()
                return@primaryBtn
            }
            // Address wins over the pill: a preset HOST in the box means that
            // preset's provider (and so its path), whatever the pill last said.
            val judgeBaseTyped = judgeBaseEdit.text.toString().trim()
            val judgeProv = resolveJudgeProvider(judgeProviderIdx, judgeBaseTyped)
            val judgeModelTyped = judgeModelEdit.text.toString().trim()
            prefs.judgeProvider = judgeProv
            // Blank falls back to THIS provider's preset — never OpenRouter's by
            // default. Custom is left exactly as typed (blank included): guessing
            // a URL for it would silently point somewhere the user did not choose.
            prefs.judgeBaseUrl = when {
                judgeBaseTyped.isNotBlank() -> judgeBaseTyped
                judgeProv == Prefs.PROVIDER_CUSTOM -> ""
                else -> defaultJudgeBase(judgeProv)
            }
            prefs.judgeKey = judgeKeyEdit.text.toString()
            prefs.judgeProtocol = if (judgeProtoChat) Prefs.PROTO_CHAT else Prefs.PROTO_DECISIONS
            prefs.judgeModel = when {
                judgeModelTyped.isNotBlank() -> judgeModelTyped
                judgeProv == Prefs.PROVIDER_CUSTOM -> ""
                else -> defaultJudgeModel(judgeProv)
            }

            prefs.replyBaseUrl = replyBaseEdit.text.toString().trim().ifBlank { Prefs.DEFAULT_REPLY_BASE }
            prefs.replyKey = replyKeyEdit.text.toString()
            prefs.replyModel = replyModelEdit.text.toString().trim().ifBlank { Prefs.DEFAULT_REPLY_MODEL }

            prefs.visionBaseUrl = visionBaseEdit.text.toString().trim()
            prefs.visionKey = visionKeyEdit.text.toString()
            prefs.visionModel = visionModelEdit.text.toString().trim().ifBlank { Prefs.DEFAULT_VISION_MODEL }

            prefs.relationship = relEdit.text.toString()   // blank stays blank, on purpose
            prefs.style = styleEdit.text.toString()
            prefs.replyLanguage = when (pickedLanguage) {
                1 -> Prefs.LANG_ZH
                2 -> Prefs.LANG_EN
                else -> Prefs.LANG_FOLLOW
            }
            prefs.replyLength = when (pickedLength) {
                0 -> Prefs.LENGTH_SHORT
                2 -> Prefs.LENGTH_DETAILED
                else -> Prefs.LENGTH_STANDARD
            }
            prefs.whitelist = wlEdit.text.toString().split("\n")
                .map { it.trim() }.filter { it.isNotEmpty() }.toSet()
            prefs.autoAnalyze = (autoRow.tag as? Boolean) ?: true
            prefs.streamReplies = (streamRow.tag as? Boolean) ?: false
            prefs.replyTemperature = tempEdit.text.toString().toDoubleOrNull() ?: 0.8
            prefs.replyFrequencyPenalty = freqPenaltyEdit.text.toString().toDoubleOrNull() ?: 0.0
            prefs.replyPresencePenalty = presPenaltyEdit.text.toString().toDoubleOrNull() ?: 0.0
            prefs.requestTimeoutSeconds = if (pickedTimeout == 1) 60 else 30
            prefs.candidateCount = pickedCount
            prefs.ocrFallback = (ocrFallbackRow.tag as? Boolean) ?: true
            prefs.ocrAutoAnalyze = (ocrAutoRow.tag as? Boolean) ?: false
            prefs.ocrPollIntervalSeconds = when (pickedOcrInterval) {
                1 -> 5
                2 -> 10
                else -> 3
            }
            prefs.contextEnabled = (ctxRow.tag as? Boolean) ?: false
            prefs.contextHistoryCount =
                ctxCountEdit.text.toString().trim().toIntOrNull()?.coerceIn(0, 100) ?: 30
            prefs.logRetentionDays =
                Prefs.RETENTION_CHOICES.getOrElse(pickedRetention) { 0 }
            prefs.ledgerEnabled = (ledgerRow.tag as? Boolean) ?: true
            prefs.reviewEnabled = (reviewRow.tag as? Boolean) ?: false
            prefs.reviewBaseUrl = reviewBaseEdit.text.toString()
            prefs.reviewModel = reviewModelEdit.text.toString()
            prefs.reviewKey = reviewKeyEdit.text.toString()
            prefs.overlayOpacity = seek.progress + 60
            if (prefs.keyStorageError == null) {
                Toast.makeText(this, "已保存", Toast.LENGTH_SHORT).show()
            } else {
                Toast.makeText(this, "设置已保存，但密钥加密失败，请重新录入", Toast.LENGTH_LONG).show()
                recreate()
            }
        })

        setContentView(scroll)

        // Debug-only acceptance hook. The drafting prompt is the thing the user
        // judged ("给的建议也很不太对", and a grovelling role-play line in a
        // flirting thread), and it can only be judged against a real model.
        //   adb shell am start -n com.jev.probe/.SettingsActivity \
        //       --ez tone_check true
        // runs the REAL drafting path once over a fixed, synthetic thread and
        // writes the candidates to files/jev-tone-check.txt. It never reads a
        // real conversation, and it is not compiled into release builds.
        if (((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) &&
            intent?.getBooleanExtra("tone_check", false) == true
        ) {
            runToneCheck()
        }
    }

    /**
     * 回到这一页时重算人设区。
     *
     * 用户很可能是「设置里选人设 → 去知识库页补标签 → 再回设置页」这条动线，回来
     * 时那个「参与检索 N 条」必须是新的；停在进页面那一刻的数字，看着就像补标签
     * 没生效，而这恰恰是这一区存在的意义。
     */
    override fun onResume() {
        super.onResume()
        personaReload?.invoke()
    }

    private fun runToneCheck() {
        val probe = draftPrefs(SCRATCH_REPLY) {
            judgeBaseUrl = prefs.judgeBaseUrl
            judgeProtocol = prefs.judgeProtocol
            judgeModel = prefs.judgeModel
            judgeKey = prefs.judgeKey
            replyBaseUrl = prefs.replyBaseUrl
            replyKey = prefs.replyKey
            replyModel = prefs.replyModel
            contextHistoryCount = prefs.contextHistoryCount
        }
        worker.execute {
            val demo = ChatSnapshot("试写", listOf(
                Msg("other", "你今天怎么这么晚才回我？"),
                Msg("me", "刚忙完，想你了"),
                Msg("other", "切，谁信啊，说好的周末陪我去看电影呢")
            ))
            // A light teasing thread: the judgment says so, and the drafter has to
            // follow it instead of writing for an imagined crisis.
            val judgment = Analysis(
                trueIntent = Choice("casual_chat", 0.7, emptyMap()),
                dangerLevel = Score(1.0, 0.8, 9),
                sheNeeds = Choice("nothing", 0.5, emptyMap()),
                shouldReplyNow = 0.9,
                bestAction = Choice("make_plan", 0.5, emptyMap()),
                tensionResolved = 0.2, literalQuestion = 0.8,
                rankedReplies = emptyList(), latencyMs = 0
            )
            val out = try {
                ReplyClient(probe).draft(demo, prefs.relationship, null, 3, emptyList(), judgment, prefs.style)
            } catch (e: Exception) {
                listOf("FAILED: ${e.message}")
            }
            runCatching { File(filesDir, "jev-tone-check.txt").writeText(out.joinToString("\n---\n")) }
            main.post { Toast.makeText(this, "试写完成：${out.size} 条", Toast.LENGTH_LONG).show() }
        }
    }

    // Held as fields because several test buttons read each other's key box.
    private lateinit var judgeKeyEdit: EditText
    private lateinit var replyKeyEdit: EditText
    private lateinit var visionKeyEdit: EditText

    private fun providerOf(idx: Int) = when (idx) {
        1 -> Prefs.PROVIDER_BOCHA
        2 -> Prefs.PROVIDER_TYPESAFE
        3 -> Prefs.PROVIDER_VERCEL
        4 -> Prefs.PROVIDER_ZEN
        5 -> Prefs.PROVIDER_DEEPSEEK
        6 -> Prefs.PROVIDER_CUSTOM
        else -> Prefs.PROVIDER_OPENROUTER
    }

    /**
     * The provider actually implied by what is in the address box. A preset host
     * carries its own path (`/alpha/decisions`, `/v1/systemone`), so leaving that
     * host in the box while the pill says something else would POST the wrong
     * path — or, for custom, the bare API root.
     */
    private fun resolveJudgeProvider(idx: Int, base: String): String =
        when (base.trim().trimEnd('/')) {
            Prefs.DEFAULT_JUDGE_BASE_BOCHA -> Prefs.PROVIDER_BOCHA
            Prefs.DEFAULT_JUDGE_BASE_OPENROUTER -> Prefs.PROVIDER_OPENROUTER
            Prefs.DEFAULT_JUDGE_BASE_TYPESAFE -> Prefs.PROVIDER_TYPESAFE
            Prefs.DEFAULT_JUDGE_BASE_VERCEL -> Prefs.PROVIDER_VERCEL
            Prefs.DEFAULT_JUDGE_BASE_ZEN -> Prefs.PROVIDER_ZEN
            Prefs.DEFAULT_JUDGE_BASE_DEEPSEEK -> Prefs.PROVIDER_DEEPSEEK
            else -> providerOf(idx)
        }

    /**
     * The full endpoint a preset host would have been expanded to. DeepSeek has
     * no Jev judgment path — its preset runs the chat protocol, so its expansion
     * is the chat completions URL, not a decisions one.
     */
    private fun expandJudgeUrl(base: String): String = when (base.trim().trimEnd('/')) {
        Prefs.DEFAULT_JUDGE_BASE_BOCHA -> Prefs.DEFAULT_JUDGE_BASE_BOCHA + "/v1/systemone"
        Prefs.DEFAULT_JUDGE_BASE_OPENROUTER -> Prefs.DEFAULT_JUDGE_BASE_OPENROUTER + "/alpha/decisions"
        Prefs.DEFAULT_JUDGE_BASE_TYPESAFE -> Prefs.DEFAULT_JUDGE_BASE_TYPESAFE + "/v1/systemone"
        Prefs.DEFAULT_JUDGE_BASE_VERCEL -> Prefs.DEFAULT_JUDGE_BASE_VERCEL + "/v1/systemone"
        Prefs.DEFAULT_JUDGE_BASE_ZEN -> Prefs.DEFAULT_JUDGE_BASE_ZEN + "/v1/systemone"
        Prefs.DEFAULT_JUDGE_BASE_DEEPSEEK -> Prefs.DEFAULT_JUDGE_BASE_DEEPSEEK + Prefs.CHAT_COMPLETIONS_PATH
        else -> base.trim()
    }

    private fun defaultJudgeBase(provider: String): String = when (provider) {
        Prefs.PROVIDER_BOCHA -> Prefs.DEFAULT_JUDGE_BASE_BOCHA
        Prefs.PROVIDER_TYPESAFE -> Prefs.DEFAULT_JUDGE_BASE_TYPESAFE
        Prefs.PROVIDER_VERCEL -> Prefs.DEFAULT_JUDGE_BASE_VERCEL
        Prefs.PROVIDER_ZEN -> Prefs.DEFAULT_JUDGE_BASE_ZEN
        Prefs.PROVIDER_DEEPSEEK -> Prefs.DEFAULT_JUDGE_BASE_DEEPSEEK
        else -> Prefs.DEFAULT_JUDGE_BASE_OPENROUTER
    }

    private fun defaultJudgeModel(provider: String): String = when (provider) {
        Prefs.PROVIDER_BOCHA -> Prefs.DEFAULT_JUDGE_MODEL_BOCHA
        Prefs.PROVIDER_TYPESAFE -> Prefs.DEFAULT_JUDGE_MODEL_TYPESAFE
        Prefs.PROVIDER_VERCEL -> Prefs.DEFAULT_JUDGE_MODEL_VERCEL
        Prefs.PROVIDER_ZEN -> Prefs.DEFAULT_JUDGE_MODEL_ZEN
        Prefs.PROVIDER_DEEPSEEK -> Prefs.DEFAULT_JUDGE_MODEL_DEEPSEEK
        else -> Prefs.DEFAULT_JUDGE_MODEL_OPENROUTER
    }

    /**
     * A throwaway [Prefs] view carrying exactly what is in the boxes right now,
     * so a test button probes the typed values rather than the saved ones. Each
     * button gets its OWN scratch file — they used to share one and clear it out
     * from under each other when two tests overlapped. The real config is never
     * touched either way.
     */
    private fun draftPrefs(scratchName: String, fill: Prefs.() -> Unit): Prefs {
        getSharedPreferences(scratchName, MODE_PRIVATE).edit().clear().commit()
        return Prefs(this, scratchName).apply(fill)
    }

    /** Opens an external link; swallows the failure with a toast rather than crashing. */
    private fun openUrl(url: String) {
        runCatching {
            startActivity(
                android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))
                    .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }.onFailure {
            Toast.makeText(this, "打不开浏览器", Toast.LENGTH_SHORT).show()
        }
    }

    private fun versionLabel(): String = try {
        val pi = packageManager.getPackageInfo(packageName, 0)
        "版本 v${pi.versionName}（${pi.longVersionCode}）"
    } catch (e: Exception) {
        "版本 —"
    }

    /** 1x1 white JPEG for the vision smoke test, via the real encoder path. */
    private fun whitePixelJpegB64(): String {
        val bmp = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
        bmp.eraseColor(Color.WHITE)
        return VisionClient.encodeJpeg(bmp)
    }

    private fun pct(d: Double?): String =
        if (d == null) "?" else "${(d * 100).roundToInt()}%"

    /** 一句确认框：套模板这类会盖掉用户手写内容的动作都得先问。 */
    private fun confirm(title: String, msg: String, onYes: () -> Unit) {
        androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle(title).setMessage(msg)
            .setPositiveButton("确定") { _, _ -> onYes() }
            .setNegativeButton("取消", null)
            .show()
    }

    // ==================================================================== 人设库
    //
    // 这一组方法只做三件事：把 `kb/personas.json` 读成内存列表、把列表画成行、
    // 把用户点的动作落回库里。**当前生效的人设不存在库里** —— 它就是
    // `personaDraft` 里的那段文本（保存时写进 `Prefs.style`），这里靠原文比对
    // 反推「现在生效的是哪一条」。多加一份 id 就多一处可以漂移的状态。

    /** 读盘。失败按空库处理（并把 [PersonaStore.lastProblem] 摆到界面上）。 */
    private fun reloadPersonas() {
        val store = PersonaStore.get(this)
        worker.execute {
            val list = runCatching { store.list() }.getOrDefault(emptyList())
            val problem = runCatching { store.lastProblem }.getOrNull()
            main.post {
                personaKnown = list
                personaProblem = problem
                renderPersonaShelf()
            }
        }
    }

    /** 重画库：一行一条，外加「当前生效是谁」那一行。 */
    private fun renderPersonaShelf() {
        val host = personaShelf ?: return
        host.removeAllViews()
        val text = personaDraft?.text?.toString().orEmpty().trim()
        val active = if (text.isEmpty()) null else personaKnown.firstOrNull { it.body.trim() == text }
        personaShelfLine?.let { line ->
            line.text = when {
                personaProblem != null -> "⚠ ${personaProblem}"
                active != null -> "当前生效：「${active.name}」"
                personaKnown.isEmpty() -> "库是空的 —— 点「新建」写一份，或「恢复模板」找回内置那几张。"
                text.isEmpty() -> "当前没有生效的人设 —— 回复只用默认风格。"
                else -> "当前生效：未存进库的自由文本（想留着就点「新建」）"
            }
            line.setTextColor(if (personaProblem != null) warn else ink)
        }
        personaKnown.forEach { p -> host.addView(personaRow(p, active?.id == p.id)) }
    }

    private fun personaRow(p: PersonaProfile, active: Boolean): View {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = round(
                dp(10),
                if (active) Color.parseColor("#EFF6FF") else Color.parseColor("#F7F8FA"),
                stroke = active
            )
            setPadding(dp(12), dp(10), dp(12), dp(10))
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(8) }
        }
        val titleRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
        }
        titleRow.addView(text(p.name, 14f, ink, bold = true).apply {
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        })
        if (active) titleRow.addView(text("生效中", 11f, accent, bold = true))
        box.addView(titleRow)

        val card = p.card()
        box.addView(
            text(
                PersonaStatus.short(card), 11f,
                if (card.hasContent() && !card.structured) warn else sub
            ).apply { setPadding(0, dp(4), 0, 0) }
        )

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; setPadding(0, dp(8), 0, 0)
        }
        actions.addView(chip("用", active) { applyPersona(p) })
        actions.addView(chip("改", false) { editPersonaDialog(p) })
        actions.addView(chip("⋯", false) { personaMenu(p) })
        box.addView(actions)
        box.setOnClickListener { applyPersona(p) }
        return box
    }

    private fun chip(label: String, on: Boolean, onClick: () -> Unit) = TextView(this).apply {
        text = label; textSize = 12.5f; gravity = Gravity.CENTER
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(if (on) Color.WHITE else accent)
        background = round(dp(8), if (on) accent else Color.WHITE, stroke = !on)
        setPadding(dp(14), dp(7), dp(14), dp(7))
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply { rightMargin = dp(8) }
        setOnClickListener { onClick() }
    }

    /** 新建 / 导入 / 导出 / 恢复模板。 */
    private fun personaShelfActions(): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; setPadding(0, dp(10), 0, 0)
        }
        val actions: List<Pair<String, () -> Unit>> = listOf(
            "新建" to { editPersonaDialog(null) },
            "导入" to { importPersonaDialog() },
            "导出" to { exportPersonas() },
            "恢复模板" to { restoreBuiltinPersonas() }
        )
        actions.forEach { (label, action) ->
            row.addView(TextView(this).apply {
                text = label; textSize = 12.5f; gravity = Gravity.CENTER
                setTypeface(typeface, Typeface.BOLD); setTextColor(accent)
                background = round(dp(9), Color.WHITE, stroke = true)
                setPadding(dp(4), dp(9), dp(4), dp(9))
                layoutParams = LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
                ).apply { rightMargin = dp(6) }
                setOnClickListener { action() }
            })
        }
        return row
    }

    /**
     * 套用：文本换成这条，并**立刻**写进 `Prefs.style`。
     *
     * 不等「保存全部设置」是有意的 —— 「用」是一个明确动作，用户按了就该生效；
     * 而 `styleEdit` 同时被改写，所以随后的「保存全部设置」写下去的还是同一段文本，
     * 两条路径不会打架。
     */
    private fun applyPersona(p: PersonaProfile) {
        personaDraft?.setText(p.body)
        prefs.style = p.body
        toast("已套用「${p.name}」")
        renderPersonaShelf()
        onPersonaTextChanged?.invoke()
    }

    /**
     * 编辑 / 新建。正文实时回显「认出什么」，因为认不出键是静默的：
     * 用户把「主题」写成「话题方向」，界面看不出差别，只有回复悄悄变回通用腔调。
     */
    private fun editPersonaDialog(existing: PersonaProfile?) {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(6), dp(16), dp(4))
        }
        val nameEdit = edit(existing?.name ?: "", "名字，例如：销售·跟单 / 客服 / 甲方")
        val bodyEdit = edit(existing?.body ?: "", PERSONA_SKELETON).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = 8; gravity = Gravity.TOP
        }
        val status = text("", 11.5f, sub).apply { setPadding(0, dp(6), 0, 0) }

        fun refresh() {
            val c = PersonaCard.parse(bodyEdit.text.toString())
            status.text = PersonaStatus.line(c)
            status.setTextColor(if (c.hasContent() && !c.structured) warn else sub)
        }
        bodyEdit.addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: android.text.Editable?) = refresh()
        })

        box.addView(label("名字")); box.addView(nameEdit)
        box.addView(label("人设原文")); box.addView(bodyEdit)
        box.addView(status)

        val helpers = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; setPadding(0, dp(8), 0, 0)
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
        box.addView(text("「收进语气示例」会把知识库里标了语气示例的笔记抄进这张卡的「示例：」段" +
            "（它们本来也会单独进提示词，抄进来是让人设自带写法样本，换机器也不丢）。",
            11f, sub).apply { setPadding(0, dp(6), 0, 0) })
        refresh()

        androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle(if (existing == null) "新建人设" else "编辑人设")
            .setView(ScrollView(this).apply { addView(box) })
            .setPositiveButton("保存") { _, _ ->
                val name = nameEdit.text.toString().trim()
                val body = bodyEdit.text.toString()
                if (body.isBlank()) { toast("人设不能是空的"); return@setPositiveButton }
                val saved = PersonaStore.get(this).save(name, body, existing?.id)
                if (saved == null) {
                    toast("保存失败：人设库写不进去（储存空间？）")
                    return@setPositiveButton
                }
                // 改的是「正在生效」的那一条时，生效文本要跟着走，否则用户改完发现回复没变。
                if (existing != null && personaDraft?.text?.toString()?.trim() == existing.body.trim()) {
                    personaDraft?.setText(saved.body)
                    prefs.style = saved.body
                }
                reloadPersonas()
                onPersonaTextChanged?.invoke()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    /** 长按「⋯」：重命名 / 复制 / 导出正文 / 删除。 */
    private fun personaMenu(p: PersonaProfile) {
        val items = arrayOf("重命名", "复制一份", "导出这段正文（复制）", "删除")
        androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle(p.name)
            .setItems(items) { _, which ->
                when (which) {
                    0 -> renamePersonaDialog(p)
                    1 -> {
                        val copy = PersonaStore.get(this).duplicate(p.id)
                        toast(if (copy == null) "复制失败" else "已复制成「${copy.name}」")
                        reloadPersonas()
                    }
                    2 -> {
                        copyToClipboard(PersonaStore.get(this).exportText(p.id))
                        toast("正文已复制，可直接粘到别处")
                    }
                    else -> confirm("删除人设", "删掉「${p.name}」？人设库里的这一条会消失，" +
                        "但已经套用到设置里的文本不受影响。") {
                        PersonaStore.get(this).delete(p.id)
                        reloadPersonas()
                    }
                }
            }
            .show()
    }

    private fun renamePersonaDialog(p: PersonaProfile) {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(6), dp(16), dp(4))
        }
        val nameEdit = edit(p.name, "新名字")
        box.addView(nameEdit)
        androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("重命名")
            .setView(box)
            .setPositiveButton("保存") { _, _ ->
                val name = nameEdit.text.toString().trim()
                if (name.isBlank()) { toast("名字不能是空的"); return@setPositiveButton }
                val saved = PersonaStore.get(this).save(name, p.body, p.id)
                toast(if (saved == null) "改名失败" else "已改名为「${name}」")
                reloadPersonas()
                onPersonaTextChanged?.invoke()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    /** 导入：粘贴 JSON（本库导出的、手拼的）或一整张纯文本人设卡。 */
    private fun importPersonaDialog() {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(6), dp(16), dp(4))
        }
        box.addView(text("粘贴人设：可以是这台机器「导出」出来的整段 JSON，" +
            "也可以直接是一张人设卡的正文（第一行当名字）。", 12f, sub))
        val input = edit("", "{\"version\":1,\"items\":[…]} 或 称呼：… 关系：…").apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = 8; gravity = Gravity.TOP
        }
        box.addView(input)
        box.addView(chip("从剪贴板粘贴", false) {
            input.setText(readClipboard())
        })
        androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("导入人设")
            .setView(ScrollView(this).apply { addView(box) })
            .setPositiveButton("导入") { _, _ ->
                val result = PersonaStore.get(this).importJson(input.text.toString())
                toast(result.describe())
                reloadPersonas()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    /** 导出：全量 JSON 进剪贴板 —— 不申请存储权限、不弹系统分享面板，够用。 */
    private fun exportPersonas() {
        val json = PersonaStore.get(this).exportJson()
        copyToClipboard(json)
        toast("已复制 ${personaKnown.size} 条人设的 JSON，粘到别的机器「导入」即可")
    }

    private fun restoreBuiltinPersonas() {
        val added = PersonaStore.get(this).restoreBuiltins()
        toast(if (added == 0) "内置模板都在库里了" else "补回 $added 张内置模板")
        reloadPersonas()
    }

    /** 把知识库里的「语气示例」笔记抄成「我：…」行。空库回调 null。 */
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

    private fun copyToClipboard(text: String) {
        val cm = getSystemService(CLIPBOARD_SERVICE) as? android.content.ClipboardManager ?: return
        cm.setPrimaryClip(android.content.ClipData.newPlainText("jev-persona", text))
    }

    private fun readClipboard(): String {
        val cm = getSystemService(CLIPBOARD_SERVICE) as? android.content.ClipboardManager ?: return ""
        return cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString().orEmpty()
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()

    /** Horizontal selectable pills; calls [onPick] with the chosen index. */
    private fun pills(options: List<String>, initial: Int, onPick: (Int) -> Unit): View =
        pillRow(options, initial, onPick).first

    /** Two-column selectable pills so presets remain visible on a phone screen. */
    private fun wrappedPills(options: List<String>, initial: Int, onPick: (Int) -> Unit): View {
        var selected = initial
        val rows = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val views = ArrayList<TextView>()
        options.forEachIndexed { index, option ->
            val pill = TextView(this).apply {
                text = option
                textSize = 12.5f
                gravity = Gravity.CENTER
                setPadding(dp(8), dp(9), dp(8), dp(9))
                layoutParams = LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
                ).apply { leftMargin = dp(3); rightMargin = dp(3) }
                setOnClickListener {
                    selected = index
                    views.forEachIndexed { viewIndex, view -> paintPill(view, viewIndex == selected) }
                    onPick(index)
                }
            }
            views.add(pill)
        }
        options.indices.step(2).forEach { start ->
            rows.addView(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(views[start])
                if (start + 1 < views.size) {
                    addView(views[start + 1])
                } else {
                    addView(View(this@SettingsActivity).apply {
                        layoutParams = LinearLayout.LayoutParams(0, 1, 1f).apply {
                            leftMargin = dp(3)
                            rightMargin = dp(3)
                        }
                    })
                }
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT
                ).apply { topMargin = dp(6) }
            })
        }
        views.forEachIndexed { index, view -> paintPill(view, index == selected) }
        return rows
    }

    /**
     * [pills] plus a programmatic selector. One row has to be able to drive
     * another: picking the DeepSeek judge preset also picks the protocol that
     * preset speaks, and a row built by [pills] cannot be re-painted from
     * outside.
     */
    private fun pillRow(options: List<String>, initial: Int, onPick: (Int) -> Unit): Pair<View, (Int) -> Unit> {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        val views = ArrayList<TextView>()
        val select: (Int) -> Unit = { i ->
            views.forEachIndexed { j, v -> paintPill(v, j == i) }
            onPick(i)
        }
        options.forEachIndexed { i, opt ->
            val pill = TextView(this).apply {
                text = opt; textSize = 12.5f; gravity = Gravity.CENTER
                setPadding(dp(13), dp(7), dp(13), dp(7))
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT).apply { rightMargin = dp(7) }
            }
            views.add(pill)
            pill.setOnClickListener { select(i) }
            row.addView(pill)
        }
        views.forEachIndexed { j, v -> paintPill(v, j == initial) }
        val scroller = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(row)
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(10) }
        }
        return scroller to select
    }

    private fun paintPill(v: TextView, on: Boolean) {
        v.setTextColor(if (on) Color.WHITE else sub)
        v.setTypeface(v.typeface, if (on) Typeface.BOLD else Typeface.NORMAL)
        v.background = round(dp(9), if (on) accent else pillOff)
    }

    private fun toggleRow(
        labelText: String,
        initial: Boolean,
        onChange: ((Boolean) -> Unit)? = null,
    ): LinearLayout {
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
            onChange?.invoke(now)
        }
        row.addView(lab); row.addView(sw)
        return row
    }

    /** 目标 App 的显示名；没装就退回包名。只是查一下，不触发任何加载。 */
    private fun appLabel(pkg: String): String = runCatching {
        @Suppress("DEPRECATION")
        val info = packageManager.getApplicationInfo(pkg, 0)
        packageManager.getApplicationLabel(info).toString()
    }.getOrNull()?.takeIf { it.isNotBlank() } ?: pkg

    /**
     * 注入层此刻连没连上。心跳带时间戳，超过两分钟就算过期（目标 App 被杀、
     * 模块崩了、手机重启都会走到这条路上），所以这里不会把一次很久以前的
     * 连接说成「已连接」。
     */
    private fun injectStatusLine(pkg: String): String {
        val alive = BridgeStore.alive(pkg)
            ?: return "状态：未连接（框架未装 / 模块未启用 / 目标 App 未启动）"
        val age = ((System.currentTimeMillis() - alive.at) / 1000L).coerceAtLeast(0L)
        return "状态：已连接 · 模块 v${alive.version} · ${age} 秒前心跳"
    }

    // atoms
    private fun header(t: String) = text(t, 24f, ink, bold = true).apply { setPadding(0, 0, 0, dp(4)) }
    private fun section(t: String) = text(t, 12f, sub, bold = true).apply { setPadding(dp(2), dp(16), 0, dp(6)) }

    /**
     * 折叠组：38 个控件块平铺一页、真机要滚六屏以上（ui-overhaul 考察 P1），
     * 按「连接 / 人设 / 行为 / 高级」分四组，默认只展开前面的组。控件本身
     * 一行不动，只是从 root 换进组容器。
     */
    private fun foldSection(title: String, defaultOpen: Boolean, body: LinearLayout): View {
        var open = defaultOpen
        val chev = TextView(this).apply {
            textSize = 15f; setTextColor(Color.parseColor("#6B7280")); setPadding(dp(8), 0, 0, 0)
        }
        val head = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(2), dp(12), dp(2), dp(12))
            setOnClickListener {
                open = !open
                chev.text = if (open) "▾" else "▸"
                body.visibility = if (open) View.VISIBLE else View.GONE
            }
        }
        head.addView(TextView(this).apply {
            text = title; textSize = 16f; setTextColor(Color.parseColor("#111827"))
            setTypeface(typeface, Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        })
        head.addView(chev)
        chev.text = if (open) "▾" else "▸"
        body.visibility = if (open) View.VISIBLE else View.GONE
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(head); addView(body)
        }
    }
    private fun label(t: String) = text(t, 13f, ink, bold = true).apply { setPadding(0, dp(12), 0, dp(4)) }
    private fun cardTitle(t: String) = text(t, 16f, ink, bold = true).apply { setPadding(0, dp(10), 0, dp(4)) }
    private fun resultText() = text("", 12.5f, sub).apply { setPadding(0, dp(10), 0, dp(2)) }

    private fun card() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background = round(dp(14), Color.WHITE)
        setPadding(dp(14), dp(4), dp(14), dp(14))
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            .apply { topMargin = dp(10) }
    }

    private fun edit(value: String, hint: String, password: Boolean = false) = EditText(this).apply {
        setText(value); this.hint = hint; textSize = 14f; setTextColor(ink)
        setHintTextColor(Color.parseColor("#9CA3AF"))
        background = round(dp(8), Color.parseColor("#F3F4F6"))
        setPadding(dp(10), dp(10), dp(10), dp(10))
        // Masked, not VISIBLE_PASSWORD: an API key should not sit in plain sight.
        if (password) inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(2) }
    }

    private fun text(t: String, size: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
        text = t; textSize = size; setTextColor(color); if (bold) setTypeface(typeface, Typeface.BOLD)
    }

    private fun primaryBtn(label: String, onClick: () -> Unit) = TextView(this).apply {
        text = label; textSize = 15f; gravity = Gravity.CENTER; setTypeface(typeface, Typeface.BOLD)
        setTextColor(Color.WHITE); background = round(dp(12), accent)
        setPadding(dp(16), dp(13), dp(16), dp(13))
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(18) }
        setOnClickListener { onClick() }
    }

    /** Outlined button sized for inside a card. */
    private fun cardBtn(label: String, onClick: () -> Unit) = TextView(this).apply {
        text = label; textSize = 14f; gravity = Gravity.CENTER; setTypeface(typeface, Typeface.BOLD)
        setTextColor(accent); background = round(dp(10), Color.WHITE, stroke = true)
        setPadding(dp(14), dp(10), dp(14), dp(10))
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(14) }
        setOnClickListener { onClick() }
    }

    private fun round(radius: Int, color: Int, stroke: Boolean = false) = GradientDrawable().apply {
        cornerRadius = radius.toFloat(); setColor(color); if (stroke) setStroke(dp(1), accent)
    }

    override fun onDestroy() { super.onDestroy(); worker.shutdownNow() }

    companion object {
        private const val TAG = "JEVASSIST"

        /**
         * 新建人设时预填的键骨架。
         *
         * 预填而不是给个空框，理由和模板一样：这套键不是常识，用户不知道要写
         * 「主题」才能让知识库跟着收窄。骨架摆在输入框里，用户只需要把冒号后面
         * 补上自己的话 —— 而认不出的键是静默的，所以框下面还有实时回显。
         */
        private const val PERSONA_SKELETON =
            "称呼：\n关系：\n语气：\n主题：\n情境：\n硬边界：\n避谈：\n示例：\n我："

        /** DeepSeek's official API has no vision model; say so instead of a 400. */
        private const val GUARD_NO_VISION =
            "该接口不支持视觉（DeepSeek 官方没有 image_url），请换 OpenRouter 或通义兼容"

        /** One scratch prefs file per test button; never the real config. */
        private const val SCRATCH_JUDGE = "jev_probe_scratch_judge"
        private const val SCRATCH_REPLY = "jev_probe_scratch_reply"
        private const val SCRATCH_VISION = "jev_probe_scratch_vision"

        private const val PRIVACY_URL = "https://github.com/emoeem/chartools/blob/main/cn/PRIVACY.md"
        private const val REPO_URL = "https://github.com/emoeem/chartools"
    }
}

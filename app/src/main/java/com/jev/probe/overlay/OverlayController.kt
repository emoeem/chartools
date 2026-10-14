package com.jev.probe.overlay

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.text.TextUtils
import android.transition.AutoTransition
import android.transition.TransitionManager
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import com.jev.probe.core.Analysis
import com.jev.probe.core.Intensity
import com.jev.probe.core.Palette
import com.jev.probe.core.Prefs
import com.jev.probe.core.RankedReply
import com.jev.probe.core.Trace
import com.jev.probe.jev.StrategyOrder
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Floating overlay with one anchor and two presentations.
 *
 * - **Capsule** (the resting form, everywhere): the small round "助手" ball,
 *   ALWAYS snapped to the left/right screen edge — dragging it anywhere else
 *   snaps it back on release. The edge snap is the fix for the old "卡被放丢"
 *   bug, where three coexisting position systems (global bubble, per-app card
 *   spot, default top) could leave the card parked where no one could find it
 *   (ui-overhaul investigation, P0). The capsule shows the round's progress
 *   seconds while a round runs, then the danger score; it flashes when new
 *   results land.
 * - **Card** (expanded, user-invoked): tap the capsule to expand the full read
 *   at the capsule's spot — candidates and the intensity row first, judgment
 *   and knowledge details folded into a 详情 toggle. Dragging the header moves
 *   the card (clamped on screen); collapsing returns to the capsule. The card
 *   never pops open on its own except for [showError], which is actionable.
 *
 * Long-pressing the capsule or the card header opens the menu (截屏识别一次…).
 */
class OverlayController(private val ctx: Context) {

    private val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val prefs = Prefs(ctx)
    private val main = Handler(Looper.getMainLooper())

    private enum class Mode { BUBBLE, CARD }

    private var root: FrameLayout? = null
    private var lp: WindowManager.LayoutParams? = null
    private var mode: Mode? = null

    // Card views (null while the card is not built).
    private var capsuleText: TextView? = null
    private var cardView: LinearLayout? = null
    private var riskPill: TextView? = null
    private var headText: TextView? = null
    private var statusText: TextView? = null
    private var chevron: TextView? = null
    private var bodyScroll: MaxHeightScroll? = null
    private var body: LinearLayout? = null
    private var menuView: View? = null
    private var expanded = false

    /** 详情区（判断/知识库/来源）是否展开；默认收起，候选永远第一屏。 */
    private var detailExpanded = false

    /** Header tap with nothing to show yet (or after an error): analyze the open chat. */
    var onManualAnalyze: (() -> Unit)? = null

    /** "换一组" / retry: draft a new set of candidates for the same judgment. */
    var onRegenerate: (() -> Unit)? = null

    /**
     * "再给 2 条": keep the candidates already on the card and add two more to the
     * bottom. Different from [onRegenerate], which throws the current set away —
     * when two of the three are nearly right, redrafting all three loses them.
     */
    var onMoreReplies: (() -> Unit)? = null
    var onOpenSettings: (() -> Unit)? = null
    var onRefine: ((String, String) -> Unit)? = null

    /**
     * 推进档位（自动/收着/自然/加码）被用户改了。服务是权威状态的持有者；
     * 改档只影响下一轮起草，「换一组」可以立刻让新档位生效。
     */
    var onIntensity: ((Intensity) -> Unit)? = null

    /** 卡片上档位 pill 的当前高亮 —— 服务状态的镜像，[setIntensity] 推回。 */
    private var intensity: Intensity = Intensity.AUTO

    /** 服务状态变化（含会话切换重置）时把档位高亮拉回一致。 */
    fun setIntensity(mode: Intensity) {
        if (intensity == mode) return
        intensity = mode
        if (expanded) render()
    }

    /** Menu → file the open conversation as a knowledge-base contact. */
    var onSaveContact: (() -> Unit)? = null

    /** Menu → one manual screenshot + OCR of whatever app is open. */
    var onOcrCapture: (() -> Unit)? = null

    /**
     * Menu → turn automatic analysis off (or back on) for the app this card sits
     * on. The label follows [appAutoEnabled], which the service keeps in sync with
     * the effective setting — global switch plus this app's mute flag.
     */
    var onToggleAppAuto: (() -> Unit)? = null

    private var appAutoEnabled = true

    // ---- what the card currently shows (survives hide(); cleared by resetForNewConversation)
    private var app: String? = null
    private var judgment: Analysis? = null
    private var replies: List<RankedReply>? = null
    private var replyError: String? = null
    private var errorMsg: String? = null
    private var judgeWaiting = false
    private var repliesWaiting = false

    /** Which waiting state [repliesWaiting] means: false = 换一组, true = 再给 2 条. */
    private var moreWaiting = false
    private var waitStart = 0L
    private var lastFill: ((String) -> Unit)? = null
    private var ctxNotes = 0
    private var ctxHistory = 0
    private var noteText: String? = null

    /** The readable text of an in-flight streaming draft (opt-in), or null. */
    private var streamText: String? = null
    private var streamPending = false
    private var uiState: OverlayUiState = OverlayUiState.Idle

    /** Text views showing an elapsed-seconds counter; the ticker updates them in place. */
    private val waitLabels = ArrayList<Pair<TextView, String>>()

    /** Whether the overlay window is currently on screen. */
    fun isShowing(): Boolean = root != null

    private fun dp(v: Int) = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), ctx.resources.displayMetrics).roundToInt()

    private fun canOverlay(): Boolean = Settings.canDrawOverlays(ctx)

    private val screenW get() = ctx.resources.displayMetrics.widthPixels
    private val screenH get() = ctx.resources.displayMetrics.heightPixels
    private val cardW get() = minOf(screenW - dp(16), dp(380))

    /** Card background: white with the user's opacity so the chat shows through. */
    private fun panelBg(): Int {
        val a = (prefs.overlayOpacity / 100f * 255).roundToInt().coerceIn(150, 255)
        return Color.argb(a, 255, 255, 255)
    }

    private fun card(radius: Int, color: Int, stroke: Boolean = false, strokeColor: Int = Color.parseColor("#22000000"), strokeW: Int = 1) =
        GradientDrawable().apply {
            cornerRadius = dp(radius).toFloat()
            setColor(color)
            if (stroke) setStroke(dp(strokeW), strokeColor)
        }

    // ---------------------------------------------------------------- window

    private fun ensureWindow(): Boolean {
        if (root != null) return true
        if (!canOverlay()) { android.util.Log.w("JEVASSIST", "overlay: canDrawOverlays=false"); return false }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        ).apply { gravity = Gravity.TOP or Gravity.START }
        lp = params
        val r = FrameLayout(ctx)
        root = r
        mode = null
        try { wm.addView(r, params) } catch (e: Exception) {
            android.util.Log.e("JEVASSIST", "overlay addView failed: ${e.message}"); root = null; return false
        }
        return true
    }

    private fun updateLayout() { root?.let { r -> lp?.let { runCatching { wm.updateViewLayout(r, it) } } } }

    private fun setMode(m: Mode) {
        val r = root ?: return
        if (mode == m && r.childCount > 0) return
        mode = m
        dismissMenu()
        r.removeAllViews()
        clearCardRefs()
        val params = lp ?: return
        if (m == Mode.BUBBLE) {
            r.addView(buildBubble())
            // 收起态永远贴边：不管 prefs 里存了什么、上一张卡片停在哪里。
            val (x, y) = BubbleSnap.snap(
                prefs.bubbleX, prefs.bubbleY, dp(52), screenW, screenH,
                marginPx = dp(4), topMinPx = dp(24))
            params.x = x; params.y = y
            prefs.bubbleX = x; prefs.bubbleY = y
        } else {
            r.addView(buildCard())
            // 展开卡以胶囊锚点为左上角，钳进屏幕；不再按应用记忆第二套位置。
            val (x, y) = BubbleSnap.cardOrigin(
                prefs.bubbleX, prefs.bubbleY, cardW, screenW, screenH,
                marginPx = dp(4), topMinPx = dp(24), maxBottomPx = screenH - dp(120))
            params.x = x; params.y = y
        }
        // 位置留痕：再出现"窗口在、屏上找不到"时一行日志定位。
        Trace.log("overlay mode=$m x=${params.x} y=${params.y} app=${app ?: "-"}")
        updateLayout()
    }

    private fun clearCardRefs() {
        capsuleText = null; cardView = null; riskPill = null; headText = null; statusText = null
        chevron = null; bodyScroll = null; body = null; expanded = false; waitLabels.clear()
    }

    // ---------------------------------------------------------------- bubble

    private fun capsuleBg(stroke: Boolean = false) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(Color.argb(235, 58, 122, 254))
        if (stroke) setStroke(dp(2), Palette.brand())
    }

    private fun buildBubble(): View {
        val b = TextView(ctx).apply {
            text = "助手"; setTextColor(Color.WHITE); gravity = Gravity.CENTER; textSize = 13f
            setTypeface(typeface, Typeface.BOLD)
            alpha = 0.85f
            background = capsuleBg()
            layoutParams = FrameLayout.LayoutParams(dp(52), dp(52))
        }
        capsuleText = b
        // 拖动：松手即吸回最近边缘（吸附结果同时写回 prefs，锚点永远有效）。
        attachDrag(b, widthPx = { dp(52) }, onTap = { expandCard() }) { x, y ->
            val (sx, sy) = BubbleSnap.snap(x, y, dp(52), screenW, screenH, dp(4), dp(24))
            prefs.bubbleX = sx; prefs.bubbleY = sy
            lp?.let { it.x = sx; it.y = sy; updateLayout() }
        }
        renderCapsule()
        return b
    }

    /** 胶囊上的状态字：跑轮时是秒数，有判断时是危险度，平时是"助手"。 */
    private fun renderCapsule() {
        val t = capsuleText ?: return
        t.text = when {
            judgeWaiting || repliesWaiting -> "${((SystemClock.elapsedRealtime() - waitStart) / 1000).toInt()}s"
            judgment?.dangerLevel != null -> {
                val d = judgment!!.dangerLevel!!
                "${d.score.roundToInt()}/${d.maxLevel}"
            }
            else -> "助手"
        }
    }

    /** 收起 → 展开卡：唯一的用户入口（胶囊点按），位置沿用胶囊锚点。 */
    private fun expandCard() {
        if (!ensureWindow()) return
        setMode(Mode.CARD)
        expanded = true
        applyBodyMaxHeight()
        bodyScroll?.visibility = View.VISIBLE
        render()
        updateLayout()
    }

    /** 展开卡 → 收起胶囊：吸到最近的边缘，绝不留在半空。 */
    private fun collapseToBubble() {
        if (mode != Mode.BUBBLE) setMode(Mode.BUBBLE)
        renderCapsule()
    }

    // ------------------------------------------------------------------ card

    private fun buildCard(): View {
        val c = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            background = card(16, panelBg(), stroke = true)
            elevation = dp(6).toFloat()
            layoutParams = FrameLayout.LayoutParams(cardW, FrameLayout.LayoutParams.WRAP_CONTENT)
        }
        val header = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(10), dp(9), dp(10), dp(9))
        }
        val pill = TextView(ctx).apply {
            textSize = 12f; setTypeface(typeface, Typeface.BOLD); setPadding(dp(8), dp(3), dp(8), dp(3))
            maxLines = 1
        }
        val head = TextView(ctx).apply {
            textSize = 14f; setTextColor(Color.parseColor("#111827")); maxLines = 1; ellipsize = TextUtils.TruncateAt.END
            setPadding(dp(8), 0, dp(6), 0)
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val status = TextView(ctx).apply { textSize = 12f; setTextColor(Color.parseColor("#9CA3AF")); setPadding(0, 0, dp(6), 0) }
        val chev = TextView(ctx).apply { textSize = 15f; setTextColor(Color.parseColor("#6B7280")) }
        header.addView(pill); header.addView(head); header.addView(status); header.addView(chev)
        attachDrag(header, widthPx = { cardW }, onTap = { onHeaderTap() }) { x, y ->
            app?.let { prefs.saveCardPosition(it, x, y) }
            if (expanded) applyBodyMaxHeight()
        }

        val scroll = MaxHeightScroll(ctx).apply { isVerticalScrollBarEnabled = false; visibility = View.GONE }
        val b = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(12), 0, dp(12), dp(12)) }
        scroll.addView(b)
        c.addView(header); c.addView(scroll)

        cardView = c; riskPill = pill; headText = head; statusText = status; chevron = chev
        bodyScroll = scroll; body = b
        render()
        return c
    }

    private fun onHeaderTap() {
        val nothingYet = judgment == null && replies.isNullOrEmpty() && !judgeWaiting
        if (nothingYet || (judgment == null && errorMsg != null)) { onManualAnalyze?.invoke(); return }
        collapseToBubble()
    }

    private fun setExpanded(v: Boolean) {
        if (!v) { collapseToBubble(); return }
        if (mode != Mode.CARD) setMode(Mode.CARD)
        val s = bodyScroll ?: return
        root?.let { TransitionManager.beginDelayedTransition(it, AutoTransition().apply { duration = 150 }) }
        expanded = true
        applyBodyMaxHeight()
        s.visibility = View.VISIBLE
        render()
        updateLayout()
    }

    /**
     * How tall the scrollable body may get: half the screen, but never so tall that
     * the card's own header and footer are pushed off the bottom. Recomputed on
     * every expand and on every drag, because the answer depends on where the card
     * currently sits — a card dragged to the bottom edge gets a shorter body.
     */
    private fun applyBodyMaxHeight() {
        val s = bodyScroll ?: return
        val y = lp?.y ?: dp(92)
        s.maxH = minOf((screenH * 0.5f).roundToInt(), screenH - y - dp(140)).coerceAtLeast(dp(180))
    }

    // ---------------------------------------------------------------- gestures

    /** Drag anywhere, tap, or long-press for the menu. [onDrop] gets the final position. */
    private fun attachDrag(v: View, widthPx: () -> Int, onTap: () -> Unit, onDrop: (Int, Int) -> Unit) {
        var startX = 0; var startY = 0; var touchX = 0f; var touchY = 0f
        var moved = false; var longFired = false
        val longPress = Runnable { if (!moved) { longFired = true; showMenu(dp(48)) } }
        v.setOnTouchListener { _, e ->
            val p = lp ?: return@setOnTouchListener false
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startX = p.x; startY = p.y; touchX = e.rawX; touchY = e.rawY
                    moved = false; longFired = false
                    v.postDelayed(longPress, 550); true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (e.rawX - touchX).toInt(); val dy = (e.rawY - touchY).toInt()
                    if (!moved && (abs(dx) > dp(6) || abs(dy) > dp(6))) { moved = true; v.removeCallbacks(longPress) }
                    if (moved) {
                        // Keep clear of the side edges: the extreme edge is MIUI's back-gesture zone.
                        p.x = (startX + dx).coerceIn(dp(4), maxOf(dp(4), screenW - widthPx() - dp(4)))
                        p.y = (startY + dy).coerceIn(dp(24), screenH - dp(120))
                        updateLayout()
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    v.removeCallbacks(longPress)
                    when {
                        longFired -> Unit
                        moved -> onDrop(p.x, p.y)
                        else -> onTap()
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> { v.removeCallbacks(longPress); true }
                else -> false
            }
        }
    }

    private fun showMenu(top: Int) {
        val r = root ?: return
        dismissMenu()
        val menu = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            background = card(12, panelBg(), stroke = true)
            elevation = dp(8).toFloat()
            setPadding(dp(4), dp(4), dp(4), dp(4))
            layoutParams = FrameLayout.LayoutParams(dp(196), ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = top }
        }
        menu.addView(menuItem("截屏识别一次") { dismissMenu(); onOcrCapture?.invoke() })
        menu.addView(menuItem(if (appAutoEnabled) "这个应用不再自动分析" else "恢复这个应用的自动分析") {
            dismissMenu(); onToggleAppAuto?.invoke()
        })
        menu.addView(menuItem("把当前会话存为联系人") { dismissMenu(); onSaveContact?.invoke() })
        menu.addView(menuItem("打开设置") { dismissMenu(); openSettings() })
        menu.addView(menuItem("隐藏助手（本次）") { hide() })
        menu.addView(menuItem("取消") { dismissMenu() })
        menuView = menu
        r.addView(menu)
    }

    private fun dismissMenu() { menuView?.let { root?.removeView(it) }; menuView = null }

    private fun menuItem(label: String, onClick: () -> Unit) = TextView(ctx).apply {
        text = label; setTextColor(Color.parseColor("#111827")); textSize = 14f
        setPadding(dp(12), dp(10), dp(12), dp(10)); setOnClickListener { onClick() }
    }

    private fun openSettings() {
        runCatching {
            ctx.startActivity(Intent().setClassName(ctx, "com.jev.probe.SettingsActivity")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        if (expanded) setExpanded(false)
    }

    // ------------------------------------------------------------ public API

    /** The chat app in the foreground; only the per-app auto-analysis flag follows it. */
    fun setApp(pkg: String?) {
        if (pkg == app) return
        app = pkg
        appAutoEnabled = prefs.autoAnalyzeFor(pkg)
    }

    /** Which app the current card/bubble belongs to, or null when nothing is up. */
    fun currentApp(): String? = app

    /** Keep the long-press label honest after the setting was toggled. */
    fun setAppAutoEnabled(on: Boolean) { appAutoEnabled = on }

    /**
     * [title] null = not inside a chat window: show the bubble. Otherwise show the
     * card with whatever it already holds for this conversation (nothing is cleared
     * here — that is [resetForNewConversation]'s job).
     */
    fun showIdle(title: String?) {
        if (!ensureWindow()) return
        // 收起态统一是胶囊（在不在聊天窗里都一样）；只有用户点它或出错才展开卡。
        if (mode == null) setMode(Mode.BUBBLE) else render()
    }

    /**
     * 通知「唤出助手」：把卡展开。收起态时从胶囊锚点展开；已展开时只是把
     * 卡片闪一下边框提醒位置。
     */
    fun summon() {
        if (!ensureWindow()) return
        if (mode == Mode.BUBBLE) expandCard() else flashIfExpanded()
    }

    private fun flashIfExpanded() {
        val c = cardView ?: return
        c.background = card(16, panelBg(), stroke = true, strokeColor = Palette.brand(), strokeW = 2)
        main.postDelayed({ cardView?.background = card(16, panelBg(), stroke = true) }, 900)
    }

    /** The conversation changed: drop everything that belonged to the previous one. */
    fun resetForNewConversation() {
        judgment = null; replies = null; replyError = null; errorMsg = null
        judgeWaiting = false; repliesWaiting = false; moreWaiting = false; stopTicker()
        lastFill = null; noteText = null; ctxNotes = 0; ctxHistory = 0; streamText = null
        detailExpanded = false; memoryHint = null
        if (expanded) setExpanded(false)
        if (mode == Mode.CARD) render()
    }

    /** A new analysis round starts. The previous result stays on the card until the new one lands. */
    fun beginRound() {
        if (!ensureWindow()) return
        errorMsg = null; replyError = null; streamText = null
        judgeWaiting = true; repliesWaiting = true; moreWaiting = false
        ctxNotes = 0; ctxHistory = 0
        startTicker()
        // 已展开的卡原地进入等待态；收起态保持胶囊（秒数在胶囊上跳），绝不自弹。
        if (mode == Mode.BUBBLE) renderCapsule() else render()
    }

    /** "换一组" started: only the candidates are being redrafted. */
    fun beginRegenerate() {
        replyError = null
        repliesWaiting = true
        moreWaiting = false
        startTicker()
        render()
    }

    /** "再给 2 条" started: the card keeps its candidates while two more are drafted. */
    fun beginMore() {
        replyError = null
        repliesWaiting = true
        moreWaiting = true
        startTicker()
        render()
    }

    /** The candidate texts on the card now, so a redraft can avoid repeating them. */
    fun currentReplyTexts(): List<String> = replies.orEmpty().map { it.text }

    fun replaceReply(original: String, replacement: RankedReply) {
        replies = replies.orEmpty().map { if (it.text == original) replacement else it }
        replyError = null
        streamText = null
        repliesWaiting = false
        moreWaiting = false
        render()
    }

    /** How many knowledge notes / history lines went into the pending analysis. */
    fun setContextInfo(notes: Int, history: Int) { ctxNotes = notes; ctxHistory = history }

    private var memoryHint: String? = null

    /**
     * 记忆没激活时的一行提醒（会话没存为联系人 → 历史与台账都是空的，模型每轮
     * 只看得到最近 20 条）。放在第一屏：这正是「AI 分不清上下文」时用户唯一
     * 能看到的解释。
     */
    fun setMemoryHint(hint: String?) { memoryHint = hint }

    /** A caveat line for the card (OCR mode); null clears it. */
    fun setNote(note: String?) { noteText = note }

    /**
     * Take the overlay out of the picture for one screenshot. INVISIBLE, not
     * removed: the window (and everything on it) must survive the round trip.
     */
    fun setHiddenForShot(hidden: Boolean) { root?.visibility = if (hidden) View.INVISIBLE else View.VISIBLE }

    fun showError(msg: String) {
        if (!ensureWindow()) return
        uiState = OverlayUiState.Error(msg)
        // 错误是唯一允许自动展开卡的路径：用户得看到"为什么没有候选"。
        setMode(Mode.CARD)
        expanded = true
        errorMsg = msg; streamText = null
        judgeWaiting = false; repliesWaiting = false; moreWaiting = false; stopTicker()
        render()
        updateLayout()
    }

    fun showJudgment(a: Analysis) {
        judgment = a; errorMsg = null; judgeWaiting = false
        stopTickerIfIdle()
        render(); flashIfCollapsed()
    }

    fun showDraftFirst(draft: List<RankedReply>, onFill: (String) -> Unit) {
        uiState = OverlayUiState.Draft(draft)
        lastFill = onFill
        streamText = null
        replies = draft.map { it.copy(ranked = false, prob = 0.0) }
        replyError = null
        repliesWaiting = false
        stopTickerIfIdle()
        render()
    }

    fun showJudgeFailure(msg: String) {
        errorMsg = msg
        judgeWaiting = false
        stopTickerIfIdle()
        render()
    }

    /** Replies land on their own — whether or not the judgment has arrived yet. */
    fun showReplies(ranked: List<RankedReply>, error: String? = null, onFill: (String) -> Unit) {
        uiState = if (error == null && ranked.any { it.ranked }) OverlayUiState.Ranked(ranked)
        else if (error != null) OverlayUiState.Error(error)
        else OverlayUiState.Draft(ranked)
        lastFill = onFill
        streamText = null
        replies = ranked
        replyError = error
        repliesWaiting = false
        moreWaiting = false
        stopTickerIfIdle()
        render()
    }

    /**
     * An in-flight streaming draft grew (opt-in; see `Prefs.streamReplies`). Only
     * readable text is passed in — the JSON envelope and the prompt's own array
     * format are stripped in [com.jev.probe.jev.StreamText]. The card shows it where
     * the skeleton would be, so the user starts reading before the model finishes.
     *
     * Re-rendering is throttled: a quick model emits dozens of chunks a second and
     * every render rebuilds the whole body.
     */
    fun showStreaming(text: String) {
        if (text == streamText) return
        streamText = text
        if (streamPending) return
        streamPending = true
        main.postDelayed({ streamPending = false; if (expanded) render() }, STREAM_FLUSH_MS)
    }

    /**
     * "再给 2 条" landed: append to what is already on the card instead of
     * replacing it. The new ones carry no rank (the ranking format is
     * exactly-three), so they show as unranked candidates under the ranked set.
     */
    fun appendReplies(more: List<RankedReply>, onFill: (String) -> Unit) {
        if (more.isEmpty()) return
        lastFill = onFill
        streamText = null
        replies = replies.orEmpty() + more
        replyError = null
        repliesWaiting = false
        moreWaiting = false
        stopTickerIfIdle()
        render()
    }

    /**
     * "再给 2 条" came back empty: clear the waiting state but keep the card's
     * existing candidates (a failed top-up must not cost the user the three
     * replies already on screen).
     */
    fun endMoreWaiting() {
        repliesWaiting = false
        moreWaiting = false
        stopTickerIfIdle()
        render()
    }

    fun toast(msg: String) = Toast.makeText(ctx, msg, Toast.LENGTH_SHORT).show()

    fun hide() {
        uiState = OverlayUiState.Idle
        val r = root ?: return
        stopTicker()
        runCatching { wm.removeView(r) }
        root = null; mode = null; menuView = null
        clearCardRefs()
    }

    // ---------------------------------------------------------------- ticker

    private val ticker = object : Runnable {
        override fun run() {
            if (!judgeWaiting && !repliesWaiting) return
            val s = ((SystemClock.elapsedRealtime() - waitStart) / 1000).toInt()
            if (s >= UI_LIMIT_S) { giveUp(); return }
            statusText?.text = if (judgment == null && judgeWaiting) "${s}s" else "更新中 ${s}s"
            waitLabels.forEach { (tv, label) -> tv.text = "$label ${s}s" }
            capsuleText?.text = "${s}s"
            main.postDelayed(this, 1000)
        }
    }

    private fun startTicker() {
        waitStart = SystemClock.elapsedRealtime()
        main.removeCallbacks(ticker)
        main.post(ticker)
    }

    private fun stopTicker() { main.removeCallbacks(ticker) }

    private fun stopTickerIfIdle() { if (!judgeWaiting && !repliesWaiting) stopTicker() }

    /** Nothing came back in time (or the round was dropped): never keep spinning. */
    private fun giveUp() {
        if (judgeWaiting) { judgeWaiting = false; if (judgment == null) errorMsg = "分析超时，点这里重试" }
        streamText = null
        if (repliesWaiting) { repliesWaiting = false; moreWaiting = false; if (replies.isNullOrEmpty()) replyError = "生成超时" }
        stopTicker()
        render()
    }

    private fun flashIfCollapsed() {
        val t = capsuleText ?: return
        if (mode != Mode.BUBBLE) return
        t.background = capsuleBg(stroke = true)
        main.postDelayed({ capsuleText?.background = capsuleBg() }, 900)
    }

    // --------------------------------------------------------------- rendering

    private fun render() {
        renderHeader()
        if (expanded) renderBody()
    }

    private fun renderHeader() {
        val pill = riskPill ?: return
        val a = judgment
        val lvl = a?.dangerLevel?.score?.roundToInt()
        when {
            lvl != null -> {
                pill.text = "${dangerWord(lvl)} $lvl/${a.dangerLevel!!.maxLevel}"
                pill.setTextColor(Color.WHITE); pill.background = card(10, dangerColor(lvl))
            }
            errorMsg != null -> { pill.text = "出错"; pill.setTextColor(Color.WHITE); pill.background = card(10, Color.parseColor("#DC2626")) }
            else -> { pill.text = "助手"; pill.setTextColor(Color.WHITE); pill.background = card(10, Palette.brand()) }
        }
        headText?.text = when {
            a?.trueIntent != null -> INTENT[a.trueIntent.choice] ?: a.trueIntent.choice
            errorMsg != null -> errorMsg
            judgeWaiting -> "分析中…"
            a != null -> "已分析"
            else -> "点这里分析当前对话"
        }
        val waiting = judgeWaiting || repliesWaiting
        statusText?.visibility = if (waiting || (a != null && errorMsg != null)) View.VISIBLE else View.GONE
        if (!waiting && a != null && errorMsg != null) statusText?.text = "更新失败"
        val hasContent = a != null || !replies.isNullOrEmpty()
        chevron?.visibility = if (hasContent) View.VISIBLE else View.GONE
        chevron?.text = if (expanded) "▴" else "▾"
    }

    private fun renderBody() {
        val b = body ?: return
        // Every render rebuilds the children, which resets the scroll to the top.
        // When the user is reading candidate #3 and a result lands, jumping to the
        // top loses their place, so put it back after the new children are laid out.
        val keepScroll = bodyScroll?.scrollY ?: 0
        b.removeAllViews()
        waitLabels.clear()
        if (expanded) applyBodyMaxHeight()

        // 信息分级：错误最先（可行动）→ 档位 → 候选永远第一屏；判断与知识库
        // 是「为什么这么建议」，折进 footer 的「详情」，想看的人再展开。
        errorMsg?.let {
            b.addView(line(it, "#DC2626", 12f))
            b.addView(pill("去设置", false) { onOpenSettings?.invoke() })
        }

        memoryHint?.let { b.addView(hint("⚠ $it")) }
        b.addView(divider())
        b.addView(intensityRow())
        val list = replies.orEmpty()
        // The judge's best_action names the move to make; the rank step only scores
        // best_reply, so promote the candidate that carries the recommended move out.
        val preferred = StrategyOrder.preferred(judgment?.bestAction?.choice)
        val shown = StrategyOrder.order(list, preferred)
        val recommended = if (preferred != null && shown.firstOrNull()?.strategy == preferred) preferred else null
        val ranked = shown.any { it.ranked }
        b.addView(hint(if (ranked) "候选回复（Jev 排序）" else "候选回复 · 策略分栏"))
        when {
            shown.isNotEmpty() -> shown.forEachIndexed { i, r ->
                b.addView(
                    replyCard(i + 1, r.text, (r.prob * 100).roundToInt(), r, recommended = recommended != null && i == 0)
                )
            }
            repliesWaiting -> {
                val live = streamText
                if (live.isNullOrBlank()) b.addView(skeleton()) else b.addView(line(live, "#111827", 14f))
                b.addView(waitHint("生成中"))
            }
            else -> {
                val msg = when {
                    replyError == "生成超时" -> "生成超时"
                    replyError != null -> "回复接口出错：$replyError"
                    else -> "（未生成候选回复）"
                }
                b.addView(line(msg, "#DC2626", 12f))
            }
        }
        // Footer: status on the left, "换一组" (or 重试) on the right.
        val footer = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(8), 0, 0)
        }
        val left = TextView(ctx).apply {
            textSize = 12f; setTextColor(Color.parseColor("#9CA3AF"))
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        if (repliesWaiting && shown.isNotEmpty()) {
            val what = if (moreWaiting) "再加 2 条中" else "换一组中"
            left.text = "$what…"; waitLabels.add(left to what)
        } else left.text = if (shown.isNotEmpty()) "${shown.size} 条候选" else ""
        footer.addView(left)
        if (!repliesWaiting && !judgeWaiting) {
            if (judgment != null || noteText?.isNotBlank() == true) {
                footer.addView(pill(if (detailExpanded) "收起详情" else "详情", primary = false) {
                    detailExpanded = !detailExpanded; render()
                })
            }
            if (shown.isNotEmpty() && shown.size < 9) {
                footer.addView(pill("再给 2 条", primary = false) { onMoreReplies?.invoke() })
            }
            footer.addView(pill(if (shown.isEmpty()) "重试" else "换一组", primary = false) { onRegenerate?.invoke() })
        }
        b.addView(footer)
        if (detailExpanded) {
            b.addView(divider())
            b.addView(hint(if (ctxNotes == 0 && ctxHistory == 0) "未用知识库" else "知识库 $ctxNotes 条 · 历史 $ctxHistory 条"))
            noteText?.let { if (it.isNotBlank()) b.addView(hint(it)) }
            val a = judgment
            if (a != null) {
                a.trueIntent?.let {
                    b.addView(line("对方真实意图：${INTENT[it.choice] ?: it.choice}", "#111827", 14f, true))
                    b.addView(hint("把握 ${(it.confidence * 100).roundToInt()}%"))
                }
                val bits = ArrayList<String>()
                a.sheNeeds?.let { bits.add("要${NEEDS[it.choice] ?: it.choice}") }
                a.bestAction?.let { bits.add(ACTION[it.choice] ?: it.choice) }
                a.shouldReplyNow?.let { bits.add(if (it >= 0.5) "可给实质" else "先别给实质") }
                if (bits.isNotEmpty()) b.addView(line(bits.joinToString("  ·  "), "#374151", 13f))
                a.tensionResolved?.let { if (it >= 0.7) b.addView(line("✓ 紧张已缓解", "#16A34A", 12f)) }
            }
        }
        if (keepScroll > 0) {
            b.post { bodyScroll?.let { s -> s.scrollTo(0, keepScroll.coerceAtMost(s.getChildAt(0)?.height ?: 0)) } }
        }
    }

    /**
     * 推进档位一排：自动/收着/自然/加码。当前档位高亮；点按即改（影响下一轮
     * 起草），服务是权威状态，这里只镜像显示。
     */
    private fun intensityRow(): View = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(0, dp(2), 0, dp(4))
        addView(TextView(ctx).apply {
            text = "档位"
            textSize = 11f
            setTextColor(Color.parseColor("#9CA3AF"))
        })
        Intensity.entries.forEach { m ->
            addView(pill(m.label, primary = intensity == m) {
                if (intensity != m) {
                    intensity = m
                    onIntensity?.invoke(m)
                    render()
                }
            })
        }
    }

    private fun skeleton(): LinearLayout = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        repeat(3) { i ->
            addView(View(ctx).apply {
                background = card(8, Color.parseColor("#E5E7EB"))
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, dp(if (i == 0) 14 else 10)
                ).apply { topMargin = dp(7) }
            })
        }
    }

    private fun waitHint(label: String): TextView = hint("$label…").also { waitLabels.add(it to label) }

    private fun replyCard(rank: Int, text: String, pct: Int, reply: RankedReply, recommended: Boolean = false): View {
        val top = rank == 1 && reply.ranked
        val c = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            background = card(12, if (top) Palette.brandTint() else Color.parseColor("#F3F4F6"))
            setPadding(dp(10), dp(8), dp(10), dp(8))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(6) }
        }
        val strategy = when (reply.strategy) {
            "safe" -> "稳妥承接"
            "forward" -> "推进话题"
            "angle" -> "换角度"
            else -> ""
        }
        if (reply.ranked || strategy.isNotBlank()) c.addView(TextView(ctx).apply {
            // "推荐" is the judge's own best_action, not a second score: it says this
            // row is the one that performs the action the judge chose.
            this.text = buildString {
                if (recommended) append("推荐 · ")
                if (reply.ranked) append("#").append(rank).append(" · ").append(pct).append("%")
                if (strategy.isNotBlank()) { if (isNotEmpty()) append(" · "); append(strategy) }
            }
            setTextColor(Palette.brand()); textSize = 11f
            setTypeface(typeface, Typeface.BOLD)
        })
        c.addView(TextView(ctx).apply {
            this.text = text; setTextColor(Color.parseColor("#111827")); textSize = 14f
            setPadding(0, dp(3), 0, dp(7)); setLineSpacing(dp(2).toFloat(), 1f)
            setTextIsSelectable(true)
        })
        val btns = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.END }
        btns.addView(pill("改短", false) {
            onRefine?.invoke(text, "把这条回复改短，保留原意和必要信息，只输出一条自然、可直接发送的回复。")
        })
        btns.addView(pill("换语气", false) {
            onRefine?.invoke(text, "保持原意，把语气改得更轻松、更像熟人聊天；不要油腻、不要过度热情，只输出一条可直接发送的回复。")
        })
        btns.addView(pill("重生成", false) {
            onRefine?.invoke(text, "重新生成一条与原句明显不同、但同样自然且贴合最近对话的回复。不要改变事实和意图。")
        })
        btns.addView(pill("复制", false) { copy(text) })
        // Fill, then fold the card so the input box + keyboard are visible to review/send.
        btns.addView(pill("填入", true) { lastFill?.invoke(text); if (expanded) setExpanded(false) })
        c.addView(btns)
        return c
    }

    private fun pill(label: String, primary: Boolean, onClick: () -> Unit) = TextView(ctx).apply {
        text = label; textSize = 13f; gravity = Gravity.CENTER
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(if (primary) Color.WHITE else Palette.brand())
        background = card(18, if (primary) Palette.brand() else Color.parseColor("#FFFFFF"), stroke = !primary)
        setPadding(dp(16), dp(6), dp(16), dp(6))
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { leftMargin = dp(8) }
        setOnClickListener { onClick() }
    }

    // --------------------------------------------------------------- helpers

    private fun line(text: String, color: String, size: Float, bold: Boolean = false) =
        TextView(ctx).apply {
            this.text = text; setTextColor(Color.parseColor(color)); textSize = size
            if (bold) setTypeface(typeface, Typeface.BOLD)
            setPadding(0, dp(2), 0, dp(2))
        }

    private fun hint(text: String) = line(text, "#9CA3AF", 12f)

    private fun divider() = View(ctx).apply {
        setBackgroundColor(Color.parseColor("#1F000000"))
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(1)).apply {
            topMargin = dp(6); bottomMargin = dp(4)
        }
    }

    private fun copy(text: String) {
        val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        cm.setPrimaryClip(android.content.ClipData.newPlainText("jev_reply", text))
        toast("已复制")
    }

    private fun dangerColor(lvl: Int): Int = when {
        lvl >= 6 -> Color.parseColor("#DC2626")
        lvl >= 3 -> Color.parseColor("#D97706")
        else -> Color.parseColor("#16A34A")
    }

    private fun dangerWord(lvl: Int): String = when {
        lvl >= 8 -> "很危险"
        lvl >= 6 -> "偏危险"
        lvl >= 3 -> "留神"
        else -> "安全"
    }

    /** A ScrollView that wraps its content but never grows past [maxH]. */
    private class MaxHeightScroll(ctx: Context) : ScrollView(ctx) {
        var maxH = Int.MAX_VALUE
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            super.onMeasure(widthMeasureSpec, View.MeasureSpec.makeMeasureSpec(maxH, View.MeasureSpec.AT_MOST))
        }
    }

    companion object {
        /** The card gives up on a round after this long, whatever the service is doing. */
        private const val UI_LIMIT_S = 40

        /** At most one streaming re-render per this many ms: a fast model emits dozens of chunks a second. */
        private const val STREAM_FLUSH_MS = 120L

        private val INTENT = mapOf(
            "confirm_you_care" to "确认你在不在乎", "vent_anger" to "在发泄情绪",
            "request_action" to "要你办事", "seek_explanation" to "要个解释",
            "casual_chat" to "随便聊聊", "close_topic" to "事情过去了",
            "intimate_roleplay" to "在推进这一场")
        private val NEEDS = mapOf(
            "apology" to "道歉", "action" to "具体行动", "explanation" to "解释",
            "care" to "你的在乎", "nothing" to "（不用做什么）",
            "engagement" to "接住、接着玩")
        private val ACTION = mapOf(
            "check_history" to "翻聊天记录", "apologize" to "先道歉", "give_commitment" to "给承诺",
            "explain" to "解释清楚", "acknowledge" to "接住情绪", "say_less" to "少说两句",
            "make_plan" to "定个安排", "play_along" to "接着往下写")
    }
}

package dev.chartools.capture.overlay

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
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
import dev.chartools.capture.Trace
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
 *   never pops open on its own except for showError, which is actionable.
 *
 * Long-pressing the capsule or the card header opens the menu (截屏识别一次…).
 *
 * ---------------------------------------------------------------- 移植说明
 * 移植自旧仓库 `com.jev.probe.overlay.OverlayController`（1037 行），移植原则
 * 与采集层一致：
 * - 视图构建（胶囊/卡片/候选行/菜单）、吸附（[BubbleSnap]）、拖拽与显隐逻辑
 *   逐字保留；
 * - 对 Prefs 的引用：`overlayOpacity` 换成构造参数（缺省取旧 Prefs 默认值 92），
 *   `bubbleX/bubbleY` 换成内存字段（见字段上的 TODO(port)），
 *   `autoAnalyzeFor`（按应用静音）随旧编排层剥掉；
 * - 对 jev/kb 的引用剥掉，**建议内容由 Dart 经 [showSuggestions] 推入，悬浮窗
 *   不调模型**。随之移除的成员（在旧文件里的位置仅作索引）：
 *   - 判断态：Analysis/judgment、showJudgment/showError/showJudgeFailure、
 *     renderHeader 的危险度 pill 与 INTENT 表、giveUp 超时兜底；
 *   - 等待跑轮：judgeWaiting/repliesWaiting/moreWaiting、ticker/waitLabels、
 *     beginRound/beginRegenerate/beginMore/stopRoundWaiting、renderCapsule 的
 *     秒数分支（Dart 侧 busy 状态暂不推给悬浮窗，TODO(port)）；
 *   - 流式草稿：streamText/showStreaming（STREAM_FLUSH_MS 节流一并移除）；
 *   - 档位与知识库详情：Intensity/setIntensity/intensityRow、detailExpanded、
 *     setContextInfo/setMemoryHint/setNote、NEEDS/ACTION 表；
 *   - 候选精修：改短/换语气/重生成三个按钮（onRefine）、StrategyOrder 重排、
 *     「推荐」前缀（judge best_action）；
 *   - 菜单项：截屏识别一次 / 重新生成候选（手动） / 这个应用不再自动分析 /
 *     把当前会话存为联系人 / 打开设置（onManualAnalyze/onRegenerate/
 *     onManualGenerate/onMoreReplies/onOpenSettings/onSaveContact/onOcrCapture/
 *     onToggleAppAuto、app 字段与 setApp/currentApp/setAppAutoEnabled）。
 *   - 本地剪贴板写入与 Toast（copy/toast）：「复制」改为把动作交回 Dart。
 * - 候选上的「填入/复制」按钮不再直接动作，经 [onOverlayAction] 交回 Dart
 *   （refill / copy + 候选下标），由 Dart 决定回填输入框还是写剪贴板。
 */
class OverlayController(
    private val ctx: Context,

    // TODO(port)：旧仓库读 Prefs.overlayOpacity（默认 92，钳 60..100）并落盘；
    // 插件无 Prefs 宿主，先由调用方传入，缺省取旧默认值。
    private val overlayOpacity: Int = 92,
) {

    private val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager

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

    /**
     * 候选按钮动作回到 Dart：action = "refill"（填入）| "copy"（复制），index
     * 是 [showSuggestions] 里候选的下标。Dart 决定回填输入框还是写剪贴板。
     */
    var onOverlayAction: ((action: String, index: Int) -> Unit)? = null

    /**
     * Dart 推来的会话标题（null 显示占位文案）。旧卡头部显示的是判断出的对方
     * 真实意图（INTENT 表，随 jev 编排未移植），这里换成会话标题。
     */
    private var title: String? = null

    // ---- what the card currently shows（survives hide()） ------------------

    private var replies: List<Suggestion>? = null

    /**
     * B8 候选展示模式（p0-plan B8）：`MODE_PRIMARY` = 主推第一张大卡、备选
     * 折叠两行小字（点按展开）；null / 其他值 = 整列平铺（移植期默认行为）。
     * 由 Dart 经 showSuggestions 的 `mode` 键随每批候选透传（设置页开关 →
     * SettingsStore.displayMode → CaptureSession）。
     */
    private var displayMode: String? = null

    /** B8 主推模式下被点开展开的备选下标（候选列表整体替换时清空）。 */
    private val expandedCandidates = mutableSetOf<Int>()

    /**
     * fix(kimi-review #11)：悬浮窗防截屏（FLAG_SECURE）开关，默认关。Dart 经
     * control 通道 `setSecure(bool)` 推来（通道契约与 capture_android.dart
     * 写死一致：方法名 'setSecure'，参数就是 bool 本身
     * `call.arguments as? Boolean`，由 CaptureService.handleControl 的
     * 'setSecure' 分支转进来）。true = 给悬浮窗窗口加 WindowManager 的
     * FLAG_SECURE：系统截图与屏幕录制都拍不到窗口内容——候选是第三方对话
     * 明文，录屏可整段带走。状态存内存：服务重启回默认关；窗口不在屏上时
     * 只记状态，下次 [ensureWindow] 建窗时带上（开关先于弹窗打开也生效）。
     * fix(#9 K-2)：重启后的恢复不靠本类持久化——Dart 把期望值带进 configure
     * 载荷随服务连接重放（CaptureService.handleControl 的 configure 分支调
     * [setSecure]），当前状态经 [isSecure] 回读。
     */
    private var secure = false

    // TODO(port)：旧仓库把锚点坐标存 Prefs（bubbleX/bubbleY，-1 = 默认），跨
    // 进程重启记忆位置；插件无 Prefs 宿主，先存内存（服务重启回到默认位置）。
    private var bubbleX = -1
    private var bubbleY = -1

    /** Dart 推来的一条候选（showSuggestions {list:[{text,strategy,prob}]}）。 */
    data class Suggestion(
        val text: String,
        val strategy: String,
        val prob: Double,
    )

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
        val a = (overlayOpacity / 100f * 255).roundToInt().coerceIn(150, 255)
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
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            // fix(kimi-review #11)：防截屏开关开着时，新建窗口直接带上
            // FLAG_SECURE（悬浮窗还没弹出期间开关被打开，等建窗在这里补上）。
            if (secure) flags = flags or WindowManager.LayoutParams.FLAG_SECURE
        }
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
                bubbleX, bubbleY, dp(52), screenW, screenH,
                marginPx = dp(4), topMinPx = dp(24))
            params.x = x; params.y = y
            bubbleX = x; bubbleY = y
        } else {
            r.addView(buildCard())
            // 展开卡以胶囊锚点为左上角，钳进屏幕；不再按应用记忆第二套位置。
            val (x, y) = BubbleSnap.cardOrigin(
                bubbleX, bubbleY, cardW, screenW, screenH,
                marginPx = dp(4), topMinPx = dp(24), maxBottomPx = screenH - dp(120))
            params.x = x; params.y = y
        }
        // 位置留痕：再出现"窗口在、屏上找不到"时一行日志定位。
        Trace.log("overlay mode=$m x=${params.x} y=${params.y}")
        updateLayout()
    }

    private fun clearCardRefs() {
        capsuleText = null; cardView = null; riskPill = null; headText = null; statusText = null
        chevron = null; bodyScroll = null; body = null; expanded = false
        expandedCandidates.clear()
    }

    // ---------------------------------------------------------------- bubble

    private fun capsuleBg(stroke: Boolean = false) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(Color.argb(235, 58, 122, 254))
        if (stroke) setStroke(dp(2), brand())
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
        // 拖动：松手即吸回最近边缘（吸附结果同时写回锚点，锚点永远有效）。
        attachDrag(b, widthPx = { dp(52) }, onTap = { expandCard() }) { x, y ->
            val (sx, sy) = BubbleSnap.snap(x, y, dp(52), screenW, screenH, dp(4), dp(24))
            bubbleX = sx; bubbleY = sy
            lp?.let { it.x = sx; it.y = sy; updateLayout() }
        }
        renderCapsule()
        return b
    }

    /**
     * 胶囊上的状态字。旧卡是三级：跑轮秒数 → 危险度 → "助手"；秒数与危险度
     * 都挂在 jev 轮次/判断态上（未移植，见类注释），这里固定"助手"。
     */
    private fun renderCapsule() {
        val t = capsuleText ?: return
        t.text = "助手"
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
        // 旧卡 header 右上角有常驻「↻ 手动生成」按钮（onManualGenerate）。它不放
        // footer 的原因：footer 在可滚动区底部，QQ 里键盘一顶、候选一多，它就滚
        // 到屏幕外。动作通道随 jev 编排剥掉了，TODO(port)：待 Dart 侧补「手动
        // 生成」动作后再加回这个按钮。
        header.addView(pill); header.addView(head); header.addView(status)
        header.addView(chev)
        attachDrag(header, widthPx = { cardW }, onTap = { onHeaderTap() }) { _, _ ->
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
        // 旧卡：无内容时点头部触发手动分析（onManualAnalyze，随编排未移植），
        // 有内容则收起。这里只剩收起。
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
        // 旧菜单还有：截屏识别一次 / 重新生成候选（手动） / 这个应用不再自动分析
        // / 把当前会话存为联系人 / 打开设置 —— 全部挂在旧编排层回调与 Prefs 上，
        // TODO(port)：待 Dart 侧补对应动作后再逐项加回。
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

    // ------------------------------------------------------------ public API

    /**
     * Dart 经 control 通道 `showSuggestions {list:[{text,strategy,prob}], title}`
     * 推来一批候选：弹出/更新展开卡，候选永远第一屏。窗口加不出（无
     * SYSTEM_ALERT_WINDOW 权限）返回 false。旧卡自动展开的唯一路径是
     * showError（可行动的错误）；本移植里 showSuggestions 是唯一入口，
     * 候选落地同样直接展开。
     */
    fun showSuggestions(list: List<Suggestion>, title: String?, mode: String? = null): Boolean {
        if (!ensureWindow()) return false
        this.title = title
        displayMode = mode
        replies = list
        // 新一批候选整体替换：展开态按新内容重新计（下标语义只对当批有效）。
        expandedCandidates.clear()
        setMode(Mode.CARD)
        expanded = true
        applyBodyMaxHeight()
        bodyScroll?.visibility = View.VISIBLE
        render()
        updateLayout()
        return true
    }

    /**
     * Dart 要求收起候选卡（control 通道 collapse）：只收卡不撤窗——卡折回
     * 胶囊，窗口本身留在屏上（整窗移除见 [hideSuggestions]）。「填入」成功后
     * Dart 调这里，与填入按钮本地的折回（[replyCard] 里 setExpanded(false)）
     * 同一语义、幂等：填入后折回胶囊，让出输入框和键盘，悬浮球仍可再点开。
     */
    fun collapseSuggestions() {
        collapseToBubble()
    }

    /** Dart 要求整窗移除（control 通道 hideSuggestions）：连胶囊一起撤下，
     *  下次 showSuggestions 再弹。只收卡不撤窗的语义走 [collapseSuggestions]。 */
    fun hideSuggestions() {
        hide()
    }

    /**
     * fix(kimi-review #11)：设置悬浮窗防截屏（FLAG_SECURE）。窗口在屏上时即时
     * 生效（updateViewLayout 重设 flags）；不在屏上时只记状态，下次建窗
     * （[ensureWindow]）直接带上——开关与弹窗的先后顺序无关。[hide] 只撤
     * 视图不重置本开关（与 [secure] 的内存态语义一致：服务活着就一直有效）。
     */
    fun setSecure(value: Boolean) {
        if (secure == value) return
        secure = value
        val r = root ?: return
        val params = lp ?: return
        params.flags = if (value) {
            params.flags or WindowManager.LayoutParams.FLAG_SECURE
        } else {
            params.flags and WindowManager.LayoutParams.FLAG_SECURE.inv()
        }
        try {
            wm.updateViewLayout(r, params)
        } catch (e: Exception) {
            android.util.Log.w(
                "JEVASSIST", "overlay setSecure updateViewLayout failed: ${e.message}")
        }
    }

    /**
     * fix(#9 K-2)：当前防截屏状态回读（control 通道 isSecure 的本体，Dart 侧
     * 采集页开关的「期望值 vs 服务回读值」早退判定用）。与 [secure] 内存态同
     * 一事实来源：窗口未建时返回已记录的开关值——[setSecure] 先记状态、
     * [ensureWindow] 建窗时按它补 FLAG_SECURE，所以回读值与将来建窗的窗口
     * flags 一致（与 [isShowing] 的取舍相同：读状态不建窗）。
     */
    fun isSecure(): Boolean = secure

    /**
     * Take the overlay out of the picture for one screenshot. INVISIBLE, not
     * removed: the window (and everything on it) must survive the round trip.
     */
    fun setHiddenForShot(hidden: Boolean) { root?.visibility = if (hidden) View.INVISIBLE else View.VISIBLE }

    fun hide() {
        val r = root ?: return
        runCatching { wm.removeView(r) }
        root = null; mode = null; menuView = null
        clearCardRefs()
    }

    // --------------------------------------------------------------- rendering

    private fun render() {
        renderHeader()
        if (expanded) renderBody()
    }

    private fun renderHeader() {
        val pill = riskPill ?: return
        // 旧卡 pill 三态：危险度 / 出错 / 品牌"助手"。判断与错误态随 jev 编排
        // 留在 Dart（应用页面上显示），这里固定品牌"助手"。
        pill.text = "助手"; pill.setTextColor(Color.WHITE); pill.background = card(10, brand())
        headText?.text = title ?: "助手"
        // 等待跑轮的状态字（statusText）随 jev 轮次未移植：永久隐藏。
        statusText?.visibility = View.GONE
        val hasContent = !replies.isNullOrEmpty()
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
        if (expanded) applyBodyMaxHeight()

        // 旧卡的信息分级：错误最先（可行动）→ 档位 → 候选永远第一屏 → 判断与
        // 知识库折进「详情」。错误/档位/详情随 jev 编排未移植，这里只保留候选
        // 与计数 footer。
        val shown = replies.orEmpty()
        if (shown.isEmpty()) {
            b.addView(line("（未生成候选回复）", "#DC2626", 12f))
            return
        }
        // Dart 推来的列表即排序结果（draftAndRank），按旧卡 ranked 分支显示。
        b.addView(hint("候选回复（Jev 排序）"))
        if (displayMode == MODE_PRIMARY && shown.size > 1) {
            // B8「一条推荐+两条备选」悬浮窗同构：排序第一张大卡带「推荐」前缀，
            // 备选折叠为两行小字、点按展开/收回；单条候选与 all 模式保持整列
            // 平铺（旧行为，缺省 displayMode=null 也落在这里）。
            shown.forEachIndexed { i, r ->
                when {
                    i == 0 -> b.addView(replyCard(i + 1, r, recommended = true))
                    expandedCandidates.contains(i) -> b.addView(
                        replyCard(i + 1, r, onCollapse = { toggleCandidate(i) })
                    )
                    else -> b.addView(collapsedReplyRow(i, r))
                }
            }
        } else {
            shown.forEachIndexed { i, r -> b.addView(replyCard(i + 1, r)) }
        }
        // Footer: status on the left. 旧 footer 右侧的「详情 / 再给 2 条 /
        // 换一组」pill 挂在 onMoreReplies/onRegenerate 上，随编排未移植。
        val footer = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(8), 0, 0)
        }
        val left = TextView(ctx).apply {
            textSize = 12f; setTextColor(Color.parseColor("#9CA3AF"))
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        left.text = "${shown.size} 条候选"
        footer.addView(left)
        b.addView(footer)
        if (keepScroll > 0) {
            b.post { bodyScroll?.let { s -> s.scrollTo(0, keepScroll.coerceAtMost(s.getChildAt(0)?.height ?: 0)) } }
        }
    }

    private fun replyCard(
        rank: Int,
        reply: Suggestion,
        recommended: Boolean = false,
        onCollapse: (() -> Unit)? = null,
    ): View {
        val pct = (reply.prob * 100).roundToInt()
        // 旧卡 top = rank == 1 && reply.ranked；Dart 推来的列表即排序结果，视为 ranked。
        val top = rank == 1
        val c = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            background = card(12, if (top) brandTint() else Color.parseColor("#F3F4F6"))
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
        c.addView(TextView(ctx).apply {
            // 旧卡的「推荐 · 」前缀：旧版挂在 judge 的 best_action 上，B8 主推
            // 模式下排序第一张即推荐（[recommended]），all 模式维持原样。
            this.text = buildString {
                if (recommended) append("推荐 · ")
                append("#").append(rank).append(" · ").append(pct).append("%")
                if (strategy.isNotBlank()) { append(" · "); append(strategy) }
            }
            setTextColor(brand()); textSize = 11f
            setTypeface(typeface, Typeface.BOLD)
        })
        c.addView(TextView(ctx).apply {
            this.text = reply.text; setTextColor(Color.parseColor("#111827")); textSize = 14f
            setPadding(0, dp(3), 0, dp(7)); setLineSpacing(dp(2).toFloat(), 1f)
            setTextIsSelectable(true)
        })
        val btns = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.END }
        // 旧卡还有「改短 / 换语气 / 重生成」三个精修按钮（onRefine → jev 起草），
        // 未移植。「填入/复制」改为把动作交回 Dart（见 [onOverlayAction]）。
        // B8 主推模式展开的备选卡带「收回」，保持折叠语义完整（与候选页一致）。
        onCollapse?.let { btns.addView(pill("收回", false) { it() }) }
        btns.addView(pill("复制", false) { onOverlayAction?.invoke("copy", rank - 1) })
        // Fill, then fold the card so the input box + keyboard are visible to
        // review/send. 这里本地立即折回（不等 Dart 回填结果），Dart 回填成功后
        // 再调一次 control 的 collapse（只收卡不撤窗）作协议级保证——两端统一
        // 为「填入后折回胶囊」，不再整窗移除（遗留 low 的语义统一结论）。
        btns.addView(pill("填入", true) {
            onOverlayAction?.invoke("refill", rank - 1)
            if (expanded) setExpanded(false)
        })
        c.addView(btns)
        return c
    }

    private fun pill(label: String, primary: Boolean, onClick: () -> Unit) = TextView(ctx).apply {
        text = label; textSize = 13f; gravity = Gravity.CENTER
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(if (primary) Color.WHITE else brand())
        background = card(18, if (primary) brand() else Color.parseColor("#FFFFFF"), stroke = !primary)
        setPadding(dp(16), dp(6), dp(16), dp(6))
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { leftMargin = dp(8) }
        setOnClickListener { onClick() }
    }

    /** B8 主推模式的备选行：两行小字 + 「展开」角标，点按展开成完整候选卡。 */
    private fun collapsedReplyRow(index: Int, reply: Suggestion): View {
        val row = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            background = card(10, Color.parseColor("#F3F4F6"))
            setPadding(dp(10), dp(6), dp(10), dp(6))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(6) }
        }
        row.addView(TextView(ctx).apply {
            text = reply.text
            setTextColor(Color.parseColor("#111827")); textSize = 13f
            maxLines = 2; ellipsize = TextUtils.TruncateAt.END
            layoutParams = LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
            )
        })
        row.addView(TextView(ctx).apply {
            text = "展开 ▾"; setTextColor(Color.parseColor("#6B7280")); textSize = 11f
            setPadding(dp(8), 0, 0, 0)
        })
        row.setOnClickListener { toggleCandidate(index) }
        return row
    }

    /** B8 备选行展开/收回的切换：换渲染重排，不挪窗口位置。 */
    private fun toggleCandidate(index: Int) {
        if (!expandedCandidates.remove(index)) expandedCandidates.add(index)
        render()
        updateLayout()
    }

    // --------------------------------------------------------------- helpers

    private fun line(text: String, color: String, size: Float, bold: Boolean = false) =
        TextView(ctx).apply {
            this.text = text; setTextColor(Color.parseColor(color)); textSize = size
            if (bold) setTypeface(typeface, Typeface.BOLD)
            setPadding(0, dp(2), 0, dp(2))
        }

    private fun hint(text: String) = line(text, "#9CA3AF", 12f)

    /** A ScrollView that wraps its content but never grows past [maxH]. */
    private class MaxHeightScroll(ctx: Context) : ScrollView(ctx) {
        var maxH = Int.MAX_VALUE
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            super.onMeasure(widthMeasureSpec, View.MeasureSpec.makeMeasureSpec(maxH, View.MeasureSpec.AT_MOST))
        }
    }

    companion object {
        // 旧仓库 core.Palette 的两个品牌色字面量（"#3A7AFE" 曾在四个文件八处
        // 出现，见旧 Palette 注释）。插件不引 UI core，就地收拢成常量。
        private const val BRAND = "#3A7AFE"
        private const val BRAND_TINT = "#EAF1FF"

        /** B8 展示模式取值：主推一张大卡（与 Dart 侧 SettingsStore 常量镜像）。 */
        private const val MODE_PRIMARY = "primary"

        private fun brand(): Int = Color.parseColor(BRAND)
        private fun brandTint(): Int = Color.parseColor(BRAND_TINT)
    }
}

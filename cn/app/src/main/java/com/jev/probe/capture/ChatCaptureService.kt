package com.jev.probe.capture

import android.accessibilityservice.AccessibilityService
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.jev.probe.capture.ocr.MlKitOcr
import com.jev.probe.capture.ocr.OcrLine
import com.jev.probe.capture.ocr.ScreenCapture
import com.jev.probe.core.BubbleRect
import com.jev.probe.bridge.SnapshotDiff
import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Intensity
import com.jev.probe.core.Msg
import com.jev.probe.core.Prefs
import com.jev.probe.core.Provenance
import com.jev.probe.core.Trace
import com.jev.probe.core.kb.ContextBuilder
import com.jev.probe.core.kb.KbStore
import com.jev.probe.jev.ReplyPrompt
import com.jev.probe.core.safety.SafetyBlockedException
import com.jev.probe.jev.HttpScope
import com.jev.probe.jev.JevClient
import com.jev.probe.overlay.OverlayController
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * The live capture service. It reads whichever
 * adapted chat app is in the foreground, detects a new incoming message from the
 * other person, runs Jev analysis off the main thread, and drives the floating
 * overlay.
 *
 * Per-app node rules live in [ChatAppAdapter] implementations; everything here
 * is app-agnostic.
 *
 * It never sends a message. The only write action is ACTION_SET_TEXT (or a
 * clipboard PASTE fallback) to fill the chat input box when the user taps
 * "填入"; the user still presses send.
 */
open class ChatCaptureService : AccessibilityService() {

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newFixedThreadPool(2)

    /** Judge/reply HTTP runs here under a hard watchdog (see [withHardTimeout]).
     *  Cached, so a straggler that outlives its round cannot starve the next one:
     *  the watchdog cancels its socket, but the pool never has to wait for it. */
    private val analysisPool = Executors.newCachedThreadPool { r ->
        Thread(r, "jev-http").apply { isDaemon = true }
    }

    /**
     * Run [body] on [analysisPool] but never wait longer than [ms], then abandon
     * the attempt: its [HttpScope] is cancelled first so the socket is really
     * closed, and only then is the thread interrupted.
     *
     * Why both: `Future.cancel(true)` only sets an interrupt flag, which a thread
     * parked in a socket read never sees — the request kept holding a connection
     * (and the caller's quota) until the read timeout, so an abandoned round
     * stayed parked on the pool while the round's [analyzing] flag was cleared.
     * Cancel-then-interrupt tears the connection down *and* stops any remaining
     * backoff sleep. Past the ceiling the caller surfaces a plain, retryable
     * error instead of waiting on a request that is already lost.
     *
     * Each guarded call gets its OWN scope: a judge timeout must not take the
     * concurrently running draft down with it.
     *
     * The ceiling is [Prefs.requestTimeoutSeconds] (default 30s), deliberately
     * shorter than [HttpJson]'s own worst retry tail (3 attempts × 40s read plus
     * backoff ≈ 123s): past the ceiling the user would rather see "生成超时" with
     * a retry than keep waiting on a request whose result is already late.
     */
    private fun <T> withHardTimeout(ms: Long, what: String, body: (HttpScope) -> T): T {
        val scope = HttpScope()
        liveScopes.add(scope)
        val f = analysisPool.submit(Callable { body(scope) })
        return try {
            f.get(ms, TimeUnit.MILLISECONDS)
        } catch (e: TimeoutException) {
            scope.cancel()
            f.cancel(true)
            throw java.io.IOException("$what 超时（${ms / 1000}秒），请检查网络后重试")
        } finally {
            liveScopes.remove(scope)
        }
    }

    /** Adapted chat apps, keyed by package name. Apps in [BLOCKED_PKGS] are
     *  never read at all (see [maybeCapture] / [onAccessibilityEvent]). */
    private val adapters = listOf(QQAdapter(), TimAdapter(), XAdapter(), FeishuAdapter(), WhatsAppAdapter(), TelegramAdapter()).associateBy { it.pkg }

    /**
     * 能力阶梯 L1。**可选**：没装框架、没开开关、模块没跑，它一律返回 null，
     * 采集路径就还是今天这条无障碍路径。单独成字段是为了单测能换掉它的数据源。
     */
    private val injection = InjectionSource()

    /** Submit to the worker, ignoring rejection after the service is torn down
     *  (a stale overlay callback must never crash the process). */
    private fun submit(task: () -> Unit) {
        try { worker.execute(task) } catch (_: RejectedExecutionException) { }
    }
    private lateinit var prefs: Prefs
    private var overlay: OverlayController? = null

    private var lastSignature: String = ""
    private var activePkg: String? = null
    private var analyzing = false
    /** A "换一组" redraft is in flight (candidates only; the judgment stays). */
    private var regenerating = false
    private val session = ConversationSession()
    /** Tells new incoming messages apart from scrolling through history. */
    private val gate = NewMessageGate()

    /** 最近几轮展示过的候选，喂给每轮起草的 avoid —— 跨轮反重复。 */
    private val recentReplies = RecentReplies()

    /** 分析卡上的推进档位（自动/收着/自然/加码），随会话切换重置。 */
    private var lastIntensity = Intensity.AUTO
    /** The snapshot and knowledge context of the last analysis, reused by "换一组". */
    private var lastAnalyzed: ChatSnapshot? = null
    private var lastCtx: com.jev.probe.core.kb.ChatContext? = null
    /** The judgment that belongs to [lastAnalyzed]; reused by "换一组" so a redraft keeps the register. */
    private var lastJudgment: com.jev.probe.core.Analysis? = null
    /** Last target whose adapter read real bubbles; an empty read after it is suspect. */
    private var lastNonEmptyTarget: ConversationSession.Target? = null
    /** When the current target first read empty (see the OCR gate in [maybeCapture]). */
    private var emptySinceTarget: ConversationSession.Target? = null
    private var emptySinceAt = 0L
    private val analysisTasks = ArrayList<Future<*>>()

    /**
     * The [HttpScope] of every HTTP call currently in flight. Interrupting a
     * thread does not close its socket, so dropping a round has to cancel these
     * too or the abandoned request keeps a connection until its read timeout.
     * Concurrent because a worker registers a scope while the main thread may be
     * cancelling the round.
     */
    private val liveScopes = java.util.concurrent.ConcurrentHashMap.newKeySet<HttpScope>()
    private var destroyed = false
    private val preferencesListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == "enabled" || key == "whitelist") {
            main.post {
                leaveConversation()
                overlay?.hide()
            }
        }
    }

    /** Invalidate callbacks before cancelling workers; interruption alone is not a guard. */
    private fun cancelAnalysis() {
        session.invalidate()
        main.removeCallbacks(debounce)
        pendingSnapshot = null
        analyzing = false
        regenerating = false
        cancelScopes()
        analysisTasks.forEach { it.cancel(true) }
        analysisTasks.clear()
        overlay?.resetForNewConversation()
    }

    /** Drop the round in flight (its result would be stale) but keep what the card shows. */
    private fun cancelInFlight() {
        session.invalidate()
        main.removeCallbacks(debounce)
        analyzing = false
        regenerating = false
        cancelScopes()
        analysisTasks.forEach { it.cancel(true) }
        analysisTasks.clear()
    }

    /** Close the sockets of every in-flight HTTP call of the round being dropped. */
    private fun cancelScopes() {
        liveScopes.forEach { it.cancel() }
        liveScopes.clear()
    }

    private fun observeTarget(target: ConversationSession.Target?) {
        if (session.observe(target)) {
            cancelAnalysis()
            currentSnapshot = null
            activePkg = null
            lastSignature = ""
            lastOcrSignature = ""
            gate.reset()
            lastAnalyzed = null
            lastCtx = null
            lastJudgment = null
            recentReplies.clear()
            lastIntensity = Intensity.AUTO
            overlay?.setIntensity(Intensity.AUTO)
        }
    }

    private fun leaveConversation() {
        observeTarget(null)
        cancelAnalysis()
        currentSnapshot = null
        weChatTitle = WeChatTitleState()
        emptySinceTarget = null
    }

    /** Read the live target, never the previous chat's cached/stabilized title. */
    private fun targetFor(root: AccessibilityNodeInfo): ConversationSession.Target? {
        val pkg = root.packageName?.toString() ?: return null
        if (isBlocked(pkg) || pkg == packageName || pkg == "com.android.systemui" ||
            pkg.contains("launcher", true) || pkg == "com.miui.home") return null
        val adapter = adapters[pkg]
        var messagesSignature: String? = null
        val title = if (adapter != null) {
            val snapshot = adapter.extract(root, resources) ?: return null
            messagesSignature = snapshot.takeIf { it.messages.isNotEmpty() }?.signature()
            // A loading/unknown title cannot prove which conversation is open —
            // unless the SAME app+window already has a known one: animated
            // headers swap in skeleton/transient titles for a beat (#68), and
            // unbinding the session there killed in-flight analyses. Keep the
            // previously verified title instead.
            val fresh = snapshot.title?.takeUnless { isTransientTitle(it) }
            if (fresh != null) fresh
            else {
                val known = session.target
                if (known != null && known.pkg == pkg && known.windowId == root.windowId &&
                    !known.title.isNullOrBlank()) known.title else return null
            }
        } else if (pkg == WECHAT_PKG) {
            // WeChat gives no node tree at all (1 empty node), so there is no
            // title to find: the OCR pass reads it off the top band and stores it
            // here. It has to be STICKY — the session identity is app + window +
            // title, so answering null between two reads would make every single
            // capture invalidate itself the moment it finished.
            weChatTitle.titleForWindow(root.windowId)
        } else {
            findTitleInActionBar(root, Int.MAX_VALUE, resources.displayMetrics.widthPixels,
                resources, 0.15, 0.85)
        }
        return ConversationSession.Target(pkg, root.windowId, title, messagesSignature)
    }

    private fun isCurrent(token: ConversationSession.Token): Boolean {
        if (destroyed || !prefs.enabled || !session.accepts(token)) return false
        val live = rootInActiveWindow?.let { targetFor(it) }
        // A null re-extract is a transient accessibility glitch (list animation,
        // node cache miss), NOT proof the chat was left — hiding there killed
        // freshly rendered candidates (seen on QQ). Identity checks apply
        // only when we actually got a reading.
        if (live != null && (!live.sameConversation(token.target) ||
            !prefs.isAllowed(currentSnapshot?.title ?: live.title))) {
            leaveConversation()
            overlay?.hide()
            return false
        }
        return true
    }

    /** Only called on the main thread, including the context-completion callback. */
    private fun submitAnalysis(task: () -> Unit) {
        try { analysisTasks.add(worker.submit(task)) } catch (_: RejectedExecutionException) { }
    }

    private val debounce = Runnable { runAnalysis() }
    private var pendingSnapshot: ChatSnapshot? = null

    /**
     * #18: WINDOW_STATE_CHANGED blips — the notification shade, a permission
     * dialog, a split-screen handle — are transient, but the drop branch below
     * used to tear the bubble down the instant one arrived, and an open panel
     * was lost mid-read. Hide only if the screen is STILL a drop-zone after a
     * short grace period; any chat-app event in between cancels the hide.
     */
    private val confirmAwayHide = Runnable {
        val fg = rootInActiveWindow?.packageName?.toString()
        val stillAway = fg == null || fg == packageName ||
            fg.contains("launcher", ignoreCase = true) ||
            fg == "com.miui.home" || fg == "com.android.systemui"
        if (stillAway) overlay?.hide()
    }
    @Volatile private var currentSnapshot: ChatSnapshot? = null
    private var foregroundPkg: String? = null

    // ---- OCR path (B stage). Everything here runs on the main thread: the
    // screenshot callback and the ML Kit callback are both posted back to it.
    private val screenCapture by lazy {
        ScreenCapture(this,
            hideOverlay = { overlay?.setHiddenForShot(true) },
            restoreOverlay = { overlay?.setHiddenForShot(false) })
    }
    private val ocr = MlKitOcr()
    private var ocrBusy = false

    /** What the screen looked like the last time we fired an automatic shot.
     *  See [ocrSignature]: this is the brake on the OCR path. */
    private var lastOcrSignature: String = ""

    /** Time of the last automatic WeChat shot — WeChat has no tree signature to
     *  dedupe on before the picture, so its brake is time-based. */
    private var lastWeChatShotAt = 0L

    /** Chat title OCR read off WeChat's top band. WeChat exposes no nodes, so this
     *  is the only source of a conversation title — and [targetFor] must keep
     *  serving it back or the session would invalidate itself on every capture.
     *  The stability rule lives in [WeChatTitleState], where it is unit tested. */
    private var weChatTitle = WeChatTitleState()

    /** Last package written to [Trace], so foreground churn does not spam it. */
    private var lastTraceForeground: String? = null
    private var lastTraceSig: String? = null

    /** Whether the "not supported" notice has been shown for the current visit
     *  to a blocked app. Reset whenever another foreground is seen, so it
     *  re-appears next visit but does not re-pop on every event. */
    private var blockedNoticeShown = false

    override fun onServiceConnected() {
        super.onServiceConnected()
        live = true
        prefs = Prefs(this)
        getSharedPreferences(Prefs.PREFS_MAIN, MODE_PRIVATE)
            .registerOnSharedPreferenceChangeListener(preferencesListener)
        overlay = OverlayController(this)
        overlay?.onManualAnalyze = {
            currentSnapshot?.let { pendingSnapshot = it; runAnalysis() }
        }
        overlay?.onRegenerate = { regenerateReplies() }
        overlay?.onMoreReplies = { moreReplies() }
        overlay?.onOpenSettings = {
            startActivity(android.content.Intent(this, com.jev.probe.SettingsActivity::class.java).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        overlay?.onRefine = { original, instruction -> refineReply(original, instruction) }
        // 推进档位：卡片上改档只改下一轮起草（想立刻见效点「换一组」）；
        // 服务持有权威状态，卡片只是显示它的镜像。
        overlay?.onIntensity = { lastIntensity = it }
        overlay?.setIntensity(lastIntensity)
        // Bubble menu: file the open conversation as a knowledge-base contact.
        // Contacts are never created automatically — this is the one-tap way in.
        overlay?.onSaveContact = {
            val title = currentSnapshot?.title
            val pkg = activePkg ?: foregroundPkg ?: ""
            when {
                title.isNullOrBlank() -> overlay?.toast("当前会话没有标题，存不了")
                isTransientTitle(title) -> overlay?.toast("当前会话标题还没加载出来，稍后再试")
                else -> submit {
                    val msg = try {
                        KbStore.get(this).saveOrMergeContact(title, pkg)
                    } catch (e: Exception) { "保存失败：${e.javaClass.simpleName}" }
                    main.post { overlay?.toast(msg) }
                }
            }
        }
        // Bubble menu: one manual screenshot + OCR, for any app at all.
        overlay?.onOcrCapture = { ocrCaptureManual() }
        // Card menu: stop (or resume) automatic analysis for just this app. One
        // noisy or sensitive chat leaves autopilot without turning the whole
        // assistant off — manual analysis still works.
        overlay?.onToggleAppAuto = { toggleAppAuto() }
        // Keep the process at foreground importance so MIUI does not freeze us.
        runCatching { KeepAliveService.start(this) }
        // Load the bundled OCR model now, off the main thread: the first
        // recognize() otherwise pays for it inside the screenshot callback.
        submit { MlKitOcr.warmUp() }
        // HyperOS may kill and restart us. On (re)connect, proactively re-show the
        // bubble for whatever chat is already open, so it comes back on its own
        // instead of waiting for the user to scroll.
        main.postDelayed({ if (prefs.enabled) runCatching { maybeCapture() } }, 900)
        Trace.init(applicationContext)
        Trace.log("connected enabled=${prefs.enabled} key=${prefs.hasKey()} ocrFallback=${prefs.ocrFallback}")
        Log.i(TAG, "capture service connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        if (!prefs.enabled) { leaveConversation(); overlay?.hide(); return }

        val type = event.eventType
        // #18-4: our own overlay redraws ("generating…" → judgment → candidates)
        // emit WINDOW_CONTENT_CHANGED / VIEW_SCROLLED carrying our package name.
        // Reacting to them woke the service in a loop: re-read → re-analyze →
        // redraw → …, which pinned the panel on "generating" forever. Window-state
        // events keep flowing: the fg == packageName branch above still hides the
        // bubble inside our own settings screens.
        if (event.packageName?.toString() == packageName &&
            (type == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED ||
             type == AccessibilityEvent.TYPE_VIEW_SCROLLED)) return
        // Decide "did we leave the chat app" from the REAL active window, not the
        // event's package. The event package can be an IME (e.g. com.tencent.wetype)
        // or the status bar while the chat app is still foreground — keying off it
        // made the bubble flicker (hide → re-show → hide…). rootInActiveWindow stays
        // on the chat app while the keyboard is up, so this is stable.
        //
        // An app with no adapter is NOT a reason to take the bubble away: the only
        // way into DingTalk / Telegram / anything else is the bubble menu's
        // "截屏识别一次", and a bubble that is gone cannot be tapped. So we park
        // the idle bubble there instead — still no automatic capture, no analysis.
        // The bubble does come off for places where it would only be in the way:
        // our own settings screens, the launcher, and the system UI.
        if (type == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            val fgTrace = rootInActiveWindow?.packageName?.toString()
            if (fgTrace != lastTraceForeground) {
                lastTraceForeground = fgTrace
                Trace.log("fg=$fgTrace")
            }
        }
        if (type == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            val fg = rootInActiveWindow?.packageName?.toString()
            // Blocked apps: never read/screenshot/OCR/fill there, only show the
            // one-time "not supported" notice and stop. Checked before the
            // generic no-adapter branch.
            if (isBlocked(fg)) { foregroundPkg = fg; showBlocked(auto = true); return }
            // WeChat has no adapter either, but unlike every other unadapted app it
            // HAS its own capture path ([maybeCaptureWeChat]). Letting it fall into
            // this branch meant every window-state change called showIdle(null),
            // which switches the overlay to BUBBLE mode and tears the card down —
            // the "悬浮显示的内容一会出现一会没有" flicker.
            if (ForegroundPolicy.needsIdlePark(fg, adapters.keys, WECHAT_PKG)) {
                val target = rootInActiveWindow?.let { targetFor(it) }
                if (session.target != target) leaveConversation()
                foregroundPkg = fg!!
                blockedNoticeShown = false // left a blocked app → allow the notice again next visit
                val drop = ForegroundPolicy.shouldHide(fg, packageName)
                if (drop) {
                    // Grace period instead of an instant tear-down (see [confirmAwayHide]).
                    main.removeCallbacks(confirmAwayHide)
                    main.postDelayed(confirmAwayHide, FOREGROUND_CONFIRM_MS)
                } else {
                    main.removeCallbacks(confirmAwayHide)
                    // showIdle(null) means BUBBLE, and setMode rebuilds the window
                    // from scratch, so calling it while a card is up for this same
                    // app is exactly the flicker. Only re-park when there is
                    // nothing on screen, or when the card belongs to another app.
                    if (ForegroundPolicy.shouldRepark(fg, overlay?.isShowing() == true, overlay?.currentApp())) {
                        overlay?.showIdle(null)
                    }
                }
                return
            }
        }

        when (type) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_VIEW_SCROLLED -> maybeCapture()
        }
    }

    private fun maybeCapture() {
        // The chat app is back (or never left): a pending hide confirmation is moot.
        main.removeCallbacks(confirmAwayHide)
        val root = rootInActiveWindow ?: run { leaveConversation(); overlay?.hide(); return }
        val pkg = root.packageName?.toString()
        // Blocked apps — no tree read, no screenshot, no OCR, no fill. A
        // content-changed / scrolled event there only re-shows the one-time
        // notice (deduped); it must never reach an adapter or the OCR path.
        if (isBlocked(pkg)) { showBlocked(auto = true); return }
        blockedNoticeShown = false // any other foreground → allow the notice again next visit
        // WeChat: no adapter, because its tree is empty. Screenshots are readable,
        // so it runs on the pixel path instead of the "menu only" path every
        // other unadapted app gets.
        if (pkg == WECHAT_PKG) { maybeCaptureWeChat(root, manual = false); return }
        // Apps with no adapter are never handled automatically (v1.3 revision):
        // the only way in for them is the bubble menu's "截屏识别一次".
        val adapter = adapters[pkg] ?: run {
            if (session.target != null && session.target != targetFor(root)) leaveConversation()
            return
        }
        // Outside a chat window (the conversation list, a profile, settings…) the
        // adapter returns null. That is NOT a reason to show nothing: an adapted
        // app must behave at least as well as an unadapted one, which parks an idle
        // bubble so the menu stays reachable. Without this, opening QQ / Feishu on
        // their list screen produced no bubble at all.
        // 能力阶梯：注入层（L1，可选、默认关）先试，取不到就落回无障碍（L0）。
        // InjectionSource 在没装框架/没开开关/数据过期/payload 坏了的时候全部返回
        // null，所以这一行不改变任何人的现有行为 —— 但它是「注入层可选」这句
        // 话在代码里的落点。降级原因由 InjectionSource 自己写 Trace。
        val injected = injection.snapshot(pkg, prefs.injectionEnabled(pkg))
        val rawSnapshot = injected ?: adapter.extract(root, resources)
        Trace.log("cap pkg=$pkg adapter=${adapter.pkg} " +
            "provenance=${injected?.provenance ?: Provenance.A11Y} snapshot=" +
            (rawSnapshot?.let { "msgs=${it.messages.size} me=${it.messages.count { m -> m.side == "me" }} " +
                "other=${it.messages.count { m -> m.side != "me" }} titleLen=${it.title?.length ?: -1}" }
                ?: "null"))
        // 对拍（诊断，默认关）：注入层确实拿到了东西时，再读一遍无障碍，把两层的
        // 差别写一行。这是 S3「L0 vs L1 逐条对拍」的验收证据，只多读一遍节点树，
        // 不额外调用模型。日志里只有条数和错位位置，没有聊天内容。
        if (injected != null && prefs.compareSources()) {
            val a11y = runCatching { adapter.extract(root, resources) }.getOrNull()
            Trace.log("cmp pkg=$pkg " + (a11y?.let { SnapshotDiff.describe(it, injected) } ?: "l0=unavailable"))
        }
        if (rawSnapshot == null) { scheduleLeave(); return }
        val target = targetFor(root)
        if (target == null) { scheduleLeave(); return }
        main.removeCallbacks(confirmLeave)
        observeTarget(target)
        overlay?.setApp(pkg)
        // Use only this window's title; never inherit another conversation's title.
        val snapshot = rawSnapshot
        if (!prefs.isAllowed(snapshot.title)) { leaveConversation(); overlay?.hide(); return }
        // In a chat window but the tree holds no text (Feishu draws its bodies)
        // → screenshot + OCR, subject
        // to ScreenCapture's own >=1s throttle and failure backoff.
        if (snapshot.messages.isEmpty()) {
            // In a chat window, but the tree carries no text (Feishu draws its
            // message bodies). Park the bubble BEFORE attempting OCR, so the user
            // still has something to tap when OCR is off, deduped, or comes back
            // empty — previously all three cases left the screen with no bubble.
            if (overlay?.isShowing() != true) overlay?.showIdle(snapshot.title)
            // An adapter that has been reading bubbles can still read ZERO for a
            // frame while a RecyclerView re-lays out or the IME animates (TIM:
            // msgs=8 → msgs=0 → snapshot=null within 300ms). A screenshot taken
            // then invents a conversation out of whatever happens to be on screen,
            // sides and all. So on an app that HAS been reading, the empty state
            // must persist before OCR runs; an app whose tree never carries text
            // (Feishu) has no such history and still goes straight to OCR.
            val now = SystemClock.uptimeMillis()
            if (emptySinceTarget != target) { emptySinceTarget = target; emptySinceAt = now }
            if (lastNonEmptyTarget == target && now - emptySinceAt < EMPTY_READ_GRACE_MS) {
                Trace.log("cap empty read held ${now - emptySinceAt}ms on $pkg")
                return
            }
            if (prefs.ocrFallback && pkg !in NO_SCREENSHOT_PKGS) {
                // Gate BEFORE the shot, not after the OCR. Feishu's tree is empty
                // on every content-changed event, and a successful shot resets the
                // failure backoff — so without this the caret blinking or an
                // "online" badge flipping keeps a screenshot going out every
                // second forever. The picture can only differ if the bubbles moved
                // or the conversation changed, and that is exactly what the
                // signature measures.
                val sig = ocrSignature(pkg ?: "", snapshot.title, snapshot.bubbleRects)
                if (sig == lastOcrSignature && overlay?.isShowing() == true) return
                if (ocrBusy) return
                lastOcrSignature = sig
                ocrCapture(snapshot.title, snapshot.bubbleRects, pkg ?: "", manual = false)
            }
            return
        }

        // Switching to another adapted app resets the dedupe signature, so two apps
        // whose last few messages happen to match cannot swallow each other.
        if (pkg != activePkg) { activePkg = pkg; lastSignature = "" }
        // This app's tree reads fine: an empty read from here on is suspect (see
        // the OCR gate above).
        lastNonEmptyTarget = target
        emptySinceTarget = null

        currentSnapshot = snapshot
        val sig = snapshot.signature()
        val showing = overlay?.isShowing() == true
        // Same content and the card is already up → nothing to do.
        if (sig == lastSignature && showing) {
            if (sig != lastTraceSig) { lastTraceSig = sig; Trace.log("dec sameSigCardUp") }
            return
        }
        lastSignature = sig
        val verdict = gate.observe(snapshot.messages)
        Trace.log("dec verdict=$verdict latest=${snapshot.latestFrom} auto=${prefs.autoAnalyzeFor(pkg)} " +
            "latestTextLen=${snapshot.messages.lastOrNull()?.text?.length ?: -1}")
        // Scrolling through history changes what is on screen but brings nothing
        // new: keep the card exactly as it is (no clearing, no re-analysis). The
        // same goes for the user's own new message. Only a first look at a chat or
        // a new incoming message goes on to analysis.
        when (verdict) {
            NewMessageGate.Verdict.NOTHING_NEW, NewMessageGate.Verdict.NEW_FROM_ME -> {
                overlay?.showIdle(snapshot.title); return
            }
            NewMessageGate.Verdict.FIRST_LOOK, NewMessageGate.Verdict.NEW_FROM_OTHER -> Unit
        }
        Log.d(TAG, "snapshot[$pkg] title=${snapshot.title} n=${snapshot.messages.size} " +
            snapshot.messages.takeLast(6).joinToString(" | ") { "${it.side}:${it.text.length}" }) // sides + lengths only, never content
        Trace.log("sides " + snapshot.messages.takeLast(10)
            .joinToString(",") { "${it.side}:${it.text.length}" })

        // Trigger only when the newest message is from the other person, and only
        // if auto-analyze is on. Otherwise show the idle bubble (tap to analyze).
        if (snapshot.latestFrom != "other" || !prefs.autoAnalyzeFor(pkg)) {
            overlay?.showIdle(snapshot.title); return
        }

        // A newer message makes any round in flight stale; the card keeps showing
        // the previous result until the new one lands.
        cancelInFlight()
        pendingSnapshot = snapshot
        main.removeCallbacks(debounce)
        main.postDelayed(debounce, 800) // debounce bursts of content-changed events
    }

    /**
     * A chat app's tree can briefly read as "not a chat" while its list re-lays
     * out (QQ while scrolling). Leave the conversation only if it still reads
     * that way after a short grace period; any good read in between cancels it.
     */
    private val confirmLeave = Runnable {
        val root = rootInActiveWindow
        val adapter = root?.packageName?.toString()?.let { adapters[it] }
        val gone = root == null || adapter == null ||
            adapter.extract(root, resources) == null || targetFor(root) == null
        if (gone) { leaveConversation(); overlay?.showIdle(null) }
    }

    private fun scheduleLeave() {
        if (session.target == null) { leaveConversation(); overlay?.showIdle(null); return }
        main.removeCallbacks(confirmLeave)
        main.postDelayed(confirmLeave, LEAVE_CONFIRM_MS)
    }

    /** "换一组" / 重试: redraft the candidates only; the judgment on the card stays. */
    private fun refineReply(original: String, instruction: String) {
        if (analyzing || regenerating || destroyed || !prefs.enabled) return
        val snapshot = lastAnalyzed ?: currentSnapshot ?: return
        val token = session.token() ?: return
        if (!isCurrent(token)) return
        if (!prefs.hasKey()) { overlay?.showError("未设置回复接口密钥，去设置里填"); return }

        regenerating = true
        val client = JevClient(prefs)
        overlay?.beginRegenerate()
        submitAnalysis {
            val refined = try {
                withHardTimeout(prefs.requestTimeoutSeconds * 1000L, "单条微调") { sc ->
                    client.refineReply(snapshot, prefs.relationship, lastCtx, original, instruction, sc)
                }
            } catch (e: Exception) {
                Log.w(TAG, "single refine failed: " + e.message)
                null
            }
            main.post {
                regenerating = false
                if (!isCurrent(token)) return@post
                if (refined != null) {
                    recentReplies.remember(listOf(refined.text))
                    overlay?.replaceReply(original, refined)
                } else {
                    overlay?.toast("单条微调失败，已保留原回复")
                    overlay?.showError("单条微调失败，原回复已保留")
                }
            }
        }
    }

    /**
     * "再给 2 条": draft two more candidates and append them, keeping the ones the
     * user can already see. Deliberately *not* ranked — [JevClient.rankOnly] only
     * ranks an exact set of three, so a top-up would either re-rank from scratch
     * (changing numbers the user is reading) or lie about the order.
     */
    private fun moreReplies() {
        if (analyzing || regenerating || destroyed || !prefs.enabled) return
        val snapshot = lastAnalyzed ?: currentSnapshot ?: return
        val token = session.token() ?: return
        if (!isCurrent(token)) return
        if (!prefs.hasKey()) { overlay?.showError("未设置判断接口密钥，去设置里填"); return }
        regenerating = true
        val avoid = (overlay?.currentReplyTexts().orEmpty() + recentReplies.asAvoid()).distinct()
        overlay?.beginMore()
        val client = JevClient(prefs)
        val rel = prefs.relationship
        val ctx = lastCtx
        submitAnalysis {
            var err: String? = null
            val fresh = try {
                withHardTimeout(prefs.requestTimeoutSeconds * 1000L, "回复接口") { sc ->
                    client.draftOnly(snapshot, rel, ctx, count = 2, avoid = avoid,
                        intensity = lastIntensity, scope = sc)
                }
            } catch (e: Exception) {
                err = replyErrorText(e)
                Log.w(TAG, "top-up draft failed: $err")
                emptyList()
            }
            main.post {
                regenerating = false
                if (!isCurrent(token)) return@post
                if (fresh.isEmpty()) {
                    overlay?.endMoreWaiting()
                    overlay?.toast(err?.let { "没能再加两条：$it" } ?: "没能再加两条，原候选已保留")
                } else {
                    recentReplies.remember(fresh.map { it.text })
                    overlay?.appendReplies(fresh) { text -> fillInput(token, text) }
                }
            }
        }
    }

    private fun regenerateReplies() {
        if (analyzing || regenerating || destroyed || !prefs.enabled) return
        val snapshot = lastAnalyzed ?: currentSnapshot ?: return
        val token = session.token() ?: return
        if (!isCurrent(token)) return
        if (!prefs.hasKey()) { overlay?.showError("未设置判断接口密钥，去设置里填"); return }
        regenerating = true
        val avoid = (overlay?.currentReplyTexts().orEmpty() + recentReplies.asAvoid()).distinct()
        overlay?.beginRegenerate()
        val client = JevClient(prefs)
        val rel = prefs.relationship
        val ctx = lastCtx
        val count = prefs.candidateCount
        submitAnalysis {
            var replyError: String? = null
            val ranked = try {
                withHardTimeout(prefs.requestTimeoutSeconds * 1000L, "回复接口") { sc ->
                    client.draftAndRank(snapshot, rel, ctx, count, avoid, lastJudgment,
                        intensity = lastIntensity, scope = sc)
                }
            } catch (e: Exception) {
                replyError = replyErrorText(e)
                Log.w(TAG, "redraft failed: $replyError")
                emptyList()
            }
            main.post {
                regenerating = false
                if (isCurrent(token)) {
                    recentReplies.remember(ranked.map { it.text })
                    overlay?.showReplies(ranked, replyError) { text -> fillInput(token, text) }
                }
            }
        }
    }

    private fun replyErrorText(e: Exception): String {
        val api = e as? com.jev.probe.jev.ApiException
        return when {
            api?.status == 401 || api?.status == 403 -> "密钥可能无效，去检查"
            api?.status == 429 -> "服务商限流，稍后重试"
            e is TimeoutException || e.message?.contains("超时") == true -> "请求超时，点重试"
            else -> e.message ?: e.javaClass.simpleName
        }
    }

    private fun isBlocked(pkg: String?): Boolean = pkg != null && pkg in BLOCKED_PKGS

    /**
     * Foreground is a blocked app: no node-tree read, no screenshot, no OCR, no
     * fill. We only surface a one-time "not supported" notice. [auto] events
     * (accessibility callbacks) show it once per visit — [blockedNoticeShown]
     * dedupes them; a manual bubble tap ([auto] = false) always shows it. Never
     * gated by the user's whitelist (it is an info notice, not a read).
     */
    private fun showBlocked(auto: Boolean) {
        leaveConversation()
        if (auto && blockedNoticeShown) return
        blockedNoticeShown = true
        // No popup panel there — take the overlay off entirely and show the
        // reason once as a small transient toast.
        overlay?.hide()
        overlay?.toast(BLOCKED_MSG)
    }

    /** A placeholder title an app shows only for a moment (e.g. X's "连接中…"
     *  right after opening a DM thread) — never a real conversation title.
     *  Blank/null counts too, so a caller can always fall back the same way. */
    private fun isTransientTitle(t: String?): Boolean {
        val trimmed = t?.trim()?.removeSuffix("…")?.removeSuffix("...")?.trim()
        if (trimmed.isNullOrEmpty()) return true
        val lower = trimmed.lowercase()
        return TRANSIENT_TITLE_WORDS.any { lower.contains(it.lowercase()) }
    }

    private fun runAnalysis() {
        val snapshot = pendingSnapshot ?: return
        if (analyzing || destroyed || !prefs.enabled) {
            if (analyzing) Log.w(TAG, "round skipped: previous round still in flight")
            Trace.log("analyze skip busy=" + analyzing + " destroyed=" + destroyed + " enabled=" + prefs.enabled)
            return
        }
        val previous = session.token() ?: return
        if (!isCurrent(previous)) return
        if (!prefs.hasKey()) { overlay?.showError("未设置判断接口密钥，去设置里填"); return }

        val token = session.begin() ?: return
        analyzing = true
        overlay?.beginRound()
        overlay?.setNote(snapshot.note)
        val count = prefs.candidateCount
        val client = JevClient(prefs)
        val rel = prefs.relationship

        submitAnalysis {
            val ctx = try {
                ContextBuilder.build(this, snapshot, token.target.pkg, prefs,
                    ReplyPrompt.judgmentWords(lastJudgment))
            } catch (e: Exception) {
                Log.w(TAG, "context build failed: " + e.javaClass.simpleName)
                null
            }
            main.post {
                if (!isCurrent(token)) return@post
                lastAnalyzed = snapshot
                lastCtx = ctx
                overlay?.setContextInfo(ctx?.notes?.size ?: 0, ctx?.history?.size ?: 0)
                // 记忆链路没激活时在卡上直说——这是「AI 分不清上下文」时用户
                // 唯一能看到的解释，也是一键可修的（长按存联系人）。
                overlay?.setMemoryHint(
                    when {
                        ctx?.contact != null -> null
                        prefs.contextEnabled -> "记忆未启用：长按悬浮卡「把当前会话存为联系人」，助手才能带上这之前的记录"
                        else -> "记忆未开启：设置页打开「记录聊天历史」并长按悬浮卡存联系人"
                    })

                val round = object {
                    var judgment: com.jev.probe.core.Analysis? = null
                    var draft: List<com.jev.probe.core.RankedReply>? = null
                    var judgeFinished = false
                    var draftFinished = false
                    var rankStarted = false
                }

                fun finishRoundIfReady() {
                    if (!round.judgeFinished || !round.draftFinished || round.rankStarted) return
                    val j = round.judgment
                    val d = round.draft.orEmpty()
                    if (j != null && j.error == null && d.size == 3) {
                        round.rankStarted = true
                        submitAnalysis {
                            val ranked = try {
                                withHardTimeout(prefs.requestTimeoutSeconds * 1000L, "回复排序") { sc ->
                                    client.rankOnly(snapshot, rel, ctx, d, sc)
                                }
                            } catch (e: Exception) {
                                Log.w(TAG, "rank failed: " + e.message)
                                d.map { it.copy(ranked = false, prob = 0.0) }
                            }
                            main.post {
                                if (!isCurrent(token)) return@post
                                lastJudgment = j
                                recentReplies.remember(ranked.map { it.text })
                                overlay?.showReplies(ranked, null) { text -> fillInput(token, text) }
                                analyzing = false
                                analysisTasks.clear()
                            }
                        }
                    } else {
                        if (j != null) lastJudgment = j.takeIf { it.error == null }
                        val error = when {
                            d.isEmpty() -> if (j?.error != null) "判断接口失败；回复也未生成，请重试" else "回复接口未生成候选"
                            j?.error != null -> "判断接口失败，候选未经排序"
                            else -> null
                        }
                        recentReplies.remember(d.map { it.text })
                        overlay?.showReplies(d, error) { text -> fillInput(token, text) }
                        analyzing = false
                        analysisTasks.clear()
                    }
                }

                submitAnalysis {
                    val judgment = try {
                        withHardTimeout(prefs.requestTimeoutSeconds * 1000L, "判断接口") { sc -> client.judge(snapshot, rel, ctx, sc) }
                    } catch (e: Exception) {
                        Log.w(TAG, "judge round failed: " + e.message)
                        com.jev.probe.core.Analysis(
                            null, null, null, null, null, null, null, emptyList(), 0L,
                            error = e.message ?: "判断接口请求失败"
                        )
                    }
                    main.post {
                        if (!isCurrent(token)) return@post
                        round.judgment = judgment
                        round.judgeFinished = true
                        if (judgment.error == null) {
                            lastJudgment = judgment
                            overlay?.showJudgment(judgment)
                        } else {
                            overlay?.showJudgeFailure("⚠ 判断接口失败，未经排序")
                        }
                        finishRoundIfReady()
                    }
                }

                submitAnalysis {
                    val draft = try {
                        // 跨轮反重复：把最近几轮展示过的候选一并交给起草，别再复读。
                        val avoid = recentReplies.asAvoid()
                        if (prefs.streamReplies) {
                            try {
                                withHardTimeout(prefs.requestTimeoutSeconds * 1000L, "回复接口") { sc ->
                                    client.draftStream(
                                        snapshot, rel, ctx, count = count, avoid = avoid,
                                        intensity = lastIntensity,
                                        onVisible = { live -> main.post { if (isCurrent(token)) overlay?.showStreaming(live) } },
                                        scope = sc
                                    )
                                }
                            } catch (e: SafetyBlockedException) {
                                // A refusal must reach the user, not be retried as a
                                // transport hiccup: the fallback would refuse again.
                                throw e
                            } catch (e: Exception) {
                                // Opt-in streaming must never cost the round its
                                // candidates: a provider or proxy that buffers SSE
                                // fails here, so redo it the ordinary way.
                                Log.w(TAG, "stream draft failed, falling back: " + e.message)
                                withHardTimeout(prefs.requestTimeoutSeconds * 1000L, "回复接口") { sc ->
                                    client.draftOnly(snapshot, rel, ctx, count, avoid,
                                        intensity = lastIntensity, scope = sc)
                                }
                            }
                        } else {
                            withHardTimeout(prefs.requestTimeoutSeconds * 1000L, "回复接口") { sc ->
                                client.draftOnly(snapshot, rel, ctx, count, avoid,
                                    intensity = lastIntensity, scope = sc)
                            }
                        }
                    } catch (e: SafetyBlockedException) {
                        Log.w(TAG, "draft blocked: " + e.message)
                        main.post {
                            if (isCurrent(token)) overlay?.showError(e.message ?: "这条不适合自动给候选")
                        }
                        emptyList()
                    } catch (e: Exception) {
                        Log.w(TAG, "draft failed: " + e.message)
                        emptyList()
                    }
                    main.post {
                        if (!isCurrent(token)) return@post
                        round.draft = draft
                        round.draftFinished = true
                        if (draft.isNotEmpty()) {
                            overlay?.showDraftFirst(draft) { text -> fillInput(token, text) }
                        }
                        finishRoundIfReady()
                    }
                }
            }
        }
    }

    /**
     * Card long-press → "这个应用不再自动分析" / "恢复这个应用的自动分析".
     *
     * Only the automatic trigger is affected: the card, the manual tap and the
     * reply buttons keep working, so nothing is taken away except the assistant
     * speaking up on its own in that one app.
     */
    private fun toggleAppAuto() {
        val pkg = activePkg ?: foregroundPkg ?: overlay?.currentApp() ?: return
        val mute = !prefs.isAppMuted(pkg)
        prefs.setAppMuted(pkg, mute)
        val on = prefs.autoAnalyzeFor(pkg)
        overlay?.setAppAutoEnabled(on)
        Trace.log("autoToggle pkg=$pkg muted=$mute on=$on global=${prefs.autoAnalyze}")
        overlay?.toast(
            when {
                mute -> "已关闭这个应用的自动分析，点卡片仍可手动分析"
                !prefs.autoAnalyze -> "已恢复，但全局自动分析是关的，去设置里打开"
                else -> "已恢复这个应用的自动分析"
            }
        )
    }

    // ------------------------------------------------------------------ OCR

    /**
     * Bubble menu → "截屏识别一次". Works on ANY app, adapted or not: one whole
     * screen shot, every line OCR'd, lines grouped into pseudo-bubbles by line
     * spacing. Nobody can tell who said what this way, so everything is filed as
     * the other person and the panel says so.
     */
    private fun ocrCaptureManual() {
        val root = rootInActiveWindow
        val pkg = root?.packageName?.toString() ?: foregroundPkg ?: activePkg ?: ""
        // Blocked apps: a manual "截屏识别一次" must NOT take a screenshot there —
        // just show the notice (a manual tap always shows it).
        if (isBlocked(pkg)) { showBlocked(auto = false); return }
        if (pkg in NO_SCREENSHOT_PKGS) { overlay?.showError("这个应用里不使用截屏识别"); return }
        // WeChat: the pixel path already knows how to find the bubbles and their
        // sides, so a manual tap must go through it rather than whole-screen OCR
        // (which cannot tell who said what).
        if (pkg == WECHAT_PKG) { maybeCaptureWeChat(root, manual = true); return }
        // Top bar text, if this app has one we can read; else the first OCR line.
        val title = root?.let {
            findTitleInActionBar(it, Int.MAX_VALUE, resources.displayMetrics.widthPixels, resources, 0.15, 0.85)
        }
        val target = root?.let { targetFor(it) } ?: run {
            overlay?.toast("无法确认当前会话，请等待标题加载后重试")
            return
        }
        observeTarget(target)
        ocrCapture(title, emptyList(), pkg, manual = true)
    }

    /**
     * What the screen would look like to a camera, as far as the tree can tell.
     *
     * Feishu: the conversation title plus every bubble rectangle and its side —
     * the bubbles move whenever the list scrolls or a message arrives, and stay
     * put when only chrome (caret, presence dot, timestamp) redraws. Apps that
     * give us no rectangles fall back to package + title, which at least stops a
     * burst of events on one screen from becoming a burst of screenshots.
     */
    private fun ocrSignature(pkg: String, title: String?, rects: List<BubbleRect>): String {
        if (rects.isEmpty()) return pkg + "|" + (title ?: "")
        return (title ?: "") + "|" + rects.joinToString(";") { br ->
            val r = br.rect
            "${r.left},${r.top},${r.right},${r.bottom},${br.side}"
        }
    }

    /**
     * Screenshot, then either OCR each known bubble rect (Feishu: the tree knows
     * where the bubbles are and who sent them, just not what they say) or OCR
     * the whole screen (everything else).
     */
    private fun ocrCapture(treeTitle: String?, rects: List<BubbleRect>, pkg: String, manual: Boolean) {
        if (ocrBusy || destroyed || !prefs.enabled) return
        val token = session.token() ?: return
        if (!isCurrent(token)) return
        ocrBusy = true
        screenCapture.capture(shouldCapture = { isCurrent(token) }) { res ->
            if (!isCurrent(token)) {
                if (res is ScreenCapture.Result.Ok) res.bitmap.recycle()
                ocrBusy = false
                return@capture
            }
            when (res) {
                is ScreenCapture.Result.Failed -> {
                    ocrBusy = false
                    Log.i(TAG, "ocr: screenshot failed code=${res.code}")
                    // Nothing was read, so the signature must not claim this
                    // screen is done — the next event may retry, still held
                    // back by ScreenCapture's own throttle and failure backoff.
                    if (!manual) lastOcrSignature = ""
                    // Throttle/interval codes are transient timing, not
                    // something the user can act on — nagging would be constant.
                    val transient = res.code == ScreenCapture.CODE_THROTTLED || res.code == 3
                    if (manual || !transient) overlay?.showError(res.humanMessage)
                }
                is ScreenCapture.Result.Ok -> {
                    ocr.scaleX = res.scaleX; ocr.scaleY = res.scaleY
                    ocr.originX = res.originX; ocr.originY = res.originY
                    if (rects.isNotEmpty() && !manual) {
                        // Re-measure inside the callback. The rects handed in were
                        // read before the 120ms overlay-hide wait and the shot
                        // itself; one scroll tick in between and we would crop the
                        // rows next to the ones in the picture. Fall back to the
                        // old rects only if the tree gives us nothing now.
                        val fresh = rootInActiveWindow?.let { collectFeishuBubbleRects(it, resources) }
                        ocrByRects(res.bitmap, if (fresh.isNullOrEmpty()) rects else fresh, treeTitle, pkg, token)
                    } else ocrWholeScreen(res.bitmap, treeTitle, pkg, manual, token)
                }
            }
        }
    }

    // ---- WeChat pixel path ------------------------------------------------

    /**
     * WeChat's entry point. Its tree is empty (see [WECHAT_PKG]), so neither
     * "are we in a chat" nor "who said what" can come from nodes: both come from
     * the picture. WeChat spends most of its life on the chat list, where the
     * pixel pass simply finds no bubbles and nothing happens — so this always
     * parks the idle bubble first, keeping the menu reachable.
     */
    private fun maybeCaptureWeChat(root: AccessibilityNodeInfo, manual: Boolean) {
        // Bind the session to this window even though the tree has no title; the
        // OCR pass fills it in and [targetFor] serves it back from then on.
        targetFor(root)?.let { observeTarget(it) }
        foregroundPkg = WECHAT_PKG
        overlay?.setApp(WECHAT_PKG)
        if (overlay?.isShowing() != true) overlay?.showIdle(weChatTitle.title)
        if (!manual) {
            if (!prefs.ocrFallback) { Trace.log("wx skip ocrFallback off"); return }
            // No tree signature exists to dedupe on before the shot, so the
            // brake is time-based; identical OCR results still never re-analyse.
            val now = SystemClock.uptimeMillis()
            if (now - lastWeChatShotAt < prefs.ocrPollIntervalSeconds * 1000L) return
            lastWeChatShotAt = now
        }
        Trace.log("wx capture manual=$manual titleLen=${weChatTitle.title?.length ?: -1}")
        ocrCaptureWeChat(manual)
    }

    /**
     * Screenshot → [WeChatBubbles] finds the bubbles and their sides in pixels →
     * one OCR pass per bubble → title from the top band.
     *
     * The title goes first and it is what binds the conversation: Telegram, QQ
     * and the rest get their title from the tree, WeChat has none, and without a
     * title [isCurrent] cannot tell one WeChat chat from another (the session
     * identity is app + window + title) and every capture would invalidate
     * itself. `weChatTitle` is the sticky copy [targetFor] hands back.
     */
    private fun ocrCaptureWeChat(manual: Boolean) {
        if (ocrBusy || destroyed || !prefs.enabled) return
        val windowId = rootInActiveWindow?.windowId ?: return
        ocrBusy = true
        screenCapture.capture(shouldCapture = {
            !destroyed && prefs.enabled && foregroundPkg == WECHAT_PKG
        }) { res ->
            when (res) {
                is ScreenCapture.Result.Failed -> {
                    ocrBusy = false
                    Log.i(TAG, "wx: screenshot failed code=${res.code}")
                    val transient = res.code == ScreenCapture.CODE_THROTTLED || res.code == 3
                    if (manual || !transient) overlay?.showError(res.humanMessage)
                }
                is ScreenCapture.Result.Ok -> {
                    ocr.scaleX = res.scaleX; ocr.scaleY = res.scaleY
                    ocr.originX = res.originX; ocr.originY = res.originY
                    val bmp = res.bitmap
                    val px = IntArray(bmp.width * bmp.height)
                    runCatching { bmp.getPixels(px, 0, bmp.width, 0, 0, bmp.width, bmp.height) }
                    val boxes = WeChatBubbles.find(px, bmp.width, bmp.height)
                    val band = Rect(0, 0, bmp.width, (bmp.height * WeChatBubbles.TITLE_BAND).toInt())
                    ocr.recognize(bmp, band) { lines ->
                        val picked = OcrGrouping.pickTitle(lines, bmp.width)
                        // The title IS the session identity, so the anti-flicker
                        // rule (accept a changed pick only on a consecutive
                        // repeat) lives in [WeChatTitleState] and is unit tested.
                        weChatTitle = weChatTitle.accept(picked, windowId)
                        val title = weChatTitle.title
                        Trace.log("wx boxes=${boxes.size} titleLines=${lines.size} titleLen=${title?.length ?: -1}")
                        observeTarget(ConversationSession.Target(WECHAT_PKG, windowId, title))
                        val token = session.token()
                        if (token == null) {
                            runCatching { bmp.recycle() }
                            ocrBusy = false
                            return@recognize
                        }
                        if (boxes.isEmpty()) {
                            // Chat list, an empty chat, or a screen the pixel
                            // rules do not understand: nothing to read here.
                            runCatching { bmp.recycle() }
                            finishOcrSnapshot(ChatSnapshot(title, emptyList()), WECHAT_PKG, manual, token)
                            return@recognize
                        }
                        val sx = ocr.scaleX; val sy = ocr.scaleY
                        val ox = ocr.originX; val oy = ocr.originY
                        val rects = boxes.map { b ->
                            BubbleRect(Rect(
                                (b.left / sx).toInt() + ox, (b.top / sy).toInt() + oy,
                                (b.right / sx).toInt() + ox, (b.bottom / sy).toInt() + oy), b.side)
                        }
                        Log.i(TAG, "wx: ${rects.size} bubbles (windowId=$windowId)")
                        // Group sender names are rendered just above incoming bubbles,
                        // outside their rectangles. OCR that conversation band once so
                        // sender attribution can be separated from bubble text. If no
                        // sender labels are found, the old 1:1 me/other semantics remain.
                        val speakerRegion = Rect(
                            0,
                            (bmp.height * WeChatBubbles.TITLE_BAND).toInt(),
                            bmp.width,
                            (bmp.height * BOTTOM_CROP).toInt()
                        )
                        ocr.recognize(bmp, speakerRegion) { speakerLines ->
                            val labels = WeChatSpeakerAttribution.labelsFor(speakerLines, boxes)
                            val speakers = WeChatSpeakerAttribution.assign(boxes, labels)
                            Trace.log("wx speakers labels=${labels.size} members=${speakers.count { it.startsWith("member:") }} unknown=${speakers.count { it == "unknown" }}")
                            ocrByRects(bmp, rects, title, WECHAT_PKG, token, speakers)
                        }
                    }
                }
            }
        }
    }


    private fun ocrByRects(
        bmp: Bitmap,
        rects: List<BubbleRect>,
        title: String?,
        pkg: String,
        token: ConversationSession.Token,
        speakers: List<String>? = null,
    ) {
        val sx = ocr.scaleX; val sy = ocr.scaleY
        // Screen -> bitmap: drop the window origin first. A window shot does not
        // start at (0,0) in split screen or when it excludes the status bar.
        val ox = ocr.originX; val oy = ocr.originY
        val out = arrayOfNulls<Msg>(rects.size)
        var remaining = rects.size
        rects.forEachIndexed { i, br ->
            val region = Rect(
                ((br.rect.left - ox) * sx).toInt(), ((br.rect.top - oy) * sy).toInt(),
                ((br.rect.right - ox) * sx).toInt(), ((br.rect.bottom - oy) * sy).toInt())
            ocr.recognize(bmp, region) { lines ->
                val text = OcrGrouping.cleanBubbleText(lines.joinToString(" ") { it.text })
                if (text.isNotEmpty()) {
                    val speaker = speakers?.getOrNull(i)
                    out[i] = Msg(
                        speaker ?: br.side,
                        text,
                        sender = speaker?.takeIf { it.startsWith("member:") }?.removePrefix("member:")
                    )
                }
                remaining--
                if (remaining == 0) {
                    runCatching { bmp.recycle() }
                    finishOcrSnapshot(ChatSnapshot(title, out.filterNotNull()), pkg, manual = false, token = token)
                }
            }
        }
    }

    /** Whole screen minus the top bar and the input area, grouped by line gaps. */
    private fun ocrWholeScreen(bmp: Bitmap, treeTitle: String?, pkg: String, manual: Boolean, token: ConversationSession.Token) {
        val region = Rect(0, (bmp.height * TOP_CROP).toInt(), bmp.width, (bmp.height * BOTTOM_CROP).toInt())
        // The same pixel pass that powers WeChat runs here for EVERY app. A flat
        // screen read is the only source of text on this path, but it is not the
        // only source of SIDES: the boxes tell who is on which side. Filing every
        // line as "other" (the old behaviour) is what turned a screen full of my
        // own messages into an incoming conversation and produced advice for
        // answering myself. Boxes are in bitmap coordinates, exactly like the OCR
        // line bounds, so they compare directly.
        val boxes = runCatching {
            val px = IntArray(bmp.width * bmp.height)
            bmp.getPixels(px, 0, bmp.width, 0, 0, bmp.width, bmp.height)
            WeChatBubbles.find(px, bmp.width, bmp.height)
        }.getOrDefault(emptyList())
        ocr.recognize(bmp, region) { lines ->
            runCatching { bmp.recycle() }
            val msgs = OcrGrouping.group(lines, boxes)
            val unknown = msgs.count { it.side == OcrGrouping.SIDE_UNKNOWN }
            val note = when {
                msgs.isEmpty() -> null
                unknown == msgs.size -> OCR_NOTE
                unknown > 0 -> "$OCR_PARTIAL_NOTE$unknown 条"
                else -> null
            }
            Trace.log("ocr whole boxes=${boxes.size} msgs=${msgs.size} me=${msgs.count { it.side == "me" }} " +
                "other=${msgs.count { it.side == "other" }} unknown=$unknown")
            val title = treeTitle?.takeIf { it.isNotBlank() }
                ?: lines.firstOrNull()?.text?.trim()?.take(24)
            finishOcrSnapshot(ChatSnapshot(title, msgs, note = note), pkg, manual, token)
        }
    }

    /** Shared tail of both OCR paths: dedupe, then analyze or park the bubble. */
    private fun finishOcrSnapshot(raw: ChatSnapshot, pkg: String, manual: Boolean, token: ConversationSession.Token) {
        ocrBusy = false
        if (!isCurrent(token)) return
        // 来源在**唯一的公共尾部**盖一次章：三条 OCR 出口（微信像素、按气泡、
        // 整屏）都不用各自记得写 provenance，也就不会有一个漏掉。
        val snapshot = raw.copy(provenance = Provenance.OCR)
        // Counts only — OCR'd chat text never goes to logcat.
        Log.i(TAG, "ocr[$pkg] msgs=${snapshot.messages.size} manual=$manual")
        Trace.log("ocr pkg=$pkg provenance=${snapshot.provenance} msgs=${snapshot.messages.size} manual=$manual sides=" +
            snapshot.messages.joinToString(",") { "${it.side}:${it.text.length}" })
        if (snapshot.messages.isEmpty()) {
            if (manual) overlay?.showError("这一屏没认出文字")
            return
        }
        if (!prefs.isAllowed(snapshot.title)) { leaveConversation(); overlay?.hide(); return }

        if (pkg.isNotEmpty() && pkg != activePkg) { activePkg = pkg; lastSignature = "" }
        currentSnapshot = snapshot
        overlay?.setApp(pkg.ifEmpty { null })
        val sig = snapshot.signature()
        // Manual taps always re-run; the automatic path dedupes like the tree path.
        if (!manual && sig == lastSignature) {
            if (overlay?.isShowing() != true) overlay?.showIdle(snapshot.title)
            return
        }
        lastSignature = sig
        // Same rule as the tree path: only a first look or a new incoming message
        // starts an automatic round; scrolling keeps the card as it is.
        val verdict = gate.observe(snapshot.messages)
        val fresh = verdict == NewMessageGate.Verdict.FIRST_LOOK || verdict == NewMessageGate.Verdict.NEW_FROM_OTHER
        val auto = fresh && prefs.ocrAutoAnalyze && prefs.autoAnalyzeFor(pkg) && snapshot.latestFrom == "other"
        if (manual || auto) {
            cancelInFlight()
            pendingSnapshot = snapshot
            main.removeCallbacks(debounce)
            runAnalysis()
        } else {
            overlay?.setNote(snapshot.note)
            overlay?.showIdle(snapshot.title)
        }
    }

    private val filler: InputFiller by lazy {
        InputFiller(object : InputFiller.Host {
            override fun activeRoot(): AccessibilityNodeInfo? = rootInActiveWindow
            override fun targetOf(root: AccessibilityNodeInfo): ConversationSession.Target? = targetFor(root)
            override fun isCurrent(token: ConversationSession.Token): Boolean = this@ChatCaptureService.isCurrent(token)
            override fun post(delayMs: Long, action: () -> Unit) { main.postDelayed({ action() }, delayMs) }
            override fun copyToClipboard(text: String) = this@ChatCaptureService.copyToClipboard(text)
        })
    }

    /** Fill without blocking the main thread; all retries re-resolve the original target. */
    private fun fillInput(token: ConversationSession.Token, text: String) {
        if (!isCurrent(token)) { overlay?.toast("会话已变化，请重新分析后填入"); return }
        filler.fill(token, text) { ok ->
            if (!isCurrent(token)) return@fill
            if (ok) overlay?.toast("已填入，确认后自己发送")
            else { copyToClipboard(text); overlay?.toast("已复制，长按输入框粘贴") }
        }
    }

    private fun copyToClipboard(text: String) {
        val cm = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
        cm.setPrimaryClip(android.content.ClipData.newPlainText("jev_reply", text))
    }

    /**
     * 通知「唤出助手」的入口。只有当前真在一个聊天窗里才有意义——不在的话
     * 悬浮球本来就看得见，点开通知也只是 toast 提示，不凭空画一张空卡。
     */
    override fun onStartCommand(intent: android.content.Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == KeepAliveService.ACTION_SUMMON) {
            main.post {
                if (session.target == null) overlay?.toast("先打开一个聊天窗口，助手才会出卡")
                else overlay?.summon()
            }
        }
        return super.onStartCommand(intent, flags, startId)
    }

    override fun onInterrupt() {
        leaveConversation()
        overlay?.hide()
    }

    /**
     * 被系统解绑（不是本 App 主动停的）。
     *
     * 这就是用户那句"我明明开着，怎么还要再点一次无障碍"的物理形态：真机上
     * `dumpsys accessibility` 里 `Enabled services:{本组件}` **还在**，`Bound
     * services:{}` 已经空了 —— 设置说开着，但没有实例在跑。覆盖安装、开机、
     * 被 ColorOS 冻死之后都会到这一步。
     *
     * 维护 [live] 就是为了让"一键修复"和主页能分辨这两种状态，而不是拿设置里那
     * 一格当"能用"的证据。
     */
    override fun onUnbind(intent: android.content.Intent?): Boolean {
        live = false
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        destroyed = true
        live = false
        getSharedPreferences(Prefs.PREFS_MAIN, MODE_PRIVATE)
            .unregisterOnSharedPreferenceChangeListener(preferencesListener)
        leaveConversation()
        main.removeCallbacksAndMessages(null)
        super.onDestroy()
        // Tear the overlay down and cut its callback so a stale button tap can
        // never call back into this dead instance.
        overlay?.onManualAnalyze = null
        overlay?.onSaveContact = null
        overlay?.onOcrCapture = null
        overlay?.onToggleAppAuto = null
        overlay?.hide()
        overlay = null
        worker.shutdownNow()
    }

    companion object {
        private const val TAG = "JEVASSIST"

        /**
         * 本进程里有没有一个**活着的**服务实例。和 `enabled_accessibility_services`
         * 那一格是两件事：那一格只说"用户在设置里开着"，这里说的是"真的在跑"。
         *
         * 无障碍服务和本 App 的界面在同一个进程（清单里没写 `android:process`），
         * 所以这个静态量就是主页和"一键修复"能拿到的最准的信号 —— 进程被杀后默认
         * false 也对（服务跟着死了）。
         */
        @Volatile
        var live = false
            private set

        /** Grace period before a "not a chat" read really leaves the conversation. */
        private const val LEAVE_CONFIRM_MS = 1200L

        /** Apps that are never read: they protect their content against screen
         *  reading or screenshots, so any capture attempt there is off-limits.
         *  No adapter, no capture, only a one-time "not supported" notice. */
        /** Supported apps that are read through the node tree only and never
         *  screenshotted: no OCR fallback, no manual "截屏识别一次". */
        private val NO_SCREENSHOT_PKGS = setOf(WhatsAppRules.PACKAGE)

        private val BLOCKED_PKGS = setOf("cn.soulapp.android")

        /**
         * WeChat. Not blocked, but not adapted either: it gives accessibility an
         * empty node tree (1 node / 407 bytes, verified with every accessibility
         * service on the phone switched off), so there is nothing to adapt. Its
         * screenshots are readable, so it runs through the pixel path in
         * [WeChatBubbles] instead — see [maybeCaptureWeChat].
         */
        private const val WECHAT_PKG = "com.tencent.mm"

        /**
         * Floor between two automatic WeChat screenshots. WeChat fires content
         * events constantly and its empty tree offers no signature to dedupe on
         * before the shot, so the brake has to be time-based. OCR still dedupes
         * the RESULT (identical messages never re-analyse).
         */
        private const val WECHAT_SHOT_INTERVAL_MS = 3000L

        /** Shown once per visit to a blocked app. Plain words, full-width
         *  punctuation; steers the user to a supported app. */
        private const val BLOCKED_MSG =
            "这个应用暂不支持，请在别的软件上使用"

        /** How long a transient non-chat foreground must persist before the
         *  bubble is taken away (#18). */
        private const val FOREGROUND_CONFIRM_MS = 1500L

        /** On an app whose adapter has been reading bubbles, an empty read must
         *  persist this long before the OCR fallback may take a screenshot: a
         *  one-frame empty read (RecyclerView re-layout, IME animation) used to
         *  fabricate a whole conversation out of the screen. */
        private const val EMPTY_READ_GRACE_MS = 4000L

        /** Whole-screen OCR keeps the middle: no action bar, no input area. */
        private const val TOP_CROP = 0.12f
        private const val BOTTOM_CROP = 0.84f

        /** Said on the panel whenever NO line of a flat-screen OCR could be assigned a side. */
        private const val OCR_NOTE = "OCR 分不出左右：这一屏的发言人不确定，别假定都是对方说的"

        /** Said when only some OCR lines could be assigned a side. */
        private const val OCR_PARTIAL_NOTE = "OCR 分边：有 "

        /** Transient placeholder titles apps show while a chat page is still
         *  connecting/loading — see [isTransientTitle]. Matched as a substring,
         *  case-insensitive, after trimming a trailing ellipsis. */
        private val TRANSIENT_TITLE_WORDS = listOf(
            "连接中", "正在连接", "未连接", "Connecting",
            "加载中", "Loading", "同步中", "Syncing"
        )
    }
}

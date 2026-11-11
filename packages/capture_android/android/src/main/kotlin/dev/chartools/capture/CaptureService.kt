package dev.chartools.capture

import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import dev.chartools.capture.ocr.MlKitOcr
import dev.chartools.capture.ocr.OcrGrouping
import dev.chartools.capture.ocr.ScreenCapture
import dev.chartools.capture.overlay.OverlayController
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * 精简版无障碍采集服务：只采集、只发射，不做任何编排。
 *
 * 旧仓库的 ChatCaptureService（1757 行）在这里被拆掉：jev 分析、注入层、
 * 消息门控（NewMessageGate）、白名单（Prefs）全部不随迁（悬浮窗 overlay 已
 * 于本版本移植，见 [overlay] 与 overlay/OverlayController——只做展示层，不调
 * 模型，建议由 Dart 经 showSuggestions 推入）。保留的是它「读窗口 → 出快照」
 * 的那条主链路：
 * - 事件进来（WINDOW_STATE_CHANGED / WINDOW_CONTENT_CHANGED），同一包名 300ms
 *   防抖后交给 [ChatAppAdapter.extract]；
 * - 快照有内容 → 签名去重后经 EventChannel 发给 Dart；
 * - 快照为空（在聊天窗里但树上没字，如飞书）→ 截屏 + OCR 兜底，OCR 分支
 *   照抄 ChatCaptureService 的原有写法（[ocrCapture] / [ocrByRects] /
 *   [ocrWholeScreen] / [finishOcrSnapshot]），其中 jev/overlay 编排调用替换成
 *   「直接发快照」。
 *
 * 它从不发送消息。唯一的写动作是 [InputFiller] 的 ACTION_SET_TEXT（或剪贴板
 * PASTE 兜底）回填聊天输入框，发送仍由用户完成。
 */
class CaptureService : AccessibilityService() {

    /** 由 MethodChannel 写入的静态可变配置；服务与 Dart 两侧共享。 */
    companion object ServiceConfig {
        private const val TAG = "CAPTURE"

        /** EventChannel：快照 JSON 流。 */
        const val SNAPSHOT_CHANNEL = "capture_android/snapshots"

        /** MethodChannel：configure / isRunning / openAccessibilitySettings / refill /
         *  manualOcr / showSuggestions / hideSuggestions / collapse / getCapabilities /
         *  setSecure，以及服务 → Dart 方向的 [REQUEST_CONFIGURE_METHOD]。 */
        const val CONTROL_CHANNEL = "capture_android/control"

        /**
         * fix(kimi-review #2)：服务 → Dart 的配置重放请求（无参数，fire-and-forget）。
         * 用户「先配开关、后启无障碍」是最常见路径：服务连接时 configuredPackages
         * 还是空的，自动采集静默失效。服务与引擎两侧都就绪的时刻（attachEngineChannels）
         * 由 [requestConfigureOver] 向 Dart 发起，Dart 侧在 capture_android/control
         * 上 setMethodCallHandler 接住，用持久化的设置重新下发 configure（幂等）。
         */
        internal const val REQUEST_CONFIGURE_METHOD = "requestConfigure"

        /**
         * fix(kimi-review #11)：Dart → 服务的悬浮窗防截屏开关（control 通道）。
         * 参数就是 bool 本身（capture_android.dart 的 [setSecure] 契约：Kotlin 侧
         * `call.arguments as? Boolean`）。独立复核（2026-11-12）发现 handleControl
         * 漏了这个分支：Dart 恒收 notImplemented，开关在服务已连接时也弹「未连接」
         * 错误，OverlayController.setSecure 与建窗的 FLAG_SECURE 注入成了够不着的
         * 死代码——原漏洞（录屏可带走悬浮窗候选明文）原样存在。常量供
         * SetSecureContractTest 与 Dart 侧测试互钳两侧方法名。
         */
        internal const val SET_SECURE_METHOD = "setSecure"

        /** 同一包名事件防抖窗口。 */
        private const val DEBOUNCE_MS = 300L

        /** 采集目标包名集合（configure {packages:[...]}）。 */
        @Volatile var configuredPackages: Set<String> = emptySet()

        /**
         * 黑名单默认值（p0-plan ⑦）：与 Dart SettingsStore.defaultBlockedPackages
         * 镜像。cn.soulapp.android 是旧 BLOCKED_PKGS 的原有成员（防截屏应用，
         * 永不读取），随黑名单可配置化并入默认清单，避免首次 configure 把它冲掉。
         * Dart 侧的可编辑清单是单一事实来源，这里只在 configure 到来之前兜底。
         */
        private val DEFAULT_BLOCKED_PKGS = setOf(
            "com.eg.android.AlipayGmobile", // 支付宝
            "com.unionpay",                 // 云闪付
            "cn.soulapp.android",           // Soul（旧采集服务基线）
        )

        /**
         * 黑名单包名（configure {blocked:[...]}，p0-plan ⑦）：[isBlocked] 先查
         * 这里再查白名单 configuredPackages——用户明确拉黑的包即使加了白名单
         * 也不采。
         */
        @Volatile var blockedPackages: Set<String> = DEFAULT_BLOCKED_PKGS

        /** 空/无快照时是否允许截屏 + OCR 兜底（configure {ocrFallback:bool}）。 */
        @Volatile var ocrFallbackEnabled: Boolean = false

        /**
         * 插件 attaching 时塞进来的 messenger（见 CaptureAndroidPlugin）。
         * 无障碍服务的生命周期独立于 Flutter 引擎：服务先连上、引擎后起是常态，
         * 两侧谁后到，谁负责调用 [attachEngineChannels]。
         */
        @Volatile var flutterMessenger: BinaryMessenger? = null

        /** 当前活着的服务实例（插件用它把 messenger 转交进来）。 */
        var instance: CaptureService? = null
            private set

        /**
         * WeChat. It gives accessibility an empty node tree (1 node / 407 bytes,
         * verified with every accessibility service on the phone switched off),
         * so there are no node rules to adapt. fix(kimi-review #22)：自动采集经
         * [WeChatOcrAdapter]（OCR 能力面 + 空快照触发既有 OCR 兜底路径）接管；
         * 旧服务的像素入口 maybeCaptureWeChat 仍未随本插件移植。这里保留常量供
         * targetFor / ocrByRects 的微信分支使用。
         */
        private const val WECHAT_PKG = "com.tencent.mm"
        private const val WECHAT_VOICE_TRANSCRIPT_NOTE =
            "微信语音尚未转成可识别文字。请长按语音消息，选择“转文字”后再分析；助手不会读取或上传语音音频。"

        /**
         * fix(kimi-review #4)：银行/支付类包名的底线清单。旧清单只有一个虚构的
         * 前缀 "com.android.bank"，匹配不到任何真实 App，隐私底线形同虚设。
         * 改为关键词**中缀匹配**（包名小写后包含即拦）：真实命中支付宝
         * （com.eg.android.AlipayGmobile 含 "pay"）、云闪付（com.unionpay）、
         * 交通银行（com.bankcomm.*）、PayPal（com.paypal.android）、Samsung Pay
         * （com.samsung.android.spay）、Google Wallet（…apps.walletnfcrel）等。
         * 已知缺口（关键词不命中，靠可编辑 [blockedPackages] 兜底）：工商银行
         * com.icbc、招商银行 cmb.pb、中国银行 com.chinamworld.* 等——关键词层
         * 是底线不是完备清单。微信支付与微信同包（com.tencent.mm），不能按包
         * 拆分（拆了等于拉黑整个微信采集目标），随微信的采集规则走。这类应用
         * 保护自身内容不被读屏/截屏，任何采集尝试都不被允许：底线清单不随
         * configure 配置、UI 清空黑名单也拦它，优先级仍高于可编辑清单。
         */
        private val BLOCKED_PKG_KEYWORDS = listOf("bank", "pay", "wallet", "paypal", "unionpay")

        /**
         * 黑名单判定的纯函数本体（p0-plan ⑦）：无 Android 依赖，离线单测直接钉它
         * （android/src/test/kotlin/dev/chartools/capture/BlockedPackagesTest.kt）。
         * [CaptureService] 是 AccessibilityService，测试环境实例化不了，实例方法
         * [isBlocked] 只负责取当前 [blockedPackages] 后转发到这里。[blocked] 由
         * 调用方传入而不是函数自己读全局，测试才能不碰可变状态验证任意清单。
         */
        internal fun isBlockedPackage(pkg: String?, blocked: Set<String>): Boolean {
            if (pkg == null) return false
            if (pkg in blocked) return true
            // fix(kimi-review #4)：startsWith 换成小写中缀匹配（见
            // [BLOCKED_PKG_KEYWORDS]），真实金融 App 的包名才拦得住。
            val lower = pkg.lowercase()
            return BLOCKED_PKG_KEYWORDS.any { lower.contains(it) }
        }

        /**
         * G2 能力查询（control 方法 `getCapabilities {pkg}`）：
         * - 已适配包（含微信——fix(kimi-review #22) 起由 [WeChatOcrAdapter] 提供
         *   同形的 OCR 能力面，原先单列的 weChatCapabilities 已并入）→ 该适配器
         *   [ChatAppAdapter.capabilities] 的 Map 投影；
         * - 其余包名（含 null）→ null：「未适配/不支持」。
         *
         * 返回 Map 而非 JSON 串：StandardMethodCodec 原生编解码 Map 与 null，
         * Dart 侧不必再解码一层。键与 [AdapterCapabilities] 字段同名。静态放在
         * companion（能力表是不随实例变的数据，同 [isBlockedPackage] 的取舍：
         * 服务实例在测试环境实例化不了，单测直接钳这个纯函数）。
         */
        internal fun capabilitiesFor(pkg: String?): Map<String, Any?>? {
            if (pkg == null) return null
            val caps = ChatApps.forPackage(pkg)?.capabilities ?: return null
            return mapOf(
                "canReadMessages" to caps.canReadMessages,
                "canIdentifySender" to caps.canIdentifySender,
                "canReadHistory" to caps.canReadHistory,
                "allowsOcrFallback" to caps.allowsOcrFallback,
                "verifiedAppVersion" to caps.verifiedAppVersion,
            )
        }

        /**
         * fix(kimi-review #2)：把重放请求发到 Dart（fire-and-forget，无回调）。
         * Dart 未注册 handler / 引擎正在销毁时消息会被丢弃——重放请求只能尽力
         * 而为，不得把服务炸掉，所以整体 runCatching。放在 companion 与
         * [capabilitiesFor] 同一取舍：CaptureService 在测试环境实例化不了，
         * 单测直接钳这个函数（ConfigureReplayTest）。
         */
        internal fun requestConfigureOver(channel: MethodChannel) {
            runCatching { channel.invokeMethod(REQUEST_CONFIGURE_METHOD, null) }
                .onFailure { Log.w(TAG, "requestConfigure send failed: $it") }
        }

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

    private val main = Handler(Looper.getMainLooper())

    /**
     * 截图像素扫描专用单线程（照抄旧服务 pixelWorker 的取舍）：1080×2376 ≈
     * 256 万像素的分配 + getPixels + 洪泛填充合计几十到一百多毫秒，压在主线程
     * 上就是聊天期间的周期性掉帧。onServiceConnected 里顺手用它预热 OCR 模型。
     */
    private val pixelWorker = Executors.newSingleThreadExecutor()

    private var destroyed = false

    // ---- Flutter 通道 ------------------------------------------------------

    private var snapshotChannel: EventChannel? = null
    private var controlChannel: MethodChannel? = null

    private var eventSink: EventChannel.EventSink? = null

    /** Dart 侧晚连接的 pending-latest：保留最近一条快照，onListen 立即补发。 */
    private var pendingLatestJson: String? = null

    private val streamHandler = object : EventChannel.StreamHandler {
        override fun onListen(args: Any?, sink: EventChannel.EventSink) {
            eventSink = sink
            pendingLatestJson?.let { last -> runCatching { sink.success(last) } }
        }

        override fun onCancel(args: Any?) {
            eventSink = null
        }
    }

    private val controlHandler = MethodChannel.MethodCallHandler { call, result ->
        handleControl(call, result)
    }

    /** 引擎 attaching 后由插件回调注册/重注册通道（热重启会换 messenger）。 */
    fun attachEngineChannels(messenger: BinaryMessenger) {
        snapshotChannel?.setStreamHandler(null)
        controlChannel?.setMethodCallHandler(null)
        snapshotChannel = EventChannel(messenger, SNAPSHOT_CHANNEL)
            .also { it.setStreamHandler(streamHandler) }
        controlChannel = MethodChannel(messenger, CONTROL_CHANNEL)
            .also {
                it.setMethodCallHandler(controlHandler)
                // fix(kimi-review #2)：这里是「服务已连接 + 引擎已挂接」两态同时
                // 就绪的唯一汇聚点（onServiceConnected 里 messenger 已就绪时走到
                // 这里；服务先连、引擎后到时由 CaptureAndroidPlugin 走到这里），
                // 向 Dart 请求重放 configure。热重启换 messenger 后再请求一次，
                // Dart 重放幂等。
                requestConfigureOver(it)
            }
    }

    // ---- 会话与去重状态（旧服务 CaptureConversationState 的采集子集） --------

    private val session = ConversationSession()

    /** 微信标题的防抖状态（[targetFor] 的微信分支读它；微信无节点树）。 */
    private var weChatTitle = WeChatTitleState()

    private var lastSignature: String? = null
    private var activePkg: String? = null
    private var lastOcrSignature: String? = ""
    private var lastNonEmptyTarget: ConversationSession.Target? = null
    private var emptySinceTarget: ConversationSession.Target? = null
    private var emptySinceAt = 0L

    /** 最近一次前台包名（手动 OCR 在活窗口读不到时的回退，照抄旧服务用法）。 */
    private var foregroundPkg: String? = null

    // ---- 事件入口 ----------------------------------------------------------

    private var debouncePkg: String? = null
    private val debounce = Runnable {
        val pkg = debouncePkg
        debouncePkg = null
        if (pkg != null) maybeCapture()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val type = event.eventType
        if (type != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            type != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED
        ) return
        // fix(kimi-review #13)：任何窗口/内容事件都可能意味着树变了——清掉
        // 回填路径的 targetOf 提取 memo（TargetMemo 的正确性依据是「两次提取
        // 之间无事件 ⇒ 树未变」；有事件就重算，绝不跨内容变化复用，否则
        // 窗口内切聊天会漏检、回填写进切换后的输入框）。宁可多提取一次，
        // 也不背陈旧标题。
        targetMemo.invalidate()
        val eventPkg = event.packageName?.toString() ?: return
        if (type == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            // fix(kimi-review #14)：foregroundPkg 直接取 event.packageName——
            // WINDOW_STATE_CHANGED 的来源就是新窗口。原来为此读
            // rootInActiveWindow（跨 binder 调用 + 全树构建），每次换窗白付一遍；
            // 消费方 manualOcr 只拿它当包名回退用。
            foregroundPkg = eventPkg
        }
        // 黑名单优先于白名单（p0-plan ⑦）：先拦用户明确拉黑的包（即使它也被
        // 加进了采集范围），再做采集范围白名单判断。
        if (isBlocked(eventPkg)) return
        // 只处理 Dart configure 过的包；事件包名可能是 IME/状态栏（旧服务的教训），
        // 真正的前台在 maybeCapture 里以 rootInActiveWindow 为准。
        if (eventPkg !in ServiceConfig.configuredPackages) return
        // 同一包名 300ms 防抖：突发的 content-changed 折叠成一次全树提取；
        // 换了包名则重启防抖窗口。
        if (debouncePkg != eventPkg) {
            debouncePkg = eventPkg
            main.removeCallbacks(debounce)
            main.postDelayed(debounce, DEBOUNCE_MS)
        }
    }

    // ---- 采集主链路（照抄 ChatCaptureService.maybeCapture，493-634 行） ------

    private fun maybeCapture() {
        val root = rootInActiveWindow ?: return
        val pkg = root.packageName?.toString() ?: return
        // 无适配器的包（抖音等）：旧服务另有像素路径（maybeCaptureWeChat），本插件
        // 只保留适配器驱动的采集，未适配包静默跳过。fix(kimi-review #22)：微信
        // 由 WeChatOcrAdapter 提供「OCR 能力面」，空快照走下面的 OCR 兜底分支。
        val adapter = ChatApps.forPackage(pkg) ?: return
        val rawSnapshot = adapter.extract(root, resources)
        Trace.log(
            "cap pkg=$pkg adapter=${adapter.pkg} snapshot=" +
                (rawSnapshot?.let {
                    "msgs=${it.messages.size} me=${it.messages.count { m -> m.side == "me" }} " +
                        "other=${it.messages.count { m -> m.side != "me" }} titleLen=${it.title?.length ?: -1}"
                } ?: "null")
        )
        if (rawSnapshot == null) {
            // 不在该 App 的聊天窗口。旧服务在这里 scheduleLeave + 拆悬浮卡；
            // 本插件无编排可拆，直接返回（会话状态保留，见 targetFor/observeTarget）。
            return
        }
        // fix(kimi-review #12)：把已提取的快照传给 targetFor，主链路每次事件只
        // 做一次全树遍历（原来 targetFor 内部再 extract 一次，两次结果还可能在
        // 边界下不一致——lastSignature 用第一次、messagesSignature 用第二次）。
        val target = targetFor(root, rawSnapshot) ?: return
        observeTarget(target)
        val snapshot = rawSnapshot
        // In a chat window but the tree holds no text (Feishu draws its bodies)
        // → screenshot + OCR, subject to ScreenCapture's own >=1s throttle and
        // failure backoff.
        if (snapshot.messages.isEmpty()) {
            if (!ServiceConfig.ocrFallbackEnabled) return
            if (!adapter.allowScreenshot) return
            // An adapter that has been reading bubbles can still read ZERO for a
            // frame while a RecyclerView re-lays out or the IME animates (TIM:
            // msgs=8 → msgs=0 → snapshot=null within 300ms). A screenshot taken
            // then invents a conversation out of whatever happens to be on screen,
            // sides and all. So on an app that HAS been reading, the empty state
            // must persist before OCR runs; an app whose tree never carries text
            // (Feishu) has no such history and still goes straight to OCR.
            val now = SystemClock.uptimeMillis()
            if (emptySinceTarget != target) {
                emptySinceTarget = target
                emptySinceAt = now
            }
            // fix(kimi-review #1)：判等用 sameConversation 的身份语义
            // （pkg/windowId/title）。原写法 lastNonEmptyTarget == target 是 data
            // class 全等，含 messagesSignature——非空读存的 Target 带真实指纹、
            // 空读构造的 Target 签名恒为 null → 永不相等，4 秒宽限是死代码，
            // TIM 类「msgs=8 → 0 → null」瞬时空帧立刻触发截屏 OCR。
            if (lastNonEmptyTarget?.sameConversation(target) == true &&
                now - emptySinceAt < EMPTY_READ_GRACE_MS
            ) {
                Trace.log("cap empty read held ${now - emptySinceAt}ms on $pkg")
                return
            }
            // Gate BEFORE the shot, not after the OCR. Feishu's tree is empty
            // on every content-changed event, and a successful shot resets the
            // failure backoff — so without this the caret blinking or an
            // "online" badge flipping keeps a screenshot going out every
            // second forever. The picture can only differ if the bubbles moved
            // or the conversation changed, and that is exactly what the
            // signature measures.
            val sig = ocrSignature(pkg, snapshot.title, snapshot.bubbleRects)
            if (sig == lastOcrSignature) return
            if (ocrBusy) return
            lastOcrSignature = sig
            ocrCapture(snapshot.title, snapshot.bubbleRects, pkg, manual = false)
            return
        }

        // Switching to another adapted app resets the dedupe signature, so two apps
        // whose last few messages happen to match cannot swallow each other.
        if (pkg != activePkg) {
            activePkg = pkg
            lastSignature = ""
        }
        // This app's tree reads fine: an empty read from here on is suspect (see
        // the OCR gate above).
        lastNonEmptyTarget = target
        emptySinceTarget = null

        val sig = snapshot.signature()
        // 签名去重：与上次发射相同则不发。旧服务还要 overlay 卡已在屏上才短路；
        // 本插件没有卡片，纯签名判定。
        if (sig == lastSignature) return
        lastSignature = sig
        // 旧服务在这里过 NewMessageGate（滚动/自己发言不触发分析）并驱动 jev 轮次；
        // 本插件只采集：内容真的变了就直接发给 Dart，触发策略由 Dart 侧决定。
        emitSnapshot(snapshot)
    }

    /**
     * 会话身份解析，照抄 ChatCaptureService.targetFor（221-254 行）。
     * fix(kimi-review #12)：[snapshot] 接收调用方已提取的快照（maybeCapture 主
     * 链路传入，避免每次事件双重全树遍历）；null 时（手动 OCR、回填的 targetOf）
     * 才在内部提取，行为与旧实现一致。
     */
    private fun targetFor(
        root: AccessibilityNodeInfo,
        snapshot: ChatSnapshot? = null,
    ): ConversationSession.Target? {
        val pkg = root.packageName?.toString() ?: return null
        if (isBlocked(pkg) || pkg == packageName || pkg == "com.android.systemui" ||
            pkg.contains("launcher", true) || pkg == "com.miui.home"
        ) return null
        val adapter = ChatApps.byPackage[pkg]
        var messagesSignature: String? = null
        val title = if (pkg == WECHAT_PKG) {
            // fix(kimi-review #22)：微信有 WeChatOcrAdapter 后适配器分支也会命中，
            // 但它的 extract 永远给不出标题（树是空的，见 WeChatOcrAdapter）——
            // 标题只能来自 OCR 读到的顶栏（sticky WeChatTitleState）。这个分支
            // 必须先于适配器分支判定，且允许 title=null 返回 Target：否则首次
            // 进窗会走适配器分支的「无标题 → null」，OCR 永远没机会跑（死锁）。
            // WeChat gives no node tree at all (1 empty node), so there is no
            // title to find: the OCR pass reads it off the top band and stores it
            // here. It has to be STICKY — the session identity is app + window +
            // title, so answering null between two reads would make every single
            // capture invalidate itself the moment it finished.
            weChatTitle.titleForWindow(root.windowId)
        } else if (adapter != null) {
            val extracted = snapshot ?: adapter.extract(root, resources) ?: return null
            messagesSignature = extracted.takeIf { it.messages.isNotEmpty() }?.signature()
            // A loading/unknown title cannot prove which conversation is open —
            // unless the SAME app+window already has a known one: animated
            // headers swap in skeleton/transient titles for a beat (#68), and
            // unbinding the session there killed in-flight analyses. Keep the
            // previously verified title instead.
            val fresh = extracted.title?.takeUnless { isTransientTitle(it) }
            if (fresh != null) fresh
            else {
                val known = session.target
                if (known != null && known.pkg == pkg && known.windowId == root.windowId &&
                    !known.title.isNullOrBlank()
                ) known.title else return null
            }
        } else {
            findTitleInActionBar(
                root, Int.MAX_VALUE, resources.displayMetrics.widthPixels,
                resources, 0.15, 0.85
            )
        }
        return ConversationSession.Target(pkg, root.windowId, title, messagesSignature)
    }

    private fun observeTarget(target: ConversationSession.Target?) {
        if (session.observe(target)) {
            // 会话切换：等价于旧服务 cancelAnalysis 的清场，只保留采集所需状态。
            main.removeCallbacks(debounce)
            debouncePkg = null
            lastSignature = ""
            lastOcrSignature = ""
            lastNonEmptyTarget = null
            emptySinceTarget = null
        }
    }

    /**
     * 黑名单判定（p0-plan ⑦）：先查可配置黑名单（黑名单优先于白名单——用户
     * 拉黑的包即使加进采集范围也不采），再查银行类前缀底线。事件层
     * （[onAccessibilityEvent]）在白名单判断之前先走这里；targetFor / 手动 OCR
     * 经它兜底同一份拒绝语义。判定本体在 companion 的纯函数
     * [ServiceConfig.isBlockedPackage]（单测可达），这里只接当前配置。
     */
    private fun isBlocked(pkg: String?): Boolean =
        isBlockedPackage(pkg, ServiceConfig.blockedPackages)

    /** A placeholder title an app shows only for a moment (e.g. X's "连接中…"
     *  right after opening a DM thread) — never a real conversation title.
     *  Blank/null counts too, so a caller can always fall back the same way. */
    private fun isTransientTitle(t: String?): Boolean {
        val trimmed = t?.trim()?.removeSuffix("…")?.removeSuffix("...")?.trim()
        if (trimmed.isNullOrEmpty()) return true
        val lower = trimmed.lowercase()
        return TRANSIENT_TITLE_WORDS.any { lower.contains(it.lowercase()) }
    }

    // ---- OCR 路径（照抄 ChatCaptureService 的 B-stage 分支） ----------------
    // Everything here runs on the main thread: the screenshot callback and the
    // ML Kit callback are both posted back to it.

    private val screenCapture by lazy {
        // 旧服务在这里传 overlay 的隐藏/恢复回调：整屏兜底的截图不把悬浮卡拍
        // 进去（ScreenCapture 的 hideOverlay/restoreOverlay 只在整屏路线上用）。
        // overlay 已移植（见 [overlay]），接上；窗口不在屏上时 setHiddenForShot
        // 是 no-op。
        ScreenCapture(
            this,
            hideOverlay = { overlay.setHiddenForShot(true) },
            restoreOverlay = { overlay.setHiddenForShot(false) },
        )
    }
    private val ocr = MlKitOcr()
    private var ocrBusy = false

    /**
     * OCR 的硬兜底。`ocrBusy` 的复位写在每个回调出口上，而截图/识别回调本身
     * 可能因为服务被解绑、Bitmap 回收、系统把截图请求吞掉而永远不来——那样
     * `ocrBusy` 就永久停在 true，之后每一次 OCR 兜底都在开头静默 return。
     * 照抄旧服务的 ocrWatchdog。
     */
    private val ocrWatchdog = Runnable {
        if (!ocrBusy) return@Runnable
        Trace.log("ocr watchdog: releasing stuck ocrBusy")
        ocrBusy = false
    }

    private fun armOcrWatchdog() {
        main.removeCallbacks(ocrWatchdog)
        main.postDelayed(ocrWatchdog, 30_000L)
    }

    /**
     * What the screen would look like to a camera, as far as the tree can tell.
     * 照抄旧服务 ocrSignature（1210-1216 行）。
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
     * the whole screen (everything else). 照抄 ocrCapture（1223-1263 行），
     * overlay/编排调用替换成对 Dart 的回话。
     */
    private fun ocrCapture(treeTitle: String?, rects: List<BubbleRect>, pkg: String, manual: Boolean) {
        if (ocrBusy || destroyed) {
            if (manual) replyManualOcr(null)
            return
        }
        val token = session.token() ?: run {
            if (manual) replyManualOcr(null)
            return
        }
        if (!session.accepts(token)) {
            if (manual) replyManualOcr(null)
            return
        }
        ocrBusy = true
        armOcrWatchdog()
        screenCapture.capture(shouldCapture = { session.accepts(token) }) { res ->
            if (!session.accepts(token)) {
                if (res is ScreenCapture.Result.Ok) res.bitmap.recycle()
                ocrBusy = false
                if (manual) replyManualOcr(null)
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
                    // 旧服务把失败文案显示到卡上；本插件只把结果（null）回给 Dart。
                    if (manual) replyManualOcr(null)
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

    private fun ocrByRects(
        bmp: Bitmap,
        rects: List<BubbleRect>,
        title: String?,
        pkg: String,
        token: ConversationSession.Token,
        speakers: List<String>? = null,
        manual: Boolean = false,
        voiceBoxes: List<WeChatBubbles.Box>? = null,
    ) {
        val sx = ocr.scaleX; val sy = ocr.scaleY
        // Screen -> bitmap: drop the window origin first. A window shot does not
        // start at (0,0) in split screen or when it excludes the status bar.
        val ox = ocr.originX; val oy = ocr.originY
        val out = arrayOfNulls<Msg>(rects.size)
        val voiceDetected = BooleanArray(rects.size)
        val voiceTranscriptRead = BooleanArray(rects.size)
        var remaining = rects.size

        fun finishBubble(index: Int, text: String) {
            if (text.isNotEmpty()) {
                val bubble = rects[index]
                val speaker = speakers?.getOrNull(index)
                out[index] = Msg(
                    speaker ?: bubble.side,
                    text,
                    sender = speaker?.takeIf { it.startsWith("member:") }?.removePrefix("member:")
                )
            }
            remaining--
            if (remaining == 0) {
                runCatching { bmp.recycle() }
                val unreadableVoice = voiceDetected.indices.any { voiceDetected[it] && !voiceTranscriptRead[it] }
                val note = if (unreadableVoice) {
                    WECHAT_VOICE_TRANSCRIPT_NOTE
                } else null
                val latestIndex = rects.lastIndex
                val blockAnalysis = latestIndex >= 0 && WeChatVoiceText.shouldBlockAnalysis(
                    latestBubbleIsIncoming = voiceBoxes?.getOrNull(latestIndex)?.side == "other",
                    latestBubbleIsVoice = voiceDetected[latestIndex],
                    latestVoiceHasTranscript = voiceTranscriptRead[latestIndex]
                )
                finishOcrSnapshot(
                    ChatSnapshot(title, out.filterNotNull(), note = note),
                    pkg, manual, token, blockAnalysis
                )
            }
        }

        rects.forEachIndexed { i, br ->
            val region = Rect(
                ((br.rect.left - ox) * sx).toInt(), ((br.rect.top - oy) * sy).toInt(),
                ((br.rect.right - ox) * sx).toInt(), ((br.rect.bottom - oy) * sy).toInt())
            ocr.recognize(bmp, region) { lines ->
                val recognized = OcrGrouping.cleanBubbleText(lines.joinToString(" ") { it.text })
                val text = if (pkg == WECHAT_PKG) {
                    WeChatVoiceText.stripDurationLabels(recognized)
                } else recognized
                val voiceBox = voiceBoxes?.getOrNull(i)
                if (pkg == WECHAT_PKG && voiceBox != null && WeChatVoiceText.isDurationLabel(recognized)) {
                    voiceDetected[i] = true
                    val transcriptRegion = weChatTranscriptRegion(voiceBoxes, i, bmp.width, bmp.height)
                    if (transcriptRegion == null) {
                        finishBubble(i, "")
                    } else {
                        ocr.recognize(bmp, transcriptRegion) { transcriptLines ->
                            val transcript = OcrGrouping.cleanBubbleText(
                                transcriptLines.joinToString(" ") { it.text }
                            ).let(WeChatVoiceText::stripDurationLabels)
                            voiceTranscriptRead[i] = transcript.isNotEmpty()
                            finishBubble(i, transcript)
                        }
                    }
                } else {
                    finishBubble(i, text.takeUnless(WeChatVoiceText::isDurationLabel).orEmpty())
                }
            }
        }
    }

    /**
     * WeChat places its built-in voice transcript below the voice bubble. Read
     * only that adjacent area after OCR identifies a duration label; never fetch
     * or upload the audio itself. 照抄旧服务 weChatTranscriptRegion（1482-1503 行）。
     */
    private fun weChatTranscriptRegion(
        boxes: List<WeChatBubbles.Box>,
        index: Int,
        width: Int,
        height: Int,
    ): Rect? {
        val box = boxes.getOrNull(index) ?: return null
        val top = box.top
        val nextBubbleTop = boxes.asSequence().drop(index + 1)
            .map { it.top }
            .filter { it > box.bottom }
            .minOrNull() ?: Int.MAX_VALUE
        val bottom = minOf(
            (height * BOTTOM_CROP).toInt(),
            box.bottom + (height * 0.16f).toInt(),
            nextBubbleTop - 1
        )
        if (bottom - top < 8) return null
        val left = if (box.side == "other") box.left else (width * 0.08f).toInt()
        val right = if (box.side == "other") (width * 0.92f).toInt() else box.right
        return Rect(left.coerceIn(0, width - 1), top, right.coerceIn(1, width), bottom)
    }

    /** Whole screen minus the top bar and the input area, grouped by line gaps.
     *  照抄旧服务 ocrWholeScreen（1506-1542 行）。 */
    private fun ocrWholeScreen(bmp: Bitmap, treeTitle: String?, pkg: String, manual: Boolean, token: ConversationSession.Token) {
        val region = Rect(0, (bmp.height * TOP_CROP).toInt(), bmp.width, (bmp.height * BOTTOM_CROP).toInt())
        // The same pixel pass that powers WeChat runs here for EVERY app. A flat
        // screen read is the only source of text on this path, but it is not the
        // only source of SIDES: the boxes tell who is on which side. Filing every
        // line as "other" (the old behaviour) is what turned a screen full of my
        // own messages into an incoming conversation and produced advice for
        // answering myself. Boxes are in bitmap coordinates, exactly like the OCR
        // line bounds, so they compare directly.
        // 像素扫描不压主线程（见 [pixelWorker]），算完回主线程再进 OCR。
        pixelWorker.execute {
            val boxes = runCatching {
                val px = IntArray(bmp.width * bmp.height)
                bmp.getPixels(px, 0, bmp.width, 0, 0, bmp.width, bmp.height)
                WeChatBubbles.find(px, bmp.width, bmp.height)
            }.getOrDefault(emptyList())
            main.post {
                if (destroyed) { runCatching { bmp.recycle() }; return@post }
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
                    Trace.log(
                        "ocr whole boxes=${boxes.size} msgs=${msgs.size} me=${msgs.count { it.side == "me" }} " +
                            "other=${msgs.count { it.side == "other" }} unknown=$unknown"
                    )
                    val title = treeTitle?.takeIf { it.isNotBlank() }
                        ?: lines.firstOrNull()?.text?.trim()?.take(24)
                    finishOcrSnapshot(ChatSnapshot(title, msgs, note = note), pkg, manual, token)
                }
            }
        }
    }

    /** Shared tail of both OCR paths: dedupe, then emit or reply. 照抄
     *  finishOcrSnapshot（1545-1595 行），jev/overlay 替换为直接发快照。 */
    private fun finishOcrSnapshot(
        raw: ChatSnapshot,
        pkg: String,
        manual: Boolean,
        token: ConversationSession.Token,
        blockAnalysis: Boolean = false,
    ) {
        ocrBusy = false
        if (!session.accepts(token)) {
            if (manual) replyManualOcr(null)
            return
        }
        // 来源在**唯一的公共尾部**盖一次章：三条 OCR 出口（微信像素、按气泡、
        // 整屏）都不用各自记得写 provenance，也就不会有一个漏掉。
        val snapshot = raw.copy(provenance = Provenance.OCR)
        // Counts only — OCR'd chat text never goes to logcat.
        Log.i(TAG, "ocr[$pkg] msgs=${snapshot.messages.size} manual=$manual")
        Trace.log(
            "ocr pkg=$pkg provenance=${snapshot.provenance} msgs=${snapshot.messages.size} manual=$manual sides=" +
                snapshot.messages.joinToString(",") { "${it.side}:${it.text.length}" }
        )
        if (snapshot.messages.isEmpty()) {
            // 旧服务在卡上提示「这一屏没认出文字」；本插件对手动请求回 null。
            if (manual) replyManualOcr(null)
            return
        }
        // TODO(port): 待接 —— 旧服务在这里过 prefs.isAllowed 白名单；插件无 Prefs。
        if (pkg.isNotEmpty() && pkg != activePkg) {
            activePkg = pkg
            lastSignature = ""
        }
        if (blockAnalysis) {
            // 微信语音无转写的拦截分支（旧服务在卡上提示并跳过分析）。本服务的
            // OCR 入口到不了这里（语音路径随微信像素入口未移植），保留旧逻辑
            // 形状；手动请求仍把读到的内容回给 Dart。
            if (manual) replyManualOcr(snapshotJson(snapshot))
            return
        }
        val sig = snapshot.signature()
        // Manual taps always reply; the automatic path dedupes like the tree path.
        if (!manual && sig == lastSignature) return
        lastSignature = sig
        emitSnapshot(snapshot)
        if (manual) replyManualOcr(snapshotJson(snapshot))
    }

    // ---- 发射与序列化 ------------------------------------------------------

    /** 签名去重后经 EventChannel 发出；保留最近一条给晚连接的 Dart 补发。 */
    private fun emitSnapshot(snapshot: ChatSnapshot) {
        val json = snapshotJson(snapshot)
        pendingLatestJson = json
        val sink = eventSink
        if (sink != null) runCatching { sink.success(json) }
    }

    /**
     * 快照 → JSON：`title/note/provenance/confidence/uncertain?/messages[{side,text}]`。
     * message 只带 side/text 两字段。bubbleRects 不再序列化：Dart 侧解析从不消费
     * 它（Dart 的 ChatSnapshot 没有该字段），气泡矩形只在服务进程内供 OCR 签名/
     * 裁剪使用。confidence/uncertain 是 G3 通道契约字段，算法见 [snapshotConfidence]；
     * uncertain 只在有原因时发（Dart 侧把「无字段」解析成空表，不破旧 JSON）。
     */
    private fun snapshotJson(s: ChatSnapshot): String {
        val o = JSONObject()
        o.put("title", s.title ?: JSONObject.NULL)
        o.put("note", s.note ?: JSONObject.NULL)
        o.put("provenance", s.provenance)
        val (confidence, uncertain) = snapshotConfidence(s)
        o.put("confidence", confidence)
        if (uncertain.isNotEmpty()) {
            val labels = JSONArray()
            for (label in uncertain) labels.put(label)
            o.put("uncertain", labels)
        }
        val msgs = JSONArray()
        for (m in s.messages) {
            val mo = JSONObject()
            mo.put("side", m.side)
            mo.put("text", m.text)
            msgs.put(mo)
        }
        o.put("messages", msgs)
        return o.toString()
    }

    // ---- 悬浮窗（overlay）--------------------------------------------------
    // 移植自旧仓库 OverlayController（见 overlay/OverlayController.kt）。旧编排
    // 层「服务端跑 jev 轮次 → 推结果上卡」在这里换成「Dart 经 control 通道
    // showSuggestions 推候选」：悬浮窗只做展示，不调模型。候选上的「填入/复制」
    // 按钮经 [emitOverlayAction] 回到 Dart，由 Dart 决定回填还是复制。

    /** 展示层悬浮窗。惰性创建；窗口本身只在 showSuggestions 时加到 WindowManager。 */
    private val overlay: OverlayController by lazy {
        OverlayController(applicationContext).apply {
            onOverlayAction = { action, index -> emitOverlayAction(action, index) }
        }
    }

    /** showSuggestions 的载荷解析：{list:[{text,strategy,prob}], title}。 */
    private fun parseSuggestions(call: MethodCall): List<OverlayController.Suggestion> =
        call.argument<List<*>>("list").orEmpty().mapNotNull { item ->
            (item as? Map<*, *>) ?: return@mapNotNull null
            val text = item["text"] as? String ?: return@mapNotNull null
            OverlayController.Suggestion(
                text = text,
                strategy = item["strategy"] as? String ?: "",
                prob = (item["prob"] as? Number)?.toDouble() ?: 0.0,
            )
        }

    /**
     * 悬浮窗「填入/复制」按钮 → Dart：{type:'overlay_action', action, index}，
     * 走快照 EventChannel（capture_android/snapshots）。Dart 侧按 type 分流
     * （见 capture_android.dart），index 按最近一次 showSuggestions 的列表解释。
     */
    private fun emitOverlayAction(action: String, index: Int) {
        val o = JSONObject()
        o.put("type", "overlay_action")
        o.put("action", action)
        o.put("index", index)
        val sink = eventSink
        if (sink == null) {
            Trace.log("overlay action dropped (dart not listening): $action #$index")
            return
        }
        runCatching { sink.success(o.toString()) }
    }

    // ---- MethodChannel: capture_android/control ----------------------------

    /** 手动 OCR（manualOcr）的挂起结果；finishOcr/失败路径里恰好回一次。 */
    private var manualOcrResult: MethodChannel.Result? = null

    /**
     * fix(kimi-review #3)：refill 的挂起结果（集合登记，可并发）。GuardedInputWriter
     * 的重试链由 main.postDelayed 驱动、对每个 result 恰好一次 complete；onDestroy
     * 的 removeCallbacksAndMessages(null) 会把 pending 重试一并杀掉，没人再回话，
     * Dart 侧 await refill 永久悬挂（剪贴板兜底、收卡都不执行）。这里登记每个
     * in-flight 的 result，onDestroy 清回调前先逐个替它回 false。
     * 恰好一次的保证全在主线程上：完成回调先从集合移除（remove 返回 false =
     * onDestroy 已代为回过）再回话；挂起期间只有主线程读写本集合，无并发。
     * fill 的 isCurrent 静默返回路径（不回话）从 refill 不可达——accepts 检查
     * 与它同主线程紧邻；即便如此 onDestroy 的兜底也只会回一次 false，不悬挂。
     */
    private val pendingRefillResults = mutableSetOf<MethodChannel.Result>()

    private fun replyManualOcr(json: String?) {
        val r = manualOcrResult ?: return
        manualOcrResult = null
        runCatching { r.success(json) }
    }

    private fun handleControl(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configure" -> {
                val pkgs = call.argument<List<*>>("packages")
                    ?.filterIsInstance<String>()?.toSet() ?: emptySet()
                ServiceConfig.configuredPackages = pkgs
                // 黑名单（p0-plan ⑦）：键在（哪怕空集——用户在 UI 清空了清单）就
                // 整体替换；键缺省（旧调用方没传）保留当前值不重置。
                call.argument<List<*>>("blocked")?.let { blocked ->
                    ServiceConfig.blockedPackages = blocked.filterIsInstance<String>().toSet()
                }
                ServiceConfig.ocrFallbackEnabled = call.argument<Boolean>("ocrFallback") ?: false
                Trace.log(
                    "configure pkgs=${pkgs.size} " +
                        "blocked=${ServiceConfig.blockedPackages.size} " +
                        "ocrFallback=${ServiceConfig.ocrFallbackEnabled}"
                )
                result.success(true)
            }
            "isRunning" -> result.success(CapturePresence.live)
            "openAccessibilitySettings" -> {
                val ok = runCatching {
                    startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    true
                }.getOrDefault(false)
                result.success(ok)
            }
            "refill" -> refill(call, result)
            "manualOcr" -> manualOcr(call, result)
            // 服务活着（通道由 CaptureService 注册）才谈得上悬浮窗；窗口加不出
            // （无 SYSTEM_ALERT_WINDOW 权限）回 false，由 Dart 提示去开权限。
            "showSuggestions" -> {
                val ok = runCatching {
                    // B8 展示模式随候选透传（'primary' 主推大卡+备选折叠，
                    // null/'all' 整列平铺——移植期默认行为）。
                    overlay.showSuggestions(
                        parseSuggestions(call),
                        call.argument<String>("title"),
                        call.argument<String>("mode"),
                    )
                }.getOrDefault(false)
                Trace.log("overlay showSuggestions ok=$ok")
                result.success(ok)
            }
            "hideSuggestions" -> {
                runCatching { overlay.hideSuggestions() }
                result.success(true)
            }
            // 只收卡不撤窗（遗留 low：与 Dart「填入成功后折回胶囊」语义统一）：
            // 候选卡折回胶囊、窗口留在屏上；整窗移除仍是 hideSuggestions。
            "collapse" -> {
                runCatching { overlay.collapseSuggestions() }
                result.success(true)
            }
            // G2 能力查询：{pkg} → 能力表（Map）；未适配包回 null。control 通道
            // 由服务注册——服务未连接时整条通道不存在，Dart 连上后取一次缓存即可
            // （能力表是静态数据）。
            "getCapabilities" -> result.success(capabilitiesFor(call.argument<String>("pkg")))
            // fix(kimi-review #11)：悬浮窗防截屏开关。窗口未建（悬浮窗还没弹出）
            // 时 OverlayController.setSecure 先记状态，ensureWindow 建窗时按它补
            // FLAG_SECURE；窗口在屏上则即时 updateViewLayout（其内部 runCatching，
            // 加 flag 失败只记日志）。参数是 bool 本身（见 [SET_SECURE_METHOD]）。
            SET_SECURE_METHOD -> {
                overlay.setSecure(call.arguments as? Boolean ?: false)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun refill(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text")
        val token = session.token()
        if (text == null || token == null || !session.accepts(token)) {
            result.success(false)
            return
        }
        // 填入是唯一要写别的 App 输入框的动作：InputFiller 内部每一步重解析来源
        // 会话（fill(token, text) 的第一条就是 isCurrent 检查，与本处同一谓词、
        // 同一主线程，不会在检查通过后又被拒）。
        // fix(kimi-review #3)：登记挂起结果；完成时先解除登记再回话（解除失败 =
        // onDestroy 已代回 false），onDestroy 就不会把已回复的 result 再回一遍
        // （恰好一次）。
        pendingRefillResults.add(result)
        filler.fill(token, text) { ok ->
            if (!pendingRefillResults.remove(result)) return@fill
            runCatching { result.success(ok) }
        }
    }

    private fun manualOcr(call: MethodCall, result: MethodChannel.Result) {
        val root = rootInActiveWindow
        val pkg = root?.packageName?.toString() ?: foregroundPkg ?: activePkg ?: ""
        // WhatsApp 等永不截屏的应用：手动 OCR 也拒绝（照抄 ocrCaptureManual）。
        if (ChatApps.forPackage(pkg)?.allowScreenshot == false) {
            result.success(null)
            return
        }
        // Top bar text, if this app has one we can read; else the first OCR line.
        val title = root?.let {
            findTitleInActionBar(
                it, Int.MAX_VALUE, resources.displayMetrics.widthPixels,
                resources, 0.15, 0.85
            )
        }
        val target = root?.let { targetFor(it) }
        if (target == null) {
            result.success(null)
            return
        }
        observeTarget(target)
        // 上一次挂起的手动请求作废（恰好回一次的保证）。
        if (manualOcrResult != null) replyManualOcr(null)
        manualOcrResult = result
        ocrCapture(title, emptyList(), pkg, manual = true)
    }

    // ---- 回填 --------------------------------------------------------------

    /**
     * fix(kimi-review #13)：回填路径 targetOf 的提取 memo（[TargetMemo]）。
     * 提取本体仍是 [targetFor]；失效钩子在 [onAccessibilityEvent]——每条
     * WINDOW_STATE_CHANGED / WINDOW_CONTENT_CHANGED 事件都清，树静默期内
     * 同窗（pkg+windowId）的重复提取直接复用。
     */
    private val targetMemo = TargetMemo { root -> targetFor(root) }

    private val filler: InputFiller by lazy {
        InputFiller(object : InputFiller.Host {
            override fun activeRoot(): AccessibilityNodeInfo? = rootInActiveWindow
            // fix(kimi-review #13)：Host 层 memo——原 InputFiller 内按 root 实例
            // 引用的缓存永不命中（框架每次 getRootInActiveWindow 都给新实例）。
            override fun targetOf(root: AccessibilityNodeInfo): ConversationSession.Target? =
                targetMemo.targetOf(root)

            override fun isCurrent(token: ConversationSession.Token): Boolean = session.accepts(token)
            override fun post(delayMs: Long, action: () -> Unit) { main.postDelayed({ action() }, delayMs) }
            override fun copyToClipboard(text: String) = this@CaptureService.copyToClipboard(text)
        }, ChatApps::forPackage)
    }

    private fun copyToClipboard(text: String) {
        val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("reply", text))
    }

    // ---- 生命周期 ----------------------------------------------------------

    override fun onServiceConnected() {
        super.onServiceConnected()
        CapturePresence.live = true
        instance = this
        Trace.init(applicationContext)
        flutterMessenger?.let { attachEngineChannels(it) }
        // Load the bundled OCR model now, off the main thread: the first
        // recognize() otherwise pays for it inside the screenshot callback.
        pixelWorker.execute { MlKitOcr.warmUp() }
        // Keep the process at foreground importance so MIUI does not freeze us.
        runCatching { KeepAliveService.start(this) }
        Trace.log(
            "connected ocrFallback=${ServiceConfig.ocrFallbackEnabled} " +
                "pkgs=${ServiceConfig.configuredPackages.size}"
        )
        Log.i(TAG, "capture service connected")
    }

    override fun onInterrupt() {
        // 旧服务：leaveConversation + overlay.hide。无编排层：断开事件流即可；
        // 悬浮窗跟旧服务一样收起——无障碍被打断而服务未销毁期间 sink 已空，
        // 留在屏上的窗口点了没反应（死窗）。恢复后下一轮 showSuggestions 重建。
        eventSink = null
        runCatching { overlay.hide() }
    }

    override fun onUnbind(intent: Intent?): Boolean {
        CapturePresence.live = false
        eventSink = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        destroyed = true
        CapturePresence.live = false
        instance = null
        eventSink = null
        // 服务可以单独被解绑停掉而进程不死：悬浮窗必须跟着服务一起下线。
        runCatching { overlay.hide() }
        // fix(kimi-review #3)：下一行的 removeCallbacksAndMessages(null) 会杀掉
        // GuardedInputWriter 的 pending 重试和未返回的截屏回调——必须先把所有
        // in-flight 的通道 result 收尾（refill 逐个→false、manualOcr→null）再清
        // 回调，否则 Dart 侧 await 永久悬挂。
        for (pending in pendingRefillResults) runCatching { pending.success(false) }
        pendingRefillResults.clear()
        replyManualOcr(null)
        main.removeCallbacksAndMessages(null)
        pixelWorker.shutdownNow()
        super.onDestroy()
    }
}

// ---- G3 采集置信度（K/D 通道契约，定义写死、两侧同源） ----------------------
//
// 通道契约：snapshotJson 的快照 JSON 增加 "confidence"（0.0..1.0，Dart 侧把
// 缺省视为 1.0）与 "uncertain"（原因标签数组，可省略；Dart 侧把缺省解析成空表，
// 旧 JSON 无字段解析不破）。本文件是 Kotlin 侧唯一实现，计算规则：
// - provenance==ocr 基线 0.6，其余（a11y；inject 将来若有）基线 1.0；
// - 每条 unknown-speaker 消息（side 既非 "me" 也非 "other"）-0.1；
// - title 为空（null 或空白）-0.05；
// - 下限 0.2。
// unknown-speaker 的两个已知来源：整屏 OCR 没有像素气泡盖住该行（OcrGrouping
// 的 SIDE_UNKNOWN "？"），微信群聊发言人归属不上（WeChatSpeakerAttribution 的
// "unknown"）；无障碍适配器路径恒为 me/other，不受这条扣分影响。

/** 置信度下限：再差也标 0.2，避免 UI 出现「越差越负」的摆烂值。 */
private const val CONFIDENCE_FLOOR = 0.2

/** OCR 快照基线：正文来自像素而非树，先天就低一档。 */
private const val CONFIDENCE_OCR_BASELINE = 0.6

/** 每条 unknown-speaker 消息的扣分。 */
private const val CONFIDENCE_UNKNOWN_SPEAKER_STEP = 0.1

/** 会话标题为空的扣分（会话身份 = app + window + title，少一要素）。 */
private const val CONFIDENCE_MISSING_TITLE_STEP = 0.05

/** 原因标签：有消息分不清是谁说的（G3：身份不明确宁可拒绝，不猜测）。
 *  标签即展示文案：Dart 侧（capture_session.uncertainReasonsOf）原样透传上卡，
 *  不做映射，所以发中文、不发 snake_case。 */
internal const val UNCERTAIN_UNKNOWN_SPEAKER = "发言人未知"

/** 原因标签：会话标题缺失（同上，直接上卡展示）。 */
internal const val UNCERTAIN_MISSING_TITLE = "标题为空"

/**
 * 快照置信度与不确定原因（G3）。纯函数（无 Android 依赖），由
 * SnapshotConfidenceContractTest 直接钳住契约算术；[snapshotJson] 只负责把结果
 * 装进 JSON。扣分项叠加后不夹上限（基线已是 1.0，只减不增），只夹下限。
 */
internal fun snapshotConfidence(s: ChatSnapshot): Pair<Double, List<String>> {
    var confidence = if (s.provenance == Provenance.OCR) CONFIDENCE_OCR_BASELINE else 1.0
    val uncertain = ArrayList<String>(2)
    val unknownSpeakers = s.messages.count { it.side != "me" && it.side != "other" }
    if (unknownSpeakers > 0) {
        confidence -= CONFIDENCE_UNKNOWN_SPEAKER_STEP * unknownSpeakers
        uncertain += UNCERTAIN_UNKNOWN_SPEAKER
    }
    if (s.title.isNullOrBlank()) {
        confidence -= CONFIDENCE_MISSING_TITLE_STEP
        uncertain += UNCERTAIN_MISSING_TITLE
    }
    return maxOf(CONFIDENCE_FLOOR, confidence) to uncertain
}

package com.jev.probe.module

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import com.jev.probe.bridge.BridgePayload
import com.jev.probe.bridge.BridgeTransport
import com.jev.probe.bridge.InjectTimeline
import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Msg
import com.jev.probe.core.Provenance
import de.robv.android.xposed.XC_MethodHook
import de.robv.android.xposed.XposedBridge
import de.robv.android.xposed.XposedHelpers
import java.lang.ref.WeakReference
import java.lang.reflect.Field
import java.lang.reflect.Method
import java.util.concurrent.ConcurrentHashMap

/**
 * S3 的 L1 读取钩子：在**用户明确给这个 App 开了注入**的前提下，把聊天页
 * 当前那段消息读成 [Msg] 列表，推给本 App（[BridgeTransport.snapshot]）。
 *
 * 这是整个项目里唯一一处「运行在目标 App 进程里、读它的内存对象」的代码，
 * 所以每一条设计都围绕「不许把宿主弄坏」：
 *
 *  - **只读**：只 `get`/调用取值，绝不 `set`、绝不调用任何会改状态的方法。
 *    读的是宿主**已经构造好的对象**，不自己开文件、不碰数据库、不要密钥。
 *  - **不阻塞**：整个读取挂在宿主主线程的一个 1 秒 tick 上，单次只扫最后
 *    [READ_WINDOW] 条；推送是单向广播（fire-and-forget），发出去就不管了。
 *  - **只在自己开的页面上干活**：只在聊天页处于 resumed 时 tick，pause 就停。
 *    「是不是聊天页」先看类名（`org.telegram.ui.ChatActivity`），类名不匹配时再看
 *    结构（窗口里有没有「输入消息」的输入框）—— 真机上见过聊天页挂在
 *    `LaunchActivity` 上的情况，只看类名会一条都推不上来（见 [isChat]）。
 *  - **失败了就当没装**：任何异常都咽掉、记一行类名，退回无障碍（L0）。读不
 *    到消息不是错误，是这条能力阶梯的正常一档。
 *  - **不猜**：见 [TelegramMessage] —— 拿不准的消息整条丢掉，宁少不错。
 *
 * 不 import 宿主的任何类（全靠 ClassLoader 里的名字 + 反射），所以 Telegram
 * 换版本时最坏的结果是「读不到 → 退回 L0」，而不是模块加载期就崩掉。
 */
internal object TelegramInjector {

    /** 只认类名，不 import：宿主改包名/换实现时我们从「读不到」开始，而不是从崩溃开始。 */
    private const val CHAT_ACTIVITY = "org.telegram.ui.ChatActivity"

    private const val TICK_MS = 1_000L

    /**
     * 不在聊天页时的探测间隔。真机教训：这台手机的 Telegram 把聊天列表和聊天页
     * 渲染在同一个 Activity 上，从列表点进会话**不会**产生新的 resume；只要停止
     * tick，就再也没有机会发现聊天页。所以不在聊天页时也继续探测，只是放慢到 3 秒。
     */
    private const val IDLE_TICK_MS = 3_000L

    /** 结构判据的 View 树遍历上限（聊天页的树很大，防病态情况）。 */
    private const val VIEW_WALK_BUDGET = 2000

    /** 一次最多看多少条（从最新往回）。 */
    private const val READ_WINDOW = 60

    /** 单条正文的硬上限：遇到过超长粘贴，不让它把 payload 撑爆。 */
    private const val MAX_TEXT = 2_000

    private val main = Handler(Looper.getMainLooper())

    /** 生命周期钩子只装一次（[track]）。 */
    private var hooked = false

    /**
     * 用户是否给这个 App 开了注入。**默认关**：关着的时候钩子只记一个弱引用，
     * 不读、不推、不打日志。
     */
    @Volatile private var enabled = false
    private var context: Context? = null
    private var pkg: String = ""
    private var session: ModuleSession? = null
    private var log: (String) -> Unit = {}

    private var active = WeakReference<Activity>(null)

    /**
     * 直接钩住的聊天页对象（`org.telegram.ui.ChatActivity` 的生命周期回调给的）。
     *
     * 为什么要有这一手：聊天的消息只在**这个对象**身上（字段 `chatAdapter` /
     * `messages`），而「怎么从 Activity 走到它」是宿主内部拓扑 —— 真机上
     * `LaunchActivity.actionBarLayout.getFragmentStack()` 在 12.10.1 里时对时不对
     * （点进会话的那一刻栈里只有 `MainTabsActivity`，靠它反推会整个读不到）。
     * 生命周期钩子直接把对象递到手里，不用猜。`onPause`/`onFragmentDestroy` 清掉
     * 时才算「离开了聊天页」，避免拿一个已经退出的会话继续推。
     */
    private var currentChat = WeakReference<Any>(null)

    /** 生命周期诊断只打前几条（够看出「钩子到底有没有被调到」就行，不刷屏）。 */
    private var lifeLogs = 0
    private var lastSignature = ""
    private var lastResumeAct: String? = null
    private var lastFailure = ""
    private var pushed = 0
    private var ticks = 0
    private var lastSource = "-"

    /** 上一次 tick 时「当前是聊天页」吗 —— 决定下一次 tick 是 1 秒还是 [IDLE_TICK_MS]。 */
    private var chatActive = false
    private val senderNames = ConcurrentHashMap<Long, String>()

    private val tick = object : Runnable {
        override fun run() {
            val activity = active.get() ?: return
            if (activity.isFinishing || activity.isDestroyed) return
            val started = android.os.SystemClock.uptimeMillis()
            try {
                once(activity)
            } catch (t: Throwable) {
                // 宿主主线程上抛异常 = 宿主闪退。咽掉，同一类错只记一次，避免刷屏。
                val kind = t.javaClass.name
                if (kind != lastFailure) {
                    lastFailure = kind
                    ModuleLog.fail("tg.tick", t)
                }
            }
            val cost = android.os.SystemClock.uptimeMillis() - started
            if (cost > 50L) ModuleLog.log("tg", "slow cost=${cost}ms src=$lastSource")
            // 不在聊天页也继续低频探测：本机 Telegram 的聊天列表和聊天页共用同一个
            // Activity，切页面根本不产生新的 resume，一旦停 tick 就再也不会开始。
            main.postDelayed(this, if (chatActive) TICK_MS else IDLE_TICK_MS)
        }
    }

    /**
     * 只装**生命周期观察**，不读任何内容：必须在问开关（`gate`）之前调用。
     *
     * 真机教训：桥上的 gate 是一次有序广播，模块侧要等本 App 答复，真机上大约
     * 700ms；宿主第一个 Activity 的 onResume 往往就落在这段时间里。如果等开关
     * 答复回来才装钩子，之后就再也不会收到任何 resume —— 模块活得好好的，却永远
     * 等不到聊天页（正是这一轮卡住的原因）。所以这里无条件挂上、只记「前台是哪个
     * Activity」；**开不开读取由 [enable] 决定**，关着的时候这里什么都不做。
     */
    fun track(loader: ClassLoader) {
        if (hooked) return
        hooked = true
        hookChatLifecycle(loader)
        XposedBridge.hookAllMethods(
            Instrumentation::class.java,
            "callActivityOnResume",
            object : XC_MethodHook() {
                override fun afterHookedMethod(param: MethodHookParam) {
                    val activity = param.args?.firstOrNull() as? Activity ?: return
                    // 只存一个弱引用，不读任何内容 —— 开关关着时这就是全部动作。
                    active = WeakReference(activity)
                    if (!enabled) return
                    // 诊断（S3）：注入层没命中时不能静默 —— 记下真正 resume 的类名，
                    // 换了类才记一次，避免刷屏。类名不是聊天内容，落框架日志无隐私问题。
                    // 这一行是「为什么没推上来」的唯一证据来源：看不到它 = 钩子没挂上，
                    // 看得到但 chat=false = 宿主的聊天页不叫 ChatActivity。
                    val name = activity.javaClass.name
                    if (name != lastResumeAct) {
                        lastResumeAct = name
                        ModuleLog.log("tg", "resume act=$name chat=${isChat(activity)}")
                    }
                    // 任何 Activity 都接管：不是「只有聊天页才 tick」。真正的判据交给
                    // tick 里的 isChat（类名 + 结构），因为同一台手机上聊天页可能和
                    // 聊天列表共用同一个 Activity。
                    onResume(activity)
                }
            }
        )
        XposedBridge.hookAllMethods(
            Instrumentation::class.java,
            "callActivityOnPause",
            object : XC_MethodHook() {
                override fun beforeHookedMethod(param: MethodHookParam) {
                    if (!enabled) return
                    val activity = param.args?.firstOrNull() as? Activity ?: return
                    onPause(activity)
                }
            }
        )
    }

    /**
     * 直接钩住聊天页的生命周期，把「当前聊天页对象」拿到手。
     *
     * `Class.forName(name, false, loader)` 只解析不初始化类 —— 宿主还没加载
     * ChatActivity 时这一手照样能挂上钩子。挂不上不影响其它路径（[fragmentsOf]
     * 那条还在，只是更脆），但会记一行日志：**「钩子没装上」和「装上了读不到」
     * 是两种完全不同的故障**，不能长得一样。
     */
    private fun hookChatLifecycle(loader: ClassLoader) {
        val chat = runCatching { Class.forName(CHAT_ACTIVITY, false, loader) }.getOrNull()
        if (chat == null) {
            ModuleLog.log("tg", "chat class missing=$CHAT_ACTIVITY（回落 fragment 栈）")
            return
        }
        val resume = object : XC_MethodHook() {
            override fun afterHookedMethod(param: MethodHookParam) {
                val obj = param.thisObject ?: return
                // 沿继承链挂钩会把 BaseFragment.onResume 也挂上（每个 fragment 都过这里），
                // 所以要按类名筛出聊天页自己。
                if (isChatClass(obj.javaClass.name)) {
                    currentChat = WeakReference(obj)
                    if (lifeLogs < 6) {
                        lifeLogs++
                        ModuleLog.log("tg", "chat live cls=${obj.javaClass.name}")
                    }
                } else if (lifeLogs < 12) {
                    // 诊断：把「非聊天页的 fragment resume」也记几条。钩子到底有没有被调到，
                    // 只有这一行能回答 —— 没有它，「没进聊天页」和「钩子没生效」长得一样。
                    lifeLogs++
                    ModuleLog.log("tg", "frag resume ${obj.javaClass.name}（非聊天页）")
                }
            }
        }
        val born = object : XC_MethodHook() {
            override fun afterHookedMethod(param: MethodHookParam) {
                val obj = param.thisObject ?: return
                // `<init>` 沿继承链挂会把 BaseFragment 的构造也挂上（所有 fragment 都过），
                // 所以同样只认聊天页自己。
                if (!isChatClass(obj.javaClass.name)) return
                currentChat = WeakReference(obj)
                if (lifeLogs < 12) {
                    lifeLogs++
                    ModuleLog.log("tg", "chat born cls=${obj.javaClass.name}")
                }
            }
        }
        val gone = object : XC_MethodHook() {
            override fun beforeHookedMethod(param: MethodHookParam) {
                val obj = param.thisObject ?: return
                // 只清「就是这一个」：别把别处刚设上的新会话抹掉。
                if (currentChat.get() === obj) currentChat = WeakReference(null)
            }
        }
        var n = hookHierarchy(chat, "onResume", resume)
        n += hookHierarchy(chat, "<init>", born)
        for (name in listOf("onPause", "onFragmentDestroy")) n += hookHierarchy(chat, name, gone)
        // 把**挂上了几个方法**记下来：`XposedBridge.hookAllMethods` 只认本类声明的方法，
        // 子类没覆写 `onResume` 时它一个都不挂却也不报错 —— 上一版就是这样「成功」地
        // 什么都没挂上。数量为 0 和数量大于 0 是两种完全不同的故障。
        ModuleLog.log("tg", "armed chat=ChatActivity lifecycle(live) methods=$n")
    }

    /**
     * 沿继承链把某个方法名的**所有声明**都挂上，返回真正挂上的个数。
     *
     * 不能用 `XposedBridge.hookAllMethods(clazz, name, …)`：它只看 `clazz` 自己
     * 声明的成员，父类里的 `onResume` 看不到，而且挂零个也不报错。
     */
    private fun hookHierarchy(target: Class<*>, name: String, cb: XC_MethodHook): Int {
        var n = 0
        val seen = HashSet<Method>()
        var cls: Class<*>? = target
        while (cls != null && cls != Any::class.java) {
            val current: Class<*> = cls
            for (m in runCatching { current.declaredMethods }.getOrNull().orEmpty()) {
                if (m.name != name || !seen.add(m)) continue
                if (runCatching { XposedBridge.hookMethod(m, cb) }.isSuccess) n++
            }
            cls = current.superclass
        }
        return n
    }

    /** 开关答复为「开」之后启用读取：这一行日志就是 S3 的验收标记。 */
    fun enable(ctx: Context, target: String, session: ModuleSession, sink: (String) -> Unit) {
        if (enabled) return
        context = ctx.applicationContext ?: ctx
        pkg = target
        this.session = session
        log = sink
        enabled = true
        ModuleLog.log("tg", "armed hook=Instrumentation.resume/pause window=$READ_WINDOW tick=${TICK_MS}ms")
        // 补一次：答复回来之前已经 resume 过的那个 Activity，钩子当时还没启用。
        active.get()?.let { onResume(it) }
    }

    private fun isChatClass(name: String): Boolean =
        name == CHAT_ACTIVITY || name.endsWith(".ChatActivity")

    private fun isChat(activity: Activity): Boolean {
        val name = activity.javaClass.name
        if (isChatClass(name)) return true
        // 最可靠的一条：直接钩住聊天页时，宿主的生命周期会告诉我们「它现在就在前台」。
        // 它一 onPause/onFragmentDestroy 就被清掉，所以「非空」= 真的在聊天页。
        if (currentChat.get() != null) return true
        // 类名不够用（真机教训）：这台手机上的 Telegram 12.10.1 在聊天页处于前台时，
        // `dumpsys activity` 里那个 task 只有 1 个 activity，resumed 的仍然是
        // `org.telegram.ui.LaunchActivity` —— 只看类名会永远 chat=false、一条都推不上来。
        // 聊天页在宿主**自己的** fragment 栈里，所以先问栈，而且**以栈为准**。
        //
        // 真机教训二（2026-10-06）：从聊天页退出来后，聊天页的 View 仍以「缓存视图」
        // 挂在 decor view 上，`hasMessageInput` 的类名判据继续命中 —— 于是人明明在聊天
        // 列表，读数取到的却是上一个会话的适配器。所以 View 树判据只能**加强**，
        // 不能单独把「不是聊天页」翻成「是」。宁可漏判（回落无障碍），不可错判。
        val stack = telegramStackOf(activity).ifEmpty { supportFragmentsOf(activity) }
        if (stack.isNotEmpty()) {
            if (!stack.any { isChatClass(it.javaClass.name) }) return false
            return isChatClass(stack.last().javaClass.name) || hasMessageInput(activity)
        }
        return hasMessageInput(activity)
    }

    /**
     * fragment 栈里最上面那个 `ChatActivity`。Telegram 把整个聊天页做成的是**宿主
     * 自己的** fragment（`org.telegram.ui.ActionBar.BaseFragment`），不是 AndroidX
     * fragment —— 挂在本机 `LaunchActivity` 的 `actionBarLayout` 上，所以 resume 的
     * 永远是 LaunchActivity。「现在是不是聊天页」要问 fragment 栈，而不是问 Activity
     * 的类名（只看类名会永远 chat=false）。
     */
    private fun chatFragmentOf(activity: Activity): Any? =
        fragmentsOf(activity).lastOrNull { isChatClass(it.javaClass.name) }

    /**
     * 窗口里有没有「输入消息」的输入框。只读宿主已经建好的 View 树（不 set 任何东西），
     * 节点数上限 [VIEW_WALK_BUDGET]，找不到就返回 false（= 按老规矩回落无障碍）。
     */
    private fun hasMessageInput(activity: Activity): Boolean {
        val root = runCatching { activity.window?.peekDecorView() }.getOrNull() ?: return false
        var budget = VIEW_WALK_BUDGET
        fun walk(v: View?): Boolean {
            if (v == null || budget <= 0) return false
            budget--
            // 结构信号（比 hint 可靠）：聊天页的输入区是宿主自己的组件类，类名里带
            // ChatActivity（如 org.telegram.ui.Components.ChatActivityEnterView$...），
            // 聊天列表上没有这种 view。输入框里有草稿时 hint 是空的，只看 hint 会漏。
            if (v.javaClass.name.contains("ChatActivity")) {
                noteChatLike(v.javaClass.name)
                return true
            }
            if (v is EditText || v.javaClass.name.contains("EditText")) {
                val hint = runCatching { (v as? EditText)?.hint?.toString() }.getOrNull().orEmpty()
                val desc = runCatching { v.contentDescription?.toString() }.getOrNull().orEmpty()
                val idName = runCatching {
                    if (v.id != View.NO_ID) activity.resources.getResourceEntryName(v.id) else null
                }.getOrNull().orEmpty()
                if (hint.contains("消息") || hint.contains("essage") ||
                    desc.contains("消息") || idName.contains("message")
                ) {
                    // 判据命中的那一环记一次（类名/id 名，都不是聊天内容）：真机上出现
                    // 「聊天列表也被判成聊天页」时，这一行就是唯一能定位的线索。
                    noteChatLike("${v.javaClass.name} hint=$hint desc=$desc id=$idName")
                    return true
                }
            }
            if (v is ViewGroup) {
                for (i in 0 until v.childCount) if (walk(v.getChildAt(i))) return true
            }
            return false
        }
        return walk(root)
    }

    /**
     * 诊断用：判据不中时，把窗口里「像输入框 / 聊天容器」的 View 长什么样记下来。
     * 只收类名、resource id 名、hint 占位文字 —— **绝不含任何聊天内容**。
     * 用途：真机上「明明开着聊天页，判据却是 false」时，这一行是唯一定位依据。
     */
    private fun inputProbe(activity: Activity): String {
        val root = runCatching { activity.window?.peekDecorView() }.getOrNull() ?: return "root=null"
        val eds = ArrayList<String>(3)
        val vgs = ArrayList<String>(5)
        var budget = VIEW_WALK_BUDGET
        fun walk(v: View?) {
            if (v == null) return
            budget--
            if (budget <= 0) return
            val cls = v.javaClass.name
            if (v is EditText || cls.contains("EditText")) {
                if (eds.size < 3) {
                    val id = runCatching {
                        if (v.id != View.NO_ID) activity.resources.getResourceEntryName(v.id) else "-"
                    }.getOrNull().orEmpty()
                    val hint = runCatching { (v as? EditText)?.hint?.toString() }.getOrNull().orEmpty()
                    eds.add("$cls/id=$id/hint=$hint")
                }
            } else if (cls.contains("Enter") || cls.contains("Input") ||
                cls.contains("Chat") || cls.contains("Recycler")
            ) {
                if (vgs.size < 5) vgs.add(cls)
            }
            if (v is ViewGroup) for (i in 0 until v.childCount) walk(v.getChildAt(i))
        }
        walk(root)
        return "ed=[" + eds.joinToString("|") + "] vg=[" + vgs.joinToString("|") + "]"
    }

    private fun onResume(activity: Activity) {
        active = WeakReference(activity)
        // 换了一个会话页就必须重新推一次：指纹是「最后 8 条」，两个会话很可能
        // 撞上同样的尾巴（比如都是「在吗」）。清掉指纹比加会话 id 更简单可靠。
        lastSignature = ""
        main.removeCallbacks(tick)
        main.postDelayed(tick, TICK_MS)
        ModuleLog.log("tg", "resume chat=${activity.javaClass.simpleName}")
    }

    private fun onPause(activity: Activity) {
        if (active.get() !== activity) return
        active = WeakReference(null)
        main.removeCallbacks(tick)
        lastSignature = ""
    }

    /**
     * 退出聊天页时**主动撤回**上一条快照。
     *
     * 不撤回会怎样：App 那边的 `BridgeStore.latest(pkg)` 会一直留着会话 A 的那一条。
     * 用户从 A 退出来、点进会话 B，App 若先抓到的是 A 的快照，分析的就是**另一个
     * 会话的内容**；而如果模块在 B 里读不到东西（读不到就不会推），A 的内容会一直
     * 被当成当前会话。
     *
     * 这条路径**不是无界的**：账本那一层有 TTL（`BridgeContract.MAX_PAYLOAD_AGE_MS`
     * = 120 秒，`BridgeLedger.latest` 里判），所以最坏也只是错两分钟。但两分钟足够
     * 让用户在一个会话里被按另一个会话的内容回答，而撤回能把窗口缩到「切页后的一个
     * tick」。TTL 是兜底，撤回才是准的——只有模块知道人还在不在聊天页。
     *
     * 撤回就是推一条**空快照**（`messages: []`），App 侧把「空」当成「没有数据」处理
     * （否则空快照会顶掉无障碍的那一份，比不撤回更坏）。发不出去就算了：发不出去说明
     * App 被强停或桥断了，那种情况下也不会有新一轮采集。
     */
    private fun retract() {
        val ctx = context ?: return
        val s = session ?: return
        val payload = BridgePayload.render(
            ChatSnapshot(title = null, messages = emptyList(), provenance = Provenance.INJECT)
        )
        val sent = BridgeTransport.snapshot(ctx, pkg, s.boot, s.nextSeq(), s.nowMs(), payload, log)
        // 指纹清掉：再进同一个会话时要重新推一次，否则会被「没变化」挡掉。
        lastSignature = ""
        if (sent) ModuleLog.log("tg", "retract 退出聊天页，已撤回上一条快照")
    }

    private class Read(val messages: List<Msg>, val source: String, val scanned: Int, val chatKey: Long?)

    private fun once(activity: Activity) {
        ticks++
        // 结构性复查：同一个 Activity 里，聊天页和聊天列表是来回切的（本机 Telegram
        // 两种页面共用 LaunchActivity）。所以每一秒都要重新确认「现在还是聊天页」，
        // 不是的话这一轮什么都不做 —— 但**不能停 tick**（见 [IDLE_TICK_MS]），
        // 只把节奏放慢，否则用户从列表点进会话时再也没人来看一眼。
        if (!isChat(activity)) {
            if (chatActive) retract()
            chatActive = false
            // 诊断：判据不中时不能静默 —— 记一次「窗口里长什么样」（只有类名/id/hint，
            // 没有任何聊天内容）。这一行就是「为什么这台机器上读不到」的依据。
            noteMiss("not_chat act=${activity.javaClass.name} ${inputProbe(activity)}")
            return
        }
        chatActive = true
        val read = readMessages(activity, ::noteMiss) ?: return
        if (read.messages.isEmpty()) return
        lastSource = read.source
        // 指纹要带会话身份：本机上从列表点进会话不产生 resume，lastSignature 不会
        // 被清掉；两个会话尾巴一样时（都是「在吗」）光比消息就会漏推。
        val signature = (read.chatKey?.toString() ?: "?") + "|" + InjectTimeline.signature(read.messages)
        if (signature == lastSignature) return
        val ctx = context ?: return
        val s = session ?: return
        val snapshot = InjectTimeline.snapshot(titleOf(activity), read.messages)
        val payload = BridgePayload.render(snapshot)
        val sent = BridgeTransport.snapshot(
            ctx, pkg, s.boot, s.nextSeq(), s.nowMs(), payload, log,
        )
        if (sent) {
            lastSignature = signature
            pushed++
            ModuleLog.log(
                "tg",
                "push src=${read.source} scanned=${read.scanned} msgs=${read.messages.size} " +
                    "chars=${payload.length} pushes=$pushed ticks=$ticks"
            )
        } else {
            // 发不出去（本 App 被强停、或 payload 超限）。指纹不更新，下一秒再试；
            // 但不要每次失败都打一行日志。
            if (pushed == 0 && ticks % 30 == 1) {
                ModuleLog.log("tg", "push failed src=${read.source} msgs=${read.messages.size} chars=${payload.length}")
            }
        }
    }

    /**
     * 读当前会话的消息。四条路，从准到松：
     *  1. 命名适配器字段（`chatAdapter` / `messagesAdapter`）
     *  2. 窗口里 RecyclerView 的 adapter（本机 12.10.1 真正命中的就是这条）
     *  3. 命名列表字段（`messages` / `messagesArrayList` / `messageObjects`）
     *  4. 类型兜底（任何字段，只要最后一条能读成消息）
     *
     * 每条失败路径都往回报一句「为什么读不到」（[miss]）：注入层最大的风险不是崩，
     * 而是**悄悄什么都读不到**，那样用户看到的就是功能没生效却查不出原因。诊断内容
     * 只包含类名、条数、正文长度，永远不含正文本身。
     */
    private fun readMessages(activity: Activity, miss: (String) -> Unit): Read? {
        val tgStack = telegramStackOf(activity)
        val axStack = supportFragmentsOf(activity)
        val fragments = tgStack + axStack
        // 直接钩住的聊天页排在最前面：它的字段就是权威答案，先问它。
        val direct = currentChat.get()
        val hosts = (sequenceOf(activity) +
            (if (direct != null) sequenceOf(direct) else emptySequence()) +
            fragments.asSequence()).toList()
        // 诊断留 8 条：4 条不够用 —— 真机上「三条 RecyclerView + 一条兜底字段」就能把
        // 命名列表字段那一路的失败原因整个挤掉，于是「为什么读不到」又变成了猜。
        val tried = ArrayList<String>(8)

        fun note(s: String) {
            if (tried.size < 8) tried.add(s)
        }

        fun attempt(value: Any?, label: String, strictTail: Boolean = false): Read? {
            if (value == null) return null
            val items = itemsOf(value) ?: run {
                note("$label=no_items")
                return null
            }
            if (items.size <= 0) {
                note("$label=empty")
                return null
            }
            // 松散兜底比命名路径危险得多：一个不相干的 List 字段也可能碰巧含一条能读成
            // 消息的东西，那读出来的就是「别人家的一页」。所以要求**最后一条**一定读得
            // 出来 —— 消息列表的最新一条永远是消息，别的列表没有这个性质。
            if (strictTail) {
                val lastRaw = items.at(items.size - 1)
                if (lastRaw == null || TelegramMessage.read(lastRaw) { null } == null) {
                    note("$label=tail_not_msg")
                    return null
                }
            }
            val from = (items.size - READ_WINDOW).coerceAtLeast(0)
            var key: Long? = null
            val messages = collect(from, items.size, { i -> items.at(i) }) { raw ->
                TelegramMessage.dialogId(raw)?.let { key = it }
            }
            if (messages.isEmpty()) {
                note("$label=unreadable(${items.size}) ${probe(items)}")
                return null
            }
            return Read(messages, label, items.size - from, key)
        }

        for (host in hosts) {
            for (name in ADAPTER_FIELDS) {
                attempt(namedField(host, name), "adapter:${host.javaClass.simpleName}.$name")?.let { return it }
            }
        }
        for (v in recyclerViews(activity)) {
            val adapter = runCatching { v.javaClass.getMethod("getAdapter").invoke(v) }.getOrNull() ?: continue
            attempt(adapter, "view:${v.javaClass.simpleName}/${adapter.javaClass.simpleName}")?.let { return it }
        }
        for (host in hosts) {
            for (name in LIST_FIELDS) {
                attempt(namedField(host, name), "list:${host.javaClass.simpleName}.$name", strictTail = true)
                    ?.let { return it }
            }
        }
        var scanned = 0
        for (host in hosts) {
            for (f in fieldsOf(host.javaClass)) {
                val value = runCatching { f.get(host) }.getOrNull() ?: continue
                scanned++
                attempt(value, "any:${f.name}", strictTail = true)?.let { return it }
            }
        }
        // 这一行要能一眼回答「聊天页到底在哪个 activity / 哪条 fragment 栈 / 哪个窗口」，
        // 所以打**全类名**、两条 fragment 栈分开计数，再附一份窗口里 RecyclerView 的清单。
        val who = "act=${activity.javaClass.name} live=${direct?.javaClass?.name ?: "-"} tg=${tgStack.size}[" +
            tgStack.take(3).joinToString(",") { it.javaClass.name } + "] ax=${axStack.size}[" +
            axStack.take(3).joinToString(",") { it.javaClass.name } + "] rv=" + recyclerInventory(activity)
        miss(("$who scanned=$scanned " + tried.joinToString(" ")).take(300).trim().ifEmpty { "no_source" })
        return null
    }

    /** 窗口里每个 RecyclerView 长什么样：类名 / 适配器类名 / 适配器自报的条数 / 有没有列表入口。 */
    private fun recyclerInventory(activity: Activity): String {
        val views = recyclerViews(activity)
        return "${views.size}[" + views.take(5).joinToString(" ") { v ->
            val adapter = runCatching { methodOf(v.javaClass, "getAdapter")?.invoke(v) }
                .getOrNull()
            if (adapter == null) return@joinToString "null"
            val shape = shapeOf(adapter.javaClass)
            val n = shape.count?.let { runCatching { it.invoke(adapter) }.getOrNull() } ?: "-"
            "${adapter.javaClass.name}(n=$n,list=${shape.list != null},item=${shape.item != null})"
        } + "]"
    }

    /** 尾部一条读不出来的原始对象长什么样 —— 用来判断反射该往哪边修（不含正文）。 */
    private fun probe(items: Items): String {
        for (i in items.size - 1 downTo (items.size - 3).coerceAtLeast(0)) {
            val raw = items.at(i) ?: continue
            val text = TelegramMessage.text(raw)
            val side = TelegramMessage.side(raw)
            return "cls=${raw.javaClass.name} text=${if (text == null) "null" else "len" + text.length} " +
                "side=${side ?: "null"} id=${TelegramMessage.id(raw) ?: "null"}"
        }
        return "no_raw"
    }

    /** 每种「读不到」的原因只记一次，避免刷屏；换了一种原因再记。 */
    private val missedReasons = HashSet<String>()

    private fun noteMiss(reason: String) {
        if (missedReasons.size > 32) missedReasons.clear()
        if (missedReasons.add(reason)) ModuleLog.log("tg", "miss $reason")
    }

    /** 「结构判据说这是聊天页」的原因，只记一次（不含任何聊天内容）。 */
    private var lastChatLike: String? = null

    private fun noteChatLike(why: String) {
        if (why == lastChatLike) return
        lastChatLike = why
        ModuleLog.log("tg", "chatlike $why")
    }

    private inline fun collect(
        from: Int,
        to: Int,
        itemAt: (Int) -> Any?,
        last: (Any?) -> Unit = {},
    ): List<Msg> {
        val out = ArrayList<Msg>(to - from)
        for (i in from until to) {
            val raw = itemAt(i) ?: continue
            val message = TelegramMessage.read(raw) { id -> resolveSenderName(id) } ?: continue
            // 会话身份取自「最后一条读得出来的消息」：它带 dialog_id，能区分会话。
            last(raw)
            val text = if (message.text.length > MAX_TEXT) message.text.substring(0, MAX_TEXT) else message.text
            out.add(if (text.length == message.text.length) message else message.copy(text = text))
        }
        return out
    }

    /**
     * 会话页标题（分析卡片用它显示「这是谁」）。拿不到就算了，不影响对拍。
     *
     * 先问聊天 fragment 的 ActionBar —— Telegram 把标题设在它上面；Activity 自己的
     * title 在 Telegram 上不是会话名（是空的或 App 名），放到最后兜底。
     */
    private fun titleOf(activity: Activity): String? {
        // 直接钩住的那个优先：它在真机上稳定存在，从 Activity 反推的 fragment 栈不稳。
        (currentChat.get() ?: chatFragmentOf(activity))?.let { chat ->
            val fromBar = runCatching {
                val bar = chat.javaClass.getMethod("getActionBar").invoke(chat)
                (bar?.javaClass?.getMethod("getTitle")?.invoke(bar) as? CharSequence)?.toString()
            }.getOrNull()
            if (!fromBar.isNullOrBlank()) return fromBar
        }
        return runCatching { activity.title?.toString()?.takeIf { it.isNotBlank() } }.getOrNull()
    }

    /**
     * 群里要把发送者名字带上。Telegram 的名字解析要过 MessagesController，
     * 而且只对「用户」有效（频道/群没有），所以：先看缓存 → 一次调用失败就
     * 永久停用这条（不再反复打宿主）。
     */
    private var senderLookupOk = true

    private fun resolveSenderName(id: Long): String? {
        senderNames[id]?.let { return it }
        if (!senderLookupOk) return null
        val activity = active.get() ?: return null
        val name = runCatching {
            val loader = activity.classLoader
            val controller = XposedHelpers.findClass("org.telegram.messenger.MessagesController", loader)
            val accountField = generateSequence<Class<*>>(activity.javaClass) { it.superclass }
                .takeWhile { it != Any::class.java }
                .firstNotNullOfOrNull { c ->
                    runCatching { c.getDeclaredField("currentAccount").apply { isAccessible = true } }.getOrNull()
                } ?: return@runCatching null
            val account = accountField.get(activity) as? Int ?: return@runCatching null
            val instance = XposedHelpers.callStaticMethod(controller, "getInstance", account) ?: return@runCatching null
            val user = XposedHelpers.callMethod(instance, "getUser", java.lang.Long.valueOf(id)) ?: return@runCatching null
            val userObject = XposedHelpers.findClass("org.telegram.messenger.UserObject", loader)
            (XposedHelpers.callStaticMethod(userObject, "getUserName", user) as? String)?.takeIf { it.isNotBlank() }
        }.getOrNull()
        if (name == null) {
            senderLookupOk = false
            ModuleLog.log("tg", "sender lookup off（群里只留「对方」，不影响正文）")
        } else {
            senderNames[id] = name
        }
        return name
    }

    // ---- 反射找「消息列表」的四条路：字段名先试常见的，再按类型兜底 ----

    /** 适配器可能挂在这些字段上。 */
    private val ADAPTER_FIELDS = listOf("chatAdapter", "messagesAdapter")

    /** 老版本把消息直接放在这些列表字段里。 */
    private val LIST_FIELDS = listOf("messages", "messagesArrayList", "messageObjects")

    private val fieldCache = ConcurrentHashMap<Class<*>, List<Field>>()

    private fun fieldsOf(type: Class<*>): List<Field> = fieldCache.getOrPut(type) {
        generateSequence(type) { it.superclass }.takeWhile { it != Any::class.java }
            .flatMap { it.declaredFields.asSequence() }
            .filter { !java.lang.reflect.Modifier.isStatic(it.modifiers) }
            .onEach { runCatching { it.isAccessible = true } }
            .toList()
    }

    /**
     * 一个「能按序号取消息」的数据源：适配器（任意版本）或一个直接的 List。
     * **不缓存取到的对象** —— 它是宿主的私有实例，放进我们的静态表等于在宿主
     * 进程里留泄漏，换会话后还会读到旧的那份；缓存「字段/方法列表」就够了。
     */
    private class Items(val size: Int, val at: (Int) -> Any?)

    /**
     * 一个类能提供消息列表的入口方法。**缓存的实例永远非空** —— 这是修
     * `ConcurrentHashMap.getOrPut` 缓存 null 必抛 NPE 的教训（真机崩过两次：
     * `putIfAbsent(key, null)` → `ConcurrentHashMap#putVal` NPE）。
     */
    private class SourceShape(val list: Method?, val count: Method?, val item: Method?)

    private val sourceShapes = ConcurrentHashMap<Class<*>, SourceShape>()

    /**
     * 把「适配器」和「列表」这两种完全不同的东西统一成可按下标取的对象。
     *
     * Telegram 12.10.1 的教训（dexdump 一手核对 `ChatActivity$ChatActivityAdapter`）：
     * 它**没有** `getItem(int)`，公开的是 `getMessages()` 返回
     * `ArrayList<MessageObject>`。老代码只认 `getItem`，于是永远读不到 —— 这不是
     * 「Telegram 难读」，是我们问错了方法。
     */
    private fun itemsOf(value: Any): Items? {
        if (value is List<*>) {
            if (value.isEmpty()) return null
            return Items(value.size) { i -> runCatching { value[i] }.getOrNull() }
        }
        val shape = shapeOf(value.javaClass)
        shape.list?.let { m ->
            val got = runCatching { m.invoke(value) as? List<*> }.getOrNull()
            if (got != null && got.isNotEmpty()) {
                return Items(got.size) { i -> runCatching { got[i] }.getOrNull() }
            }
        }
        val count = shape.count?.let { runCatching { it.invoke(value) }.getOrNull() as? Number }?.toInt() ?: 0
        val item = shape.item
        if (count > 0 && item != null) {
            return Items(count) { i -> runCatching { item.invoke(value, i) }.getOrNull() }
        }
        return null
    }

    private fun shapeOf(type: Class<*>): SourceShape = sourceShapes.getOrPut(type) {
        SourceShape(
            list = methodOf(type, "getMessages"),
            count = methodOf(type, "getItemCount"),
            // `Int::class.java` 就是 int.class —— getItem(int) 要的是基本类型。
            item = methodOf(type, "getItem", Int::class.java),
        )
    }

    /**
     * 沿继承链找公开方法（`getMethod` 只认 public，注入层只要这些）。
     *
     * 也要 `isAccessible = true`：Telegram 的适配器是**非 public 的嵌套类**
     * （`ChatActivity$ChatActivityAdapter`），`getMethod` 照样能返回它的公开方法，
     * 但直接 `invoke` 会抛 `IllegalAccessException` —— 而它被 `runCatching` 吞掉后
     * 长得和「这个方法不存在」一模一样。真机上就是这种「静默失败」最难查。
     */
    private fun methodOf(type: Class<*>, name: String, vararg params: Class<*>): Method? =
        generateSequence(type) { it.superclass }.takeWhile { it != Any::class.java }
            .firstNotNullOfOrNull { c ->
                runCatching { c.getMethod(name, *params).also { it.isAccessible = true } }.getOrNull()
            }

    private fun namedField(host: Any, name: String): Any? =
        fieldsOf(host.javaClass).firstOrNull { it.name == name }
            ?.let { runCatching { it.get(host) }.getOrNull() }

    /** 宿主把聊天页放在 fragment 上时（本机就是这样），适配器挂在 fragment 的字段上。 */
    private fun fragmentsOf(activity: Activity): List<Any> = telegramStackOf(activity) + supportFragmentsOf(activity)

    /**
     * Telegram 自己的 fragment 栈：`LaunchActivity.actionBarLayout.getFragmentStack()`
     * （dexdump 一手核对：该方法是 PUBLIC，返回 `Ljava/util/List;`）。Telegram 不用
     * AndroidX fragment，所以这是拿到 `ChatActivity` 的**主要**入口。
     */
    private fun telegramStackOf(activity: Activity): List<Any> {
        val out = ArrayList<Any>(4)
        val layout = namedField(activity, "actionBarLayout")
            ?: methodOf(activity.javaClass, "getActionBarLayout")?.let {
                runCatching { it.invoke(activity) }.getOrNull()
            }
            ?: return out
        val stack = runCatching {
            methodOf(layout.javaClass, "getFragmentStack")?.invoke(layout) as? List<*>
        }.getOrNull() ?: return out
        stack.forEach { if (it != null) out.add(it) }
        return out
    }

    /** AndroidX / 平台的 fragment（Telegram 基本不用，但主界面新版可能挂在这里）。 */
    private fun supportFragmentsOf(activity: Activity): List<Any> {
        val out = ArrayList<Any>(2)
        for (getter in listOf("getSupportFragmentManager", "getFragmentManager")) {
            val fm = runCatching { activity.javaClass.getMethod(getter).invoke(activity) }.getOrNull() ?: continue
            collectFragments(fm, out, 0)
        }
        return out
    }

    private fun collectFragments(fm: Any, out: MutableList<Any>, depth: Int) {
        if (depth > 4 || out.size > 64) return
        val list = runCatching {
            fm.javaClass.getMethod("getFragments").invoke(fm) as? List<*>
        }.getOrNull() ?: return
        for (f in list) {
            if (f == null) continue
            out.add(f)
            val child = runCatching { f.javaClass.getMethod("getChildFragmentManager").invoke(f) }.getOrNull() ?: continue
            collectFragments(child, out, depth + 1)
        }
    }

    /** 窗口里所有 RecyclerView（宿主的消息列表也在里面）。 */
    private fun recyclerViews(activity: Activity): List<View> {
        val out = ArrayList<View>(4)
        val root = runCatching { activity.window?.peekDecorView() }.getOrNull() ?: return out
        var budget = VIEW_WALK_BUDGET
        fun walk(v: View?) {
            if (v == null || budget-- <= 0) return
            if (v is ViewGroup) {
                if (v.javaClass.name.contains("Recycler")) out.add(v)
                for (i in 0 until v.childCount) walk(v.getChildAt(i))
            }
        }
        walk(root)
        return out
    }
}

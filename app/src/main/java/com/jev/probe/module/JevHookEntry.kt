package com.jev.probe.module

import android.app.Activity
import android.app.Application
import android.app.Instrumentation
import android.content.Context
import android.os.Process
import com.jev.probe.BuildConfig
import com.jev.probe.bridge.BridgeTransport
import com.jev.probe.bridge.HookTargets
import de.robv.android.xposed.IXposedHookLoadPackage
import de.robv.android.xposed.XC_MethodHook
import de.robv.android.xposed.XposedBridge
import de.robv.android.xposed.XposedHelpers
import de.robv.android.xposed.callbacks.XC_LoadPackage
import java.util.concurrent.Executors

/**
 * jev 的**第二张面孔**：同一个 APK 被 Vector/LSPosed 当作模块加载时的入口。
 * 声明在 `app/src/main/assets/xposed_init`，框架设置页里的说明和允许注入的
 * 范围在 AndroidManifest 的 `xposed*` meta-data 与 `@array/xposed_scope`。
 *
 * 为什么用 legacy API 而不是现代 Module API：`de.robv.android.xposed:api:82`
 * 是唯一能在 compileSdk 35 上直接编译的（YukiHookAPI 1.3.2 声明
 * minCompileSdk=37，而 `platforms;android-37` 在 Google 仓库里不存在）。
 * Vector 2.2 的 API 102 兼容它，两种声明方式都认。
 *
 * **这个类只能被框架在目标 App 的进程里加载。** 本 App 自己的进程里没有
 * Xposed API 的类，一旦被本进程引用就是 NoClassDefFoundError。所以：
 *  - 纯逻辑（包名/进程门槛、桥协议、单调版本）全部放在
 *    [com.jev.probe.bridge]，那里不 import 任何 xposed 的东西；
 *  - 本 App 的设置页只读 [com.jev.probe.bridge.BridgeStore] 的状态，
 *    永远不 touch 这个包。
 *
 * S2 立住了挂载点、门槛与跨进程桥；S3 在**用户给这个 App 开了注入**的分支里启用
 * [TelegramInjector] 的只读读取钩子（只在聊天页、每秒一次、只看最后 60 条）。
 * 生命周期观察（「前台是哪个 Activity」）无论开关都要先装上 —— 见
 * [TelegramInjector.track] 里的时序原因；开关关着时它不读、不推、不打日志，
 * 用户拿到的就是今天的行为。
 */
class JevHookEntry : IXposedHookLoadPackage {

    private val session = ModuleSession()

    /** 每个进程只初始化一次；`Application.attach` 与 resume 两个挂载点会撞。 */
    @Volatile private var installed = false

    private val io = Executors.newSingleThreadExecutor { r ->
        Thread(r, "jev-inject").apply { isDaemon = true; priority = Thread.MIN_PRIORITY }
    }

    override fun handleLoadPackage(lpparam: XC_LoadPackage.LoadPackageParam?) {
        val param = lpparam ?: return
        // 第一道门槛：不在允许范围内、或者不是主进程，立刻返回，什么都不做。
        if (!HookTargets.shouldLoad(param.packageName, param.processName)) return
        try {
            install(param)
        } catch (t: Throwable) {
            // 往宿主进程里抛异常是最坏的结果：宿主会被这套注入连累。咽掉、记日志。
            ModuleLog.fail("install", t)
        }
    }

    private fun install(param: XC_LoadPackage.LoadPackageParam) {
        ModuleLog.frameworkSink = { line -> XposedBridge.log(line) }
        ModuleLog.log(
            "entry",
            "pkg=${param.packageName} process=${param.processName} boot=${session.boot} " +
                "pid=${Process.myPid()} sdk=${android.os.Build.VERSION.SDK_INT}"
        )

        // 挂载点一：Application.attach。常规路径，进程一启动就拿到 Context。
        XposedHelpers.findAndHookMethod(
            Application::class.java,
            "attach",
            Context::class.java,
            object : XC_MethodHook() {
                override fun afterHookedMethod(m: MethodHookParam) {
                    val ctx = m.args?.firstOrNull() as? Context ?: return
                    initialize(ctx, param)
                }
            }
        )

        // 挂载点二：Instrumentation.callActivityOnResume。
        // 有些模块加载器在 Application.attach 已经跑完之后才把模块注进来，
        // 只挂第一个点的话进程已经起来的 App 永远等不到初始化（yanwai 同样的
        // 双挂载）。这里再判一次包名，免得被宿主的别的 Activity 带进来。
        XposedBridge.hookAllMethods(
            Instrumentation::class.java,
            "callActivityOnResume",
            object : XC_MethodHook() {
                override fun afterHookedMethod(m: MethodHookParam) {
                    val activity = m.args?.firstOrNull() as? Activity ?: return
                    if (activity.packageName != param.packageName) return
                    initialize(activity.application, param)
                }
            }
        )
    }

    /**
     * 拿到 Context 之后的初始化。**这一步在宿主的主线程上被调用**（attach 与
     * resume 都是），所以真正的活儿全部丢到自己的单线程池里：问本 App 的开关
     * 是一次跨进程 IPC，备用通道还会 bindService 等 4 秒，在主线程上做就是把
     * 宿主卡成 ANR —— CLAUDE.md 的「注入层永不阻塞」。
     */
    private fun initialize(context: Context, param: XC_LoadPackage.LoadPackageParam) {
        synchronized(this) {
            if (installed) return
            installed = true
        }
        val app = context.applicationContext ?: context
        val pkg = param.packageName
        val log: (String) -> Unit = { ModuleLog.log("bridge", it) }
        // 先装生命周期观察（不读任何内容），再去问开关：真机上 gate 那次有序广播
        // 要等本 App 答复约 700ms，宿主第一个 Activity 的 resume 通常就落在这一段里。
        // 等答复回来才装钩子 = 永远收不到 resume，模块活着却什么都读不到。
        try {
            TelegramInjector.track(param.classLoader)
        } catch (t: Throwable) {
            ModuleLog.fail("track", t)
        }
        io.execute {
            val version = ourVersion()
            // 报到：不依赖开关，是「模块确实跑起来了」的唯一可验证证据。
            // 只带 pkg/boot/seq/时间/版本，没有任何聊天内容。
            //
            // 这是**单向**广播：返回值只表示「发出去了没有」，不表示本 App 收下
            // 了。真机上没法在这里等答复（目标 App 的 uid 被包可见性挡住，连
            // 本 App 的接收器都解析不出来，只能靠点名投递），而且摸不到对方正好
            // 没活着的时候也不该把宿主的启动拖住。收下了没有，看本 App 那边：
            // `flows/jev-trace.log` 的 `bridge hello`、设置页的「已连接」。
            val sent = try {
                BridgeTransport.hello(app, pkg, session.boot, session.nextSeq(), session.nowMs(), version, log)
            } catch (t: Throwable) {
                ModuleLog.fail("hello", t)
                false
            }
            // 逐 App 的开关。默认关；读不到就是关（fail-closed）。
            // 这条要答复，走有序广播；等不到答复再退回 Provider / 绑定 Service。
            val enabled = try {
                BridgeTransport.gate(app, pkg, log)
            } catch (t: Throwable) {
                ModuleLog.fail("gate", t)
                false
            }
            ModuleLog.log(
                "ctx",
                "pkg=${pkg} ver=${version} boot=${session.boot} hello=${if (sent) "sent" else "failed"} " +
                    "gate=${if (enabled) "on" else "off"}"
            )
            if (!enabled) {
                // 用户没给这个 App 开注入：到此为止，不装读取钩子、不读任何消息。
                // （上面那个生命周期观察只记「前台是哪个 Activity」，不看内容。）
                ModuleLog.log("idle", "pkg=${pkg} 注入开关关闭，未安装任何读取钩子")
            } else {
                ModuleLog.log("armed", "pkg=${pkg} 注入开关已开启，装 L1 读取钩子（只读、只在聊天页、1 秒一次）")
                try {
                    TelegramInjector.enable(app, pkg, session, log)
                } catch (t: Throwable) {
                    // 装钩子失败 = 退回 L0，不是错误：这条能力阶梯本来就有兜底。
                    ModuleLog.fail("injector", t)
                }
            }
        }
    }

    /**
     * 版本串取编译期生成的 `BuildConfig.VERSION_NAME`。
     *
     * 这个函数前两版都是错的，真机上各留下一行证据：
     *  1. 用宿主 Context 的 `packageName` 去查 → 报出的是**宿主的**版本号
     *     （框架日志里 `ver=12.10.1`，那是 Telegram 的）。
     *  2. 改成查 `OWNER_PACKAGE` → 在宿主的进程里抛 NameNotFoundException
     *     （`ver=?`）：**包可见性**同样挡住了 `getPackageInfo`，目标 App 的
     *     清单里不会声明我们。
     *
     * 而 `BuildConfig` 是同一个 APK、同一次构建生成的常量，抄不出漂移 ——
     * 比任何跨进程查询都可靠。它也不 import 任何 xposed 的东西。
     */
    private fun ourVersion(): String = BuildConfig.VERSION_NAME
}

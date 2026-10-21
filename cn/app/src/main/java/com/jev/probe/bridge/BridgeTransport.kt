package com.jev.probe.bridge

import android.app.Activity
import android.app.BroadcastOptions
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.Looper
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/**
 * 桥的**调用方**。这段代码跑在目标 App 的进程里（由注入入口加载），它要问本
 * App 两件事：这个 App 的用户开关开着吗；以及把读到的一条快照推回去。
 *
 * 通道顺序与理由（真机实测定下来的）：
 *  1. **广播**（[BridgeContract.ACTION]）。模块用的是目标 App 的 UID 和 Context，
 *     **包可见性**把本 App 整个挡掉了：Provider 取不到、Service 绑不上。广播的
 *     投递由系统做，不需要发送方解析出接收方，所以这是唯一走得通的方向。
 *     但广播要能**证明自己是谁**：Android 14 起接收端拿到的发送方 uid 默认是
 *     `INVALID_UID`，必须由发送方 `setShareIdentityEnabled(true)` 才给真值 ——
 *     见 [identityOptions]。少了这一步，本 App 会按 fail-closed 静默拒收。
 *  2. 对 `gate` 还有一条兜底：Provider → 绑定 Service。它们是同步的、能直接
 *     拿到答复，在**不**受可见性限制的调用方（本 App 自己、或 root 调试）那里
 *     仍然有效，也是真机上用来确认「Provider 本身没坏、只是被可见性挡住」的
 *     对照手段。
 *
 * 四条铁律：
 *  1. **永不抛**。所有异常在这里咽掉，返回 null/false，调用方按「没有注入」
 *     处理，能力阶梯自然落回无障碍。注入代码往宿主进程里抛异常是最坏的结果。
 *  2. **永不在主线程绑定**。`bindService` 会等回调，主线程上等就是卡 UI。
 *  3. **永不落盘**。这里只用 Bundle/Intent 传值，不 import 本 App 的 Trace ——
 *     那段代码在宿主的进程里跑，会写到宿主的 filesDir 去。诊断信息由注入入口
 *     用 XposedBridge.log 输出，写进框架日志。
 *  4. **永不等待太久**。`gate` 的有序广播最多等 [GATE_TIMEOUT_MS]；等不到就
 *     当「关」（fail-closed），绝不让宿主的启动被这条桥拖住。
 *
 * 注意这个文件**不能** import `de.robv.android.xposed`：它跟着 APK 一起被
 * 本 App 自己的进程加载，而本 App 进程里没有 Xposed API 的类。
 */
internal object BridgeTransport {

    /** 备用通道的等待上限。OPPO / Android 16 上的实测值，与 yanwai 一致。 */
    const val BIND_TIMEOUT_MS = 4_000L

    /** 有序广播等答复的上限。等不到就是「关」，L0 照常。 */
    const val GATE_TIMEOUT_MS = 4_000L

    private fun uri(): Uri = Uri.parse("content://${BridgeContract.AUTHORITY}")

    /**
     * 问「我这个 App 在设置里开着注入吗」。任何失败都返回 false（fail-closed）。
     *
     * 先走有序广播拿答复；拿不到再退回 Provider / 绑定 Service（给不受可见性
     * 限制的调用方留的门）。
     */
    fun gate(context: Context, pkg: String, log: (String) -> Unit = {}): Boolean {
        val extras = Bundle().apply { putString(BridgeContract.K_PKG, pkg) }
        val viaBroadcast = orderedCall(context, BridgeContract.M_GATE, extras, log)
        if (viaBroadcast != null) return viaBroadcast.getBoolean(BridgeContract.K_ENABLED, false)
        val viaIpc = request(context, BridgeContract.M_GATE, pkg, extras, log) ?: return false
        return viaIpc.getBoolean(BridgeContract.K_ENABLED, false)
    }

    /**
     * 报到。单向广播：**发出去就算成功**，本 App 收没收下由本 App 那边的证据
     * 回答（`flows/jev-trace.log` 的 `bridge hello` 与设置页的「已连接」状态）。
     * 单向是刻意的 —— 报到不该依赖本 App 正好活着，也不该为此等一个答复。
     */
    fun hello(
        context: Context,
        pkg: String,
        boot: String,
        seq: Long,
        at: Long,
        version: String,
        log: (String) -> Unit = {},
    ): Boolean {
        val extras = stampExtras(pkg, boot, seq, at) {
            it.putString(BridgeContract.K_MODULE_VERSION, version)
        }
        return fire(context, BridgeContract.M_HELLO, extras, log)
    }

    /**
     * 推一条快照（S3 才用）。payload 超限会被本 App 整条拒收
     * （[BridgeContract.MAX_PAYLOAD_CHARS]），这里先自己判一次，省掉一次无意义的
     * 跨进程投递。
     */
    fun snapshot(
        context: Context,
        pkg: String,
        boot: String,
        seq: Long,
        at: Long,
        payload: String?,
        log: (String) -> Unit = {},
    ): Boolean {
        if (payload == null || payload.length > BridgeContract.MAX_PAYLOAD_CHARS) return false
        val extras = stampExtras(pkg, boot, seq, at) {
            it.putString(BridgeContract.K_PAYLOAD, payload)
        }
        return fire(context, BridgeContract.M_SNAPSHOT, extras, log)
    }

    private inline fun stampExtras(
        pkg: String,
        boot: String,
        seq: Long,
        at: Long,
        extra: (Bundle) -> Unit,
    ): Bundle = Bundle().apply {
        putString(BridgeContract.K_PKG, pkg)
        putString(BridgeContract.K_BOOT, boot)
        putLong(BridgeContract.K_SEQ, seq)
        putLong(BridgeContract.K_AT, at)
        extra(this)
    }

    // ------------------------------------------------------------------ 广播通道

    private fun intentFor(method: String, extras: Bundle): Intent = Intent(BridgeContract.ACTION)
        // 显式指定包名：清单接收器只对发件人可见的包投递，而**发件人在这个方向上
        // 恰好看不见我们** —— 所以这里不能靠隐式广播，必须点名。
        .setPackage(BridgeContract.OWNER_PACKAGE)
        .addFlags(Intent.FLAG_RECEIVER_FOREGROUND)
        // 真机教训（2026-10-06）：本 App 刚被 `install -r` 覆盖装、或者在设置里被
        // 「强行停止」过之后，包处在 stopped 状态；点名投递的广播**默认不进 stopped
        // 的包**，于是模块那边 `ordered method=gate reply=false`、`gate=off`、
        // 一个钩子都不装 —— 表现和「用户没开开关」完全一样，但设置里明明是开的。
        // 加上这个 flag，冷启动那次握手才能把 App 进程拉起来。
        .addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES)
        .putExtra(BridgeContract.K_METHOD, method)
        .putExtras(extras)

    /**
     * 广播的身份选项 —— **没有它，接收端认不出我们是谁**。
     *
     * Android 14 起，`BroadcastReceiver.getSentFromUid()` 只有在发送方显式
     * `setShareIdentityEnabled(true)` 时才回真 uid，否则回
     * `Process.INVALID_UID`。真机实测：不设这个选项时本 App 收到广播后
     * `uid=-1`，`BridgeSender` 按 fail-closed 拒收 —— 也就是说整个注入层在
     * 那时是**静默失效**的（框架日志里 `hello=sent`，本 App 那边一条 deny）。
     *
     * 类名是 `android.app.BroadcastOptions`（不是 `android.content.…`），公开
     * API，加在 API 34。更低版本上返回 null：那时的桥一律不发（接收端本来也
     * 认不出人），能力栈自动落回无障碍 L0。
     */
    private fun identityOptions(): Bundle? =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            null
        } else {
            runCatching {
                BroadcastOptions.makeBasic().setShareIdentityEnabled(true).toBundle()
            }.getOrNull()
        }

    /** 单向：发出去就返回 true（没抛异常即算发出）。 */
    private fun fire(
        context: Context,
        method: String,
        extras: Bundle,
        log: (String) -> Unit,
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            log("broadcast method=$method skipped=no_identity sdk=${Build.VERSION.SDK_INT}")
            return false
        }
        val options = identityOptions()
        if (options == null) {
            log("broadcast method=$method skipped=no_identity sdk=${Build.VERSION.SDK_INT}")
            return false
        }
        val sent = runCatching { context.sendBroadcast(intentFor(method, extras), null, options) }
            .onFailure { log("broadcast threw ${it.javaClass.simpleName}:${it.message}") }
            .isSuccess
        log("broadcast method=$method sent=$sent")
        return sent
    }

    /**
     * 有序广播 + 结果接收器：本 App 在 `onReceive` 里 `setResultExtras(reply)`，
     * 系统把答复回投到这里的 [BroadcastReceiver]。
     *
     * 结果接收器默认跑在主线程上；它只做一件事（把 Bundle 交给一个 Future），
     * 不阻塞。真正在等的是调用方自己的后台线程（注入入口的单线程池）。
     */
    private fun orderedCall(
        context: Context,
        method: String,
        extras: Bundle,
        log: (String) -> Unit,
    ): Bundle? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            log("ordered method=$method skipped=no_identity sdk=${Build.VERSION.SDK_INT}")
            return null
        }
        val options = identityOptions()
        if (options == null) {
            log("ordered method=$method skipped=no_identity sdk=${Build.VERSION.SDK_INT}")
            return null
        }
        val ready = CompletableFuture<Bundle?>()
        val result = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, i: Intent?) {
                ready.complete(runCatching { getResultExtras(false) }.getOrNull())
            }
        }
        val started = runCatching {
            context.sendOrderedBroadcast(
                intentFor(method, extras),
                null,
                options,
                result,
                null,
                Activity.RESULT_OK,
                null,
                null,
            )
        }.onFailure { log("ordered broadcast threw ${it.javaClass.simpleName}:${it.message}") }
            .isSuccess
        if (!started) {
            log("ordered sent=false")
            return null
        }
        val reply = try {
            ready.get(GATE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (t: Throwable) {
            if (t is InterruptedException) Thread.currentThread().interrupt()
            log("ordered wait failed ${t.javaClass.simpleName}:${t.message}")
            null
        }
        log("ordered method=$method reply=${reply != null}")
        return reply
    }

    // -------------------------------------------------- 兜底通道（Provider / 绑定）

    private interface Connection : AutoCloseable {
        fun call(method: String, arg: String?, extras: Bundle?): Bundle?
    }

    /**
     * Provider 优先，取不到才绑 Service。
     *
     * 回退发生在**派发之前**，所以两条通道不会把同一次推送给本 App 送两遍
     * （yanwai 的 SettingsTransport 同样的理由）。
     *
     * 两条通道各自失败的原因一定要说出来：`log` 由注入入口接到 XposedBridge
     * 的框架日志上。第一版真机上 `hello=false` 而两条通道都静默返回 null，
     * 除了「没连上」之外拿不到任何信息 —— 诊断必须能区分「Provider 取不到」
     * 和「绑不上 Service」，否则只能靠猜。
     */
    private fun <T> route(context: Context, log: (String) -> Unit, request: (Connection) -> T): T? {
        val p = provider(context)
        if (p != null) {
            log("provider=ok")
            return runCatching { p.use(request) }
                .onFailure { log("provider failed ${it.javaClass.simpleName}:${it.message}") }
                .getOrNull()
        }
        log("provider=null")
        val bound = bound(context, log) ?: return null
        return runCatching { bound.use(request) }
            .onFailure { log("bound failed ${it.javaClass.simpleName}:${it.message}") }
            .getOrNull()
    }

    private fun request(
        context: Context,
        method: String,
        arg: String?,
        extras: Bundle?,
        log: (String) -> Unit,
    ): Bundle? = route(context, log) { conn -> conn.call(method, arg, extras) }

    private fun provider(context: Context): Connection? {
        val client = try {
            @Suppress("DEPRECATION")
            context.contentResolver.acquireUnstableContentProviderClient(uri())
        } catch (t: Throwable) {
            null
        } ?: return null
        return object : Connection {
            override fun call(method: String, arg: String?, extras: Bundle?): Bundle? =
                runCatching { client.call(method, arg, extras) }.getOrNull()

            override fun close() {
                runCatching { client.close() }
            }
        }
    }

    private fun bound(context: Context, log: (String) -> Unit): Connection? {
        // 主线程绝不绑定：bindService 的回调要等主线程消息队列，在主线程上等
        // 它就是把宿主卡成 ANR。调用方本来就应该在后台线程，这里再兜一道。
        //
        // 判据只能是「是不是主线程」。**不能**顺手要求 `myLooper() != null`：
        // 注入入口把工作丢给一个普通 Executor 线程，那种线程根本没有 Looper，
        // 加了这一条就等于永远不走备用通道（第一版就是这么错的）。
        if (Looper.myLooper() == Looper.getMainLooper()) {
            log("bound skipped=main_thread")
            return null
        }

        val app = context.applicationContext ?: context
        val ready = CompletableFuture<IBinder>()
        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                if (service == null) ready.completeExceptionally(IllegalStateException("null binder"))
                else ready.complete(service)
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                ready.completeExceptionally(IllegalStateException("service disconnected"))
            }

            override fun onNullBinding(name: ComponentName?) {
                ready.completeExceptionally(IllegalStateException("null binding"))
            }

            override fun onBindingDied(name: ComponentName?) {
                ready.completeExceptionally(IllegalStateException("binding died"))
            }
        }
        val intent = Intent().setComponent(
            ComponentName(BridgeContract.OWNER_PACKAGE, BridgeContract.SERVICE_CLASS)
        )
        val started = runCatching {
            app.bindService(intent, conn, Context.BIND_AUTO_CREATE)
        }.onFailure { log("bindService threw ${it.javaClass.simpleName}:${it.message}") }
            .getOrDefault(false)
        if (!started) {
            log("bindService=false")
            return null
        }

        val binder = try {
            ready.get(BIND_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (t: Throwable) {
            if (t is InterruptedException) Thread.currentThread().interrupt()
            log("bind wait failed ${t.javaClass.simpleName}:${t.message}")
            null
        }
        if (binder == null) {
            runCatching { app.unbindService(conn) }
            return null
        }
        log("bound=ok")

        val remote = IBridgeConnection.Stub.asInterface(binder)
        return object : Connection {
            override fun call(method: String, arg: String?, extras: Bundle?): Bundle? =
                runCatching { remote?.call(method, arg, extras) }.getOrNull()

            override fun close() {
                runCatching { app.unbindService(conn) }
            }
        }
    }
}

package com.jev.probe.bridge

import android.content.Context
import android.os.Bundle
import android.os.Process
import com.jev.probe.core.Prefs
import com.jev.probe.core.Trace

/**
 * 三条通道（广播 / Provider / 绑定 Service）共用的派发。
 *
 * 换通道不换语义：广播的 extras、`ContentProvider.call` 和
 * [IBridgeConnection.call] 的参数同形，所以门禁、单调版本、有界拒收这三条
 * 规则只写一份。
 *
 * 唯一不能共用的是「谁在说话」的取值时机 —— 调用方在真正执行派发之前就把它
 * 读出来传进来。这也正是「通道失败可以安全回退」的原因：回退发生在派发
 * **之前**，不会把同一次写重放两遍。
 */
internal object BridgeDispatch {

    /**
     * 永不抛异常。**这一点是被真机教训改出来的**：广播接收器的 `onReceive` 由
     * 系统在主线程上调用，在那里抛 SecurityException 就是本 App 自己崩；而
     * Provider 那条路上抛异常会跨 Binder 回给宿主进程。拒收统一用
     * `{accepted=false, reason=...}` 回答，调用方本来也不该从「问路」里得到
     * 超过「放行/不放行」的信息。
     */
    fun handle(
        context: Context,
        callerUid: Int,
        method: String?,
        arg: String?,
        extras: Bundle?,
    ): Bundle {
        // Trace 平时由无障碍服务在 connect 时打开。桥这条路上，本 App 的进程
        // 很可能是被 Provider 冷启动起来的 —— 那时无障碍服务还没连上，Trace
        // 没初始化，整条桥的往返就一条记录都不留，S2 的验收也就没有证据。
        // 这个调用是幂等的（已启用时直接返回，不会删掉现有文件）。
        Trace.init(context)

        val callerPackages = runCatching {
            context.packageManager.getPackagesForUid(callerUid)?.toList() ?: emptyList()
        }.getOrDefault(emptyList())

        // 广播把方法名放在 extras 里（Intent 的 action 让给通道本身）。
        // 先取出来，拒收的日志里才能记下「谁想干什么」—— 只记方法名，不记内容。
        val verb = method ?: extras?.getString(BridgeContract.K_METHOD)

        // 「谁在说话」只有一条规则，放在 BridgeSender 里（纯逻辑、可单测）：
        // 认不出人 → 拒；认得出人但不是自己/清单内的目标 App → 拒。
        val deny = BridgeSender.denyReason(
            senderUid = if (callerUid < 0) null else callerUid,
            ownUid = Process.myUid(),
            senderPackages = callerPackages,
        )
        if (deny != null) {
            Trace.log(
                "bridge deny reason=$deny uid=$callerUid method=${verb ?: "-"} " +
                    "pkgs=${callerPackages.size}"
            )
            return rejection(deny)
        }

        return when (verb) {
            BridgeContract.M_GATE -> gate(context, extras, arg)
            BridgeContract.M_HELLO -> hello(extras)
            BridgeContract.M_SNAPSHOT -> snapshot(extras)
            else -> rejection(BridgeContract.R_UNKNOWN_METHOD)
        }
    }

    private fun rejection(reason: String): Bundle = Bundle().apply {
        putBoolean(BridgeContract.K_ACCEPTED, false)
        putString(BridgeContract.K_REASON, reason)
    }

    /**
     * 「我这个 App 在设置里开着注入吗」。
     *
     * 答案里永远带包名回显：注入代码拿到的 false 可能是「开关关着」，也可能是
     * 「问错了人」（比如模块被注进了另一个 App），回显让这两种情况在 Trace 里
     * 分得开。
     */
    private fun gate(context: Context, extras: Bundle?, arg: String?): Bundle {
        val pkg = extras?.getString(BridgeContract.K_PKG) ?: arg
        val enabled = pkg != null && HookTargets.isScoped(pkg) &&
            runCatching { Prefs(context).injectionEnabled(pkg) }.getOrDefault(false)
        Trace.log("bridge gate pkg=${pkg ?: "-"} enabled=${enabled}")
        return Bundle().apply {
            putString(BridgeContract.K_PKG, pkg)
            putBoolean(BridgeContract.K_ENABLED, enabled)
        }
    }

    private fun hello(extras: Bundle?): Bundle {
        val reason = BridgeStore.hello(
            pkg = extras?.getString(BridgeContract.K_PKG),
            boot = extras?.getString(BridgeContract.K_BOOT),
            seq = extras?.getLong(BridgeContract.K_SEQ, 0L) ?: 0L,
            at = extras?.getLong(BridgeContract.K_AT, 0L) ?: 0L,
            version = extras?.getString(BridgeContract.K_MODULE_VERSION),
        )
        return verdict(reason)
    }

    private fun snapshot(extras: Bundle?): Bundle {
        val reason = BridgeStore.snapshot(
            pkg = extras?.getString(BridgeContract.K_PKG),
            boot = extras?.getString(BridgeContract.K_BOOT),
            seq = extras?.getLong(BridgeContract.K_SEQ, 0L) ?: 0L,
            at = extras?.getLong(BridgeContract.K_AT, 0L) ?: 0L,
            payload = extras?.getString(BridgeContract.K_PAYLOAD),
        )
        return verdict(reason)
    }

    private fun verdict(reason: String?): Bundle = Bundle().apply {
        putBoolean(BridgeContract.K_ACCEPTED, reason == null)
        if (reason != null) putString(BridgeContract.K_REASON, reason)
    }
}

package dev.chartools.capture.bridge

import android.content.Context
import android.os.Bundle
import android.os.Process
import dev.chartools.capture.CaptureService
import dev.chartools.capture.Trace

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
        // 没初始化，整条桥的往返就一条记录都不留，验收也就没有证据。
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
            BridgeContract.M_GATE -> gate(callerUid, callerPackages, extras, arg)
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
     * gate 的应答判定 —— **抽成纯函数**（[gateVerdict]）以便 JVM 单测直接钉住
     * 三道门闩（设计 §1.3）与 enabled 两分支。本方法只负责取参 + 落 Trace。
     *
     * M0 口径（root-module-design.md §2.2 / M0 门语义）：gate 问「我这个 App
     * 开着注入吗」，答案来自 Dart 经 configure 下发的逐 App 开关镜像
     * [CaptureService.ServiceConfig.injectionEnabled] —— legacy 的
     * `Prefs(context).injectionEnabled(pkg)` 不随迁（新仓库设置的事实来源在
     * Dart SettingsStore，原生侧只做镜像，值仅来自 Dart 下发）。
     */
    private fun gate(
        callerUid: Int,
        callerPackages: List<String>,
        extras: Bundle?,
        arg: String?,
    ): Bundle {
        val pkg = extras?.getString(BridgeContract.K_PKG) ?: arg
        val verdict = gateVerdict(
            callerPkg = pkg,
            callerUid = callerUid,
            ownUid = Process.myUid(),
            callerPackages = callerPackages,
            injectionEnabled = CaptureService.ServiceConfig.injectionEnabled,
        )
        // 拒收路径（uid 判不出来 / 不在 SCOPED）把原因记进 Trace；回给发送方的
        // Bundle 只带 pkg + enabled（legacy 形状），reason 仅在异常路径补写。
        Trace.log(
            "bridge gate pkg=${pkg ?: "-"} enabled=${verdict.enabled} " +
                "reason=${verdict.rejectReason ?: "-"}"
        )
        return Bundle().apply {
            putString(BridgeContract.K_PKG, pkg)
            putBoolean(BridgeContract.K_ENABLED, verdict.enabled)
            if (verdict.rejectReason != null) {
                putString(BridgeContract.K_REASON, verdict.rejectReason)
            }
        }
    }

    /**
     * gate 应答的纯判定（无 android 依赖，JVM 单测直接覆盖）。
     *
     * 三道门闩，fail-closed（设计 §1.3，legacy BridgeSender/BridgeReceiver 语义）：
     *  1. **认不出人就不认**：`callerUid < 0` 是接收端对「系统没给出身份」的
     *     归一化 —— [BridgeReceiver.senderUid] 在 API < 34、`getSentFromUid()`
     *     返回 null、以及 `Process.INVALID_UID` 三种情况都归成 null，再由
     *     `onReceive` 以 -1 哨兵传进来。两种来源都落 `R_NO_SENDER_UID`。
     *  2. **UID 白名单**：按 uid 反查的包名（不是 Intent 自报的）必须命中
     *     本 App 自己（callerUid == ownUid）或 [HookTargets.SCOPED]，否则
     *     `R_NOT_SCOPED`。故意不放行 uid 0（root 是风险源不是用户）。
     *  3. **开关镜像**：过完上面两道，enabled 还要求自报包名落在 SCOPED 内
     *     且镜像里对它为 true。包名不在 SCOPED / 开关关着 / 包名为 null 都
     *     如实回 `enabled=false` —— gate 是「问路」不是「写入」，不构成拒收
     *     （legacy BridgeDispatch.gate 同语义），所以 rejectReason 为 null。
     *
     * @param callerPkg 请求自报的包名（广播 extras 的 `pkg` 键）；回显进应答，
     *   让「开关关着」与「问错了人」在 Trace 里分得开。
     */
    internal fun gateVerdict(
        callerPkg: String?,
        callerUid: Int,
        ownUid: Int,
        callerPackages: List<String>,
        injectionEnabled: Map<String, Boolean>,
        scoped: Collection<String> = HookTargets.SCOPED,
    ): GateVerdict {
        val deny = BridgeSender.denyReason(
            senderUid = if (callerUid < 0) null else callerUid,
            ownUid = ownUid,
            senderPackages = callerPackages,
            scoped = scoped,
        )
        if (deny != null) return GateVerdict(enabled = false, rejectReason = deny)
        val enabled = callerPkg != null && callerPkg in scoped &&
            injectionEnabled[callerPkg] == true
        return GateVerdict(enabled = enabled, rejectReason = null)
    }

    /** gate 判定的出参：`enabled` + 拒收原因（null = 通过门闩、如实应答）。 */
    internal data class GateVerdict(val enabled: Boolean, val rejectReason: String?)

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

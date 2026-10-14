package com.jev.probe.root

import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings
import com.jev.probe.capture.ChatCaptureService
import com.jev.probe.core.Prefs
import com.jev.probe.core.Trace

/** 一次自愈里的一项，`detail` 是**命令真实输出**（截断过），设置页原文贴出来。 */
internal data class FixStep(val name: String, val ok: Boolean, val detail: String) {
    fun line(): String = (if (ok) "✓ " else "✗ ") + name + "：" + detail
    fun trace(): String = "$name=${if (ok) "ok" else "fail"} " + detail.replace('\n', ' ')
}

/**
 * root 自愈：把"每次打开软件点一次无障碍"这件事交给 root 做掉。
 *
 * 为什么这件事在真机上一直在发生（2026-10-07 实测）：**设置里那一格会活下来，但
 * 服务不会**。`adb install -r` 前后 `enabled_accessibility_services` 和
 * `accessibility_enabled=1` 都还在，可是 `dumpsys accessibility` 里
 * `Bound services:{}` 空了 —— 系统说"开着"，却没有任何实例在跑。覆盖安装、开机、
 * 被 ColorOS 冻死都会落到这个状态，而它的唯一出路是**让那一格变一次**（关掉再
 * 打开），这正是用户在系统设置里手动点的那两下。所以这里做的是**修**，不是绕。
 *
 * 能力阶梯（能用小的就用小的，和项目其它地方一致）：
 *  1. 先要 `WRITE_SECURE_SETTINGS`（一次性 `pm grant`）。拿到之后改无障碍只需要
 *     **直接写系统设置**，不再 spawn su —— su 每次都要过 KernelSU。
 *  2. 没拿到就走 `su -c "settings put secure ..."`。
 *  3. 两条都走不通（没 root）：明说"只能手动开"，不假装成功。
 *
 * 唯一会改到**别人**的地方是 `enabled_accessibility_services` 这一格：设备上还有
 * ColorOS 取词、输入法自己的服务。合并逻辑在 [A11ySettings]，是纯函数、有单测。
 */
internal object RootFix {

    const val SECURE_SETTINGS = "android.permission.WRITE_SECURE_SETTINGS"

    /** 跑完整套自愈。**必须在后台线程调用**（里面会 spawn su，首次可能弹授权框）。 */
    fun apply(ctx: Context, prefs: Prefs): List<FixStep> {
        val app = ctx.applicationContext
        Trace.init(app)
        val pkg = app.packageName

        // 框架名懒探测，理由见 [probeFlavor]：`su` 第一次会弹 KernelSU 授权框，
        // 而"修无障碍"在拿到 WRITE_SECURE_SETTINGS 之后根本不需要 su。按顺序做下来，
        // 用户真正在意的那一项会在任何弹窗出现之前就修好。
        var cached: String? = null
        val flavor: () -> String = {
            cached ?: probeFlavor(prefs).also { cached = it }
        }

        Trace.log("root fix start auto=${prefs.rootAuto}")
        val steps = listOf(
            grantSecureSettings(app, pkg, flavor),
            enableA11y(app, flavor),
            grantOverlay(app, pkg, flavor),
            whitelistBattery(pkg, flavor)
        )

        prefs.rootFixAt = System.currentTimeMillis()
        prefs.rootFixReport = steps.joinToString("\n") { it.line() }
        Trace.log("root fix done " + steps.joinToString(" | ") { it.trace() }.take(500))
        return steps
    }

    /**
     * 探测是哪个 root 框架（顺带把结果缓存进 [Prefs.rootFlavor]，主页直接读缓存，
     * 不会为了显示一行字去 spawn 一个 su）。
     */
    private fun probeFlavor(prefs: Prefs): String =
        RootProbe.flavorOf(RootShell.id()).also {
            // 「无」也要缓存。本机就是这种情况（SUSFS 把 su 对 App 隐藏），不写的话
            // 主页永远显示"未检测"，而修复报告里明明写着"没有 root，跳过" —— 自相矛盾。
            // 下一次「一键修复」会重新探测，所以缓存不是永久判决。
            prefs.rootFlavor = it
            Trace.log("root flavor=$it")
        }

    private fun hasSecure(ctx: Context): Boolean =
        ctx.checkSelfPermission(SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    private fun firstLine(s: String, fallback: String): String =
        s.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() }?.take(160) ?: fallback

    /**
     * 一次性授权。`pm grant` 只对**清单里声明过**的权限有效，所以
     * `AndroidManifest.xml` 里必须有 `WRITE_SECURE_SETTINGS`；否则这里会回
     * "not a changeable permission type"，那种失败要如实显示，不能当成已授权。
     */
    private fun grantSecureSettings(ctx: Context, pkg: String, flavor: () -> String): FixStep {
        val name = "写系统设置权限"
        if (hasSecure(ctx)) return FixStep(name, true, "已授权")
        if (flavor() == "无") return FixStep(name, false, "没有 root，跳过")
        val r = RootShell.su("pm grant $pkg $SECURE_SETTINGS")
        return if (hasSecure(ctx)) {
            FixStep(name, true, "pm grant 成功（以后改无障碍不再需要 su）")
        } else {
            FixStep(name, false, firstLine(r.output, "pm grant 无输出"))
        }
    }

    private fun readA11y(ctx: Context): String? = runCatching {
        Settings.Secure.getString(
            ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        )
    }.getOrNull()

    /**
     * 关→开两步之间必须留的时间。同一格连着写两次，系统可能只读到最后一个值、
     * 判定"没有变化"而不重绑 —— 那就等于什么都没做。真机上手动验证用的是 1 秒；
     * 这里取一半，够系统处理完第一次变化。
     */
    private const val REBIND_GAP_MS = 600L

    /** 写完设置之后，等服务真正连上来的最长时间。 */
    private const val RECONNECT_WAIT_MS = 4_000L

    /**
     * 无障碍。判据**不是**"设置里写着开着"，而是 [ChatCaptureService.live] ——
     * 这两件事在真机上被实测证明可以不一致（覆盖安装 / 开机之后设置还开着、
     * 服务已经没了）。要干什么由 [A11ySettings.plan] 这个纯函数算。
     */
    private fun enableA11y(ctx: Context, flavor: () -> String): FixStep {
        val name = "无障碍"
        val cur = readA11y(ctx)
        val plan = A11ySettings.plan(cur, ChatCaptureService.live)
        if (plan is A11yPlan.Already) return FixStep(name, true, plan.why)
        val writes = (plan as A11yPlan.Write).values

        // 设置改完之后唯一的验收标准：服务真的连上来了没有。
        fun verdict(listed: Boolean, notListedMsg: String): FixStep = when {
            !listed -> FixStep(name, false, notListedMsg)
            awaitLive() -> FixStep(name, true, plan.why + "（服务已重新连接）")
            else -> FixStep(
                name, false,
                "设置已经改成开着，但服务 ${RECONNECT_WAIT_MS / 1000} 秒内没连上来；" +
                    "去系统设置里手动关开一次"
            )
        }

        // 阶梯 1：直接写系统设置（一次性 `pm grant` 换来的）。不用 su，也不会被
        // KernelSU 的授权框拦住 —— 这是装机后真正的日常路径。
        if (hasSecure(ctx)) {
            var allOk = true
            writes.forEachIndexed { i, v ->
                allOk = runCatching {
                    Settings.Secure.putString(
                        ctx.contentResolver,
                        Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, v
                    )
                }.isSuccess && allOk
                if (i < writes.lastIndex) Thread.sleep(REBIND_GAP_MS)
            }
            runCatching {
                Settings.Secure.putInt(ctx.contentResolver, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
            }
            if (!allOk) return FixStep(name, false, "写系统设置失败（权限可能刚被收回）")
            return verdict(A11ySettings.contains(readA11y(ctx)), "写进去了但设置没变")
        }

        // 阶梯 2：su + settings put。关→开两步各一条命令，中间同样要留时间。
        if (flavor() == "无") {
            return FixStep(name, false, "没有 root，也没有写系统设置权限，只能手动去系统设置里开")
        }
        var last = ""
        for ((i, v) in writes.withIndex()) {
            val r = RootShell.su(A11ySettings.setCommand(v))
            last = firstLine(r.output, if (r.ok) "ok" else "exit=${r.code}")
            if (!r.ok) return FixStep(name, false, last)
            if (i < writes.lastIndex) Thread.sleep(REBIND_GAP_MS)
        }
        val r = RootShell.su(A11ySettings.enableCommand())
        if (!r.ok) return FixStep(name, false, firstLine(r.output, "exit=${r.code}"))
        return verdict(A11ySettings.contains(readA11y(ctx)), "命令已执行但设置没变：$last")
    }

    /**
     * 等无障碍服务**真的**连上来。这是唯一算数的证据：设置里那一格在服务死着的
     * 时候也是"开着"的，用它当成功判据就是这个 bug 本身。
     *
     * 服务在同一个进程里（清单里没有 `android:process`），所以 `onServiceConnected`
     * 会直接把 [ChatCaptureService.live] 翻成 true，这里轮询就能看到。
     */
    private fun awaitLive(timeoutMs: Long = RECONNECT_WAIT_MS): Boolean {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            if (ChatCaptureService.live) return true
            Thread.sleep(150)
        }
        return ChatCaptureService.live
    }

    private fun grantOverlay(ctx: Context, pkg: String, flavor: () -> String): FixStep {
        val name = "悬浮窗"
        if (Settings.canDrawOverlays(ctx)) return FixStep(name, true, "已开着")
        if (flavor() == "无") return FixStep(name, false, "没有 root，只能去系统设置里点")
        val r = RootShell.su("appops set $pkg SYSTEM_ALERT_WINDOW allow")
        return if (Settings.canDrawOverlays(ctx)) {
            FixStep(name, true, "appops 已设为 allow")
        } else {
            FixStep(name, false, firstLine(r.output, "appops 无输出，状态没变"))
        }
    }

    /**
     * 省电白名单。`KeepAliveService` 只能把进程提到前台优先级，真正让 ColorOS
     * 不冻结还得进 deviceidle 白名单 —— 这一项在设置页里没有对应的开关，用户
     * 通常只能靠"允许后台高耗电"猜，root 下一条命令就是确定的。
     */
    private fun whitelistBattery(pkg: String, flavor: () -> String): FixStep {
        val name = "省电白名单"
        if (flavor() == "无") return FixStep(name, false, "没有 root，跳过")
        val before = RootShell.su("dumpsys deviceidle whitelist")
        if (RootProbe.onWhitelist(before.output, pkg)) return FixStep(name, true, "已在白名单")
        val add = RootShell.su("cmd deviceidle whitelist +$pkg")
        val after = RootShell.su("dumpsys deviceidle whitelist")
        return if (RootProbe.onWhitelist(after.output, pkg)) {
            FixStep(name, true, firstLine(add.output, "已加入"))
        } else {
            FixStep(name, false, firstLine(add.output, "命令没生效"))
        }
    }
}

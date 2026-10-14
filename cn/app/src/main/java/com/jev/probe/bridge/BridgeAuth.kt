package com.jev.probe.bridge

/**
 * 谁可以调这条桥。
 *
 * 注入代码跑在**目标 App 的进程**里，所以 Binder 报的是目标 App 的 uid —
 * 一个签名级权限在这里只会把自己人挡在门外（目标 App 不可能用我们的签名）。
 * 真正的门是这份 UID 白名单：本 App 自己，或者被授权范围内的目标 App。
 *
 * 故意**不放行 uid 0**：本机 KernelSU 可用，`su -c` 起来的东西就是 root，
 * 放行 0 等于给任何拿到 root 的脚本开一个读聊天记录的接口，而注入层自己的
 * 代码根本不需要 root。
 *
 * 纯逻辑，可单测。`callerPackages` 由调用方用 PackageManager 解析后传进来，
 * 这样规则本身与 Android 无关。
 */
object BridgeAuth {

    fun allows(
        callerUid: Int,
        ownUid: Int,
        callerPackages: List<String>,
        scoped: Collection<String> = HookTargets.SCOPED,
    ): Boolean {
        if (callerUid == ownUid) return true
        return callerPackages.any { it in scoped }
    }
}

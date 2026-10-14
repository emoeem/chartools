package com.jev.probe.bridge

/**
 * 广播发送方的资格判定，**纯逻辑**，所以能在 JVM 单测里跑。
 *
 * 广播接收器必须是 `exported=true`：说话的人在目标 App 的进程里，用的是目标
 * App 的 UID，不可能持有本 App 的签名级权限（`android:permission` 挡的是发送
 * 方，给接收器加签名权限就等于把自己的模块也挡在外面）。所以门禁只能在
 * `onReceive` 里做，依据是系统告诉我们的发送方 UID。
 *
 * 这把门的三条规则：
 *  1. **认不出人就不认**。Android 14（API 34）以下没有
 *     `BroadcastReceiver.getSentFromUid()`，uid 未知时一律拒（fail-closed）：
 *     这是一个 exported 的入口，认不出人却放行，任何 App 都能往本 App 里灌
 *     假的聊天快照。
 *  2. **自己人放行**（本 App 自己的进程也可能用广播通道，单测/调试用）。
 *  3. **只有清单内的目标 App 放行**，判定依据是 `PackageManager` 从这个 uid
 *     反查出来的包名列表 —— 不是 Intent 里自称的包名。
 */
object BridgeSender {

    /**
     * @param senderUid 系统给出的发送方 uid；未知时传 null（API < 34 或
     *   `getSentFromUid()` 返回 `Process.INVALID_UID`）。
     * @return null 表示放行，否则是拒收原因。
     */
    fun denyReason(
        senderUid: Int?,
        ownUid: Int,
        senderPackages: List<String>,
        scoped: Collection<String> = HookTargets.SCOPED,
    ): String? {
        if (senderUid == null || senderUid < 0) return BridgeContract.R_NO_SENDER_UID
        if (!BridgeAuth.allows(senderUid, ownUid, senderPackages, scoped)) {
            return BridgeContract.R_NOT_SCOPED
        }
        return null
    }
}

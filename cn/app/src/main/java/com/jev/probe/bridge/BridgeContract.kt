package com.jev.probe.bridge

/**
 * 两条跨进程通道共用的唯一契约：authority、方法名、Bundle 键、以及有界的大小。
 *
 * 全部是常量字符串/整数，没有 `android.net.Uri` 之类的静态初始化 —— 单测在
 * JVM 上跑，碰到 android.jar 的桩会直接抛 "not mocked"。Uri 在用到它的两个
 * 类（Provider / Transport）里各自 lazy 构造。
 */
object BridgeContract {

    /** Provider 的 authority，也是备用 Service 归属的包名。 */
    const val AUTHORITY = "com.jev.probe.bridge"

    /** 备用通道要绑的组件：指定 App 与类名，不走隐式 Intent。 */
    const val OWNER_PACKAGE = "com.jev.probe"
    const val SERVICE_CLASS = "com.jev.probe.bridge.BridgeConnectionService"

    /**
     * 广播通道的动作。**这是真机上唯一走得通的方向。**
     *
     * 实测（Android 16 / Telegram targetSdk 36）：模块代码跑在目标 App 的进程
     * 里，用的却是目标 App 的 UID 与 Context，于是 **包可见性** 把它对 `com.jev.probe`
     * 的一切都挡掉了 —— `acquireUnstableContentProviderClient` 返回 null，
     * `bindService` 返回 false，`getPackageInfo(com.jev.probe)` 抛 NameNotFound
     * （模块日志里就是 `provider=null` / `bindService=false` / `ver=?`）。目标
     * App 的清单里不会有 `<queries>` 指向我们，也不允许改它的清单，所以对
     * Provider / Service 这两条路来说这是死路。
     *
     * 发广播不受可见性过滤（投递由系统做，不需要发送方解析出接收方），所以
     * 目标 App 进程里的模块能发、本 App 的清单接收器能收。
     */
    const val ACTION = "com.jev.probe.bridge.CALL"

    /** 广播里表示调用的方法名（Intent 的 action 让给通道本身）。 */
    const val K_METHOD = "method"

    /**
     * 快照正文的最大长度（字符）。
     *
     * 有界是这条桥的前提：快照来自别的进程，不设上限就等于让目标 App 的
     * 进程决定本 App 要分配多少内存。超限的直接拒收并记 Trace，不截断 ——
     * 截断过的 JSON 解析出来是半条时间线，比没有更坏。
     */
    const val MAX_PAYLOAD_CHARS = 24 * 1024

    /** 每个 App 只留最近一条快照；心跳表也只可能在 SCOPED 里，天然有界。 */
    const val MAX_PAYLOAD_AGE_MS = 120_000L

    // 方法名。
    /** 模块问「我的 App 在设置里开着注入吗」→ {enabled}。 */
    const val M_GATE = "gate"

    /** 模块报到：本进程已注入 → {accepted}。 */
    const val M_HELLO = "hello"

    /** 模块推一条快照（payload 是有界 JSON）→ {accepted}。 */
    const val M_SNAPSHOT = "snapshot"

    // Bundle 键。
    const val K_PKG = "pkg"
    const val K_BOOT = "boot"
    const val K_SEQ = "seq"
    const val K_AT = "at"
    /** 模块侧自报的版本串（模块代码与 APK 同源，报的是 versionName）。 */
    const val K_MODULE_VERSION = "module_version"
    const val K_PAYLOAD = "payload"
    const val K_ENABLED = "enabled"
    const val K_ACCEPTED = "accepted"
    const val K_REASON = "reason"

    /** 拒收原因，写进 Trace 用；永远不把 payload 内容写进日志。 */
    const val R_OUT_OF_SCOPE = "out_of_scope"
    const val R_STALE = "stale"
    const val R_TOO_LARGE = "too_large"
    const val R_UNKNOWN_METHOD = "unknown_method"
    const val R_BAD_ARGS = "bad_args"

    /**
     * 广播的发送方认不出来。两种情况都落这里：Android 14（API 34）以下没有
     * `BroadcastReceiver.getSentFromUid()`，以及系统明确说 uid 未知。判不出来
     * 就不认（fail-closed）—— 广播接收器是 `exported=true`，认不出人却放行
     * 等于让任何 App 都能往本 App 里灌假的聊天快照。
     */
    const val R_NO_SENDER_UID = "no_sender_uid"

    /** 说话的人不在允许的包清单里。 */
    const val R_NOT_SCOPED = "not_scoped"
}

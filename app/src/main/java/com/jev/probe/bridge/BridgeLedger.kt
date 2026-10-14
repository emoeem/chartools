package com.jev.probe.bridge

/**
 * 桥的内存账本：谁还活着、最近一条快照是什么。
 *
 * 全部在内存里，**不落盘**。目标 App 的消息正文不该因为「开着注入」就被写进
 * 本 App 的存储：落盘的那一份是用户显式打开「记录聊天历史」之后、由主进程自
 * 己写的知识库历史（KbStore），来源清楚、可被 retention 清掉。这条桥只做转
 * 手，进程一死就什么都不剩。
 *
 * 纯逻辑，没有 android 依赖，JVM 单测直接覆盖「迟到消息不能覆盖新状态」和
 * 「超大有界拒收」两条规则。
 */
class BridgeLedger(
    private val scoped: Collection<String> = HookTargets.SCOPED,
    private val now: () -> Long = System::currentTimeMillis,
) {

    /** 模块进程活着的一个证据。 */
    data class Alive(val version: String, val at: Long)

    /** 最近一条被接受、且还没被丢掉的重注入快照。 */
    data class Push(val payload: String, val at: Long)

    private val lock = Any()
    private val aliveStamps = HashMap<String, Stamp>()
    private val aliveRows = HashMap<String, Alive>()
    private val pushStamps = HashMap<String, Stamp>()
    private val pushRows = HashMap<String, Push>()

    /**
     * 模块报到。
     * @return null 表示被接受；否则是 [BridgeContract] 里的拒收原因。
     */
    fun hello(pkg: String?, stamp: Stamp, version: String): String? {
        if (pkg == null || pkg !in scoped) return BridgeContract.R_OUT_OF_SCOPE
        synchronized(lock) {
            if (!BridgeOrder.accept(aliveStamps[pkg], stamp)) return BridgeContract.R_STALE
            aliveStamps[pkg] = stamp
            aliveRows[pkg] = Alive(version.take(64), if (stamp.at > 0L) stamp.at else now())
            return null
        }
    }

    /** 模块推一条快照。payload 超限整条拒收（见 [BridgeContract.MAX_PAYLOAD_CHARS]）。 */
    fun snapshot(pkg: String?, stamp: Stamp, payload: String?): String? {
        if (pkg == null || pkg !in scoped) return BridgeContract.R_OUT_OF_SCOPE
        if (payload == null) return BridgeContract.R_BAD_ARGS
        if (payload.length > BridgeContract.MAX_PAYLOAD_CHARS) return BridgeContract.R_TOO_LARGE
        synchronized(lock) {
            if (!BridgeOrder.accept(pushStamps[pkg], stamp)) return BridgeContract.R_STALE
            pushStamps[pkg] = stamp
            pushRows[pkg] = Push(payload, if (stamp.at > 0L) stamp.at else now())
            return null
        }
    }

    /** 心跳还在，且没有超时。 */
    fun alive(pkg: String): Alive? = synchronized(lock) {
        val row = aliveRows[pkg] ?: return null
        if (now() - row.at > BridgeContract.MAX_PAYLOAD_AGE_MS) return null
        row
    }

    /**
     * 取最近一条快照。超时的那条当作没有 —— 一块两分钟前的屏幕不能拿来当
     * 「现在这一句」的回复依据，宁可在能力阶梯上落回 L0。
     */
    fun latest(pkg: String): Push? = synchronized(lock) {
        val row = pushRows[pkg] ?: return null
        if (now() - row.at > BridgeContract.MAX_PAYLOAD_AGE_MS) return null
        row
    }

    /** 目标 App 进程退出后由模块侧显式告知；本轮 S2 没有调用点，留给 S3。 */
    fun forget(pkg: String) = synchronized(lock) {
        aliveStamps.remove(pkg); aliveRows.remove(pkg)
        pushStamps.remove(pkg); pushRows.remove(pkg)
        Unit
    }
}

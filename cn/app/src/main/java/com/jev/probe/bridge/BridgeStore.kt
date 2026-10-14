package com.jev.probe.bridge

import com.jev.probe.core.Trace

/**
 * 进程级的桥状态。注入代码在目标 App 的进程里，本 App 的进程拿不到它的任何
 * 内存；两边唯一的交汇点就是 Provider/Service 派发进来的那几个 Bundle，落到
 * 这个对象上。
 *
 * 注入层是**可选**的：本对象在没装框架、没开任何开关时永远是空的，能力阶梯
 * 到此为止会无条件落回无障碍路径（见 InjectionSource）。
 */
object BridgeStore {

    val ledger = BridgeLedger()

    /** 模块报到。只记包名、版本长度和接收结果，不记任何聊天内容。 */
    fun hello(pkg: String?, boot: String?, seq: Long, at: Long, version: String?): String? {
        if (pkg == null || boot == null) return BridgeContract.R_BAD_ARGS
        val reason = ledger.hello(pkg, Stamp(boot, seq, at), version.orEmpty())
        Trace.log("bridge hello pkg=${pkg} seq=${seq} accepted=${reason == null} reason=${reason ?: "-"}")
        return reason
    }

    /** 模块推来一条快照。payload 只记长度，正文不落 Trace。 */
    fun snapshot(pkg: String?, boot: String?, seq: Long, at: Long, payload: String?): String? {
        if (pkg == null || boot == null) return BridgeContract.R_BAD_ARGS
        val reason = ledger.snapshot(pkg, Stamp(boot, seq, at), payload)
        Trace.log("bridge snapshot pkg=${pkg} seq=${seq} len=${payload?.length ?: -1} " +
            "accepted=${reason == null} reason=${reason ?: "-"}")
        return reason
    }

    /** 目标 App 里的模块进程是否还活着（且没有超时）。 */
    fun alive(pkg: String): BridgeLedger.Alive? = ledger.alive(pkg)

    /** 最近一条没过期的注入快照。 */
    fun latest(pkg: String): BridgeLedger.Push? = ledger.latest(pkg)
}

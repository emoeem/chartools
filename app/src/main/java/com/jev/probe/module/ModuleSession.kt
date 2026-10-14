package com.jev.probe.module

import java.util.UUID
import java.util.concurrent.atomic.AtomicLong

/**
 * 注入进程这一条命的状态：一个随机 boot 串加一个自增序号。
 *
 * 为什么需要 boot：目标 App 被重启后模块进程也重来，序号从 0 开始。只发序号
 * 的话本 App 那边的单调比较会把新进程的第一条当成旧消息永远拒掉，模块从此
 * 静默失效。boot 让「同一个进程内比序号、跨进程比时间」成为可能，判定规则在
 * [com.jev.probe.bridge.BridgeOrder]（那一份是纯逻辑，有单测）。
 */
internal class ModuleSession(
    private val now: () -> Long = System::currentTimeMillis,
) {
    val boot: String = UUID.randomUUID().toString().replace("-", "").take(8)

    private val seq = AtomicLong(0L)

    fun nextSeq(): Long = seq.incrementAndGet()

    fun nowMs(): Long = now()
}

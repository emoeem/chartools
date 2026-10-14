package com.jev.probe.bridge

/**
 * 一个来源进程的指纹：`(boot, seq, at)`。
 *
 * `boot` 是模块每次进程启动生成的一个随机串，`seq` 是该进程内自增的序号，
 * `at` 是**发送方**的墙上时间。
 *
 * 为什么不能只看 `seq`：进程重启后 seq 从 0 重来，纯单调比较会让新进程的第
 * 一条消息永远被当成旧的拒掉，模块从此静默失效。为什么不能只看 `boot`：两个
 * 不同的 boot 之间无法比先后，旧进程的迟到消息就能盖掉新进程的状态。
 *
 * 所以分两支：同一个 boot 内比 seq（严格递增），跨 boot 比发送时间。同一台
 * 设备、同一个时钟，跨 boot 的时间比较是可靠的；这也是 wenyi 的「内容寻址
 * 检查点 + 单调版本号」在这里的最小形态。
 */
data class Stamp(val boot: String, val seq: Long, val at: Long)

object BridgeOrder {

    /**
     * @param last 该 App 上一条被接受的状态；null 表示还没有过。
     * @return true 表示这条更新应当被接受。
     */
    fun accept(last: Stamp?, next: Stamp): Boolean {
        if (last == null) return true
        if (next.boot != last.boot) return next.at > last.at
        return next.seq > last.seq
    }
}

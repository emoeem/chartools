package com.jev.probe.capture

import com.jev.probe.core.Analysis

/**
 * 首轮「先判后写」的触发器 —— 纯逻辑、主线程 confined，JVM 单测直接钉。
 *
 * 为什么要有它：起草过去和判断**并行**，判断结果只用来排序，写的时候是盲的
 * —— 轻松闲聊被按想象中的危机写、角色场被写成日常寒暄，都从这来。现在起草
 * 要等判断：判断回来就带着它写（[fireWithJudgment]）；等满 [WAIT_MS] 还没
 * 回来就盲写（[fireBlind]），判断路由慢或挂掉时延迟有上界，不会跟着 30 秒
 * 超时一起卡死。
 *
 * 两个触发点（判断完成、超时）谁都可能先到，fire 只允许成功**一次**；后到的
 * 一律返回 false，由调用方丢弃。判断自身带 error 时由调用方换成 null 再传
 * 进来（盲写等价），这里只管次序不管语义。
 */
internal class DraftTrigger {

    /** 这一轮的起草是否已经被触发过（无论哪个触发点）。 */
    var started = false
        private set

    /** 起草实际带上的判断；盲写触发时是 null。 */
    var judgment: Analysis? = null
        private set

    /** 判断回来了：带着它触发。已经触发过（比如超时先到、已经盲写）就放弃。 */
    fun fireWithJudgment(a: Analysis?): Boolean {
        if (started) return false
        started = true
        judgment = a
        return true
    }

    /** 等满了还没等到判断：盲写触发。判断已经到过就什么都不做。 */
    fun fireBlind(): Boolean {
        if (started) return false
        started = true
        judgment = null
        return true
    }

    companion object {
        /**
         * 最多等判断这么久。Jev 判断实测一次约 900ms，2 秒覆盖正常路径；
         * chat 协议的判断更慢，但候选晚到总比每一轮都盲写要强。
         */
        const val WAIT_MS = 2_000L
    }
}

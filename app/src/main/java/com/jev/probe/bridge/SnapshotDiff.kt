package com.jev.probe.bridge

import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Msg

/**
 * 把同一聊天页上两层读数放在一起比 —— 计划书里 S3 的验收就是这一条。
 *
 * 为什么要有它：没有对拍，「注入层比无障碍准」就只是一句没有证据的话。而
 * 对拍**不能把聊天正文写进日志**（CLAUDE.md：不记聊天正文）。所以比完之后
 * 只留结构：各读到几条、从最新往回连续对上了几条、第一条对不上的位置在哪、
 * 是分边对不上还是正文对不上。
 *
 * 对齐方式是从**最新往旧**比：两层读到的窗口长度天然不同（无障碍树只有屏
 * 上那几条、注入层能拿到更长的滑动窗口），旧的那一头对不齐是正常的，新的
 * 那一头对不上才是真问题 —— 分析永远只看最新的那几条。
 */
object SnapshotDiff {

    /**
     * @param left 一侧（约定传 L0）
     * @param right 另一侧（约定传 L1）
     * @param leftCount/rightCount 各自读到的条数（可能比传入的 List 大，注入层
     *   的 List 已经被 [InjectTimeline] 裁过；调用方若按自己的窗口计数就传进来）
     */
    data class Result(
        val leftCount: Int,
        val rightCount: Int,
        val aligned: Int,
        val sideIndex: Int,
        val textIndex: Int,
        /** 两侧**内容上**共有的条数（见 [multisetOverlap]）。 */
        val overlap: Int = 0,
    ) {
        /**
         * 只有「对上了至少一条，而且短的那一侧全对上了」才算同一份读数。
         * 两侧都空**不算**：什么都读到不等于读得一样。
         */
        val same: Boolean get() = aligned > 0 && aligned == minOf(leftCount, rightCount)

        /** 一行、无正文，直接进 Trace。 */
        fun describe(): String = buildString {
            append("cmp l0=").append(leftCount).append(" l1=").append(rightCount)
            append(" aligned=").append(aligned)
            append(" sideDiff=").append(sideIndex)
            append(" textDiff=").append(textIndex)
            append(" overlap=").append(overlap)
            append(" same=").append(same)
        }
    }

    /**
     * 从最新往回逐条比，返回连续对上的条数与第一条对不上的位置（1 = 最新那条）。
     * 位置 0 表示在共同长度内没出现该种不一致。
     */
    fun compare(left: List<Msg>, right: List<Msg>): Result {
        val common = minOf(left.size, right.size)
        var aligned = 0
        var sideIndex = 0
        var textIndex = 0
        for (k in 1..common) {
            val a = left[left.size - k]
            val b = right[right.size - k]
            val sideSame = a.side == b.side
            val textSame = a.text == b.text
            val first = sideIndex == 0 && textIndex == 0
            if (sideSame && textSame && first) {
                aligned = k
            } else {
                if (!sideSame && sideIndex == 0) sideIndex = k
                if (!textSame && textIndex == 0) textIndex = k
            }
        }
        return Result(left.size, right.size, aligned, sideIndex, textIndex, multisetOverlap(left, right))
    }

    /**
     * 两层**内容上**共有的条数（多重集合交集，按「分边 + 正文」配对）。
     *
     * 为什么位置对齐之外还要这个数：位置对齐回答的是「新的那一头从第几条开始
     * 对不上」，而真机上更常见的情况是两层窗口长度不同、最新那几条 L0 根本没
     * 有（屏幕外、正在输入、日期分隔），于是 `aligned=0` —— 只剩「对不上」一个
     * 结论，「注入层多读到了什么」这个唯一要回答的问题反而没了。重叠数是位置
     * 无关的，`l0=4 l1=5 overlap=3` 说的是「两层读的确实是同一段聊天，L1 多出
     * 两条」，这才能当证据用。
     *
     * 仍然只输出**计数**，不含任何正文。
     */
    private fun multisetOverlap(left: List<Msg>, right: List<Msg>): Int {
        val counts = HashMap<Pair<String, String>, Int>(right.size)
        for (m in right) counts.merge(m.side to m.text, 1, Int::plus)
        var n = 0
        for (m in left) {
            val key = m.side to m.text
            val c = counts[key] ?: 0
            if (c > 0) {
                counts[key] = c - 1
                n++
            }
        }
        return n
    }

    fun describe(left: ChatSnapshot, right: ChatSnapshot): String =
        compare(left.messages, right.messages).describe()
}

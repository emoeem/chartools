package com.jev.probe.bridge

import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Msg
import com.jev.probe.core.Provenance

/**
 * 注入层把宿主读到的消息**收成一个有界的快照**。
 *
 * 三条约束都来自「这段代码跑在别人的进程里」：
 *  1. **有界**：只看最后 [MAX_MESSAGES] 条、总共不超过 [MAX_CHARS] 个字符。
 *     宿主聊天页的消息列表可以有几万条，无界读取等于把对方的 App 拖死；而且
 *     线上格式在接收端也有一个总长上限（[BridgeContract.MAX_PAYLOAD_CHARS]），
 *     发送端自觉比接收端拒收更早、更好查。
 *  2. **整数条**：宁可少给几条，也不给半条。字符预算只用来决定从哪一条开始
 *     不要，不会把某一条截半 —— 半条消息比没有更坏。
 *  3. **只前进**：`at`/`id` 为 0 或缺字段都不影响，但顺序永远保持宿主给的
 *     时间线顺序（最新的在最后），不去猜、不重排。
 *
 * 这里不 import 任何 xposed 或 Telegram 的东西，所以 JVM 单测能直接跑。
 */
object InjectTimeline {

    /** 一条快照最多带多少条消息。 */
    const val MAX_MESSAGES = 40

    /** 一条快照最多带多少字符（正文长度之和，不含 JSON 结构）。 */
    const val MAX_CHARS = 6_000

    /**
     * 从整段时间线里裁出快照要带的那一段：**从最新往回取**，直到条数或字符
     * 预算用尽。预算不够放下一条时直接停 —— 不跳过它去拿更老的一条，那样
     * 拼出来的上下文是断的，而且断在哪只有这条日志知道。
     */
    fun bound(
        raw: List<Msg>,
        maxMessages: Int = MAX_MESSAGES,
        maxChars: Int = MAX_CHARS,
    ): List<Msg> {
        if (raw.isEmpty()) return emptyList()
        val take = ArrayDeque<Msg>(minOf(raw.size, maxMessages.coerceAtLeast(1)))
        var chars = 0
        var i = raw.size - 1
        while (i >= 0 && take.size < maxMessages.coerceAtLeast(1)) {
            val m = raw[i]
            val size = m.text.length
            if (take.isNotEmpty() && chars + size > maxChars.coerceAtLeast(1)) break
            chars += size
            take.addFirst(m)
            i--
        }
        return take.toList()
    }

    fun snapshot(title: String?, raw: List<Msg>): ChatSnapshot = ChatSnapshot(
        title = title?.takeIf { it.isNotBlank() },
        messages = bound(raw),
        provenance = Provenance.INJECT,
    )

    /**
     * 变化指纹：只为「要不要再推一次」服务，进日志也**不含正文**。
     *
     * 用 `id` 作为身份、正文长度与哈希作为内容，是因为注入层能拿到真的消息 id，
     * 而 L0 拿不到 —— 指纹只在注入层内部比较，不跨层比较。
     */
    fun signature(messages: List<Msg>): String = messages.takeLast(8).joinToString("|") { m ->
        val ident = m.id ?: "#${m.side}"
        "$ident:${m.side}:${m.text.length}:${m.text.hashCode()}"
    }
}

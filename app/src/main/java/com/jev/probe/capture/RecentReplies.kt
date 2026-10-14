package com.jev.probe.capture

/**
 * 最近几轮已经展示过的候选回复 —— 跨轮反重复的原料。
 *
 * 为什么需要它：avoid 列表过去只在「换一组 / 再给 2 条」时才有值，每条新消息
 * 进来的新一轮起草拿到的永远是空 avoid。模型能从最近对话里看见自己发过的消息，
 * 但没有任何机制叫它别复读 —— 2026-10-07 实测聊天记录里整场复读「跪好 / 报数 /
 * 乖」，倒计时 10→0 跑了三遍，对方给出的评语是「AI味十足、不好玩到爆」。
 *
 * 只记**展示过**的（不区分用户是否真的发送了）：用户在卡片上看到的候选就算没发，
 * 下一轮再原样出现也是坏的体验；这和 yanwai 的 previous_suggestion 语义一致。
 *
 * 纯内存、主线程读写、随会话切换整体清空（observeTarget），不落盘 —— 与
 * 「历史默认关闭、不新增采集」的边界一致。放在纯类里是为了能被 JVM 单测钉住，
 * 和 [ForegroundPolicy] 同一个理由。
 */
internal class RecentReplies(
    /** 环上限：3 条候选 + 微调 / 追加，两轮足够看出复读。 */
    private val maxTexts: Int = MAX_TEXTS,
    /** 单条截断长度：标准长度的候选 40 字以内，80 字足够识别一个说法。 */
    private val maxChars: Int = MAX_CHARS
) {

    private val texts = ArrayDeque<String>()

    /**
     * 记住一轮展示的候选。重复的先移除再追加（最近用的排最后），环满丢最旧。
     */
    fun remember(newTexts: List<String>) {
        newTexts.forEach { raw ->
            val t = raw.trim().take(maxChars)
            if (t.isEmpty()) return@forEach
            texts.remove(t)
            texts.addLast(t)
        }
        while (texts.size > maxTexts) texts.removeFirst()
    }

    /** 喂给起草 avoid 的快照，旧 → 新。 */
    fun asAvoid(): List<String> = texts.toList()

    fun isEmpty(): Boolean = texts.isEmpty()

    fun clear() = texts.clear()

    companion object {
        const val MAX_TEXTS = 6
        const val MAX_CHARS = 80
    }
}

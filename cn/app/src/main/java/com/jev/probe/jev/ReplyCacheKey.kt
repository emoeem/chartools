package com.jev.probe.jev

/**
 * 回复 / 判断缓存键的唯一构造处。
 *
 * ## 为什么抽出来
 *
 * 键里少一个分量，表现**不是报错**：改了输入、回复没变，用户以为功能坏了，
 * 我们没有任何日志能看出是缓存命中。这一类 bug 只能靠测试咬住，而键原本藏在
 * `JevClient` 的私有方法里、还直接读 `Prefs`，测试够不着。
 *
 * 抽成纯函数之后，[ReplyCacheKeyTest] 可以对**每一个**分量做一次变异：把它改掉，
 * 键必须变。谁哪天顺手删掉一个分量（尤其 `style` —— 专家库全靠它），那条测试
 * 立刻红。
 *
 * 它防的是「退化」，不防「一开始就错」：如果某个输入从一开始就不在键里，这里
 * 也只会把一个错的行为锁起来。当前是否正确由 `ExpertApplyEndToEndTest` 那 331
 * 条（专家正文真的进提示词）负责。
 */
internal object ReplyCacheKey {

    /** 字段分隔。用控制字符是为了不与正文里可能出现的标点冲突。 */
    private const val FIELD = "\u001e"

    /** 列表项分隔（`avoid` 是多条候选文本）。 */
    private const val ITEM = "\u001f"

    /**
     * 回复缓存键。**十四个分量，缺一个就会串味**：
     *
     * - `title` 会话标题（两个无 KB 会话的末几条消息可能逐字相同，没有它就串台）
     * - `signature` 聊天快照指纹（消息本身变了，候选就作废）
     * - `relationship` 关系（联系人自己的关系压过全局）
     * - `style` **当前生效**的正文 —— 专家库换人、联系人专用人设都换它
     *   （调用方必须传 `StyleSource.resolve` 的结果，不是裸 `Prefs.style`）
     * - `replyModel` 回复路由的模型（换 provider 必须重打）
     * - `count` 要几条候选
     * - `avoid` 已经展示过的候选（「换一组」）
     * - `ctxKey` 提示词里的知识与历史 + 风格样本 + 技能 L1 目录（回复侧独有）
     * - `ledgerKey` 台账（它进回复提示词，不进 Jev 的 state）
     * - `judgmentKey` 这次判断的选项（含置信度与「可不急回」——都改提示词）
     * - `intensity` 力度档
     * - `params` 采样与开关：语言 / 长度 / 温度 / 两个惩罚 / 证据复查 + 复查模型
     */
    fun reply(
        title: String,
        signature: String,
        relationship: String,
        style: String,
        replyModel: String,
        count: Int,
        avoid: List<String>,
        ctxKey: String,
        ledgerKey: String,
        judgmentKey: String,
        intensity: String,
        params: String
    ): String = listOf(
        title, signature, relationship, style, replyModel, count.toString(),
        avoidKey(avoid), ctxKey, ledgerKey, judgmentKey, intensity, params
    ).joinToString(FIELD)

    /**
     * `avoid` 逐条带上长度。
     *
     * 只按分隔符拼会撞：【空列表】与【含一条空串的列表】拼出来一模一样，
     * `["a\u001fb"]` 与 `["a", "b"]` 也一样。撞了就是缓存命中一条本不该命中的
     * 候选，而表现仍然是「回复没变」，查不出来。长度前缀把这件事变成不可能。
     */
    private fun avoidKey(avoid: List<String>): String =
        avoid.joinToString(ITEM) { "${it.length}:$it" }

    /**
     * 判断缓存键：回复键减去只管回复的输入（`count` / `avoid` / `style` /
     * `params` / 台账），加上判断路由自己的模型与协议。
     *
     * `ctxKey` 传判断侧的（background + history + skills）；风格样本与 L1 目录
     * 是写给写手的，判断侧刻意不看，所以不在这里 —— 不然换个技能目录就把
     * 判断缓存全作废了。
     */
    fun judge(
        title: String,
        signature: String,
        relationship: String,
        judgeModel: String,
        judgeProtocol: String,
        ctxKey: String
    ): String = listOf(title, signature, relationship, judgeModel, judgeProtocol, ctxKey)
        .joinToString(FIELD)
}

package com.jev.probe.core.kb

/**
 * 把一整个知识库预扫成**一段**领域卡，而不是每轮塞 5 段 BM25 命中的原始片段。
 *
 * 为什么要有它（实况 A/B，见 `_reports/kb-effect_report.md`）：同一个问卷、
 * 同一张人设卡，只换注入内容，让同一个模型盲评「像不像网调语境里会说的话」：
 *
 * | 注入 | 提示词长度 | 盲评 |
 * | --- | --- | --- |
 * | 人设卡 + 5 段原始片段 | ~3,440 字 | 4.45 |
 * | 人设卡，无笔记 | ~255 字 | 4.12 |
 * | 笔记不变、去掉人设卡 | ~3,261 字 | 3.25 |
 * | 人设卡 + 一张领域卡 | ~910 字 | 4.60 |
 *
 * 两个结论：**人设卡是最大的杠杆**（+1.20），原始片段的边际收益很小（+0.33）
 * 而且把 3000 字塞进去会稀释人设；把整库先压成一张卡反而最高，长度只有 1/4。
 * 这也是 /home/emo/code/wenyi 的「全书预扫 → 注入每批」在对话场景里的形态 ——
 * 锚点少、密度高、不随话题漂移。
 *
 * 这个对象只做**纯文字**的两件事，不发请求：[sample] 按来源均衡采样、[user] 拼
 * 提示词、[note] 把模型输出收成一条常驻笔记。请求走
 * [com.jev.probe.jev.ReplyClient.domainBrief]，和 `tools/jev/build_domain_brief.py`
 * 是同一套采样与提示词 —— 那个脚本是离线实验路径（在开发机上直接读 notes.json），
 * 这里是手机上的生产路径。两边的抽样规则必须一起改，[DomainBriefTest] 会盯住这一点。
 */
object DomainBrief {

    /** 默认的主题名；调用方通常用 [PersonaCard.topic]，空则退回这个。 */
    const val DEFAULT_TOPIC = "网调"

    /** 采样总量上限（字符）。再长只会让模型把同样的规则换个说法说两遍。 */
    const val BUDGET_CHARS = 24_000

    /** 每份来源文档分到的采样预算。 */
    const val PER_DOC_CHARS = 1_600

    /** 每段只取开头这么多字 —— 够看出这段在讲什么，不必读完整段。 */
    const val SAMPLE_CHUNK = 400

    /** 领域卡的长度上限（汉字）。超了模型就开始复述情节。 */
    const val MAX_HAN = 900

    /** 生成出来的笔记标题后缀；前面拼主题，所以一张卡只服务一个主题。 */
    const val TITLE_SUFFIX = "领域卡（自动预扫）"

    fun title(topic: String): String = "${topic.ifBlank { DEFAULT_TOPIC }}$TITLE_SUFFIX"

    const val SYSTEM =
        "你在给一个中文私密角色扮演助手写**领域设定卡**。用户和对方是成年人、自愿、" +
            "已经约定好安全词和硬边界。这张卡会被逐字放进每次回复的提示词里，作用是让" +
            "回复保持在这个语境的规矩、流程和说法里，而不是给出通用的安慰或说教。\n" +
            "你只做归纳：素材里没有的东西不要编。用中文，不要 Markdown 标题符号，" +
            "直接分小段写，每段以「词：」开头。"

    fun user(topic: String, sample: String): String = """
        下面是从一个「${topic.ifBlank { DEFAULT_TOPIC }}」知识库里按来源均衡采样出来的片段。请把它压缩成一张领域卡。

        要求（很严，超了就废）：
        1. 总长不超过 ${MAX_HAN} 个汉字。
        2. 只写「让回复像这个语境里的话」所必需的东西，分这六段，每段一行到三行：
           角色与关系：谁是什么身份，谁定规矩
           称呼与语气：常用的称呼、说话的口吻和长度
           典型流程：这类对话通常怎么推进（开场／布置／执行／汇报／收尾）
           常用说法：这个领域里高频出现的词和句式（列 15-25 个词即可）
           边界与安全：必须一直遵守的底线、安全词怎么用、事后怎么处理
           不要做什么：最容易让回复「出戏」的几种写法
        3. 不要复述具体情节，不要写「根据素材」之类的元话，不要列表符号。
        4. 素材里反复出现但只是同一句话说很多遍的，合并成一句。

        素材：
        ----------------
        $sample
        ----------------
    """.trimIndent()

    /** 采样结果里一个来源文档的标题行，[sample] 用它分段。 */
    private fun header(doc: String, count: Int): String = "### 来源：$doc（共 $count 段）"

    /**
     * 按来源均衡采样：先按来源文档分组，每份文档均匀取几段，总量封顶。
     *
     * 为什么不按长度取前 N 条：用户这套素材里最大的一本书（235,747 字 / 367 段）
     * 占全库一半以上 —— 按长度排的话采样会被它一个人吃掉，领域卡就只剩那本书的
     * 一家之言。按文档分组、每份先分到 [perDocChars] 的额度，主题才铺得开。
     *
     * 来源取 `tags[1]`（导入时写的是文件名），没有标签就退回标题。
     */
    fun sample(
        notes: List<Note>,
        budgetChars: Int = BUDGET_CHARS,
        perDocChars: Int = PER_DOC_CHARS
    ): String {
        val byDoc = LinkedHashMap<String, MutableList<Note>>()
        notes.filter { it.enabled }.forEach { n ->
            val doc = n.tags.getOrNull(1)?.takeIf { it.isNotBlank() }
                ?: n.title.ifBlank { "（无标题）" }
            byDoc.getOrPut(doc) { ArrayList() }.add(n)
        }
        if (byDoc.isEmpty()) return ""

        val picked = ArrayList<String>()
        // 长的来源先分额度：大文档段多，先给它安排，小文档不至于被剩下。
        for ((doc, items) in byDoc.entries.sortedByDescending { it.value.size }) {
            val take = maxOf(1, perDocChars / SAMPLE_CHUNK)
            val step = maxOf(1, items.size / take)
            picked.add(header(doc, items.size))
            var i = 0
            while (i < items.size) {
                if (picked.size * SAMPLE_CHUNK > budgetChars) break
                picked.add(items[i].content.take(SAMPLE_CHUNK))
                i += step
            }
            if (picked.size * SAMPLE_CHUNK > budgetChars) break
        }
        return picked.joinToString("\n")
    }

    /**
     * 把模型输出收成一条**常驻**笔记（`alwaysOn = true`），这样它每轮都在，不靠
     * BM25 去猜这一轮该不该带上它。
     *
     * 返回 null 表示这段输出不能用（空，或者一个汉字都没有）。宁可什么都不存，
     * 也不要存一段空壳进知识库 —— 它会静默地占掉每次分析的预算。
     */
    fun note(
        raw: String,
        topic: String,
        id: String = KbStore.newId(),
        now: Long = System.currentTimeMillis()
    ): Note? {
        val body = normalize(raw) ?: return null
        return Note(
            id = id,
            title = title(topic),
            content = body,
            tags = listOf("领域卡", topic.ifBlank { DEFAULT_TOPIC }),
            alwaysOn = true,
            enabled = true,
            updatedAt = now,
            type = "note"
        )
    }

    /** 清掉 Markdown 装饰、裁到 [MAX_HAN] 个汉字；不可用时返回 null。 */
    fun normalize(raw: String): String? {
        var s = raw.trim()
        if (s.isEmpty()) return null
        // 模型偶尔会在外面套一段 ``` 或加粗，去掉不影响内容。
        s = s.removePrefix("```").removeSuffix("```").replace("**", "").trim()
        s = s.lines().joinToString("\n") { it.trimEnd() }.trim()
        if (hanCount(s) == 0) return null
        if (hanCount(s) <= MAX_HAN) return s
        // 超长就在最后一个句末处断，别把一句话劈成两半。
        var cut = -1
        var seen = 0
        for (index in s.indices) {
            if (isHan(s[index])) seen++
            if (seen >= MAX_HAN) { cut = index; break }
        }
        if (cut < 0) return s
        val head = s.substring(0, cut + 1)
        val stop = head.indexOfLast { it in "。！？\n" }
        return (if (stop > MAX_HAN / 2) head.substring(0, stop + 1) else head).trim()
    }

    fun hanCount(s: String): Int = s.count { isHan(it) }

    private fun isHan(ch: Char): Boolean = ch in '\u4e00'..'\u9fff'
}

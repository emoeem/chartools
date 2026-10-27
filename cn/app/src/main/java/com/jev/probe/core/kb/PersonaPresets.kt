package com.jev.probe.core.kb

/**
 * 一张**内置预设**，外加它在「专家库」页面里要显示的那些信息。
 *
 * 为什么不是 `Pair<String, String>`：预设从此不只是「名字 + 正文」，它还要带
 * 头像、一句话简介、标签、分类 —— 也就是用户在专家库里**浏览**时看到的全部。
 * 但 `Pair` 化的旧接口（[PersonaPresets.ALL]）被测试和 `restoreBuiltins` 依赖着，
 * 所以两者都由这一份数据派生：**单一数据源，既不重复也不会漂移**。
 *
 * [key] 是**稳定标识**，用户改名不变。`seeded[]` / `removed[]` 台账靠它认人 ——
 * 只按名字认的话，用户把「日常」改成「闲聊」，台账里记的旧名字再也匹配不上，
 * 下次启动就会**复活一份和它并排的重名副本**。
 *
 * [avatar] / [description] / [tags] / [category] 是**浏览层**：只被 UI 和检索读，
 * 永远不进 `promptText()`。这不是约定，是 [PersonaCard] 的构造决定的 ——
 * 提示词只由 `body` 解析出来的卡决定。
 */
data class PersonaPreset(
    val key: String,
    val name: String,
    val body: String,
    val category: String,
    val tags: List<String>,
    val description: String,
    /** 一个 emoji。不用图片资源：res/layout 只有一个 XML，也没有图片加载库。 */
    val avatar: String
)

/**
 * 内置起步人设卡 —— 现在它们是**种子数据**，不是唯一选项。
 *
 * 首装时由 [PersonaStore] 播种进 `kb/personas.json`，之后就是用户自己的东西：
 * 能改名、能改内容、能删、能复制、能导出。想找回来时「恢复内置模板」会按
 * `presetKey` 把删掉的那几张补回来。所以这个 object 的职责只剩一件 ——
 * 给第一次打开 App 的人看几个**长成什么样才对的示范**。
 *
 * 为什么是数据类而不是界面代码：这些字串不是排版，是**喂给 `PersonaCard.parse` 的
 * 输入**。放在这里，单测就能断言「每一张模板都真的能解析成结构化卡、主题和语域都
 * 认得出来、硬边界拆成了闸门能匹配的关键词」—— 模板一旦写错（比如把 `主题` 写成
 * `话题方向`，或者硬边界写成整句话），`PersonaCard` 会**静默地**退回自由文本，
 * 用户看到的是「填了人设但回复没变」。那种失败没有报错，只能靠测试挡。
 *
 * 写的都是**键**，不是散文：散文只会被原样塞进提示词，键才会被拆开分别送进提示词、
 * 闸门和语域开关。
 *
 * 「硬边界」只写关键词（`家人` 而不是「不要提家人」）：`SafetyGate` 是**逐字**
 * 匹配对方那条消息，写成整句话反而匹配不上。也**必须写两个字以上** ——
 * `PersonaCard.splitBoundaries` 会把单字条目丢掉（单字当关键词误杀太多），
 * 所以「钱」写进去等于没写，这里一律用双字词。只约束我方措辞、不该拦对方的词
 * （销售的「稳赚」这类）写**避谈**而不是硬边界——硬边界会在对方提到它的那一轮
 * 直接掐掉全部候选，避谈只管住我的回复不许出现。
 */
object PersonaPresets {

    /**
     * 出厂预设。**顺序即专家库里的初始显示顺序**，也是 `PersonaPresetsTest`
     * 和 `PersonaBaselineTest` 逐张校验的对象。
     */
    val PRESETS: List<PersonaPreset> = listOf(
        PersonaPreset(
            key = "roleplay.dom",
            name = "网调·我是主",
            category = "情感",
            tags = listOf("网调", "主位", "短句"),
            description = "网调里的主位：定规矩、要求汇报，短句命令式，不解释理由",
            avatar = "🖤",
            body =
                """
                称呼：叫我主人，我称你乖
                关系：网调关系，我定规矩，你执行并汇报
                语气：短句、命令式，不解释理由，不用表情
                语域：亲密
                主题：网调
                情境：线上，见不到面
                硬边界：家人、前任
                安全词：红灯
                黄灯：黄灯
                示例：
                我：跪好，等我
                我：做完拍一张
                我：超时了，自己想怎么罚
                """.trimIndent(),
        ),
        PersonaPreset(
            key = "roleplay.sub",
            name = "网调·我是奴",
            category = "情感",
            tags = listOf("网调", "臣位", "汇报"),
            description = "网调里的臣位：照做并汇报，短句顺从，带一点示弱和讨好",
            avatar = "🕊",
            body =
                """
                称呼：我叫你主人，你叫我小狗
                关系：网调关系，你定规矩，我照做并汇报
                语气：短句、顺从，带一点示弱和讨好
                语域：亲密
                主题：网调
                情境：线上，随时可能收到任务
                硬边界：家人、前任
                安全词：红灯
                黄灯：黄灯
                示例：
                我：主人，我做完了
                我：我错了，请罚
                我：现在方便吗，想请示
                """.trimIndent(),
        ),
        PersonaPreset(
            key = "daily.friend",
            name = "日常",
            category = "日常",
            tags = listOf("朋友", "口语", "松弛"),
            description = "日常闲聊：用平时的叫法，口语松弛，不端着",
            avatar = "🌿",
            body =
                """
                称呼：用平时的叫法
                关系：朋友
                语气：口语、松弛，别端着
                主题：日常
                示例：
                我：在忙吗
                我：晚饭吃了吗
                """.trimIndent(),
        ),
        // 第四张的意义是把「人设」从亲密场景里拽出来：用户原话是「销售的时候
        // 需要一个销售的说话风格」。「稳赚／保证收益」写成**避谈**而不是硬边界：
        // 闸门是逐字匹配**对方**那条消息，写成硬边界时客户一问「能稳赚吗」整轮
        // 就没候选了——恰恰是最需要回的一轮。避谈只约束我方措辞：这两个词
        // （以及换汤不换药的许诺）不许出现在我的回复里。
        PersonaPreset(
            key = "sales.followup",
            name = "销售·跟单",
            category = "销售",
            tags = listOf("跟单", "方案", "不催"),
            description = "销售跟单：先结论后理由，不催不捧，不替客户许诺",
            avatar = "📈",
            body =
                """
                称呼：按对方名片上的称呼，姓＋总或姓＋老师
                关系：销售和客户，我给方案，他做决定
                语气：短句、具体，先给结论再给理由，不催不捧
                主题：销售
                情境：微信或电话跟单，隔着屏幕
                避谈：稳赚、保证收益
                示例：
                我：王总，方案按您上次说的改完了，您看哪天方便过一遍
                我：这个折扣我申请不下来，先如实跟您说
                我：不急，您先忙，我明天上午再跟您确认
                """.trimIndent(),
        ),
    )

    /**
     * 老接口：`名字 to 正文`。**由 [PRESETS] 派生**，不单独维护一份 ——
     * 两份同名数据早晚会漂移，而这里的漂移表现是「设置页显示的名字和实际播种的不一样」。
     */
    val ALL: List<Pair<String, String>> = PRESETS.map { it.name to it.body }

    /** 按名字反查 `presetKey`；不是内置预设时返回空串（v1 → v2 迁移用）。 */
    fun keyOf(name: String): String = PRESETS.firstOrNull { it.name == name }?.key.orEmpty()

    fun byKey(key: String): PersonaPreset? =
        if (key.isBlank()) null else PRESETS.firstOrNull { it.key == key }
}

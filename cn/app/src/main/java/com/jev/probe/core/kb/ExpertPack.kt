package com.jev.probe.core.kb

import org.json.JSONArray
import org.json.JSONObject

/**
 * **专家目录**：随 APK 打包的 331 位专家（来自 MichengAI/dsh-agency-agents）。
 *
 * ## 它和「我的专家库」是什么关系
 *
 * 目录是**只读的货架**，不是第二个存储。[PersonaStore] 里那些条目才是用户的东西。
 * 用户在专家库里点到一位没加入的专家，[PersonaStore.install] 会把它落成一条
 * [PersonaProfile] —— 之后它就是普通的人设卡：能改名、能改正文、能删。
 *
 * 这样安排是为了守住 S1 就定死的三条不变量：
 *
 * 1. **专家只能由 [PersonaProfile] 派生**。目录条目本身就是 [PersonaPreset]，
 *    和内置那 14 张预设**同一个类型**，所以「派生」只有一条路径（[asProfile]）。
 * 2. **`Prefs.style` 是唯一真源**。目录里没有「当前选中」的概念。
 * 3. **只有 `body` 进提示词**。目录里的 `emoji` / `category` / `tags` /
 *    `description` 全是浏览层，卡片怎么画都不会碰 `promptText()`。
 *
 * ## 为什么不把 JSON 解析放进 Activity
 *
 * 这一段是纯函数 `String → 列表`，不依赖 `Context`：单测能直接喂真实的
 * `assets/kb/experts.json`，把「331 条里有一条解析不成卡」这种问题在 CI 里挡掉。
 * 读文件的那一行（`assets.open`）留在 [com.jev.probe.ExpertActivity]。
 *
 * ## 解析失败时的态度
 *
 * **不抛异常、不返回 null**：目录坏了只该退化成「没有货架」，不能把整个专家库页面
 * 带崩 —— 用户自己的 14 张卡还在 `personas.json` 里，那才是他的数据。
 */
object ExpertPack {

    /** APK 内的路径。改这里要同步 [tools/gen_experts.py] 的 `--out`。 */
    const val ASSET: String = "kb/experts.json"

    /**
     * 分类抽屉的**固定顺序**：五个老分类在前（那 14 张手写预设还用着它们），
     * 后面是上游 22 个 division。
     *
     * 和 JSON 里的 `categories` 字段必须逐字一致 —— `ExpertPackTest` 会比对，
     * 因为顺序错了不会报错，只会让 chips 的顺序莫名其妙。
     */
    val CATEGORY_ORDER: List<String> = listOf(
        "情感", "销售", "职场", "客服", "日常",
        "学术研究", "企业战略", "设计", "技术工程", "金融财务",
        "游戏开发", "地理信息", "医疗健康", "人力组织", "法务合规",
        "市场营销", "投放广告", "产品", "项目管理", "研究",
        "安全", "空间计算", "垂直专业", "供应链", "质量测试"
    )

    /** 目录的出处信息，只用于「关于」这类展示，不参与任何逻辑。 */
    data class Meta(
        val source: String = "",
        val commit: String = "",
        val hash: String = "",
        val categories: List<String> = emptyList()
    )

    /**
     * @param presets 已按上游文件名排序的专家（顺序稳定，所以「综合」排序结果可复现）。
     * @param problem 解析失败时的说明；空串表示正常。
     */
    data class Parsed(
        val presets: List<PersonaPreset> = emptyList(),
        val meta: Meta = Meta(),
        val problem: String = ""
    ) {
        val ok: Boolean get() = presets.isNotEmpty()
    }

    /**
     * 解析目录 JSON。任何异常都收敛成 `problem`，绝不外抛。
     *
     * 逐条容错而不是整包放弃：一条 emoji 写坏了，不该让另外 330 位专家消失。
     */
    fun parse(json: String): Parsed {
        if (json.isBlank()) return Parsed(problem = "目录为空")
        val root = runCatching { JSONObject(json) }.getOrElse { e ->
            return Parsed(problem = "目录不是合法 JSON：${e.message}")
        }
        val meta = Meta(
            source = root.optString("source"),
            commit = root.optString("sourceCommit"),
            hash = root.optString("contentHash"),
            categories = root.optJSONArray("categories").toStringList()
        )
        val array: JSONArray = root.optJSONArray("experts") ?: return Parsed(
            meta = meta, problem = "目录缺少 experts 数组"
        )
        val out = ArrayList<PersonaPreset>(array.length())
        var skipped = 0
        for (i in 0 until array.length()) {
            val o = array.optJSONObject(i) ?: run { skipped++; null } ?: continue
            val preset = runCatching { o.toPreset() }.getOrNull()
            if (preset == null || preset.body.isBlank() || preset.key.isBlank()) {
                skipped++
                continue
            }
            out += preset
        }
        val problem = when {
            out.isEmpty() -> "目录里没有可用专家（跳过 $skipped 条）"
            skipped > 0 -> "目录有 $skipped 条解析失败，已跳过"
            else -> ""
        }
        return Parsed(presets = out, meta = meta, problem = problem)
    }

    private fun JSONObject.toPreset(): PersonaPreset = PersonaPreset(
        key = optString("key"),
        name = optString("name").ifBlank { optString("key") },
        body = optString("body"),
        category = optString("category"),
        tags = optJSONArray("tags").toStringList(),
        description = optString("description"),
        avatar = optString("emoji").ifBlank { "🧩" }
    )

    private fun JSONArray?.toStringList(): List<String> {
        if (this == null) return emptyList()
        val out = ArrayList<String>(length())
        for (i in 0 until length()) {
            val v = optString(i).trim()
            if (v.isNotEmpty()) out += v
        }
        return out
    }
}

/**
 * 预设 → 人设条目。**全工程唯一**的一条派生路径。
 *
 * 之前它藏在 `PersonaStore` 里当一个文件私有扩展，只要目录也想产出条目，
 * 就会出现第二份同样的 13 行 —— 而两份一旦漂移，症状是「从目录加入的专家少了分类」，
 * 不会有任何报错。所以搬到纯 Kotlin 层，[PersonaStore] 和目录都调它。
 */
fun PersonaPreset.asProfile(id: String): PersonaProfile = PersonaProfile(
    id = id,
    name = name,
    body = body,
    builtin = true,
    avatar = avatar,
    description = description,
    tags = tags,
    category = category,
    presetKey = key
)

/**
 * 把「我的库」和「目录」拼成一张列表：**同 `presetKey` 时我的库优先**。
 *
 * 目录条目是货架上的样品，[PersonaStore] 里那条是用户手里已经改过名、
 * 改过正文的那一份。拼的时候留样品、丢掉用户改过的东西，是这类功能最容易犯的错
 * ——它不会报错，只会让用户以为「我改的东西丢了」。
 *
 * 目录条目的 id 统一是 `pack:<key>`：稳定、可预测，且和库里 `UUID` 形状不同，
 * 所以「这条是不是目录样品」判断起来没有歧义。
 */
object ExpertShelf {

    const val PACK_ID_PREFIX: String = "pack:"

    fun isFromPack(p: PersonaProfile): Boolean = p.id.startsWith(PACK_ID_PREFIX)

    fun packId(key: String): String = PACK_ID_PREFIX + key

    /**
     * @param mine 用户库里已有的条目（含他从目录加入的）。
     * @param pack 目录里的全部专家。
     * @return 我的条目 + 尚未加入的目录条目；顺序稳定。
     */
    fun merge(
        mine: List<PersonaProfile>,
        pack: List<PersonaPreset>
    ): List<PersonaProfile> {
        val mineKeys = mine.map { it.presetKey }.filter { it.isNotBlank() }.toSet()
        val mineNames = mine.map { it.name }.toSet()
        val ghosts = pack
            .filter { it.key !in mineKeys && it.name !in mineNames }
            .map { it.asProfile(packId(it.key)) }
        return mine + ghosts
    }
}

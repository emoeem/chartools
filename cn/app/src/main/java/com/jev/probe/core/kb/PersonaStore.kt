package com.jev.probe.core.kb

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** [PersonaStore.importJson] 的结果。永远不抛，失败写在 [error] 里。 */
data class PersonaImport(
    val added: Int = 0,
    val renamed: Int = 0,
    val skipped: Int = 0,
    val error: String = ""
) {
    val ok: Boolean get() = error.isBlank()

    fun describe(): String = when {
        !ok -> error
        added == 0 && renamed == 0 && skipped == 0 -> "没找到可导入的人设"
        else -> buildString {
            append("导入 $added 条")
            if (renamed > 0) append("，$renamed 条因重名改成「…(导入)」")
            if (skipped > 0) append("，跳过 $skipped 条完全相同/为空")
        }
    }
}

/**
 * 人设库：`filesDir/kb/personas.json`。
 *
 * 存在的理由是「人设不该被编译进 APK」。在此之前，能选的人设只有
 * [PersonaPresets] 里那几张写死的字串 —— 卖货的话术、客服的口气、和甲方说话的
 * 分寸，全都要用户重新敲一遍，而且一关页面就没了。有了这个库，人设是**数据**：
 * 有名字、能存、能改、能导出给第二台机器。
 *
 * 三条设计约束：
 *
 * 1. **`Prefs.style` 仍然是唯一真源。** 库只登记名字和原文，不存「当前选了谁」。
 *    谁是当前人设靠 [activeOf] 比原文算出来 —— 两边各存一份 id 必然会漂移，而
 *    漂移的表现是「界面说生效的是 A，实际发出去的是 B」，这种错没有报错可查。
 * 2. **绝不静默丢用户写的东西。** 解析失败时把原文件备份成
 *    `personas.corrupt-<时间戳>.json` 再继续，而不是像缓存那样一删了之。
 * 3. **导入不覆盖。** 同名不同文时新增一条 `名字(导入)` —— 用户点「导入」想要的是
 *    「多几份」，不是「把现在这份换掉」。
 *
 * 单写者：所有读写过同一把锁，落盘走临时文件 + rename（同 [KbStore]）。
 *
 * ## v2 文件格式与两个台账
 *
 * ```json
 * {"version":2,
 *  "seeded":["roleplay.dom", ...],
 *  "removed":["daily.friend"],
 *  "items":[{...}]}
 * ```
 *
 * - `seeded[]`：**播过**哪些预设。老用户升级后新加的预设能补进来，靠的就是
 *   「`key ∉ seeded`」这一个条件。
 * - `removed[]`：用户**主动删掉**过哪些预设。它是 `seeded` 的补充说明 ——
 *   点名「这张是删的，不是没播过」，`restoreBuiltins()` 会它显式放行（用户点
 *   「恢复内置模板」就是反悔）。
 *
 * 没有这两个台账，只能靠「文件在不在」判断要不要播种，于是：① 老用户永远收不到
 * 新增预设；② 一旦改成「每次启动补缺」，用户删掉的预设会每次启动都长回来。
 */
class PersonaStore private constructor(context: Context) {

    private val app = context.applicationContext
    private val lock = Any()

    private val root: File get() = File(app.filesDir, "kb")
    private val file: File get() = File(root, "personas.json")

    /** 台账的内存副本；每次读盘由 [decode] 刷新，写盘时随 items 一起落盘。 */
    private val seeded = LinkedHashSet<String>()
    private val removed = LinkedHashSet<String>()

    /** 最近一次读盘的坏消息（文件损坏已备份、升级没写成等），给设置页回显用；正常为 null。 */
    @Volatile
    var lastProblem: String? = null
        private set

    // ------------------------------------------------------------------ 读

    fun list(): List<PersonaProfile> = synchronized(lock) { loadLocked() }

    /**
     * 当前生效的是哪一条。
     *
     * 只比原文（去首尾空白），因为 [Prefs.style][com.jev.probe.core.Prefs] 是唯一真源；
     * 匹配不上任何一条就是「未保存的自由文本」，这是合法状态，不是错误。
     */
    fun activeOf(style: String): PersonaProfile? {
        val text = style.trim()
        if (text.isEmpty()) return null
        return list().firstOrNull { it.body.trim() == text }
    }

    fun get(id: String): PersonaProfile? =
        if (id.isBlank()) null else list().firstOrNull { it.id == id }

    /** 「清空知识库」的确认框要报得出会连带删掉几份人设。 */
    fun count(): Int = list().size

    /** 台账快照（诊断/测试用）：哪些预设播过、哪些被用户删过。 */
    fun ledger(): Pair<Set<String>, Set<String>> = synchronized(lock) {
        loadLocked()
        seeded.toSet() to removed.toSet()
    }

    // ------------------------------------------------------------------ 写

    /**
     * 新建或就地更新。[id] 为 null 时新建。
     *
     * 就地更新**保留**浏览层字段（头像/简介/标签/分类/热度/`presetKey`/绑定）——
     * 编辑正文不该顺手清掉用户填过的分类。
     *
     * @return 落盘后的条目；正文为空或 [id] 指向不存在的条目时返回 null（不新建半条）。
     */
    fun save(name: String, body: String, id: String? = null): PersonaProfile? {
        val text = body.trimEnd()
        if (text.isBlank()) return null
        val label = name.trim().ifBlank { "未命名人设" }
        return synchronized(lock) {
            val items = loadLocked().toMutableList()
            val at = if (id.isNullOrBlank()) -1 else items.indexOfFirst { it.id == id }
            if (!id.isNullOrBlank() && at < 0) return@synchronized null
            val entry = if (at >= 0) {
                items[at].copy(name = label, body = text, updatedAt = System.currentTimeMillis())
            } else {
                PersonaProfile(newId(), label, text)
            }
            if (at >= 0) items[at] = entry else items += entry
            if (writeLocked(items)) entry else null
        }
    }

    /** 带完整字段的新建（专家编辑器用）；正文为空时不新建。 */
    fun create(
        name: String,
        body: String,
        avatar: String? = null,
        description: String? = null,
        tags: List<String> = emptyList(),
        category: String? = null,
        skillRefs: List<String> = emptyList(),
        appPkgs: List<String> = emptyList()
    ): PersonaProfile? {
        val text = body.trimEnd()
        if (text.isBlank()) return null
        return synchronized(lock) {
            val items = loadLocked().toMutableList()
            val entry = PersonaProfile(
                id = newId(),
                name = name.trim().ifBlank { "未命名专家" },
                body = text,
                avatar = avatar?.trim()?.ifBlank { null },
                description = description?.trim()?.ifBlank { null },
                tags = tags.map { it.trim() }.filter { it.isNotBlank() }.distinct(),
                category = category?.trim()?.ifBlank { null },
                skillRefs = skillRefs.filter { it.isNotBlank() }.distinct(),
                appPkgs = appPkgs.filter { it.isNotBlank() }.distinct()
            )
            items += entry
            if (writeLocked(items)) entry else null
        }
    }

    /** 只改浏览层（头像/简介/标签/分类），不动正文。 */
    fun updateMeta(
        id: String,
        name: String? = null,
        avatar: String? = null,
        description: String? = null,
        tags: List<String>? = null,
        category: String? = null
    ): PersonaProfile? = synchronized(lock) {
        val items = loadLocked().toMutableList()
        val at = items.indexOfFirst { it.id == id }
        if (at < 0) return@synchronized null
        val old = items[at]
        val next = old.copy(
            name = name?.trim()?.ifBlank { old.name } ?: old.name,
            avatar = avatar?.trim()?.ifBlank { null },
            description = description?.trim()?.ifBlank { null },
            tags = tags?.map { it.trim() }?.filter { it.isNotBlank() }?.distinct() ?: old.tags,
            category = category?.trim()?.ifBlank { null },
            updatedAt = System.currentTimeMillis()
        )
        items[at] = next
        if (writeLocked(items)) next else null
    }

    /**
     * 记一次「这个专家被用了」。**唯一**的热度打点入口。
     *
     * 故意**不动** `updatedAt`：「最新」排序按「最近编辑」排，如果套用也刷时间，
     * 那么「最新」会悄悄变成「最近使用」，两个概念糊成一个，用户永远说不清
     * 为什么刚建的那条专家排在最后。
     *
     * @return 更新后的条目；id 不存在时返回 null（不打点，也不写盘）。
     */
    fun touch(id: String): PersonaProfile? = synchronized(lock) {
        if (id.isBlank()) return@synchronized null
        val items = loadLocked().toMutableList()
        val at = items.indexOfFirst { it.id == id }
        if (at < 0) return@synchronized null
        val next = items[at].copy(usedCount = items[at].usedCount + 1)
        items[at] = next
        if (writeLocked(items)) next else null
    }

    /**
     * 按正文打点 —— 起草链路手上只有 `Prefs.style`（那段文本），没有 id。
     * 匹配不上任何一条时什么也不做：自由文本不是专家，没有热度可记。
     */
    fun touchActive(style: String): PersonaProfile? {
        val hit = activeOf(style) ?: return null
        return touch(hit.id)
    }

    /**
     * 删除。删的是内置预设时**记一笔墓碑**（`removed[]`），下次启动不会复活。
     *
     * 注意：这里的「不复活」有两条独立保险 —— `seeded[]` 里永远留着这个 key
     * （播过就是播过），`removed[]` 只是把「用户是主动删的」这件事说明白，
     * 好让「恢复内置模板」知道该放行哪一张。
     */
    fun delete(id: String): Boolean = synchronized(lock) {
        val items = loadLocked().toMutableList()
        val at = items.indexOfFirst { it.id == id }
        if (at < 0) return@synchronized false
        val key = items[at].presetKey
        items.removeAt(at)
        if (key.isNotBlank()) removed += key
        val ok = writeLocked(items)
        if (!ok) reloadLedgerLocked()
        ok
    }

    /** 复制一份，名字加「副本」。返回新的那条。 */
    fun duplicate(id: String): PersonaProfile? = synchronized(lock) {
        val items = loadLocked().toMutableList()
        val src = items.firstOrNull { it.id == id } ?: return@synchronized null
        // 副本是**用户自己的**专家，不是那张预设：清掉 presetKey，否则台账里
        // 会出现两条同 key 的条目，删除语义会变得说不清。热度也从 0 开始。
        val copy = PersonaProfile(
            id = newId(),
            name = uniqueName(items, src.name + " 副本"),
            body = src.body,
            avatar = src.avatar,
            description = src.description,
            tags = src.tags,
            category = src.category,
            skillRefs = src.skillRefs,
            appPkgs = src.appPkgs
        )
        items += copy
        if (writeLocked(items)) copy else null
    }

    /**
     * 把**缺的**内置预设补回来，已存在的（按 `presetKey`，退化时按名字）跳过。
     * 删了内置模板又想找回来时用；不会复制出一堆同名条目。
     *
     * 这里对 `removed[]` **显式放行**：用户点「恢复内置模板」就是明确反悔。
     */
    fun restoreBuiltins(): Int = synchronized(lock) {
        val items = loadLocked().toMutableList()
        val haveKeys = items.map { it.presetKey }.filter { it.isNotBlank() }.toSet()
        val haveNames = items.map { it.name }.toSet()
        var added = 0
        PersonaPresets.PRESETS.forEach { preset ->
            val already = preset.key in haveKeys || preset.name in haveNames
            if (!already) {
                items += preset.toProfile()
                seeded += preset.key
                removed -= preset.key
                added++
            }
        }
        if (added > 0 && !writeLocked(items)) {
            reloadLedgerLocked()
            return@synchronized 0
        }
        added
    }

    /**
     * 从**专家目录**（[ExpertPack]，331 位）装一位进「我的专家库」。
     *
     * 和 [restoreBuiltins] 的区别是「谁主动」：那里是用户点「恢复内置模板」批量补
     * 14 张，这里是用户在专家库里点了某一位。相同的是两条台账规则 ——
     * **装过就记 `seeded`**（下次启动不再当新预设播）、**从 `removed` 里划掉**
     * （用户主动反悔）。
     *
     * 已经装过（同 `presetKey`）就直接返回那一条，**不写第二份**：目录卡片和
     * 库里条目会在列表里并排出现，复制一份重名条目是这类功能最典型的翻车。
     *
     * 台账更新在 [writeLocked] **之前**：`writeLocked` 序列化的就是此刻的 `seeded`，
     * 反过来写文件里就永远少这几笔（见 [topUpLocked] 里那次真机抓到的回归）。
     */
    fun install(preset: PersonaPreset): PersonaProfile? = synchronized(lock) {
        val items = loadLocked().toMutableList()
        items.firstOrNull { it.presetKey.isNotEmpty() && it.presetKey == preset.key }
            ?.let { return@synchronized it }
        val entry = preset.toProfile()
        items += entry
        seeded += preset.key
        removed -= preset.key
        val ok = writeLocked(items)
        if (!ok) reloadLedgerLocked()
        if (ok) entry else null
    }

    // ------------------------------------------------------- 导入 / 导出

    /**
     * 全量导出成 JSON（人设库是给人看的，`toString(2)`）。
     * 拿去另一台机器「导入」即可，不需要 root、不需要云。
     *
     * 导出**带浏览层**（头像/简介/标签/分类）与 S4 的绑定，否则「把我的专家搬过去」
     * 会搬成一堆没头像没分类的裸文本。不导出 `presetKey`（那是本机的台账标识）和
     * `usedCount`（另一台机器上的热度没有意义）。
     */
    fun exportJson(): String = synchronized(lock) {
        val arr = JSONArray()
        loadLocked().forEach { p ->
            arr.put(
                JSONObject()
                    .put("name", p.name)
                    .put("body", p.body)
                    .put("updatedAt", p.updatedAt)
                    .put("builtin", p.builtin)
                    .put("avatar", p.avatar ?: JSONObject.NULL)
                    .put("description", p.description ?: JSONObject.NULL)
                    .put("tags", p.tags.toJsonArray())
                    .put("category", p.category ?: JSONObject.NULL)
                    .put("skillRefs", p.skillRefs.toJsonArray())
                    .put("appPkgs", p.appPkgs.toJsonArray())
            )
        }
        JSONObject().put("version", VERSION).put("items", arr).toString(2)
    }

    /** 单条导出：只有正文（可直接粘进「人设」输入框，或发给别人）。 */
    fun exportText(id: String): String = get(id)?.body.orEmpty()

    /**
     * 导入。接受三种形态，都不抛异常：
     *
     * - 本库 [exportJson] 的输出（`{"version":2,"items":[…]}`）
     * - 裸数组 `[{"name":…,"body":…}]`（手工拼的、别的工具给的）
     * - 一段**纯文本人设卡**（没有 name 字段时用第一行当名字）
     *
     * 重名策略见类注释：同名不同文 → 新增 `名字(导入)`。绝不覆盖已有条目。
     * 浏览层字段（头像/简介/标签/分类/绑定）**有就带上，没有就空着** ——
     * 导入别人的旧版导出文件不会因为缺字段而失败。
     */
    fun importJson(raw: String): PersonaImport = synchronized(lock) {
        val text = raw.trim()
        if (text.isEmpty()) return@synchronized PersonaImport(error = "内容是空的")

        val incoming = ArrayList<Incoming>()
        try {
            val root = when {
                text.startsWith("[") -> JSONArray(text)
                else -> JSONObject(text).optJSONArray("items") ?: JSONArray()
            }
            for (i in 0 until root.length()) {
                val o = root.optJSONObject(i) ?: continue
                val body = o.optString("body", "").trimEnd()
                if (body.isBlank()) continue
                incoming += Incoming(
                    name = o.optString("name", "").trim(),
                    body = body,
                    avatar = o.optText("avatar"),
                    description = o.optText("description"),
                    tags = o.stringList("tags"),
                    category = o.optText("category"),
                    skillRefs = o.stringList("skillRefs"),
                    appPkgs = o.stringList("appPkgs")
                )
            }
        } catch (e: Exception) {
            // 不是 JSON —— 当成一张纯文本人设卡收下，而不是报错让人重来。
            val name = text.split('\n').firstOrNull { it.isNotBlank() }
                ?.substringBefore('：')?.take(24)?.trim().orEmpty()
            incoming += Incoming(name = name.ifBlank { "导入的人设" }, body = text)
        }
        if (incoming.isEmpty()) return@synchronized PersonaImport(error = "里面没有人设（缺 body / 正文为空）")

        val items = loadLocked().toMutableList()
        var added = 0
        var renamed = 0
        var skipped = 0
        incoming.forEach { src ->
            val name = src.name.ifBlank { "导入的人设" }
            val same = items.firstOrNull { it.name == name }
            when {
                same == null -> {
                    items += src.toProfile(name)
                    added++
                }
                same.body.trim() == src.body.trim() -> skipped++
                else -> {
                    items += src.toProfile(uniqueName(items, "$name(导入)"))
                    added++
                    renamed++
                }
            }
        }
        if (added == 0) return@synchronized PersonaImport(skipped = skipped)
        if (!writeLocked(items)) return@synchronized PersonaImport(error = "写盘失败，人设库没变")
        PersonaImport(added = added, renamed = renamed, skipped = skipped)
    }

    // -------------------------------------------------------------- 落盘

    /**
     * 读盘。三条路径：文件不存在 → 播种；文件是 v1 → 迁移；文件是 v2 → 补缺预设。
     *
     * 「只播种一次」靠的是文件里的 `seeded[]` 台账，**不再靠文件在不在**：
     * 后者只能表达「有没有播过」，表达不了「播过之后用户删了哪几张」，
     * 于是老用户永远收不到新增预设 —— 那是专家库这个功能的地基，不能坏在这。
     */
    private fun loadLocked(): List<PersonaProfile> {
        val f = file
        if (!f.isFile) return seedLocked()
        val doc = runCatching { decode(f.readText(Charsets.UTF_8)) }.getOrNull()
        if (doc != null) {
            seeded.clear(); seeded.addAll(doc.seeded)
            removed.clear(); removed.addAll(doc.removed)
            return if (doc.version < VERSION) migrateLocked(doc) else topUpLocked(doc.items)
        }

        // 解析失败：先备份再放行，绝不直接覆盖用户的文件。
        val stamp = System.currentTimeMillis()
        val backup = File(root, "personas.corrupt-$stamp.json")
        val saved = runCatching {
            root.mkdirs()
            f.copyTo(backup, overwrite = true)
            true
        }.getOrDefault(false)
        lastProblem = if (saved) {
            "人设库文件读不出来，已备份到 kb/${backup.name}，现在是空库（备份没删，别慌）"
        } else {
            "人设库文件读不出来，也没能备份（储存空间？），现在是空库"
        }
        Log.w(TAG, "personas.json unreadable, backup=$saved")
        return emptyList()
    }

    private fun seedLocked(): List<PersonaProfile> {
        val items = PersonaPresets.PRESETS.map { it.toProfile() }
        seeded.clear()
        removed.clear()
        items.forEach { seeded += it.presetKey }
        writeLocked(items)
        lastProblem = null
        return items
    }

    /**
     * v1 → v2。**这是全套改动里最高危的一步**：写坏 = 用户人设全没。
     *
     * 顺序刻意固定：先备份原文件 → 再算新结构 → 最后原子写。写失败也**不丢数据**：
     * 内存里用迁移结果继续跑（用户这次能用），原 v1 文件原样留着，下次启动再试。
     *
     * 台账怎么填：v1 的首读会把**全部**预设播种一遍，所以「库里没有某张」等价于
     * 「用户把它删了」。于是迁移时把全部内置 key 一次性记进 `seeded[]` ——
     * 那几张被删掉的就再也不会被当成「新预设」复活。这不是偷懒，是 v1 的唯一解：
     * 被删掉的条目连名字都没留下，无从反推。
     */
    private fun migrateLocked(doc: Doc): List<PersonaProfile> {
        val stamp = System.currentTimeMillis()
        val backup = File(root, "personas.v1-$stamp.json")
        val saved = runCatching {
            root.mkdirs()
            file.copyTo(backup, overwrite = true)
            true
        }.getOrDefault(false)

        val items = doc.items.map { p ->
            // 老条目的 presetKey 只能按名字反查（v1 没存过它）。改名过的那几条查不到，
            // 就留空 —— 它们从此被当成用户自己的专家，不会再被预设逻辑碰。
            val key = if (p.builtin) PersonaPresets.keyOf(p.name) else ""
            if (key.isNotEmpty()) p.copy(presetKey = key) else p
        }
        seeded.clear()
        PersonaPresets.PRESETS.forEach { seeded += it.key }
        removed.clear()

        val ok = writeLocked(items)
        lastProblem = when {
            ok -> null
            saved -> "人设库升级到 v2 没写成功，原文件已备份到 kb/${backup.name}，本次只读"
            else -> "人设库升级到 v2 没写成功，也没能备份，本次只读（内容还在，只是没落盘）"
        }
        Log.i(TAG, "personas migrated v1->v2 ok=$ok backup=$saved items=${items.size}")
        return items
    }

    /**
     * v2 的补缺：把「没播过、也没被删过」的预设补进来。
     *
     * 只有这一条路径能让老用户收到新增预设。两个条件缺一不可 ——
     * 少了 `seeded` 会重复播，少了 `removed` 会把用户删掉的长回来。
     */
    private fun topUpLocked(current: List<PersonaProfile>): List<PersonaProfile> {
        val present = current.map { it.presetKey }.filter { it.isNotBlank() }.toSet()
        val missing = PersonaPresets.PRESETS.filter {
            it.key !in present && it.key !in seeded && it.key !in removed
        }
        if (missing.isEmpty()) return current

        val items = current.toMutableList()
        missing.forEach { items += it.toProfile() }
        // 台账必须在写盘**之前**补上：`writeLocked` 序列化的是此刻的 `seeded`。
        // 反过来写（先写盘再记台账）文件里就永远少这几笔 —— 真机实测过，
        // 补进来的 10 张预设只活在 `items` 里，`seeded` 停在 4，台账等于说谎。
        missing.forEach { seeded += it.key }
        if (!writeLocked(items)) {
            reloadLedgerLocked()
            lastProblem = "有新的内置专家没写进人设库（储存空间？），下次启动会再试"
            return current
        }
        return items
    }

    private fun writeLocked(items: List<PersonaProfile>): Boolean {
        val arr = JSONArray()
        items.forEach { p ->
            arr.put(
                JSONObject()
                    .put("id", p.id)
                    .put("name", p.name)
                    .put("body", p.body)
                    .put("updatedAt", p.updatedAt)
                    .put("builtin", p.builtin)
                    .put("avatar", p.avatar ?: JSONObject.NULL)
                    .put("description", p.description ?: JSONObject.NULL)
                    .put("tags", p.tags.toJsonArray())
                    .put("category", p.category ?: JSONObject.NULL)
                    .put("usedCount", p.usedCount)
                    .put("presetKey", p.presetKey)
                    .put("skillRefs", p.skillRefs.toJsonArray())
                    .put("appPkgs", p.appPkgs.toJsonArray())
            )
        }
        val text = JSONObject()
            .put("version", VERSION)
            .put("seeded", seeded.toJsonArray())
            .put("removed", removed.toJsonArray())
            .put("items", arr)
            .toString(2)
        return writeAtomic(file, text)
    }

    private fun writeAtomic(f: File, text: String): Boolean {
        val tmp = File(f.parentFile, f.name + ".tmp")
        return try {
            f.parentFile?.mkdirs()
            tmp.writeText(text, Charsets.UTF_8)
            if (tmp.renameTo(f)) return true
            Log.w(TAG, "rename failed, overwriting ${f.name} in place")
            f.writeText(text, Charsets.UTF_8)
            runCatching { tmp.delete() }
            true
        } catch (e: Exception) {
            Log.w(TAG, "write ${f.name} failed: ${e.javaClass.simpleName}")
            runCatching { tmp.delete() }
            false
        }
    }

    /**
     * 写盘失败时把台账从磁盘重新对齐。
     *
     * [install] / [topUpLocked] / [restoreBuiltins] / [delete] 都是**先**动内存里的
     * `seeded` / `removed` **再** [writeLocked]（那个顺序本身是对的：写盘序列化的
     * 就是此刻的台账）。但写失败返回时，内存里的台账已经带着没落盘的改动——
     * 若同一个进程里随后另一次写盘成功，幻影 key 会被一并持久化，「装过=不再
     * 播种」从此对不上事实。每次 [loadLocked] 本来就会刷新台账，这里只是把
     * 「写失败到下一次读盘」之间的那个窗口关掉。
     */
    private fun reloadLedgerLocked() {
        val f = file
        val doc = if (f.isFile) runCatching { decode(f.readText(Charsets.UTF_8)) }.getOrNull() else null
        if (doc != null) {
            seeded.clear(); seeded.addAll(doc.seeded)
            removed.clear(); removed.addAll(doc.removed)
        } else {
            // 文件没了或读不出：回到「全新播种」的台账状态，与 loadLocked 的
            // 处理一致（items 的处理是调用方的事，这里只管台账）。
            seeded.clear()
            removed.clear()
        }
    }

    /**
     * 解析。**所有新字段都必须显式 `optXXX` 兜底** —— 工程用 `org.json`，
     * 反序列化时不套用 data class 默认值；直接 `getString("tags")` 遇到 v1 文件
     * 会抛，`optString` 遇到数组会给出字符串 `"[]"` 这种垃圾。
     */
    private fun decode(text: String): Doc {
        val trimmed = text.trimStart()
        val root = if (trimmed.startsWith("{")) JSONObject(text) else null
        val arr = root?.optJSONArray("items") ?: JSONArray(text)
        val out = ArrayList<PersonaProfile>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val body = o.optString("body", "")
            if (body.isBlank()) continue
            val name = o.optString("name", "").trim().ifBlank { "未命名人设" }
            out += PersonaProfile(
                id = o.optString("id", "").ifBlank { newId() },
                name = name,
                body = body,
                updatedAt = o.optLong("updatedAt", 0L),
                builtin = o.optBoolean("builtin", false),
                avatar = o.optText("avatar"),
                description = o.optText("description"),
                tags = o.stringList("tags"),
                category = o.optText("category"),
                usedCount = o.optInt("usedCount", 0).coerceAtLeast(0),
                presetKey = o.optString("presetKey", "").trim(),
                skillRefs = o.stringList("skillRefs"),
                appPkgs = o.stringList("appPkgs")
            )
        }
        return Doc(
            // 裸数组 / 没有 version 的旧文件都按 v1 处理，走迁移路径补台账。
            version = root?.optInt("version", 1) ?: 1,
            items = out,
            seeded = root?.stringList("seeded")?.toSet().orEmpty(),
            removed = root?.stringList("removed")?.toSet().orEmpty()
        )
    }

    companion object {
        private const val TAG = "JEVASSIST"
        /** 2 = 加了浏览层字段、`presetKey` 与 `seeded[]`/`removed[]` 两个台账。 */
        private const val VERSION = 2

        @Volatile private var instance: PersonaStore? = null

        fun get(context: Context): PersonaStore =
            instance ?: synchronized(this) {
                instance ?: PersonaStore(context).also { instance = it }
            }

        /** 单测用：不碰进程级单例，每个用例一个自己的目录。 */
        internal fun create(context: Context): PersonaStore = PersonaStore(context)

        fun newId(): String = "psn-" + java.util.UUID.randomUUID().toString().substring(0, 10)

        /** 重名就加序号：`名字`、`名字 2`、`名字 3`。 */
        internal fun uniqueName(items: List<PersonaProfile>, base: String): String {
            val taken = items.map { it.name }.toSet()
            if (base !in taken) return base
            var n = 2
            while ("$base $n" in taken) n++
            return "$base $n"
        }
    }
}

/** 一份解析结果：条目 + 版本 + 两个台账。 */
private data class Doc(
    val version: Int,
    val items: List<PersonaProfile>,
    val seeded: Set<String>,
    val removed: Set<String>
)

/** 导入过程中随身携带的一行（正文 + 浏览层），落成 [PersonaProfile] 前不分配 id。 */
private data class Incoming(
    val name: String,
    val body: String,
    val avatar: String? = null,
    val description: String? = null,
    val tags: List<String> = emptyList(),
    val category: String? = null,
    val skillRefs: List<String> = emptyList(),
    val appPkgs: List<String> = emptyList()
) {
    fun toProfile(name: String = this.name): PersonaProfile = PersonaProfile(
        id = PersonaStore.newId(),
        name = name.ifBlank { "导入的人设" },
        body = body,
        avatar = avatar,
        description = description,
        tags = tags,
        category = category,
        skillRefs = skillRefs,
        appPkgs = appPkgs
    )
}

/**
 * 预设 → 条目。`presetKey` 就是这里种下的，台账全靠它。
 *
 * 实现在 [asProfile]（`ExpertPack.kt`，纯 Kotlin）：目录里的 331 位专家也要走同一条
 * 派生路径，两份 13 行代码各写一次，漂移起来的症状是「从目录加入的专家少了分类」，
 * 而那种 bug 不报错。
 */
private fun PersonaPreset.toProfile(id: String = PersonaStore.newId()): PersonaProfile =
    asProfile(id).copy(body = body.trim())

// ------------------------------------------------------------- org.json 小工具

/** 缺失 / `null` / 空串 → null。`optString` 在这三种情况下都会给 `""`，分不开。 */
private fun JSONObject.optText(key: String): String? =
    if (!has(key) || isNull(key)) null else optString(key, "").trim().ifBlank { null }

/** 字符串数组；不是数组就当空（导入别人的半截文件时不抛）。 */
private fun JSONObject.stringList(key: String): List<String> {
    val a = optJSONArray(key) ?: return emptyList()
    val out = ArrayList<String>(a.length())
    for (i in 0 until a.length()) {
        val s = a.optString(i, "").trim()
        if (s.isNotEmpty() && s !in out) out += s
    }
    return out
}

private fun Collection<String>.toJsonArray(): JSONArray {
    val arr = JSONArray()
    forEach { arr.put(it) }
    return arr
}

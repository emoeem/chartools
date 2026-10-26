package com.jev.probe.core.kb

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 一条**有名字的人设**。
 *
 * 和 [PersonaCard] 的分工：卡是「这一份人设被怎么理解」（解析结果，不可持久化），
 * 这里是人设**本身**（用户写下的那段原文 + 它的名字）。一份人设可以被改名、复制、
 * 导出、删掉，卡不会跟着存 —— 卡每次都由 [body] 现算。
 *
 * [builtin] 只标「这条来自内置模板」，用来给「恢复内置模板」判断哪些已经在了；
 * 内置条和用户自建的条**完全平等**：可以改、可以改名、可以删。模板是起点，不是枷锁。
 */
data class PersonaProfile(
    val id: String,
    val name: String,
    /**
     * 人设原文，逐字保存（含换行）。这就是 `Prefs.style` 里会出现的那些字节 ——
     * 中间不做任何规范化，否则「套用 → 保存 → 回头再套用」会悄悄变形。
     */
    val body: String,
    val updatedAt: Long = System.currentTimeMillis(),
    val builtin: Boolean = false
) {
    /** 现算的结构化卡；认不出键时退回自由文本，与手写人设完全同一套规则。 */
    fun card(): PersonaCard = PersonaCard.parse(body)
}

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
 * [PersonaPresets] 里那三张写死的字串 —— 卖货的话术、客服的口气、和甲方说话的
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
 */
class PersonaStore private constructor(context: Context) {

    private val app = context.applicationContext
    private val lock = Any()

    private val root: File get() = File(app.filesDir, "kb")
    private val file: File get() = File(root, "personas.json")

    /** 最近一次读盘的坏消息（文件损坏已备份等），给设置页回显用；正常为 null。 */
    @Volatile
    var lastProblem: String? = null
        private set

    // ------------------------------------------------------------------ 读

    fun list(): List<PersonaProfile> = synchronized(lock) { loadLocked() }

    /**
     * 当前生效的是哪一条。
     *
     * 只比原文（去首尾空白），因为 [Prefs.style] 是唯一真源；匹配不上任何一条
     * 就是「未保存的自由文本」，这是合法状态，不是错误。
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

    // ------------------------------------------------------------------ 写

    /**
     * 新建或就地更新。[id] 为 null 时新建。
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

    fun delete(id: String): Boolean = synchronized(lock) {
        val items = loadLocked().toMutableList()
        if (!items.removeAll { it.id == id }) return@synchronized false
        writeLocked(items)
    }

    /** 复制一份，名字加「副本」。返回新的那条。 */
    fun duplicate(id: String): PersonaProfile? = synchronized(lock) {
        val items = loadLocked().toMutableList()
        val src = items.firstOrNull { it.id == id } ?: return@synchronized null
        val copy = PersonaProfile(newId(), uniqueName(items, src.name + " 副本"), src.body)
        items += copy
        if (writeLocked(items)) copy else null
    }

    /**
     * 把**缺的**内置模板补回来，已存在的（按名字）跳过。
     * 删了内置模板又想找回来时用；不会复制出一堆同名条目。
     */
    fun restoreBuiltins(): Int = synchronized(lock) {
        val items = loadLocked().toMutableList()
        val have = items.map { it.name }.toSet()
        var added = 0
        PersonaPresets.ALL.forEach { (name, body) ->
            if (name !in have) {
                items += PersonaProfile(newId(), name, body.trim(), builtin = true)
                added++
            }
        }
        if (added > 0 && !writeLocked(items)) return@synchronized 0
        added
    }

    // ------------------------------------------------------- 导入 / 导出

    /**
     * 全量导出成 JSON（人设库是给人看的，`toString(2)`）。
     * 拿去另一台机器「导入」即可，不需要 root、不需要云。
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
            )
        }
        JSONObject().put("version", VERSION).put("items", arr).toString(2)
    }

    /** 单条导出：只有正文（可直接粘进「人设」输入框，或发给别人）。 */
    fun exportText(id: String): String = get(id)?.body.orEmpty()

    /**
     * 导入。接受三种形态，都不抛异常：
     *
     * - 本库 [exportJson] 的输出（`{"version":1,"items":[…]}`）
     * - 裸数组 `[{"name":…,"body":…}]`（手工拼的、别的工具给的）
     * - 一段**纯文本人设卡**（没有 name 字段时用第一行当名字）
     *
     * 重名策略见类注释：同名不同文 → 新增 `名字(导入)`。绝不覆盖已有条目。
     */
    fun importJson(raw: String): PersonaImport = synchronized(lock) {
        val text = raw.trim()
        if (text.isEmpty()) return@synchronized PersonaImport(error = "内容是空的")

        val incoming = ArrayList<Pair<String, String>>()
        try {
            val root = when {
                text.startsWith("[") -> JSONArray(text)
                else -> JSONObject(text).optJSONArray("items") ?: JSONArray()
            }
            for (i in 0 until root.length()) {
                val o = root.optJSONObject(i) ?: continue
                val body = o.optString("body", "").trimEnd()
                if (body.isBlank()) continue
                incoming += o.optString("name", "").trim() to body
            }
        } catch (e: Exception) {
            // 不是 JSON —— 当成一张纯文本人设卡收下，而不是报错让人重来。
            val name = text.split('\n').firstOrNull { it.isNotBlank() }
                ?.substringBefore('：')?.take(24)?.trim().orEmpty()
            incoming += name.ifBlank { "导入的人设" } to text
        }
        if (incoming.isEmpty()) return@synchronized PersonaImport(error = "里面没有人设（缺 body / 正文为空）")

        val items = loadLocked().toMutableList()
        var added = 0
        var renamed = 0
        var skipped = 0
        incoming.forEach { (rawName, body) ->
            val name = rawName.ifBlank { "导入的人设" }
            val same = items.firstOrNull { it.name == name }
            when {
                same == null -> {
                    items += PersonaProfile(newId(), name, body)
                    added++
                }
                same.body.trim() == body.trim() -> skipped++
                else -> {
                    items += PersonaProfile(newId(), uniqueName(items, "$name(导入)"), body)
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
     * 读盘。文件不存在 → 用 [PersonaPresets] 播种。
     *
     * 「只播种一次」靠的是文件本身：用户逐条删光后文件还在（items 为空），不会再
     * 长回来；而**整个 kb 目录**被「清空知识库与历史」删掉时，下一次读会重新播种 ——
     * 那是一次明确的「回到出厂」，设置页的确认框里写明了这一点。
     */
    private fun loadLocked(): List<PersonaProfile> {
        val f = file
        if (!f.isFile) return seedLocked()
        val parsed = runCatching { decode(f.readText(Charsets.UTF_8)) }.getOrNull()
        if (parsed != null) return parsed

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
        val seeded = PersonaPresets.ALL.map { (name, body) ->
            PersonaProfile(newId(), name, body.trim(), builtin = true)
        }
        writeLocked(seeded)
        lastProblem = null
        return seeded
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
            )
        }
        val text = JSONObject().put("version", VERSION).put("items", arr).toString(2)
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

    private fun decode(text: String): List<PersonaProfile> {
        val arr = when {
            text.trimStart().startsWith("{") -> JSONObject(text).optJSONArray("items") ?: JSONArray()
            else -> JSONArray(text)
        }
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
                builtin = o.optBoolean("builtin", false)
            )
        }
        return out
    }

    companion object {
        private const val TAG = "JEVASSIST"
        private const val VERSION = 1

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

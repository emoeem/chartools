package com.jev.probe.root

/**
 * `enabled_accessibility_services` 是一格用冒号分隔的系统设置，里面同时住着
 * **别人**。这台设备（OnePlus PJE110）上就有 ColorOS 自带的取词
 * （`com.coloros.codebook`）和输入法自己的服务。写它是 root 增强里唯一会改到
 * 别人状态的地方：整格覆盖 = 替用户关掉其它无障碍服务，而且用户多半不会立刻
 * 发现，只会觉得"某个功能怎么不好使了"。
 *
 * 所以这里只做**合并**，并且做成纯函数（不 import 任何 `android.*`）——单测覆盖
 * 空值、重复项、多余分隔符、大小写、以及"不动别人"这几条分支。
 *
 * 真机上这格的现状（2026-10-06 实测）：
 * ```
 * com.jev.probe/com.jev.probe.capture.ChatCaptureService:com.coloros.codebook:...
 * ```
 */
internal object A11ySettings {

    /** 本 App 的无障碍服务组件名，和 `AndroidManifest.xml` 里声明的一致。 */
    const val COMPONENT = "com.jev.probe/com.jev.probe.capture.ChatCaptureService"

    /** 系统设置名：无障碍服务列表 / 无障碍总开关。 */
    const val KEY_SERVICES = "enabled_accessibility_services"
    const val KEY_ENABLED = "accessibility_enabled"

    /**
     * 拆成条目。空串、纯分隔符、`null`（`settings get` 对没设过的键就回这个字面量）
     * 都得到空列表；顺带去掉空白与完全重复的条目（重复项会让系统重复绑定同一个
     * 服务，没有意义，但保留**首次出现的位置**，因为那是用户自己的排列顺序）。
     *
     * `null` 这个字面量必须在这里就被吃掉：它一旦混进 [merge] 的结果，写回系统
     * 设置的就是一个名叫 `null` 的服务，而那是**永久性**的脏数据 —— 系统不认识它，
     * 但用户以后每次都要在设置里看到它。
     */
    fun parse(current: String?): List<String> {
        if (current.isNullOrBlank()) return emptyList()
        val out = LinkedHashSet<String>()
        for (part in current.split(':')) {
            val t = part.trim()
            if (t.isNotEmpty() && !t.equals("null", ignoreCase = true)) out.add(t)
        }
        return out.toList()
    }

    /** 这一格现在有没有本 App。大小写不敏感：组件名的包名部分理论上可变大小写。 */
    fun contains(current: String?, component: String = COMPONENT): Boolean =
        parse(current).any { it.equals(component, ignoreCase = true) }

    /** 在**不动别人**的前提下把本 App 加进去；已在里面就原样回。 */
    fun merge(current: String?, component: String = COMPONENT): String {
        val list = parse(current).toMutableList()
        if (list.none { it.equals(component, ignoreCase = true) }) list.add(component)
        return list.joinToString(":")
    }

    /** POSIX 单引号字面量：值里的 `'` 要拆成 `'\''`，否则 shell 会把命令截断。 */
    fun quote(value: String): String = "'" + value.replace("'", "'\\''") + "'"

    /** 去掉本 App 之后剩下的列表 —— 也就是"先把无障碍关掉"那一步要写的值。 */
    fun without(current: String?, component: String = COMPONENT): String =
        parse(current).filterNot { it.equals(component, ignoreCase = true) }.joinToString(":")

    /** 把这一格写成 [value] 的那条命令。 */
    fun setCommand(value: String): String = "settings put secure $KEY_SERVICES ${quote(value)}"

    /** 总开关那条命令。只写列表不打开它，系统仍然不绑定。 */
    fun enableCommand(): String = "settings put secure $KEY_ENABLED 1"

    /** 用 root 把本 App 的无障碍打开时跑的完整命令。 */
    fun commands(current: String?, component: String = COMPONENT): List<String> = listOf(
        setCommand(merge(current, component)),
        enableCommand()
    )

    /**
     * 算出现在该干什么。**这才是这个功能的核心**，执行只是把它翻译成命令。
     *
     * 为什么要看 [live]：真机实测（2026-10-07，`adb install -r` 前后）证明
     * `enabled_accessibility_services` **说开着 ≠ 服务真的在跑** —— 覆盖安装、
     * 开机、被 ColorOS 冻死之后，设置里那一格照样留着组件名，但 `dumpsys
     * accessibility` 只剩 `Enabled services`，没有 `Bound services`。用户看到的就是
     * "我明明开着，怎么还要再点一次"。
     *
     * 而复活的唯一办法是**让它变一次**：同一格重复写同样的值，系统不认为有变化，
     * 不会重绑；所以要先写 [without]（关掉）再写 [merge]（打开）。这正是
     * `CLAUDE.md` 里"改完无障碍必须关掉再开启"的自动化版本。
     *
     * 返回两段写操作时，**顺序就是执行顺序**，中间必须留出时间让系统处理第一次变化
     * （见 `RootFix.REBIND_GAP_MS`），否则两次写入会被读成一次、等于没变。
     */
    fun plan(current: String?, live: Boolean, component: String = COMPONENT): A11yPlan {
        val wanted = merge(current, component)
        return when {
            !contains(current, component) ->
                A11yPlan.Write(listOf(wanted), "无障碍没开着，已打开")

            live -> A11yPlan.Already("设置里开着，服务也在跑，没动它")

            else -> A11yPlan.Write(
                listOf(without(current, component), wanted),
                "设置里开着但服务没在跑（覆盖安装 / 开机后常见）→ 关掉再打开，强制重绑"
            )
        }
    }
}

/** [A11ySettings.plan] 的结果：要么什么都不用做，要么按顺序写这几个值。 */
internal sealed interface A11yPlan {
    /** 已经是好的，一根手指都不动。 */
    data class Already(val why: String) : A11yPlan

    /** 按顺序把 [values] 写进 `enabled_accessibility_services`；最后一个值是想要的终态。 */
    data class Write(val values: List<String>, val why: String) : A11yPlan
}

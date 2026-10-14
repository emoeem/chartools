package com.jev.probe.root

/**
 * `su` 的输出 → 人话。全部是纯函数，因为这里错了会往设置页上写错话：把 KernelSU
 * 显示成"无 root"，用户就去点没用的按钮了。
 *
 * 认 root 框架**只能靠 SELinux 域**：`id` 在 root 下的最后一段是
 * `context=u:r:<域>:s0`，KernelSU = `ksu`、Magisk = `magisk`、APatch = `apatch`。
 * 版本号、`su -v` 各家格式都不一样，不作为判据（真机实测：KernelSU 的
 * `su -v` 与 Magisk 的 `MAGISK_VER` 完全不同形）。
 */
internal object RootProbe {

    /** `su -c id` 的原文 → 框架名；没拿到 uid=0 就是"无"。 */
    fun flavorOf(idOutput: String?): String {
        val s = idOutput?.lowercase() ?: return "无"
        if (!s.contains("uid=0")) return "无"
        return when {
            s.contains(":r:ksu:") || s.contains("ksu:s0") -> "KernelSU"
            s.contains(":r:magisk:") -> "Magisk"
            s.contains(":r:apatch") || s.contains(":r:apd:") -> "APatch"
            else -> "root"
        }
    }

    /**
     * `settings get secure <key>` 的原文 → 值。没设过的键系统回字面量 `null`，
     * 不能把它当成"一个叫 null 的服务"（那会让 merge 把它塞回列表里）。
     */
    fun settingValue(raw: String?): String? {
        val t = raw?.trim() ?: return null
        return if (t.isEmpty() || t.equals("null", ignoreCase = true)) null else t
    }

    /**
     * `dumpsys deviceidle whitelist` 的原文里有没有这个包。真机每行是
     * `user,com.jev.probe,10138` —— uid 跟在后面，所以**不能**用 endsWith 去匹配
     * 整行，必须按逗号切开逐字段比。
     */
    fun onWhitelist(dump: String?, pkg: String): Boolean =
        dump?.lineSequence()?.any { line -> line.split(',').any { it.trim() == pkg } } == true
}

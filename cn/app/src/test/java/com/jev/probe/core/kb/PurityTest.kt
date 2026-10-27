package com.jev.probe.core.kb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * S5 的两条**机器化守卫**，直接读源码树断言。跑在 JVM 单测里，不需要真机。
 *
 * 为什么用「读文件」这种土办法：`import android.` 这条约束靠人眼评审是守不住的 ——
 * 只要有人为了省事在 `PersonaProfile` 里 `import android.util.Log`，`global/` 就再也
 * 引不了它，而**编译依旧通过**（cn 工程本来就有 android.jar）。这种破坏没有任何
 * 报错，只有下一次想复用时才发现。所以让测试去看文件本身。
 */
class PurityTest {

    /** 单测的工作目录是 `app/`，所以从这里相对定位源码树。 */
    private fun source(rel: String): File {
        val f = File("src/main/java/com/jev/probe/$rel")
        assertTrue("源码文件找不到：${f.absolutePath}", f.isFile)
        return f
    }

    @Test
    fun theReusableExpertFilesCarryNoAndroidImports() {
        val pure = listOf(
            "core/kb/PersonaProfile.kt",
            "core/kb/ExpertCatalog.kt",
            "core/kb/ExpertPack.kt",
            "core/kb/ExpertBinding.kt",
            "ui/ExpertCard.kt"
        )
        pure.forEach { rel ->
            val bad = source(rel).readLines().filter { it.trimStart().startsWith("import android.") }
            assertEquals("$rel 引入了 Android 依赖（S5 要求它保持纯 Kotlin）：$bad", emptyList<String>(), bad)
        }
    }

    @Test
    fun theModelCarriesNoSecondSourceOfTruthForTheActiveExpert() {
        // 不变量 2：`Prefs.style` 是唯一真源。出现 activeExpertId 之类的**字段或函数**，
        // 就说明有人又存了一份「当前生效」—— 两份必然漂移，而且漂移没有报错可查。
        // 注：注释里提到这个名字是允许的（`ExpertActivity` 的类注释就是在解释「为什么不存」），
        // 所以只查代码行。
        val decl = Regex("""\b(v(?:a[lr])|fun)\s+activeExpertId\b""")
        val hits = File("src/main/java/com/jev/probe").walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .flatMap { f ->
                f.readLines().mapIndexed { i, l -> "$f:${i + 1}: ${l.trim()}" to l }
            }
            .filter { (_, line) ->
                val t = line.trim()
                !t.startsWith("*") && !t.startsWith("//") && !t.startsWith("/*") && decl.containsMatchIn(t)
            }
            .map { it.first }
            .toList()
        assertEquals("不许出现第二份「当前生效」状态", emptyList<String>(), hits)
    }

}

package com.jev.probe.capture

import com.jev.probe.bridge.HookTargets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * 适配器注册表的 drift-guard。新增一个聊天 App 只该改两处（适配器实现 +
 * [ChatApps.all] 一行），这里把「注册表」和其它清单之间的同步关系钉死：
 *
 * - `HookTargets.SCOPED`（运行期注入判定，[HookTargetsTest] 从代码侧钳）
 * - `res/values/arrays.xml` 的 `xposed_scope`（框架侧允许注入范围）
 * - `AndroidManifest.xml` 的 `<queries>`（Android 11+ 包可见性，设置页
 *   显示注入状态靠它解析到目标 App）
 *
 * 三边不一致的表现是「框架说加载了、日志里什么都没有」或「设置页认不出
 * 已安装的目标 App」——都是静默失败，所以用测试拦。
 */
class ChatAppsRegistryTest {

    private val moduleDir: File =
        System.getProperty("jev.moduleDir")?.let { File(it) }
            ?: error("jev.moduleDir 未设置：build.gradle.kts 里给 Test 任务注入 app 模块目录")

    @Test fun registryIsWellFormed() {
        assertTrue("注册表为空", ChatApps.all.isNotEmpty())
        val pkgs = ChatApps.all.map { it.pkg }
        assertEquals("包名不得重复", pkgs.size, pkgs.toSet().size)
        ChatApps.all.forEach { a ->
            assertTrue("${a.pkg}.displayName 为空", a.displayName.isNotBlank())
        }
        assertEquals("packages 应与 all 一致", pkgs.toSet(), ChatApps.packages)
    }

    /** 钉住输入框定位的现有行为：五个可写 App 的路径不回归。 */
    @Test fun inputContractsArePinned() {
        val qq = ChatApps.forPackage("com.tencent.mobileqq")
        assertNotNull(qq)
        val tim = ChatApps.forPackage("com.tencent.tim")
        assertNotNull(tim)
        val feishu = ChatApps.forPackage("com.ss.android.lark")
        assertNotNull(feishu)
        // X / Telegram 走通用可编辑节点查找（findEditableNode），行为由
        // GuardedInputWriterTest / InjectionSourceTest 覆盖写入路径。
        assertTrue(ChatApps.forPackage("com.twitter.android") != null)
        assertTrue(ChatApps.forPackage("org.telegram.messenger") != null)
        // WhatsApp / 微信没有验证过的写入口：填入只能剪贴板。
        assertTrue(ChatApps.forPackage("com.whatsapp") != null)
    }

    @Test fun whatsappNeverScreenshots() {
        assertFalse(ChatApps.forPackage("com.whatsapp")!!.allowScreenshot)
        ChatApps.all.filter { it.pkg != "com.whatsapp" }.forEach {
            assertTrue("${it.pkg} 应允许截屏兜底", it.allowScreenshot)
        }
    }

    /** 注入范围的三份清单必须逐字一致。 */
    @Test fun xposedScopeIsInSyncAcrossResources() {
        val scoped = HookTargets.SCOPED

        val arraysXml = File(moduleDir, "src/main/res/values/arrays.xml").readText()
        val resourceItems = Regex("""<item>([^<]+)</item>""")
            .findAll(arraysXml.substringAfter("xposed_scope").substringBefore("</string-array>"))
            .map { it.groupValues[1] }
            .toList()
        assertEquals("arrays.xml 的 xposed_scope 与 HookTargets.SCOPED 不一致", scoped, resourceItems)

        val manifest = File(moduleDir, "src/main/AndroidManifest.xml").readText()
        val queries = Regex("""<package android:name="([^"]+)" />""")
            .findAll(manifest.substringAfter("<queries>").substringBefore("</queries>"))
            .map { it.groupValues[1] }
            .toList()
        scoped.forEach { pkg ->
            assertTrue("Manifest <queries> 缺少注入目标 $pkg（设置页将认不出已安装的目标 App）", pkg in queries)
        }
    }

    /** 注入目标必须也是可读的 App：注入只是采集的增强，采集本体是适配器。 */
    @Test fun everyScopedAppHasAnAdapter() {
        HookTargets.SCOPED.forEach { pkg ->
            assertNotNull("注入目标 $pkg 没有适配器：注入层读到的数据没有采集侧消费方", ChatApps.forPackage(pkg))
        }
    }
}

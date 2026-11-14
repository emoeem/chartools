package dev.chartools.capture.bridge

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 注入范围与主进程门槛。M0 没有 `arrays.xml`：钳制对象就是 [HookTargets] 自身
 * 的常量（设计 §2.4——legacy 的 `xposed_scope` blob 已缺失，将来 M1 落数组时
 * 内容以 HookTargets.kt 为准重写）—— 那边是框架级的「允许注入范围」，这边是
 * 模块自己的第一道判断，两边不一致的表现是「框架说加载了、日志里什么都没有」。
 */
class HookTargetsTest {

    @Test fun thePilotAppIsInScope() {
        assertEquals(listOf("org.telegram.messenger"), HookTargets.SCOPED)
    }

    @Test fun aScopedAppOnItsMainProcessLoads() {
        assertTrue(HookTargets.shouldLoad("org.telegram.messenger", "org.telegram.messenger"))
    }

    /** :push / :webview 之类的小进程不值得注入：那里通常也读不到聊天。 */
    @Test fun aScopedAppOnItsHelperProcessDoesNotLoad() {
        assertFalse(HookTargets.shouldLoad("org.telegram.messenger", "org.telegram.messenger:push"))
        assertFalse(HookTargets.shouldLoad("org.telegram.messenger", "org.telegram.messenger:webview"))
    }

    @Test fun anAppOutsideTheScopeNeverLoads() {
        assertFalse(HookTargets.shouldLoad("com.tencent.mm", "com.tencent.mm"))
        assertFalse(HookTargets.shouldLoad("dev.chartools.chartools_app", "dev.chartools.chartools_app"))
    }

    @Test fun missingArgumentsAreNotAMatch() {
        assertFalse(HookTargets.shouldLoad(null, "org.telegram.messenger"))
        assertFalse(HookTargets.shouldLoad("org.telegram.messenger", null))
        assertFalse(HookTargets.shouldLoad(null, null))
        assertFalse(HookTargets.shouldLoad("", ""))
    }

    @Test fun aScopeEntryWithATrailingSpaceIsNotAMatch() {
        assertFalse(HookTargets.isScoped(" org.telegram.messenger"))
        assertFalse(HookTargets.shouldLoad("org.telegram.messenger ", "org.telegram.messenger "))
    }
}

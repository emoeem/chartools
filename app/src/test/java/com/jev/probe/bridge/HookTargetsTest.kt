package com.jev.probe.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 注入范围与主进程门槛。这一份必须和 `res/values/arrays.xml` 里的
 * `xposed_scope` 一致 —— 那边是框架级的「允许注入范围」，这边是模块自己的
 * 第一道判断，两边不一致的表现是「框架说加载了、日志里什么都没有」。
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
        assertFalse(HookTargets.shouldLoad("com.jev.probe", "com.jev.probe"))
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

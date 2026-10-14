package com.jev.probe.root

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 写系统设置那一格的逻辑是"会改到别人"的地方，所以测的是**边界**：既要把自己
 * 加进去，又必须一根手指都不碰到别人；重复调用要幂等（每次开机都跑一遍）。
 */
class A11ySettingsTest {

    private val me = A11ySettings.COMPONENT

    /** 真机 `settings get secure enabled_accessibility_services` 的形状。 */
    private val realDevice =
        "com.coloros.codebook:com.jev.probe/com.jev.probe.capture.ChatCaptureService"

    @Test
    fun otherServicesSurviveIntact() {
        val merged = A11ySettings.merge("com.coloros.codebook:com.iMe.android/com.iMe.Service")
        assertEquals(
            "com.coloros.codebook:com.iMe.android/com.iMe.Service:$me",
            merged
        )
    }

    @Test
    fun alreadyPresentIsLeftAloneAndOrderKept() {
        assertEquals(realDevice, A11ySettings.merge(realDevice))
    }

    /** 每次开机 / 每次启动都会跑，重复跑一百遍结果必须一样。 */
    @Test
    fun mergeIsIdempotent() {
        var s = A11ySettings.merge(null)
        repeat(100) { s = A11ySettings.merge(s) }
        assertEquals(me, s)
    }

    /** `settings get` 对没设过的键回字面量 `null` —— 不能被当成一个服务名。 */
    @Test
    fun nullLiteralBecomesNothing() {
        assertEquals(me, A11ySettings.merge("null"))
        assertEquals(emptyList<String>(), A11ySettings.parse("null  "))
    }

    @Test
    fun emptyAndSeparatorOnlyInput() {
        assertEquals(me, A11ySettings.merge(""))
        assertEquals(me, A11ySettings.merge("   "))
        assertEquals(me, A11ySettings.merge("::"))
        assertEquals(listOf(me), A11ySettings.parse("::$me::"))
    }

    /** 重复项去重，但保留用户自己的排列顺序。 */
    @Test
    fun duplicatesCollapsePreservingOrder() {
        assertEquals(
            listOf("a/1", "b/2", me),
            A11ySettings.parse("a/1:b/2:a/1:$me:$me")
        )
    }

    @Test
    fun containsIsCaseInsensitive() {
        assertTrue(
            A11ySettings.contains("com.jev.probe/com.jev.probe.capture.chatcaptureservice")
        )
        assertFalse(A11ySettings.contains("com.coloros.codebook"))
        assertFalse(A11ySettings.contains(null))
    }

    /** 命令里的值必须带引号：这一格由冒号分隔，裸写会被 shell 当成分隔符。 */
    @Test
    fun commandsQuoteTheValue() {
        val cmds = A11ySettings.commands("com.coloros.codebook")
        assertEquals(2, cmds.size)
        assertEquals(
            "settings put secure enabled_accessibility_services 'com.coloros.codebook:$me'",
            cmds[0]
        )
        assertEquals("settings put secure accessibility_enabled 1", cmds[1])
    }

    @Test
    fun singleQuoteIsEscapedNotDropped() {
        assertEquals("'a'\\''b'", A11ySettings.quote("a'b"))
        assertTrue(A11ySettings.commands("a'b").first().contains("'a'\\''b:$me'"))
    }

    // ----------------------------------------------------------- plan（该干什么）

    /** 好的状态下一根手指都不动 —— 尤其不能"顺手重写一遍"把别人踢掉。 */
    @Test
    fun planIsNoopWhenListedAndLive() {
        val p = A11ySettings.plan(realDevice, live = true)
        assertTrue("$p", p is A11yPlan.Already)
    }

    @Test
    fun planOpensWhenNotListed() {
        val p = A11ySettings.plan("com.coloros.codebook", live = false)
        assertTrue("$p", p is A11yPlan.Write)
        p as A11yPlan.Write
        assertEquals(listOf("com.coloros.codebook:$me"), p.values)
    }

    /**
     * 这条就是整个功能的理由：设置里开着、服务没在跑 → 必须先写一遍"没有我"
     * 再写回"有我"，否则系统认为没变化、不重绑。
     */
    @Test
    fun planCyclesWhenListedButDead() {
        val p = A11ySettings.plan(realDevice, live = false)
        assertTrue("$p", p is A11yPlan.Write)
        p as A11yPlan.Write
        assertEquals(2, p.values.size)
        assertEquals("com.coloros.codebook", p.values[0])
        assertFalse(p.values[0].contains(me))
        assertEquals(realDevice, p.values[1])
    }

    /** 只有自己一个服务时，"关掉"那一步就是空串（真机上验证过能解绑）。 */
    @Test
    fun planDisablesToEmptyStringWhenAlone() {
        val p = A11ySettings.plan(me, live = false) as A11yPlan.Write
        assertEquals(listOf("", me), p.values)
        assertEquals("settings put secure enabled_accessibility_services ''", A11ySettings.setCommand(""))
    }

    /**
     * 两次写必须是**不同的值**。同值重写 = 系统判定没变化 = 什么都没发生，
     * 那这个功能就白做了 —— 几种输入都不许出现这种情况。
     */
    @Test
    fun cycleWritesAlwaysDiffer() {
        for (cur in listOf(me, "$me:", "a/1:$me", "$me:b/2", "$me:$me", realDevice)) {
            val p = A11ySettings.plan(cur, live = false) as A11yPlan.Write
            assertEquals("$cur -> $p", 2, p.values.size)
            assertTrue("$cur -> $p", p.values[0] != p.values[1])
            assertFalse("$cur -> $p", A11ySettings.contains(p.values[0]))
            assertTrue("$cur -> $p", A11ySettings.contains(p.values[1]))
        }
    }

    /** 大小学不同也要认出来：认成"没开过"会多写一次，不会坏，但要多说一句谎。 */
    @Test
    fun planSeesComponentCaseInsensitively() {
        val cur = "com.jev.probe/com.jev.probe.capture.chatcaptureservice"
        assertTrue(A11ySettings.plan(cur, live = true) is A11yPlan.Already)
        val p = A11ySettings.plan(cur, live = false) as A11yPlan.Write
        assertEquals(2, p.values.size)
        assertFalse(p.values[0].contains("chatcaptureservice"))
    }

    /** `commands` 只是 plan 那个"没开着"分支的执行形态，两者不许漂移。 */
    @Test
    fun openCommandsMatchTheWritePlan() {
        val cur = "com.coloros.codebook"
        val cmds = A11ySettings.commands(cur)
        val p = A11ySettings.plan(cur, live = false) as A11yPlan.Write
        assertEquals(A11ySettings.setCommand(p.values.last()), cmds[0])
        assertEquals(A11ySettings.enableCommand(), cmds[1])
    }
}

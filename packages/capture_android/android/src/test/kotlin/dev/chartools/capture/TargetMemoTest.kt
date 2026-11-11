package dev.chartools.capture

import android.view.accessibility.AccessibilityNodeInfo
import org.mockito.Mockito
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame

/**
 * fix(kimi-review #13)：Host 层 targetOf 提取 memo 的单测（CaptureService 在
 * 测试环境实例化不了，memo 独立成类才有了 JVM 可达的断言面——上一版缓存在
 * InputFiller 内部且键是 root 实例引用，生产恒不命中，也没有任何测试能咬住
 * 「提取次数」）。
 *
 * 键语义：pkg+windowId（ConversationSession.sameConversation 的会话身份前两
 * 级）——框架每次 getRootInActiveWindow 都返回新实例，实例引用不是键；失效
 * 由 CaptureService.onAccessibilityEvent 对每条窗口/内容事件调 [TargetMemo
 * .invalidate]（「两次提取之间无事件 ⇒ 树未变」是正确性依据）。
 */
class TargetMemoTest {

    private fun root(pkg: String? = "com.example.chat", windowId: Int = 7): AccessibilityNodeInfo =
        Mockito.mock(AccessibilityNodeInfo::class.java).also { m ->
            Mockito.`when`(m.packageName).thenReturn(pkg)
            Mockito.`when`(m.windowId).thenReturn(windowId)
        }

    /** 记录提取次数的 memo 工厂；提取恒回 [result]。 */
    private fun memo(result: ConversationSession.Target?): Pair<TargetMemo, IntRef> {
        val count = IntRef()
        val memo = TargetMemo { _ ->
            count.value++
            result
        }
        return memo to count
    }

    private class IntRef { var value = 0 }

    @Test
    fun sameWindowSecondCall_reusesWithoutReExtract() {
        val t = ConversationSession.Target("com.example.chat", 7, "Alice")
        val (memo, count) = memo(t)
        val r1 = memo.targetOf(root())
        val r2 = memo.targetOf(root())
        assertEquals(1, count.value)
        assertSame(t, r1)
        assertSame(t, r2)
    }

    @Test
    fun newRootInstanceSameWindow_reuses() {
        // 框架语义：getRootInActiveWindow 每次给新实例——实例身份不是键。
        val t = ConversationSession.Target("com.example.chat", 7, "Alice")
        val (memo, count) = memo(t)
        memo.targetOf(root())
        memo.targetOf(root(windowId = 7))   // 新实例、同窗
        assertEquals(1, count.value)
    }

    @Test
    fun windowIdChange_reExtracts() {
        val t = ConversationSession.Target("com.example.chat", 7, "Alice")
        val (memo, count) = memo(t)
        memo.targetOf(root(windowId = 7))
        memo.targetOf(root(windowId = 99))
        assertEquals(2, count.value)
    }

    @Test
    fun packageChange_reExtracts() {
        val t = ConversationSession.Target("com.example.chat", 7, "Alice")
        val (memo, count) = memo(t)
        memo.targetOf(root(pkg = "com.example.chat"))
        memo.targetOf(root(pkg = "com.other.app"))
        assertEquals(2, count.value)
    }

    @Test
    fun invalidate_forcesReExtract() {
        val t = ConversationSession.Target("com.example.chat", 7, "Alice")
        val (memo, count) = memo(t)
        val r1 = memo.targetOf(root())
        memo.invalidate()                    // 生产：每条无障碍事件都调
        val r2 = memo.targetOf(root())       // 同一 root 实例也必须重提取
        assertEquals(2, count.value)
        assertSame(t, r1)
        assertSame(t, r2)
    }

    @Test
    fun nullResultIsCachedUntilInvalidated() {
        // 提取为 null（不在跟踪的会话里）也算结果：静默窗内同窗重复问不重复
        // 遍历；事件后重算。
        val (memo, count) = memo(null)
        assertNull(memo.targetOf(root()))
        assertNull(memo.targetOf(root()))
        assertEquals(1, count.value)
        memo.invalidate()
        assertNull(memo.targetOf(root()))
        assertEquals(2, count.value)
    }
}

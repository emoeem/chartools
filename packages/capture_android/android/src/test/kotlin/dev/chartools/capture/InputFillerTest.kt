package dev.chartools.capture

import android.os.Bundle
import android.view.accessibility.AccessibilityNodeInfo
import org.mockito.Mockito
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * InputFiller 单测（fix(kimi-review #15)，兼作 #6 / #13 的回归）。
 *
 * - #6 回归：会话身份走 [ConversationSession.Target.sameConversation]
 *   （pkg+windowId+title）。对方在会话里又发一条消息只微变 messagesSignature——
 *   inputFor 必须照常解析出输入框（此前的 data class 全等会判成「换了会话」、
 *   回填失败退剪贴板）；换标题 / 换窗口 / 换包名 / 提取为 null 仍然拒绝。
 * - #13 回归（v2，独立复核 2026-11-12 后重做）：targetOf 的提取缓存在 Host 层
 *   （[TargetMemo]，键 = pkg+windowId，无障碍事件一律失效）。旧版在 InputFiller
 *   里按 root 实例引用缓存——框架每次 getRootInActiveWindow 都返回新实例，
 *   引用恒不等，缓存从未命中（死代码）。FakeHost 镜像生产接线：targetOf 过
 *   memo、[FakeHost.onAccessibilityEvent] 对应服务的每条事件；提取次数按新
 *   语义断言（树静默期复用，事件后重提取——「窗口内切聊天」的漏检防线）。
 * - 「绝不 GLOBAL_ACTION 发送」：FakeHost 记录全部 host 调用，节点桩记录全部
 *   performAction——fill 全流程对节点发出的动作必须落在 SET_TEXT / CLICK(focus) /
 *   PASTE 白名单内。GLOBAL_ACTION_* 是 AccessibilityService 层的常量，节点 API
 *   根本没有全局动作；且 GLOBAL_ACTION_BACK(1) 与 ACTION_CLICK(1) 数值重叠，
 *   「不含 GLOBAL 值」无法按值判定——白名单断言是它更强且可判定的形式：BACK、
 *   HOME、send 按钮点击、ENTER 等一切可能触发发送/系统行为的动作都不在白名单。
 */
class InputFillerTest {

    // ---- 脚手架 ----------------------------------------------------------

    /** Host 桩：targetOf 过 [TargetMemo]（镜像 CaptureService 的 Host 实现），
     *  记录真实提取（全树遍历）的入参、post 的延时值与剪贴板写入。 */
    private class FakeHost(
        var root: AccessibilityNodeInfo?,
        private val target: ConversationSession.Target?,
    ) : InputFiller.Host {
        var current = true
        /** 提取（= 全树遍历）真实发生的入参，按调用序（#13 断言输入）。 */
        val targetOfCalls = mutableListOf<AccessibilityNodeInfo>()

        private val memo = TargetMemo { root ->
            targetOfCalls.add(root)
            target
        }

        /** 生产镜像：CaptureService.onAccessibilityEvent 对每条窗口/内容事件
         *  调 TargetMemo.invalidate。测试用它模拟「树上真的发生了变化」。 */
        fun onAccessibilityEvent() = memo.invalidate()

        val postedDelays = mutableListOf<Long>()
        val copies = mutableListOf<String>()
        private val pending = ArrayDeque<() -> Unit>()

        override fun activeRoot(): AccessibilityNodeInfo? = root

        override fun targetOf(root: AccessibilityNodeInfo): ConversationSession.Target? =
            memo.targetOf(root)

        override fun isCurrent(token: ConversationSession.Token): Boolean = current

        override fun post(delayMs: Long, action: () -> Unit) {
            postedDelays.add(delayMs)
            pending.add(action)
        }

        override fun copyToClipboard(text: String) { copies.add(text) }

        /** 执行全部挂起的延时任务（含执行中新挂上的），返回执行条数。 */
        fun runPending(): Int {
            var ran = 0
            while (pending.isNotEmpty()) {
                pending.removeFirst().invoke()
                ran++
            }
            return ran
        }
    }

    /**
     * 输入框节点桩：记录一切 performAction 的 actionId（GLOBAL_ACTION 白名单的
     * 断言输入）；SET_TEXT 的「写入成功但内容读不到」（无障碍缓存里的旧草稿，
     * InputFiller KDoc 提到的现象）与 PASTE 的生效文本由测试控制。
     *
     * [onContentChanged]：SET_TEXT / PASTE 改到内容时回调——测试把它接到
     * [FakeHost.onAccessibilityEvent] 如实建模生产（内容变了 → 无障碍事件 →
     * TargetMemo 失效）。不接钩子的测试即建模「事件被丢弃/树静默」。
     *
     * [windowId] / [pkg]：TargetMemo 的缓存键读 root 的这两项，测试用它构造
     * 「同窗新实例」（键不变）与「换窗」（键变）两种框架行为。
     */
    private class StubNode(
        initial: CharSequence? = null,
        val windowId: Int = 7,
        val pkg: CharSequence = "com.example.chat",
    ) {
        var text: CharSequence? = initial
            private set
        /** 前 N 次 SET_TEXT 返回 true 但内容保持旧值（模拟缓存延迟）。 */
        var staleWrites = 0
        /** PASTE 时写入的文本；null = 粘贴不改变内容。 */
        var pasteWrites: CharSequence? = null
        /** SET_TEXT / PASTE 真正改到内容后的回调（接 FakeHost.onAccessibilityEvent）。 */
        var onContentChanged: (() -> Unit)? = null
        /** 全部 performAction 的 actionId，按调用序。 */
        val actions = mutableListOf<Int>()

        val node: AccessibilityNodeInfo = Mockito.mock(AccessibilityNodeInfo::class.java).also { m ->
            Mockito.`when`(m.text).thenAnswer { text }
            Mockito.`when`(m.refresh()).thenReturn(true)
            Mockito.`when`(m.isVisibleToUser).thenReturn(true)
            Mockito.`when`(m.isEnabled).thenReturn(true)
            Mockito.`when`(m.isPassword).thenReturn(false)
            Mockito.`when`(m.windowId).thenReturn(windowId)
            Mockito.`when`(m.packageName).thenReturn(pkg)
            Mockito.`when`(m.performAction(Mockito.anyInt())).thenAnswer { inv ->
                val id = inv.getArgument<Int>(0)
                actions.add(id)
                if (id == AccessibilityNodeInfo.ACTION_PASTE) {
                    if (pasteWrites != null) {
                        text = pasteWrites
                        onContentChanged?.invoke()
                    }
                }
                true
            }
            Mockito.`when`(
                m.performAction(Mockito.anyInt(), Mockito.any(Bundle::class.java))
            ).thenAnswer { inv ->
                val id = inv.getArgument<Int>(0)
                actions.add(id)
                if (id == AccessibilityNodeInfo.ACTION_SET_TEXT) {
                    val incoming = inv.getArgument<Bundle>(1)
                        .getCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE)
                    val changed = if (staleWrites > 0) {
                        staleWrites--
                        false    // 写入「成功」但内容没变（旧草稿仍在）——无内容事件
                    } else {
                        text = incoming
                        true
                    }
                    if (changed) onContentChanged?.invoke()
                }
                true
            }
        }
    }

    private fun fillerFor(host: FakeHost, input: AccessibilityNodeInfo?): InputFiller {
        val adapter = Mockito.mock(ChatAppAdapter::class.java)
        // fix(kimi-review 循环)：不能用 `when`(adapter.findInput(any()))——any() 返回
        // null，而 findInput 是 Kotlin 接口的非空参数位，调用点的平台类型断言直接
        // NPE（"any(...) must not be null"，实测）。改 doReturn 风格 + 具体实例注册
        // 桩（不用匹配器，彻底绕开调用点断言与匹配器状态污染）；input 为 null 时
        // 不打桩，mock 默认返回 null 即所期行为。
        if (input != null) {
            Mockito.doReturn(input).`when`(adapter).findInput(input)
        }
        return InputFiller(host, { _ -> adapter })
    }

    private fun target(
        pkg: String = "com.example.chat",
        windowId: Int = 7,
        title: String? = "Alice",
        sig: String? = null,
    ) = ConversationSession.Target(pkg, windowId, title, sig)

    // ---- #6 回归：sameConversation 契约 ----

    @Test
    fun inputFor_messageSignatureDriftInSameConversation_stillResolves() {
        // 对方又发一条消息 → messagesSignature 微变（Target.sameConversation 的
        // 注释契约：指纹微变不算换会话）→ inputFor 必须照常解析出输入框。
        val t = target(sig = "sig-at-fill-start")
        val node = StubNode()
        val host = FakeHost(root = node.node, target = t.copy(messagesSignature = "sig-after-new-message"))
        val resolved = fillerFor(host, node.node).inputFor(ConversationSession.Token(t, 0))
        assertNotNull(resolved)
        assertSame(node.node, resolved)
    }

    @Test
    fun inputFor_titleChangeIsAChatSwitch_rejects() {
        val t = target(title = "Alice")
        val node = StubNode()
        val host = FakeHost(root = node.node, target = t.copy(title = "Bob"))
        assertNull(fillerFor(host, node.node).inputFor(ConversationSession.Token(t, 0)))
    }

    @Test
    fun inputFor_windowOrPackageChange_rejects() {
        val t = target()
        val node = StubNode()
        val host = FakeHost(root = node.node, target = t.copy(windowId = 99))
        assertNull(fillerFor(host, node.node).inputFor(ConversationSession.Token(t, 0)))
        val host2 = FakeHost(root = node.node, target = t.copy(pkg = "com.other.app"))
        assertNull(fillerFor(host2, node.node).inputFor(ConversationSession.Token(t, 0)))
    }

    @Test
    fun inputFor_untrackedRoot_rejects() {
        val node = StubNode()
        val host = FakeHost(root = node.node, target = null)
        assertNull(fillerFor(host, node.node).inputFor(ConversationSession.Token(target(), 0)))
    }

    // ---- 「绝不 GLOBAL_ACTION 发送」（#15）：动作白名单 ----

    @Test
    fun fill_happyPath_performsOnlyWhitelistedNodeActions() {
        val node = StubNode()
        val t = target()
        val host = FakeHost(root = node.node, target = t)
        val results = mutableListOf<Boolean>()
        fillerFor(host, node.node).fill(ConversationSession.Token(t, 0), "你好") { results.add(it) }
        host.runPending()
        assertEquals(listOf(true), results)
        // happy path 只有一次 SET_TEXT 写入；没有任何可能发送/系统级的动作。
        assertEquals(listOf(AccessibilityNodeInfo.ACTION_SET_TEXT), node.actions)
    }

    @Test
    fun fill_fullRetryPath_performsOnlyWhitelistedNodeActions_neverGlobalActions() {
        // 完整重试链：SET_TEXT → 检查读到旧缓存草稿 → focus(CLICK) → SET_TEXT →
        // 复查仍不等 → copy + SET_TEXT("") 清空 → PASTE → 粘贴后见全文。每个动作
        // 都打在输入框节点上、全部落在白名单——GLOBAL_ACTION 发送类动作一个没有。
        val node = StubNode("旧草稿")
        node.staleWrites = 2        // 入口写入与 focus 后重写都「读不到」
        node.pasteWrites = "你好"   // PASTE 生效
        val t = target()
        val host = FakeHost(root = node.node, target = t)
        val results = mutableListOf<Boolean>()
        fillerFor(host, node.node).fill(ConversationSession.Token(t, 0), "你好") { results.add(it) }
        host.runPending()
        assertEquals(listOf(true), results)
        assertEquals(
            listOf(
                AccessibilityNodeInfo.ACTION_SET_TEXT,  // 入口写入
                AccessibilityNodeInfo.ACTION_CLICK,     // focus——打在输入框，不是发送按钮
                AccessibilityNodeInfo.ACTION_SET_TEXT,  // focus 后重试写入
                AccessibilityNodeInfo.ACTION_SET_TEXT,  // 清空 ""
                AccessibilityNodeInfo.ACTION_PASTE,     // 系统粘贴进输入框
            ),
            node.actions,
        )
        assertEquals(listOf("你好"), host.copies)   // 剪贴板恰好一次
        // 本测试不接 onContentChanged（建模「事件被丢弃/树静默」）：6 次 resolve
        // 全部落在 TargetMemo 的静默窗内，全树提取只发生 1 次（#13 v2）。
        // 忠实事件模型下的计数见 fill_fullRetryPath_faithfulEvents_extractsThrice。
        assertEquals(1, host.targetOfCalls.size)
    }

    @Test
    fun fill_unverifiableAfterPaste_nodeActionsStillWhitelisted_reportsFalseOnce() {
        val node = StubNode("旧草稿")
        node.staleWrites = 2
        node.pasteWrites = null     // PASTE 无效：验证失败 → complete(false)
        val t = target()
        val host = FakeHost(root = node.node, target = t)
        val results = mutableListOf<Boolean>()
        fillerFor(host, node.node).fill(ConversationSession.Token(t, 0), "你好") { results.add(it) }
        host.runPending()
        assertEquals(listOf(false), results)        // complete 恰一次
        assertTrue(
            node.actions.all {
                it == AccessibilityNodeInfo.ACTION_SET_TEXT ||
                    it == AccessibilityNodeInfo.ACTION_CLICK ||
                    it == AccessibilityNodeInfo.ACTION_PASTE
            },
            "fill 对节点只许发 SET_TEXT/CLICK/PASTE，实际动作表：${node.actions}",
        )
        assertEquals(listOf("你好"), host.copies)
    }

    // ---- #13 回归（v2）：targetOf 提取缓存在 Host 层 TargetMemo（pkg+windowId
    // 键 + 无障碍事件失效），入口检查与首个 resolve 共用一次解析。
    //
    // 旧版按 root 实例引用缓存是死代码（框架每次 getRootInActiveWindow 都给新
    // 实例），本节按新语义重钉：树静默（无事件）复用提取、事件后重提取、
    // 实例更换而键不变不重提取。「每次 SET_TEXT/PASTE 改到内容都触发事件」
    // 由 StubNode.onContentChanged → FakeHost.onAccessibilityEvent 如实建模；
    // 不接钩子的测试即建模「事件被丢弃/树静默」——memo 在此复用且正确
    // （TargetMemo 的正确性依据：两次提取之间无事件 ⇒ 树未变 ⇒ 结果不变）。

    @Test
    fun fill_happyPath_faithfulEvents_extractsTwice() {
        // 入口+首个 resolve 共用 1 次提取（同栈无事件）；SET_TEXT 改了内容 →
        // 事件 → checkFirst 的 resolve 重提取。生产 happy path 的提取次数：2。
        val node = StubNode()
        val t = target()
        val host = FakeHost(root = node.node, target = t)
        node.onContentChanged = host::onAccessibilityEvent
        val results = mutableListOf<Boolean>()
        fillerFor(host, node.node).fill(ConversationSession.Token(t, 0), "你好") { results.add(it) }
        host.runPending()
        assertEquals(listOf(true), results)
        assertEquals(2, host.targetOfCalls.size)
        assertSame(node.node, host.targetOfCalls[0])
        assertSame(node.node, host.targetOfCalls[1])
    }

    @Test
    fun fill_fullRetryPath_faithfulEvents_extractsThrice() {
        // 完整重试链（staleWrites=2：前两次 SET_TEXT 内容没变、无内容事件；
        // 清空与 PASTE 才真改了内容）。提取 = 入口 1 次 + 清空后 paste resolve
        // 1 次 + checkPaste 1 次 = 3（旧死缓存在生产是 6 次全树遍历）。
        val node = StubNode("旧草稿")
        node.staleWrites = 2
        node.pasteWrites = "你好"
        val t = target()
        val host = FakeHost(root = node.node, target = t)
        node.onContentChanged = host::onAccessibilityEvent
        val results = mutableListOf<Boolean>()
        fillerFor(host, node.node).fill(ConversationSession.Token(t, 0), "你好") { results.add(it) }
        host.runPending()
        assertEquals(listOf(true), results)
        assertEquals(3, host.targetOfCalls.size)
    }

    @Test
    fun fill_quietTree_eventsDropped_extractionMemoHolds() {
        // 建模「事件被丢弃/树静默」：不接 onContentChanged。入口+首个 resolve
        // 共用 1 次；checkFirst 的 resolve 也在静默窗内 → 复用。整次 fill 只
        // 提取 1 次（Target 的 pkg/windowId/title 没变，复用即正确）。
        val node = StubNode()
        val t = target()
        val host = FakeHost(root = node.node, target = t)
        val results = mutableListOf<Boolean>()
        fillerFor(host, node.node).fill(ConversationSession.Token(t, 0), "你好") { results.add(it) }
        host.runPending()
        assertEquals(listOf(true), results)
        assertEquals(1, host.targetOfCalls.size)
        assertSame(node.node, host.targetOfCalls[0])
    }

    @Test
    fun fill_newRootInstanceSameWindowQuietTree_reusesMemo() {
        // 框架每次 getRootInActiveWindow 都返回新实例——实例更换而键
        // （pkg+windowId）不变时**不得**重提取（旧版的 === 键在生产恒失效的
        // 根因；键是身份不是引用）。
        val node = StubNode()
        val t = target()
        val host = FakeHost(root = node.node, target = t)
        val results = mutableListOf<Boolean>()
        val filler = fillerFor(host, node.node)
        filler.fill(ConversationSession.Token(t, 0), "你好") { results.add(it) }
        host.root = StubNode().node     // 同窗新实例，无事件
        host.runPending()
        assertEquals(listOf(true), results)
        assertEquals(1, host.targetOfCalls.size)
    }

    @Test
    fun fill_windowIdChanges_reExtractsEvenWithoutEvent() {
        // 键变了（换窗）必须重提取：陈旧 Target 会让 sameConversation 误判
        // 同会话，把回填写进另一个窗口。
        val node = StubNode()
        val t = target()
        val host = FakeHost(root = node.node, target = t)
        val results = mutableListOf<Boolean>()
        val filler = fillerFor(host, node.node)
        filler.fill(ConversationSession.Token(t, 0), "你好") { results.add(it) }
        host.root = StubNode(windowId = 99).node    // 换窗，无事件也必须重提取
        host.runPending()
        assertEquals(listOf(true), results)         // FakeHost 恒回同一 Target：仍同会话
        assertEquals(2, host.targetOfCalls.size)
        assertSame(node.node, host.targetOfCalls[0])
        assertSame(host.root, host.targetOfCalls[1])
    }

    @Test
    fun fill_eventBetweenFills_reExtractsEvenWithSameRoot() {
        // 两次 fill 之间有任何事件（树可能变了）→ 重提取，即使 root 引用与键
        // 都没变。「同窗口内可能切了聊天」由事件失效兜住。
        val node = StubNode()
        val t = target()
        val host = FakeHost(root = node.node, target = t)
        val filler = fillerFor(host, node.node)
        val r1 = mutableListOf<Boolean>()
        filler.fill(ConversationSession.Token(t, 0), "你好") { r1.add(it) }
        host.runPending()
        assertEquals(listOf(true), r1)
        assertEquals(1, host.targetOfCalls.size)
        host.onAccessibilityEvent()                 // 树上发生了变化
        val r2 = mutableListOf<Boolean>()
        filler.fill(ConversationSession.Token(t, 0), "第二条") { r2.add(it) }
        host.runPending()
        assertEquals(listOf(true), r2)
        assertEquals(2, host.targetOfCalls.size)
    }

    @Test
    fun fill_quietSecondFill_reusesExtraction() {
        // 两次 fill 之间无事件 ⇒ 树未变 ⇒ Target 未变：跨 fill 复用是 v2 的
        // 既定语义（旧版「绝不跨 fill 复用」防的陈旧 Target，现在由事件失效
        // 保证不陈旧——无事件就没有陈旧可言）。
        val node = StubNode()
        val t = target()
        val host = FakeHost(root = node.node, target = t)
        val filler = fillerFor(host, node.node)
        val r1 = mutableListOf<Boolean>()
        filler.fill(ConversationSession.Token(t, 0), "你好") { r1.add(it) }
        host.runPending()
        assertEquals(listOf(true), r1)
        val r2 = mutableListOf<Boolean>()
        filler.fill(ConversationSession.Token(t, 0), "第二条") { r2.add(it) }
        host.runPending()
        assertEquals(listOf(true), r2)
        assertEquals(1, host.targetOfCalls.size)
    }

    // ---- 边界：不在会话 / 无输入框 / 会话过期 ----

    @Test
    fun fill_sessionNoLongerCurrent_noWriteNoCallback() {
        val node = StubNode()
        val t = target()
        val host = FakeHost(root = node.node, target = t)
        host.current = false
        val results = mutableListOf<Boolean>()
        fillerFor(host, node.node).fill(ConversationSession.Token(t, 0), "你好") { results.add(it) }
        host.runPending()
        assertEquals(emptyList<Boolean>(), results)  // 入口 isCurrent 直接返回
        assertEquals(emptyList<Int>(), node.actions) // 一个动作都没有
        assertFalse(host.postedDelays.isNotEmpty())
    }

    @Test
    fun fill_noInputOnScreen_reportsFalseOnce_noClipboardNoActions() {
        val node = StubNode()
        val t = target()
        val host = FakeHost(root = node.node, target = t)
        val results = mutableListOf<Boolean>()
        fillerFor(host, null).fill(ConversationSession.Token(t, 0), "你好") { results.add(it) }
        host.runPending()
        assertEquals(listOf(false), results)         // complete 恰一次
        assertEquals(emptyList<Int>(), node.actions)
        assertEquals(emptyList<String>(), host.copies)
        assertEquals(emptyList<Long>(), host.postedDelays)
    }
}

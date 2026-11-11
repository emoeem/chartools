package dev.chartools.capture

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * GuardedInputWriter 状态机单测（fix(kimi-review #15)）。
 *
 * 基建的两个决定：
 * - 重试时序用可注入时钟：[later] 不真延时，把动作记进 [FakeClock] 队列、由
 *   [FakeClock.runPending] 手动执行；顺带断言每次排程的延时值与个数（检查即过
 *   = 150，focus 重试 = 150,300,150，剪贴板+粘贴全链 = 150,300,150,150）——
 *   状态机的时序契约一并钉住。
 * - complete 恰一次：GuardedInputWriter 头注释的保证（「exactly one complete
 *   per fill，pending 的 MethodChannel.Result 必有回复」）在每个场景——包括
 *   全部 6 个 resolve 位（入口/检查/重试/复查/粘贴前/粘贴后检查）各自 miss——
 *   都用 [Harness.results] 显式断言 size == 1。
 *
 * Input 桩只记日志，不碰 Android 类型，纯 JVM 可跑。
 */
class GuardedInputWriterTest {

    // ---- 脚手架 ----------------------------------------------------------

    /** 可注入时钟：任务按注册顺序 FIFO 执行（状态机的任务链是串行的）。 */
    private class FakeClock {
        private val queue = mutableListOf<() -> Unit>()
        /** 每次排程的延时值，按调用序。 */
        val scheduledDelays = mutableListOf<Long>()

        fun later(delay: Long, action: () -> Unit) {
            scheduledDelays.add(delay)
            queue.add(action)
        }

        /** 执行全部已排任务（含执行中新挂上的），返回执行条数。 */
        fun runPending(): Int {
            var ran = 0
            while (queue.isNotEmpty()) {
                queue.removeAt(0).invoke()
                ran++
            }
            return ran
        }
    }

    /** Input 桩：动作只记日志；setText 是否真的改内容由 [applyText] 决定。 */
    private class FakeInput(initialText: String? = null, applyText: Boolean = true) :
        GuardedInputWriter.Input {
        private var current: String? = initialText
        private val ok = applyText
        val log = mutableListOf<String>()

        override val text: String? get() = current

        override fun setText(text: String): Boolean {
            log.add("setText(\"$text\")")
            if (ok) current = text
            return ok
        }

        override fun focus() { log.add("focus") }

        override fun paste() { log.add("paste") }
    }

    /** resolve 输入队列 + complete 记录 + copy 日志的聚合脚手架。 */
    private class Harness {
        val clock = FakeClock()
        /** complete 的全部返回值——恰一次断言的载体。 */
        val results = mutableListOf<Boolean>()
        /** copy 与 complete 的动作流（focus/paste/setText 在各 Input 自己的 log 里）。 */
        val log = mutableListOf<String>()
        private val resolves = ArrayDeque<GuardedInputWriter.Input?>()
        // fix(kimi-review 循环)：collected 用 FakeInput 类型——Input 接口没有 log，
        // allInputActions 的 it.log 需要 FakeInput 的动作日志。
        private val collected = mutableListOf<FakeInput>()

        /** 聚合全部传入 Input 的动作日志（断言「谁都没收到 PASTE」之类用）。 */
        val allInputActions: List<String> get() = collected.flatMap { it.log }

        fun resolve(vararg inputs: GuardedInputWriter.Input?) {
            inputs.forEach {
                resolves.add(it)
                if (it != null) collected.add(it as FakeInput)
            }
        }

        fun writer(): GuardedInputWriter = GuardedInputWriter(
            resolve = { resolves.removeFirstOrNull() },
            later = { delay, action -> clock.later(delay, action) },
            copy = { log.add("copy") },
            complete = { ok -> log.add("complete($ok)"); results.add(ok) },
        )
    }

    // ---- 入口 resolve miss ----

    @Test
    fun resolveMissOnEntry_completesFalseExactlyOnce_neverSchedules() {
        val h = Harness()
        h.resolve(null)
        h.writer().fill("hi")
        assertEquals(0, h.clock.runPending())
        assertEquals(emptyList<Long>(), h.clock.scheduledDelays)
        assertEquals(listOf(false), h.results)
        assertEquals(listOf("complete(false)"), h.log)
    }

    // ---- 检查即过的 happy path ----

    @Test
    fun firstCheckSeesFullText_completesTrueExactlyOnce_withoutClipboard() {
        val h = Harness()
        val editor = FakeInput()                       // 入口被写入
        h.resolve(editor, FakeInput("hi"))             // 150ms 检查点已见全文
        h.writer().fill("hi")
        assertEquals(1, h.clock.runPending())          // 只有 checkFirst 一个挂起任务
        assertEquals(listOf(150L), h.clock.scheduledDelays)
        assertEquals(listOf(true), h.results)          // complete 恰一次
        assertEquals(listOf("complete(true)"), h.log)  // 不走剪贴板
        assertEquals(listOf("setText(\"hi\")"), editor.log)
        assertEquals("hi", editor.text)
        assertFalse(editor.log.contains("focus"))
        assertFalse(editor.log.contains("paste"))
    }

    // ---- focus 重试链 ----

    @Test
    fun firstCheckMismatch_focusThenRewrite_retryVerifiesTrue() {
        val h = Harness()
        val editor = FakeInput()
        val stale = FakeInput("旧草稿")                // 检查点读到缓存里的旧草稿
        val refocused = FakeInput("旧草稿")            // focus 后重取的输入框：重写
        h.resolve(editor, stale, refocused, FakeInput("hi"))
        h.writer().fill("hi")
        assertEquals(3, h.clock.runPending())          // checkFirst → retry → checkRetry
        assertEquals(listOf(150L, 300L, 150L), h.clock.scheduledDelays)
        assertEquals(listOf(true), h.results)
        assertEquals(listOf("complete(true)"), h.log)
        assertEquals(listOf("focus"), stale.log)       // focus 打在检查点那个节点上
        assertEquals(listOf("setText(\"hi\")"), refocused.log)
        assertFalse(h.log.contains("copy"))
    }

    // ---- 剪贴板 + 清空 + 粘贴全链 ----

    @Test
    fun retryStillStale_copiesClearsAndPastes_pasteThenVerifiesTrue() {
        val h = Harness()
        val editor = FakeInput()
        val stale1 = FakeInput("旧草稿")
        val rewritten = FakeInput("旧草稿")            // retry 被重写，检查仍不等
        val pasteHost = FakeInput("旧草稿")            // 清空成功：先 SET_TEXT("") 打这
        val pasteInput = FakeInput("旧草稿")           // PASTE 前重解析出的输入框：paste 打这
        h.resolve(editor, stale1, rewritten, pasteHost, pasteInput, FakeInput("hi"))
        h.writer().fill("hi")
        assertEquals(4, h.clock.runPending())          // 150/300/150/150 全链
        assertEquals(listOf(150L, 300L, 150L, 150L), h.clock.scheduledDelays)
        assertEquals(listOf(true), h.results)
        assertEquals(listOf("copy", "complete(true)"), h.log)  // 剪贴板恰好一次
        assertEquals(listOf("setText(\"hi\")"), rewritten.log)
        assertEquals(listOf("setText(\"\")"), pasteHost.log)   // 先清空
        assertEquals("", pasteHost.text)
        assertEquals(listOf("paste"), pasteInput.log)          // PASTE 打在清空后的输入框
    }

    @Test
    fun pasteStillStale_completesFalseExactlyOnce() {
        val h = Harness()
        h.resolve(
            FakeInput(), FakeInput("旧草稿"), FakeInput("旧草稿"),
            FakeInput("旧草稿"), FakeInput("旧草稿"), FakeInput("别的草稿"),
        )
        h.writer().fill("hi")
        assertEquals(4, h.clock.runPending())
        assertEquals(listOf(150L, 300L, 150L, 150L), h.clock.scheduledDelays)
        assertEquals(listOf(false), h.results)         // complete 恰一次
        assertEquals(listOf("copy", "complete(false)"), h.log)
    }

    @Test
    fun clearFails_skipsPaste_butStillChecksAndCompletesOnce() {
        // 清空 SET_TEXT("") 返回 false：不 PASTE，但仍挂 checkPaste 收尾——
        // complete 恰一次的保证不许因为跳过 PASTE 而破。
        //
        // 甄别 #8 kotlin-test（判测试错、实现对）：清空打在 checkRetry **重解析
        // 出的输入框**上，不是 retry 步骤的旧对象。依据：GuardedInputWriter 头
        // 注释契约「resolve must validate the live session on every call」+
        // InputFiller 类注释「Every step re-resolves the originating conversation,
        // so a chat switch mid-retry can never land the text in the wrong
        // window」——对 150ms 前的旧节点清空 = 绕过重校验写入，会话已切时会把
        // SET_TEXT("") 打进别的窗口；姊妹用例
        // retryStillStale_copiesClearsAndPastes_pasteThenVerifiesTrue 钉的也是
        // 同一语义（清空落在 checkRetry 解析位 pasteHost 上）。原版把
        // applyText=false 挂在 retry 步骤对象上、却期望清空日志也落在它——
        // 与契约矛盾（实得 [setText("hi")]：清空按实现打在重解析对象上）。
        // 改模型：retry 重写失败（旧值不动），checkRetry 重解析出的输入框清空
        // 失败 → 不 PASTE，checkPaste 照排、complete 恰一次。
        val h = Harness()
        val retryWriteMiss = FakeInput("旧草稿", applyText = false)  // retry 重写失败
        val clearMiss = FakeInput("旧草稿", applyText = false)       // checkRetry 位：清空失败
        h.resolve(
            FakeInput(), FakeInput("旧草稿"), retryWriteMiss,
            clearMiss, FakeInput("旧草稿"),
        )
        h.writer().fill("hi")
        assertEquals(4, h.clock.runPending())          // checkPaste 照排（4 个延时全链）
        assertEquals(listOf(150L, 300L, 150L, 150L), h.clock.scheduledDelays)
        assertEquals(listOf(false), h.results)
        assertEquals(listOf("copy", "complete(false)"), h.log)
        assertEquals(listOf("setText(\"hi\")"), retryWriteMiss.log)
        assertEquals(listOf("setText(\"\")"), clearMiss.log)   // 清空打在重解析位
        assertEquals("旧草稿", retryWriteMiss.text)    // 重写没生效
        assertEquals("旧草稿", clearMiss.text)         // 清空也没生效
        // 没有任何 Input 收到 PASTE。
        assertTrue(h.allInputActions.none { it == "paste" })
    }

    // ---- 各 resolve 位 miss：每处恰一次 complete(false)，miss 后不排后续任务 ----

    @Test
    fun resolveMissOnFirstCheck_completesFalseExactlyOnce() {
        val h = Harness()
        h.resolve(FakeInput(), null)
        h.writer().fill("hi")
        assertEquals(1, h.clock.runPending())
        assertEquals(listOf(150L), h.clock.scheduledDelays)
        assertEquals(listOf(false), h.results)
        assertEquals(listOf("complete(false)"), h.log)
    }

    @Test
    fun resolveMissOnRetry_completesFalseExactlyOnce() {
        val h = Harness()
        val stale = FakeInput("旧草稿")
        h.resolve(FakeInput(), stale, null)
        h.writer().fill("hi")
        assertEquals(2, h.clock.runPending())
        assertEquals(listOf(150L, 300L), h.clock.scheduledDelays)
        assertEquals(listOf(false), h.results)
        assertEquals(listOf("focus"), stale.log)       // miss 前 focus 已发生
    }

    @Test
    fun resolveMissOnRetryCheck_completesFalseExactlyOnce() {
        val h = Harness()
        h.resolve(FakeInput(), FakeInput("旧草稿"), FakeInput("旧草稿"), null)
        h.writer().fill("hi")
        assertEquals(3, h.clock.runPending())
        assertEquals(listOf(150L, 300L, 150L), h.clock.scheduledDelays)
        assertEquals(listOf(false), h.results)
        assertEquals(listOf("complete(false)"), h.log)
    }

    @Test
    fun resolveMissBeforePaste_completesFalseExactlyOnce() {
        // 清空可能触发导航（状态机行内注释）：PASTE 前也要 resolve——miss 直接收尾。
        val h = Harness()
        h.resolve(
            FakeInput(), FakeInput("旧草稿"), FakeInput("旧草稿"),
            FakeInput("旧草稿"), null,
        )
        h.writer().fill("hi")
        assertEquals(3, h.clock.runPending())          // checkRetry 内收尾，无 checkPaste
        assertEquals(listOf(150L, 300L, 150L), h.clock.scheduledDelays)
        assertEquals(listOf(false), h.results)
        assertEquals(listOf("copy", "complete(false)"), h.log)
    }

    @Test
    fun resolveMissOnPasteCheck_completesFalseExactlyOnce() {
        val h = Harness()
        h.resolve(
            FakeInput(), FakeInput("旧草稿"), FakeInput("旧草稿"),
            FakeInput("旧草稿"), FakeInput("旧草稿"), null,
        )
        h.writer().fill("hi")
        assertEquals(4, h.clock.runPending())
        assertEquals(listOf(150L, 300L, 150L, 150L), h.clock.scheduledDelays)
        assertEquals(listOf(false), h.results)
        assertEquals(listOf("copy", "complete(false)"), h.log)
    }
}

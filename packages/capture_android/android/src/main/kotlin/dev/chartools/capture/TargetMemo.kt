package dev.chartools.capture

import android.view.accessibility.AccessibilityNodeInfo

/**
 * fix(kimi-review #13)：Host 层的 targetOf 提取 memo（输入框回填路径）。
 *
 * 前一版实现在 InputFiller 里按 root **实例引用**（`cachedRoot !== root`）做
 * 缓存键——而 Host.activeRoot() = getRootInActiveWindow() 每次都返回新构造的
 * AccessibilityNodeInfo（框架语义），引用恒不等，缓存一次都没命中过，是死
 * 代码（独立复核 2026-11-12）。且实例引用语义本身就不安全：若框架真复用实例，
 * 跨内容变化复用提取结果会让「同一窗口内切聊天」漏检——sameConversation 靠
 * 提取到的**标题**辨认换会话，陈旧标题会放行把回填写进切换后的聊天输入框，
 * 违反 InputFiller「换会话绝不写错窗口」的类注释契约。
 *
 * 本实现按最初 #13 建议的语义落在 Host 层：
 * - 键 = root 的 pkg + windowId（[ConversationSession.Target.sameConversation]
 *   的会话身份前两级；窗口内切聊天不换 windowId，所以**必须**配合失效钩子）。
 * - 失效 = [invalidate]，由 CaptureService.onAccessibilityEvent 对每一条
 *   TYPE_WINDOW_STATE_CHANGED / TYPE_WINDOW_CONTENT_CHANGED 事件调用——
 *   「两次提取之间无事件 ⇒ 树未变 ⇒ 提取结果不变」是正确性依据；有事件就
 *   重提取，绝不跨内容变化复用（这是回填重试链 6 次 resolve 里相邻两次之间
 *   都夹着一次 SET_TEXT 写入的原因：写入本身触发 content-changed，重试路径
 *   本来就该逐次重提取——memo 省下的是树静默期的重复提取，不是失败重试的）。
 * - null 也算提取结果（同样缓存，失效后重算）。
 *
 * 主线程单线程使用：onAccessibilityEvent 与 GuardedInputWriter 的 resolve 都
 * 在 main（Host.post 落主线程 Handler），无锁。
 */
internal class TargetMemo(
    private val extract: (AccessibilityNodeInfo) -> ConversationSession.Target?,
) {
    private var filled = false
    private var cachedPkg: String? = null
    private var cachedWindowId: Int = -1
    private var cachedTarget: ConversationSession.Target? = null

    fun targetOf(root: AccessibilityNodeInfo): ConversationSession.Target? {
        val pkg = root.packageName?.toString()
        val windowId = root.windowId
        if (!filled || pkg != cachedPkg || windowId != cachedWindowId) {
            cachedTarget = extract(root)
            cachedPkg = pkg
            cachedWindowId = windowId
            filled = true
        }
        return cachedTarget
    }

    /** 任何无障碍事件都调：树可能变了，下一次提取必须重算。 */
    fun invalidate() {
        filled = false
    }
}

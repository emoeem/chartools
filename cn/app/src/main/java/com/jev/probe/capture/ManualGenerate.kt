package com.jev.probe.capture

/**
 * 「手动生成」的决策层。
 *
 * 用户反馈：在 QQ、TIM 这类应用里点「换一组」经常没反应，只能靠自动触发碰运气。
 * 真正的根因不在按钮本身，而在它前面那条前置条件链——卡片要展开、footer 要滚到、
 * `lastAnalyzed`/`currentSnapshot` 要非空、`analyzing`/`regenerating` 要为 false、
 * 会话 token 还要仍然有效。旧代码在**任何一条**不满足时都是静默 `return`：
 * 没有 toast、没有错误行、屏幕上什么都不变，用户只能得出「按钮坏了」的结论。
 *
 * 这里把那串条件收敛成一个显式的三选一，服务层照做，于是每一次手动点击都一定
 * 落到一个用户看得见的结果：
 *
 * - [Decision.Regenerate] —— 有快照，直接重起草；
 * - [Decision.CaptureFirst] —— 没快照但能抓，先读一次当前屏幕，读完自动生成；
 * - [Decision.Explain] —— 不能生成，把原因说出来。
 *
 * 纯逻辑、不碰 Android 框架类，单测直接跑（见 ManualGenerateTest）。
 */
internal object ManualGenerate {

    /**
     * 忙到这个时间还没结束，就认为上一轮已经卡死，手动点击有权强制重来。
     * 低于它只提示「正在生成中」——用户双击不该把正常的一轮砍掉。
     */
    const val FORCE_GRACE_MS = 8_000L

    sealed interface Decision {
        /** 有可用的对话快照，直接重新起草候选。 */
        data object Regenerate : Decision

        /**
         * 没有快照，但当前前台应用抓得到：先走一次读取（节点树优先，其次 OCR），
         * 读到内容后由既有路径自动开一轮。
         */
        data object CaptureFirst : Decision

        /**
         * 现在生成不了，必须把原因显示给用户，绝不能静默。
         *
         * [transient] = 这是一句过程提示（「正在生成中…」），说一声就行；否则是
         * 一个可行动的原因，要展开卡片、留在第一屏。
         */
        data class Explain(val reason: String, val transient: Boolean = false) : Decision
    }

    /**
     * @param enabled      助手总开关
     * @param hasKey       判断接口密钥是否已配置
     * @param hasSnapshot  手里是否已有一份对话快照（lastAnalyzed 或 currentSnapshot）
     * @param canCapture   当前前台应用是否抓得到内容（有适配器 / 微信像素路径 / 可截图）
     * @param busyAgeMs    若正在跑一轮，距开跑已过的毫秒数；不忙传 null
     */
    fun decide(
        enabled: Boolean,
        hasKey: Boolean,
        hasSnapshot: Boolean,
        canCapture: Boolean,
        busyAgeMs: Long?,
        forceGraceMs: Long = FORCE_GRACE_MS
    ): Decision {
        if (!enabled) return Decision.Explain("助手总开关是关的，去设置里打开")
        if (!hasKey) return Decision.Explain("未设置判断接口密钥，去设置里填")
        // 忙但没超时：正常的一轮还在路上，别砍。
        if (busyAgeMs != null && busyAgeMs < forceGraceMs) {
            return Decision.Explain("正在生成中…", transient = true)
        }
        // 忙且超时：上一轮多半卡住了，手动点击直接把锁放开重来。
        if (hasSnapshot) return Decision.Regenerate
        if (canCapture) return Decision.CaptureFirst
        return Decision.Explain("没读到当前对话：先打开一个聊天窗口，或长按悬浮球用「截屏识别一次」")
    }

    /** 忙碌是否已经久到该被强制接管（服务层用它决定要不要先 cancelInFlight）。 */
    fun shouldForceTakeOver(busyAgeMs: Long?, forceGraceMs: Long = FORCE_GRACE_MS): Boolean =
        busyAgeMs != null && busyAgeMs >= forceGraceMs
}

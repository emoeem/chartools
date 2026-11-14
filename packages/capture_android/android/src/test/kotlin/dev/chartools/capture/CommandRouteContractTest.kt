package dev.chartools.capture

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

/**
 * fix(P1 通知按钮)：KeepAliveService 通知按钮 action 与 CaptureService 消费侧的
 * 字面量互钳 + onStartCommand 对未知动作的容错。
 *
 * 背景：KeepAliveService.onCreate 用两个 PendingIntent.getService 把
 * {ACTION_SUMMON, ACTION_GENERATE} 指向 CaptureService（构造侧），消费侧是
 * CaptureService.onStartCommand → [CaptureService.commandRouteOf]。本服务此前
 * 没有 onStartCommand，按钮点了没反应（外部审阅 P1 ②的原始形态）。构造侧改
 * action 常量、或路由映射漏接一个分支，按钮就再次静默——这里在 JVM 层钉死
 * 三件事：
 * 1. action 字面量沿用 legacy（com.jev.probe.action.*），值漂移必红；
 * 2. 常量 ↔ 路由分支一一对应（两侧引用同一常量，测的是路由没漏接）；
 * 3. 未知/null action 一律 IGNORE（sticky 重启的 null intent、陌生 startService
 *    调用不得崩、不得误触发按钮语义）。
 *
 * onStartCommand 本体（AccessibilityService 实例方法，JVM 实例化不了，与
 * ConfigureReplayTest 同一取舍）与两个动作的运行时效果依赖 Android 框架，
 * 真机回归项：
 * - 通知「唤出助手」：聊天窗内收起胶囊后点按 → 卡片重展开（重放最近一批候选）；
 *   不在任何聊天窗、或从无候选上屏时点按 → 无反应（legacy 是 toast 提示，
 *   overlay 移植时移除，降级为 Trace）。
 * - 通知「重新生成」：聊天窗内点按 → 一轮手动采集，快照经 EventChannel 到
 *   Dart（manual=true，跳过签名去重）；采集在途（ocrBusy）时点按 → 静默让位。
 * - 保活生命周期（P1 ①）：系统设置关掉无障碍 → 保活通知消失（onDestroy
 *   stopService，且不再被 START_STICKY 拉起）；重新打开无障碍 → 通知回来。
 * - START_NOT_STICKY：`adb shell am kill` 杀进程后 capture 服务不被 started-
 *   service 语义拉起（保活服务仍按 START_STICKY 重拉进程，无障碍框架重绑）。
 */
class CommandRouteContractTest {

    @Test
    fun actionLiterals_matchLegacyValues() {
        // 字面量本身就是契约：构造侧（KeepAliveService 的 PendingIntent）与消费侧
        // （commandRouteOf）引用同一常量，改值不会让编译器报警——这里钉死防止
        // 「顺手改名」造成两侧漂移。值沿用 legacy，历史诊断/文档按这个串定位。
        assertEquals("com.jev.probe.action.SUMMON_OVERLAY", KeepAliveService.ACTION_SUMMON)
        assertEquals("com.jev.probe.action.GENERATE_REPLIES", KeepAliveService.ACTION_GENERATE)
    }

    @Test
    fun knownActions_routeToTheirBranches() {
        // 消费侧路由必须原样接住构造侧的两个常量（互钳：任一侧漏接必红）。
        assertEquals(CommandRoute.SUMMON, CaptureService.commandRouteOf(KeepAliveService.ACTION_SUMMON))
        assertEquals(CommandRoute.GENERATE, CaptureService.commandRouteOf(KeepAliveService.ACTION_GENERATE))
    }

    @Test
    fun unknownOrNullAction_isIgnored() {
        // null = START_STICKY 重启携带的 null intent / 无 action 的 startService；
        // 陌生串 = 系统里任意 startService 调用。都落 IGNORE：不崩、不误触发。
        assertEquals(CommandRoute.IGNORE, CaptureService.commandRouteOf(null))
        assertEquals(CommandRoute.IGNORE, CaptureService.commandRouteOf(""))
        assertEquals(CommandRoute.IGNORE, CaptureService.commandRouteOf("garbage"))
        // CaptureService 自身 intent-filter 的绑定 action（无障碍框架用）若被
        // startService 误用，同样必须落 IGNORE。
        assertEquals(
            CommandRoute.IGNORE,
            CaptureService.commandRouteOf("android.accessibilityservice.AccessibilityService")
        )
    }

    @Test
    fun actionMatch_isExactValueAndCase() {
        // when(String) 逐字相等，路由不得「宽容」：大小写/空白差异命中按钮语义
        // 等于给任意 startService 开了误触发口。
        assertEquals(
            CommandRoute.IGNORE,
            CaptureService.commandRouteOf("com.jev.probe.action.summon_overlay")
        )
        assertEquals(
            CommandRoute.IGNORE,
            CaptureService.commandRouteOf(KeepAliveService.ACTION_SUMMON.lowercase())
        )
        assertEquals(
            CommandRoute.IGNORE,
            CaptureService.commandRouteOf(KeepAliveService.ACTION_GENERATE + " ")
        )
    }

    @Test
    fun summonAndGenerate_areDistinctActions() {
        // 两个按钮共用同一目标组件，只有 action 区分——常量撞车会让「重新生成」
        // 静默变成「唤出」。
        assertNotEquals(KeepAliveService.ACTION_SUMMON, KeepAliveService.ACTION_GENERATE)
    }
}

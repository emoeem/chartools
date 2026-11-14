package dev.chartools.capture.bridge

import dev.chartools.capture.CaptureService
import io.flutter.plugin.common.MethodCall
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * 广播 gate 应答契约（M0，root-module-design.md §1.3 三道门闩 / §4-M0 验收②）。
 *
 * 覆盖两层：
 *  1. **门闩判定**：[BridgeDispatch.gateVerdict] 纯函数 —— 三道门闩 fail-closed
 *     （验收②的三个拒收原因：uid=null / INVALID_UID / 非 SCOPED，前两者在
 *     [BridgeReceiver.senderUid] 里归一成 null、再以 -1 哨兵进入派发，都落
 *     `R_NO_SENDER_UID`）+ gate 的 enabled=true/false 两分支。
 *  2. **开关镜像**：[CaptureService.injectionEnabled] 的 configure 解析
 *     （键缺省 = 空映射 = 全关；W2/W3 契约键名 `injectionEnabled` 逐字）。
 *
 * companion 静态与 [BridgeDispatch.gateVerdict] 在 JVM 上直接可跑（无 android
 * 调用）；Receiver 本体的 uid 取值（API 34 门）不在 JVM 能力内，由纯函数替代。
 */
class BridgeGateContractTest {

    private val tg = "org.telegram.messenger"

    /** 本 App uid 与两个陌生 uid（互不相同，模拟真机多 uid 环境）。 */
    private val ownUid = 10086
    private val tgUid = 10101

    // ---- 三道门闩：拒收路径（验收②的三个拒收原因）--------------------------

    @Test
    fun uidNullIsRejectedFailClosed() {
        // BridgeReceiver.senderUid() 在 API<34 / getSentFromUid()==null 时返回
        // null，onReceive 以 -1 哨兵传给派发（BridgeReceiver.kt senderUid）。
        // 即便开关是开的、包名是对的 —— 认不出人就不认（§1.3 门闩一）。
        val v = BridgeDispatch.gateVerdict(
            callerPkg = tg,
            callerUid = -1,
            ownUid = ownUid,
            callerPackages = listOf(tg),
            injectionEnabled = mapOf(tg to true),
        )
        assertEquals(false, v.enabled)
        assertEquals(BridgeContract.R_NO_SENDER_UID, v.rejectReason)
    }

    @Test
    fun invalidUidIsRejectedFailClosed() {
        // Process.INVALID_UID 同样被 senderUid() 归一成 null → -1 哨兵 →
        // R_NO_SENDER_UID。两个「认不出人」的来源共享一个拒收原因（legacy
        // BridgeSender.denyReason: senderUid == null || senderUid < 0）。
        val v = BridgeDispatch.gateVerdict(
            callerPkg = tg,
            callerUid = -1,
            ownUid = ownUid,
            callerPackages = emptyList(),
            injectionEnabled = mapOf(tg to true),
        )
        assertEquals(false, v.enabled)
        assertEquals(BridgeContract.R_NO_SENDER_UID, v.rejectReason)
    }

    @Test
    fun uidOutsideScopedIsRejected() {
        // 门闩二：uid 反查的包名不是自己、也不在 SCOPED 清单里 → R_NOT_SCOPED。
        // 判定依据是 PackageManager 反查结果（callerPackages），不是 Intent 自报。
        val v = BridgeDispatch.gateVerdict(
            callerPkg = tg,
            callerUid = tgUid,
            ownUid = ownUid,
            callerPackages = listOf("com.attacker.app"),
            injectionEnabled = mapOf(tg to true),
        )
        assertEquals(false, v.enabled)
        assertEquals(BridgeContract.R_NOT_SCOPED, v.rejectReason)
    }

    @Test
    fun rootUidIsNotWavedThrough() {
        // §1.3：故意不放行 uid 0 —— root 是风险源不是这条桥的用户。uid 0 反查
        // 出的包名（system/脚本宿主）不在 SCOPED 里，门闩二自然拦下。
        val v = BridgeDispatch.gateVerdict(
            callerPkg = tg,
            callerUid = 0,
            ownUid = ownUid,
            callerPackages = listOf("android"),
            injectionEnabled = mapOf(tg to true),
        )
        assertEquals(false, v.enabled)
        assertEquals(BridgeContract.R_NOT_SCOPED, v.rejectReason)
    }

    @Test
    fun ownUidPassesTheUidGate() {
        // 自己人（本 App 进程也可能走广播通道，单测/调试用）：门闩通过，enabled
        // 只由自报包名 + 开关决定。
        val on = BridgeDispatch.gateVerdict(
            callerPkg = tg,
            callerUid = ownUid,
            ownUid = ownUid,
            callerPackages = listOf("dev.chartools.chartools_app"),
            injectionEnabled = mapOf(tg to true),
        )
        assertEquals(true, on.enabled)
        assertNull(on.rejectReason)

        val off = BridgeDispatch.gateVerdict(
            callerPkg = tg,
            callerUid = ownUid,
            ownUid = ownUid,
            callerPackages = listOf("dev.chartools.chartools_app"),
            injectionEnabled = emptyMap(),
        )
        assertEquals(false, off.enabled)
        assertNull(off.rejectReason)
    }

    // ---- gate 应答：enabled=true / false 两分支 ------------------------------

    @Test
    fun gateEnabledTrueWhenScopedAndSwitchOn() {
        // 模块进程（uid 反查 = org.telegram.messenger，在 SCOPED）+ 自报同名包
        // + Dart 下发的开关对它是 true → enabled=true，无拒收原因。
        val v = BridgeDispatch.gateVerdict(
            callerPkg = tg,
            callerUid = tgUid,
            ownUid = ownUid,
            callerPackages = listOf(tg),
            injectionEnabled = mapOf(tg to true),
        )
        assertEquals(true, v.enabled)
        assertNull(v.rejectReason)
    }

    @Test
    fun gateEnabledFalseWhenSwitchMissing() {
        // 门闩全过但开关镜像里没有这个包（默认 emptyMap = 全关）→ enabled=false
        // 且**不构成拒收**（gate 是问路，如实回 false，rejectReason=null）。
        val v = BridgeDispatch.gateVerdict(
            callerPkg = tg,
            callerUid = tgUid,
            ownUid = ownUid,
            callerPackages = listOf(tg),
            injectionEnabled = emptyMap(),
        )
        assertEquals(false, v.enabled)
        assertNull(v.rejectReason)
    }

    @Test
    fun gateEnabledFalseWhenSwitchExplicitlyOff() {
        val v = BridgeDispatch.gateVerdict(
            callerPkg = tg,
            callerUid = tgUid,
            ownUid = ownUid,
            callerPackages = listOf(tg),
            injectionEnabled = mapOf(tg to false),
        )
        assertEquals(false, v.enabled)
        assertNull(v.rejectReason)
    }

    @Test
    fun gateEnabledFalseWhenSelfReportedPkgNotScoped() {
        // 问错了人：uid 属于 Telegram（门闩过），自报包名却不在 SCOPED ——
        // 如实回 false（回显进 Bundle，Trace 里分得开「开关关着」与「问错人」）。
        val v = BridgeDispatch.gateVerdict(
            callerPkg = "com.other.app",
            callerUid = tgUid,
            ownUid = ownUid,
            callerPackages = listOf(tg),
            injectionEnabled = mapOf(tg to true),
        )
        assertEquals(false, v.enabled)
        assertNull(v.rejectReason)
    }

    @Test
    fun gateEnabledFalseWhenCallerPkgNull() {
        val v = BridgeDispatch.gateVerdict(
            callerPkg = null,
            callerUid = tgUid,
            ownUid = ownUid,
            callerPackages = listOf(tg),
            injectionEnabled = mapOf(tg to true),
        )
        assertEquals(false, v.enabled)
        assertNull(v.rejectReason)
    }

    // ---- 开关镜像：configure 载荷解析（W2/W3 契约键名逐字）------------------

    private fun call(vararg pairs: Pair<String, Any?>) =
        MethodCall("configure", mapOf(*pairs))

    @Test
    fun configureParsesInjectionEnabledMirror() {
        CaptureService.applyConfigureStatics(
            call(
                "packages" to listOf(tg),
                "injectionEnabled" to mapOf(tg to true, "com.other.app" to false),
            )
        )
        assertEquals(mapOf(tg to true, "com.other.app" to false), CaptureService.injectionEnabled)
    }

    @Test
    fun injectionEnabledIsReplacedNotKeptWhenKeyAbsent() {
        // 与 packages 同构的恒替换语义：键缺省 = 空映射 = 全关。用户关掉最后一个
        // 开关后 Dart 下发的空载荷（或旧调用方不带键）必须真的把它关掉——
        // 绝不能像 blocked 那样「键缺省保留当前值」。
        CaptureService.injectionEnabled = mapOf(tg to true)
        CaptureService.applyConfigureStatics(call("packages" to listOf(tg)))
        assertEquals(emptyMap(), CaptureService.injectionEnabled)
    }

    @Test
    fun injectionEnabledDropsNonBooleanEntries() {
        // 非 (String → Boolean) 条目逐项丢弃不抛（对手写载荷/未来调用方的容错）。
        CaptureService.applyConfigureStatics(
            call(
                "packages" to listOf(tg),
                "injectionEnabled" to mapOf(tg to true, "com.b" to "yes", 42 to true),
            )
        )
        assertEquals(mapOf(tg to true), CaptureService.injectionEnabled)
    }

    @Test
    fun injectionEnabledOfIsEmptyForMalformedArguments() {
        assertEquals(emptyMap(), CaptureService.injectionEnabledOf(null))
        assertEquals(emptyMap(), CaptureService.injectionEnabledOf("garbage"))
        assertEquals(emptyMap(), CaptureService.injectionEnabledOf(listOf("not a map")))
        // 键在、值不是映射 → 空映射（不抛）。
        assertEquals(emptyMap(), CaptureService.injectionEnabledOf(mapOf("injectionEnabled" to listOf(tg))))
        // 键在、空映射 → 空映射（显式全关）。
        assertTrue(CaptureService.injectionEnabledOf(mapOf("injectionEnabled" to mapOf<String, Boolean>())).isEmpty())
    }

    // ---- 桥常量钳制：W1 的 BridgeContract 与本轮清单注册逐字对齐 ------------

    @Test
    fun bridgeContractConstantsMatchNewPackageAndManifestRegistration() {
        // 设计 §2.4 表：AUTHORITY / OWNER_PACKAGE / ACTION 全部改新包名。这三个
        // 值同时硬编码在本轮 library 清单的注册项里（manifest 无法引用 Kotlin
        // 常量）——任一侧漂移，receiver 的 intent-filter 就永远收不到广播。
        assertEquals("dev.chartools.chartools_app.bridge", BridgeContract.AUTHORITY)
        assertEquals("dev.chartools.chartools_app", BridgeContract.OWNER_PACKAGE)
        assertEquals("dev.chartools.chartools_app.bridge.CALL", BridgeContract.ACTION)
    }
}

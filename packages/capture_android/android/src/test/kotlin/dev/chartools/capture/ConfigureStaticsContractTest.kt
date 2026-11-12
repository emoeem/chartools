package dev.chartools.capture

import io.flutter.plugin.common.MethodCall
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * configure 静态解析契约（#11 复核遗留 low）。
 *
 * 背景：兜底路径（服务未连接时插件级 handler 直接落）与重放路径（服务 attach
 * 后 Dart 重新下发）共用同一入口 [CaptureService.applyConfigureStatics]——
 * 「两路逐行一致」的注释约定由这个单一入口消灭。本测试把解析语义钉死，防
 * 将来在任一方向引入漂移：
 *  1. packages：**恒替换**（载荷缺 packages 键 → 空集，不是保留旧值）——
 *     白名单门 `eventPkg !in configuredPackages` 读它，替换语义错了就是
 *     全采/不采的事故；
 *  2. blocked：键缺省 → **保留当前值**（用户已配置的黑名单不被空载荷清掉）；
 *  3. ocrFallback：键缺省 → false（不沿用上次的 true——OCR 兜底是重操作，
 *     必须显式开启）；
 *  4. 载荷里的非 String 项逐项过滤，不抛（Dart 侧序列化不会混型，这是对
 *     手写载荷/未来调用方的容错）。
 *
 * companion 静态在 JVM 单测里直接可读写（@Volatile var，无 Android 依赖）。
 */
class ConfigureStaticsContractTest {

    private fun call(vararg pairs: Pair<String, Any?>) =
        MethodCall("configure", mapOf(*pairs))

    @Test
    fun packagesAreAlwaysReplaced() {
        CaptureService.configuredPackages = setOf("old.app")
        CaptureService.applyConfigureStatics(
            call("packages" to listOf("com.a", "com.b"))
        )
        assertEquals(setOf("com.a", "com.b"), CaptureService.configuredPackages)

        // 缺 packages 键也是「替换」：替换成空集（不是保留 old.app）。
        CaptureService.applyConfigureStatics(call("blocked" to listOf("x")))
        assertEquals(emptySet(), CaptureService.configuredPackages)
    }

    @Test
    fun blockedIsKeptWhenKeyAbsent() {
        CaptureService.blockedPackages = setOf("user.blocked.app")
        CaptureService.applyConfigureStatics(
            call("packages" to listOf("com.a"))
        )
        // 键缺省 → 保留：用户的黑名单不被不带 blocked 的载荷清掉。
        assertEquals(setOf("user.blocked.app"), CaptureService.blockedPackages)

        CaptureService.applyConfigureStatics(
            call("packages" to listOf("com.a"), "blocked" to listOf("com.z"))
        )
        assertEquals(setOf("com.z"), CaptureService.blockedPackages)
    }

    @Test
    fun ocrFallbackDefaultsToFalseWhenKeyAbsent() {
        CaptureService.ocrFallbackEnabled = true
        CaptureService.applyConfigureStatics(call("packages" to listOf("com.a")))
        // 缺省 → false：OCR 兜底是重操作，必须显式开启，不沿用上次 true。
        assertEquals(false, CaptureService.ocrFallbackEnabled)
    }

    @Test
    fun nonStringEntriesAreFilteredNotFatal() {
        CaptureService.applyConfigureStatics(
            call(
                "packages" to listOf("com.a", 42, null),
                "blocked" to listOf("com.b", true),
            )
        )
        assertEquals(setOf("com.a"), CaptureService.configuredPackages)
        assertEquals(setOf("com.b"), CaptureService.blockedPackages)
        assertTrue(CaptureService.configuredPackages.all { it.isNotEmpty() })
    }
}

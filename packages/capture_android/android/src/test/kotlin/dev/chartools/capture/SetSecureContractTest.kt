package dev.chartools.capture

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * fix(kimi-review #11)：悬浮窗防截屏开关的两侧方法名契约。
 *
 * 独立复核（2026-11-12）发现：Dart 的 [CaptureAndroid.setSecure] 早已存在，
 * OverlayController.setSecure 与建窗 FLAG_SECURE 注入也在，但 handleControl
 * 没有 'setSecure' 分支——调用落入 notImplemented，整条链路够不着，开关在
 * 服务已连接时也报「未连接」。分支已补（CaptureService.handleControl 的
 * `SET_SECURE_METHOD ->`）；本测试与 Dart 侧 capture_android_test.dart 的
 * 同名断言互钳：任何一侧改方法名都必须两侧同步（CaptureService 在测试环境
 * 实例化不了，分支路由本身与 requestConfigureOver 同一取舍——只能真机回归，
 * 这里钉的是通道契约的名字面量）。
 *
 * fix(#9 K-2) 回放场景：configure 载荷增加 `secure` 键（契约
 * `{packages, ocrFallback, blocked, secure}`，缺省 false 向后兼容），随服务
 * 连接重放把原生 FLAG_SECURE（内存态）恢复成 Dart 侧期望值；状态回读走
 * `IS_SECURE_METHOD`（Dart 侧采集页开关的「期望值 vs 服务回读值」早退判定）。
 * 载荷解析本体在 companion 纯函数 [CaptureService.overlaySecureOf]
 * （与 isBlockedPackage 同一取舍：handleControl 实例方法测试环境够不着），
 * 这里钉缺省语义与载荷读值；configure → overlay.setSecure 的接线与回读分支
 * 路由同上，只能真机回归。
 */
class SetSecureContractTest {

    @Test
    fun setSecure_methodNameMatchesDartContract() {
        // capture_android.dart 的 setSecure 经 control 通道发 'setSecure'，
        // 参数就是 bool 本身（handleControl 里 call.arguments as? Boolean）。
        assertEquals("setSecure", CaptureService.SET_SECURE_METHOD)
    }

    @Test
    fun setSecure_methodRidesControlChannel() {
        // 与 Dart 侧 _control = MethodChannel(CaptureAndroid.controlChannelName)
        // 同一条通道；改通道名任何一侧都必须两侧同步。
        assertEquals("capture_android/control", CaptureService.CONTROL_CHANNEL)
    }

    @Test
    fun isSecure_methodNameMatchesDartContract() {
        // fix(#9 K-2)：状态回读方法名与 Dart 侧 capture_android.isSecureMethod
        // 同名同值（无参数、返回 bool）；改任何一侧都必须两侧同步。
        assertEquals("isSecure", CaptureService.IS_SECURE_METHOD)
    }

    @Test
    fun configureReplay_secureDefaultsToFalse_whenKeyAbsent() {
        // fix(#9 K-2) 向后兼容：旧调用方的 configure 载荷没有 secure 键（形状
        // 与旧 Dart 侧 configure 完全一致）——缺省 false = OverlayController
        // 缺省，旧载荷解析不破；null 载荷同样按 false。
        val legacy = mapOf<String, Any?>(
            "packages" to listOf("com.tencent.mobileqq"),
            "ocrFallback" to true,
            "blocked" to emptyList<String>(),
        )
        assertEquals(false, CaptureService.overlaySecureOf(legacy))
        assertEquals(false, CaptureService.overlaySecureOf(null))
    }

    @Test
    fun configureReplay_secureIsReadFromPayload() {
        // fix(#9 K-2) 服务重连重放：Dart 把 _overlaySecure 带进 configure 载荷，
        // 原生按它恢复 FLAG_SECURE——true/false 都要能读出来；类型不符兜底
        // false（与缺省一致，不让坏载荷炸掉 configure）。
        assertEquals(true, CaptureService.overlaySecureOf(mapOf("secure" to true)))
        assertEquals(false, CaptureService.overlaySecureOf(mapOf("secure" to false)))
        assertEquals(false, CaptureService.overlaySecureOf(mapOf("secure" to "true")))
        assertEquals(false, CaptureService.overlaySecureOf(mapOf<String, Any?>(/* secure 键缺省 */)))
    }
}

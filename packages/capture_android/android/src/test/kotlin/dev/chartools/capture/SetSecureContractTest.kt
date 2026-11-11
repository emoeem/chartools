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
}

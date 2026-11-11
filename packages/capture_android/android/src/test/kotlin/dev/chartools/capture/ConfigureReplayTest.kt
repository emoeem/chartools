package dev.chartools.capture

import io.flutter.plugin.common.MethodChannel
import org.mockito.ArgumentMatchers.anyString
import org.mockito.Mockito
import kotlin.test.Test

/**
 * fix(kimi-review #2)：服务 → Dart 的 configure 重放请求。
 *
 * 背景：configure 只由 Dart 下发一次，服务侧 onServiceConnected 没有任何重放
 * 机制——用户「先配开关、后启无障碍」（最常见路径）时，服务连接时
 * configuredPackages 还是空的，自动采集静默失效。修复：服务与引擎两侧都就绪
 * 的汇聚点（CaptureService.attachEngineChannels，onServiceConnected 与
 * CaptureAndroidPlugin.onAttachedToEngine 两条路径都汇到它）经 control 通道向
 * Dart 发 `requestConfigure`（无参数、无回调），Dart 侧接住后用持久化设置重新
 * 下发 configure（幂等）。
 *
 * maybeCapture/onServiceConnected 是 AccessibilityService，JVM 单测实例化不了，
 * 「attachEngineChannels 触发发送」的接线只能在真机上回归；这里钳住发送单元
 * （companion 的 [CaptureService.requestConfigureOver]）的通道契约与容错。
 */
class ConfigureReplayTest {

    @Test
    fun replay_sendsRequestConfigureWithoutCallback() {
        val channel = Mockito.mock(MethodChannel::class.java)
        CaptureService.requestConfigureOver(channel)
        // 方法名与参数就是与 Dart 侧（capture_android/control 的
        // setMethodCallHandler）的对接契约，改了任何一侧都必须同步。
        Mockito.verify(channel).invokeMethod(CaptureService.REQUEST_CONFIGURE_METHOD, null)
        // 只发这一个方法、不带 Result 回调（fire-and-forget：Dart 未注册 handler
        // 时消息被丢弃，服务侧不等待也不重试）。
        Mockito.verifyNoMoreInteractions(channel)
    }

    @Test
    fun replay_channelFailureIsSwallowed() {
        val channel = Mockito.mock(MethodChannel::class.java)
        Mockito.doThrow(RuntimeException("engine detached"))
            .`when`(channel).invokeMethod(anyString(), Mockito.any())
        // 引擎正在销毁 / 通道已断时，重放请求不得把服务炸掉（attachEngineChannels
        // 处于服务启动的关键路径上）。
        CaptureService.requestConfigureOver(channel)
    }
}

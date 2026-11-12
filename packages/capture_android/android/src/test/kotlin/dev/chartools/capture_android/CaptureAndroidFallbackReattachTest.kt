package dev.chartools.capture_android

import dev.chartools.capture.CaptureService
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import kotlin.test.Test
import kotlin.test.assertEquals
import org.mockito.ArgumentCaptor
import org.mockito.Mockito

/**
 * fix(独立复核 2)：「服务连接 → 服务死亡」转移的兜底回归。
 *
 * 独立复核发现：onServiceConnected → attachEngineChannels 的服务级 handler 按
 * 「后注册覆盖先注册」顶掉插件级兜底，而 onUnbind/onDestroy 只置 live=false、
 * instance=null，从不恢复兜底——服务死后 control 通道上活跃的仍是已销毁实例的
 * controlHandler（isRunning 恰好回 false 正确；openAccessibilitySettings 走已
 * 销毁实例的 startActivity 被报失败；refill/manualOcr 等打到销毁实例上）。修复
 * 模型：onDestroy → detachEngineChannels 摘服务级 handler →
 * CaptureAndroidPlugin.reattachControlFallback 把兜底重新挂回。
 *
 * onDestroy 是 AccessibilityService，JVM 单测实例化不了（与 ConfigureReplayTest
 * 同一取舍）；这里钳住回归单元 [CaptureAndroidPlugin.reattachControlFallback] 的
 * 通道契约：
 * - 挂回发生在给定 messenger 的 CONTROL_CHANNEL 上，且挂回后的 handler 是插件级
 *   兜底本身（服务无关方法就地应答：isRunning → false），不依赖任何服务实例；
 * - onDetachedFromEngine 摘除在场登记后，reattach 变 no-op——引擎先于服务退场
 *   （关应用）时不会把兜底挂到已死的 messenger 上。
 */
class CaptureAndroidFallbackReattachTest {

    /** 生产路径的 attach：真 binding（Mockito 桩）+ 真插件，登记在场实例。 */
    private fun attachedPlugin(
        messenger: BinaryMessenger,
    ): Pair<CaptureAndroidPlugin, FlutterPlugin.FlutterPluginBinding> {
        val binding = Mockito.mock(FlutterPlugin.FlutterPluginBinding::class.java)
        Mockito.`when`(binding.binaryMessenger).thenReturn(messenger)
        val plugin = CaptureAndroidPlugin()
        plugin.onAttachedToEngine(binding)
        return plugin to binding
    }

    /** 二进制层调用捕获到的 handler，解出应答（与 Dart 侧同一编码栈）。 */
    private fun callHandler(
        handler: BinaryMessenger.BinaryMessageHandler,
        method: String,
    ): Any? {
        val codec = StandardMethodCodec.INSTANCE
        var reply: ByteBuffer? = null
        // encodeMethodCall 返回的缓冲 position=limit（未回卷）——本 embedding 的
        // send 路径会自行 rewind，测试直调 onMessage 前要自己回卷到 0。
        val encoded = codec.encodeMethodCall(MethodCall(method, null))
        encoded.rewind()
        handler.onMessage(encoded, BinaryMessenger.BinaryReply { r -> reply = r })
        return reply?.let {
            // 应答缓冲同样未回卷（encodeSuccessEnvelope 的 position=limit 约定）。
            it.rewind()
            codec.decodeEnvelope(it)
        }
    }

    @Test
    fun reattach_afterAttach_registersServiceFreeFallbackOnGivenMessenger() {
        val messenger = Mockito.mock(BinaryMessenger::class.java)
        val (plugin, binding) = attachedPlugin(messenger)
        try {
            CaptureAndroidPlugin.reattachControlFallback(messenger)

            // attach 与 reattach 都在 CONTROL_CHANNEL 上注册过：最后一次是兜底。
            val captor =
                ArgumentCaptor.forClass(BinaryMessenger.BinaryMessageHandler::class.java)
            Mockito.verify(messenger, Mockito.atLeastOnce())
                .setMessageHandler(
                    Mockito.eq(CaptureService.CONTROL_CHANNEL),
                    captor.capture(),
                )

            // 挂回的 handler 是服务无关兜底：isRunning 就地回 false（服务未连接
            // = 没在跑，与 CapturePresence.live 语义一致），不经任何服务实例。
            assertEquals(
                false,
                callHandler(captor.value, CaptureService.IS_RUNNING_METHOD),
            )
        } finally {
            // 清在场登记，不让静态状态泄漏进下一个用例。
            plugin.onDetachedFromEngine(binding)
        }
    }

    @Test
    fun detach_clearsRegistration_andReattachBecomesNoOp() {
        val messenger = Mockito.mock(BinaryMessenger::class.java)
        val (plugin, binding) = attachedPlugin(messenger)

        plugin.onDetachedFromEngine(binding)

        // 引擎 detach 且服务未连接（instance == null，JVM 测试恒为 null）时，
        // 兜底自己挂的那份 handler 被摘（CaptureAndroidPlugin.onDetachedFromEngine）。
        Mockito.verify(messenger)
            .setMessageHandler(
                Mockito.eq(CaptureService.CONTROL_CHANNEL),
                Mockito.isNull(),
            )

        // 在场登记已清：reattach 变 no-op，不会往（已死的）messenger 挂兜底。
        Mockito.reset(messenger)
        CaptureAndroidPlugin.reattachControlFallback(messenger)
        Mockito.verifyNoInteractions(messenger)
    }
}

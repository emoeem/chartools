package dev.chartools.capture_android

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import dev.chartools.capture.CaptureService
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** CaptureAndroidPlugin */
class CaptureAndroidPlugin :
    FlutterPlugin,
    MethodCallHandler {
    // The MethodChannel that will the communication between Flutter and native Android
    //
    // This local reference serves to register the plugin with the Flutter Engine and unregister it
    // when the Flutter Engine is detached from the Activity
    private lateinit var channel: MethodChannel

    /** applicationContext：悬浮窗权限的查/跳在插件通道上做（见 onMethodCall）。 */
    private var appContext: Context? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        appContext = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "capture_android")
        channel.setMethodCallHandler(this)
        // 无障碍服务（CaptureService）的生命周期独立于引擎：谁后到，谁把
        // messenger 转交给对方。服务已连接则立刻挂通道，否则服务连接时再取。
        CaptureService.flutterMessenger = flutterPluginBinding.binaryMessenger
        CaptureService.instance?.attachEngineChannels(flutterPluginBinding.binaryMessenger)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result
    ) {
        when (call.method) {
            "getPlatformVersion" -> result.success("Android ${android.os.Build.VERSION.RELEASE}")
            // 悬浮窗开关需要先查（canDrawOverlays）再引导用户去系统设置页
            // （ACTION_MANAGE_OVERLAY_PERMISSION）。这两个动作读系统设置、跳系统
            // 页面，与采集服务是否启用无关，挂在本插件通道（capture_android）
            // 而不是 capture_android/control：control 由 CaptureService 注册，
            // 服务未启用时整条通道都不存在。
            "canDrawOverlays" -> {
                val ctx = appContext
                result.success(ctx != null && Settings.canDrawOverlays(ctx))
            }
            "openOverlaySettings" -> {
                val ctx = appContext
                val ok = if (ctx == null) {
                    false
                } else {
                    runCatching {
                        ctx.startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:${ctx.packageName}")
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        true
                    }.getOrDefault(false)
                }
                result.success(ok)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        appContext = null
        // 服务可能仍在跑（进程不被引擎托管），只是不再有引擎可回话；
        // CaptureService 持有的是注册时的局部引用，这里清掉静态指针即可。
        CaptureService.flutterMessenger = null
    }
}

package dev.chartools.capture_android

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import dev.chartools.capture.CaptureService
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** CaptureAndroidPlugin */
class CaptureAndroidPlugin :
    FlutterPlugin,
    MethodCallHandler {
    companion object {
        /**
         * fix(独立复核 2)：注册在场的插件实例。服务销毁时由 CaptureService.onDestroy
         * 经 [reattachControlFallback] 找回 [controlFallback] 重新挂回 control 通道；
         * 引擎 detach 时就地清空，避免悬引用。
         */
        @Volatile
        private var active: CaptureAndroidPlugin? = null

        /**
         * fix(独立复核 2)：「服务连接 → 服务死亡」转移的兜底回归。
         *
         * attachEngineChannels 注册服务级 handler 时按「后注册覆盖先注册」把
         * [controlFallback] 顶掉了；服务销毁若不摘，control 通道上活跃的仍是已销毁
         * 实例的 controlHandler（isRunning 恰好读静态 CapturePresence.live 回 false、
         * openAccessibilitySettings 走已销毁实例的 startActivity——runCatching 兜住
         * 回 false，本可用 appContext 成功的跳转被报失败；refill/manualOcr 等打到
         * 销毁实例上，观察为失败而非崩溃）。由 CaptureService.onDestroy 在
         * flutterMessenger 判空后调用：重新挂回兜底，「服务不在 = 兜底应答」的不变量
         * 对 连接→死亡 方向与 未连接→连接 方向一样成立。引擎已先 detach（关应用）
         * 时 flutterMessenger 已被清空，服务侧不会调到这里；重复挂接是幂等的。
         */
        fun reattachControlFallback(messenger: BinaryMessenger) {
            active?.let { plugin ->
                MethodChannel(messenger, CaptureService.CONTROL_CHANNEL)
                    .setMethodCallHandler(plugin.controlFallback)
            }
        }
    }

    // The MethodChannel that will the communication between Flutter and native Android
    //
    // This local reference serves to register the plugin with the Flutter Engine and unregister it
    // when the Flutter Engine is detached from the Activity
    private lateinit var channel: MethodChannel

    /** applicationContext：悬浮窗权限的查/跳在插件通道上做（见 onMethodCall）。 */
    private var appContext: Context? = null

    /**
     * fix(#11 P0-1)：capture_android/control 的插件级兜底 handler。
     *
     * control 通道原本只由 CaptureService（attachEngineChannels）注册，首次运行
     * （服务未启）时整条通道不存在：Dart 调 openAccessibilitySettings / isRunning
     * 得 MissingPluginException 且被 UI 静默吞（onboarding/capture 页的引导按钮
     * 没反应）。兜底在插件 attaching 时就挂上，服务未连接也能回答三个「服务
     * 无关」的方法（契约见 [CaptureService.CONFIGURE_METHOD] 注释）：
     * - configure：载荷经 [CaptureService.applyConfigureStatics] 落 ServiceConfig
     *   静态字段——服务连接时自动生效（onAccessibilityEvent 的白名单门、
     *   maybeCapture 的 ocrFallbackEnabled 直接读静态）；secure 属 overlay 实例态，
     *   兜底不落，由服务连接后的 requestConfigure → Dart 重放补齐（#7）。
     * - isRunning：回 false（服务未连接 = 没在跑）。
     * - openAccessibilitySettings：直接 startActivity 跳系统无障碍设置页。
     * 其余方法一律 notImplemented（refill/manualOcr/showSuggestions 等都要服务
     * 实例，兜底没有）。服务连接后 attachEngineChannels 注册的服务级 handler
     * （handleControl）在同一通道名上**后注册覆盖先注册**，整体接管——优先级
     * 与注册顺序一致，服务逻辑零改动。
     */
    private val controlFallback = MethodCallHandler { call, result ->
        when (call.method) {
            CaptureService.CONFIGURE_METHOD -> {
                CaptureService.applyConfigureStatics(call)
                result.success(true)
            }
            CaptureService.IS_RUNNING_METHOD -> result.success(false)
            CaptureService.OPEN_ACCESSIBILITY_SETTINGS_METHOD -> {
                val ctx = appContext
                val ok = if (ctx == null) {
                    false
                } else {
                    runCatching {
                        ctx.startActivity(
                            Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        true
                    }.getOrDefault(false)
                }
                result.success(ok)
            }
            else -> result.notImplemented()
        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        appContext = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "capture_android")
        channel.setMethodCallHandler(this)
        // fix(独立复核 2)：登记在场实例，供服务销毁时经 reattachControlFallback
        // 找回兜底 handler（见 companion 的注释）。
        active = this
        // fix(#11 P0-1)：兜底先挂、服务级后挂——顺序即优先级。引擎对同一通道
        // 名后注册的 handler 覆盖先注册的：服务已连接时下面的
        // attachEngineChannels 立刻用服务级 handler（handleControl）覆盖兜底；
        // 服务未连接则兜底留着，等 onServiceConnected → attachEngineChannels 接管；
        // 服务销毁时由 onDestroy 反向把兜底挂回来（detachEngineChannels +
        // reattachControlFallback）——「服务不在 = 兜底应答」双向成立。
        // 两次注册都在主线程同步完成，之间不会有通道消息插进来。
        MethodChannel(flutterPluginBinding.binaryMessenger, CaptureService.CONTROL_CHANNEL)
            .setMethodCallHandler(controlFallback)
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
            // 而不是 capture_android/control：fix(#11 P0-1) 后 control 有了插件级
            // 兜底，但它只接 configure/isRunning/openAccessibilitySettings 三个
            // 方法（其余 notImplemented），悬浮窗权限的查/跳继续走本通道。
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
            // fix(#11 P0-3)：通知权限（POST_NOTIFICATIONS）的查/求。Android 13+
            // 起 POST_NOTIFICATIONS 是运行时授权：未授予时 KeepAliveService 的
            // 前台通知（含「唤出助手/重新生成」动作按钮）被系统整条隐藏——服务
            // 照跑，通知不可见。13 以下没有运行时授权，areNotificationsEnabled()
            // 恒回 true，两个分支无需按 SDK 分叉。挂本插件通道（capture_android，
            // 引擎 attach 即注册），与 canDrawOverlays/openOverlaySettings 同址：
            // 读系统设置、跳系统页面，与采集服务是否连接无关。
            "canRequestNotifications" -> {
                // 返回「通知当前是否已开启」（通道不可用时 false，Dart 侧按
                // 「未知」处理）。
                val ctx = appContext
                result.success(
                    ctx != null &&
                        ctx.getSystemService(NotificationManager::class.java)
                            .areNotificationsEnabled()
                )
            }
            "requestNotifications" -> {
                // 返回值 = 调用时刻通知是否已开启；未开启时跳系统「应用通知
                // 设置」页（ACTION_APP_NOTIFICATION_SETTINGS + EXTRA_APP_PACKAGE）。
                // 不弹 13+ 运行时对话框：一是不需要 Activity 引用（本插件只实现
                // FlutterPlugin），二是用户在系统对话框勾过「不再询问」后对话框
                // 静默不弹，设置页是唯一稳妥入口——与 openOverlaySettings 的
                // 引导模式一致。授权回来后由采集页 lifecycle resumed 刷新重查。
                val ctx = appContext
                val enabled = ctx != null &&
                    ctx.getSystemService(NotificationManager::class.java)
                        .areNotificationsEnabled()
                if (!enabled) {
                    runCatching {
                        ctx?.startActivity(
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, ctx.packageName)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                    }
                }
                result.success(enabled)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        // fix(#11 P0-1)：只清兜底自己挂的那份 handler。引擎里 handler 按
        // 「messenger + 通道名」登记，用同名 MethodChannel 置 null 会连服务级
        // handler 一起清掉——服务已连接（instance != null）时注册方是
        // attachEngineChannels 的 handleControl，不能动（与下面不清服务侧指针
        // 同一取舍：服务可能仍在跑，只是不再有引擎可回话）。服务未连接时兜底
        // 就是当前注册者，随引擎一起摘掉，避免悬空的 appContext 引用。
        if (CaptureService.instance == null) {
            MethodChannel(binding.binaryMessenger, CaptureService.CONTROL_CHANNEL)
                .setMethodCallHandler(null)
        }
        appContext = null
        // fix(独立复核 2)：只清自己登记的那份在场引用（防后来的实例被误清）。
        if (active === this) {
            active = null
        }
        // 服务可能仍在跑（进程不被引擎托管），只是不再有引擎可回话；
        // CaptureService 持有的是注册时的局部引用，这里清掉静态指针即可。
        CaptureService.flutterMessenger = null
    }
}

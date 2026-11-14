package dev.chartools.capture.bridge

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import dev.chartools.capture.Trace

/**
 * 跨进程桥的备用通道：Provider 拿不到的机型上，注入代码显式绑这条 Service。
 *
 * 两条通道共用 [BridgeDispatch]，所以门禁和单调版本规则只写了一份 —— 换通道
 * 不会换语义。备用通道存在的唯一理由是 OPPO / Android 16 上出现过
 * `acquireUnstableContentProviderClient` 直接返回 null 的情况（yanwai 的教训）。
 *
 * 注：目标 App 进程里的模块因为包可见性绑不上本服务（`bindService` 返回 false，
 * legacy 实测）—— 本通道真正可用的调用方与 [BridgeProvider] 相同：不受可见性
 * 限制的本 App 自己与 root 调试对照。
 */
class BridgeConnectionService : Service() {

    private val binder = object : IBridgeConnection.Stub() {
        override fun call(method: String?, arg: String?, extras: Bundle?): Bundle? {
            return BridgeDispatch.handle(applicationContext, Binder.getCallingUid(), method, arg, extras)
        }
    }

    override fun onBind(intent: Intent?): IBinder {
        Trace.log("bridge service bound")
        return binder
    }
}

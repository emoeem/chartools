package com.jev.probe.bridge

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import com.jev.probe.core.Trace

/**
 * 跨进程桥的备用通道：Provider 拿不到的机型上，注入代码显式绑这条 Service。
 *
 * 两条通道共用 [BridgeDispatch]，所以门禁和单调版本规则只写了一份 —— 换通道
 * 不会换语义。备用通道存在的唯一理由是 OPPO / Android 16 上出现过
 * `acquireUnstableContentProviderClient` 直接返回 null 的情况（yanwai 的教训）。
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

package com.jev.probe.bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Process

/**
 * 桥的接收端 —— **这是真机上唯一走得通的方向**（见 [BridgeContract.ACTION]）。
 *
 * 目标 App 进程里的模块发一条显式广播过来，这里收下、判人、交给
 * [BridgeDispatch] 处理，并把答复写进 `setResultExtras`（模块用
 * `sendOrderedBroadcast` 等这个答复）。
 *
 * 为什么 Receiver 不是 Provider：模块用的是目标 App 的 UID 和 Context，包可见
 * 性把 `com.jev.probe` 对它整个挡掉了（Provider 取不到、Service 绑不上、
 * `getPackageInfo` 抛异常）。广播的投递由系统完成，不需要发送方解析出接收方。
 *
 * `exported=true` 且没有 `android:permission`：说话的人不可能持有本 App 的
 * 签名权限。安全靠 [BridgeSender] 在 `onReceive` 里按发送方 UID 判，判不出来
 * 就拒。
 */
class BridgeReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != BridgeContract.ACTION) return
        val extras = intent.extras
        // 拒收时 BridgeDispatch 返回 {accepted=false, reason=...}，**不抛异常**：
        // onReceive 由系统在主线程调用，在这里抛就是本 App 自己崩。
        val reply = BridgeDispatch.handle(
            context = context.applicationContext ?: context,
            callerUid = senderUid() ?: -1,
            method = null,
            arg = null,
            extras = extras,
        )
        // 只有有序广播才有答复；普通广播上这次调用没有意义（也不报错）。
        runCatching { setResultExtras(reply) }
    }

    /**
     * 系统告诉我们的发送方 uid。Android 14 起才有这个 API；更老的系统上返回
     * null —— 认不出人就拒收（fail-closed），代价是那些设备上只有 L0 能力栈。
     */
    private fun senderUid(): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return null
        val uid = runCatching { sentFromUidCompat() }.getOrNull() ?: return null
        return if (uid == Process.INVALID_UID) null else uid
    }

    /** 只给上面的版本判断用；单独抽出来免得在两个 Build 分支里各写一次调用。 */
    @androidx.annotation.RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun sentFromUidCompat(): Int = getSentFromUid()
}

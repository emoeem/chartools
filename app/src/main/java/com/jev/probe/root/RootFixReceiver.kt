package com.jev.probe.root

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.jev.probe.core.Prefs
import com.jev.probe.core.Trace

/**
 * 开机 / **覆盖安装**之后自己把权限修回来。覆盖安装那一条（`MY_PACKAGE_REPLACED`）
 * 才是天天用的那条：每次重装 APK，系统都会把本 App 的无障碍服务关掉，用户看到
 * 的就是"又要去点一次无障碍"。
 *
 * 只有 [Prefs.rootAuto] 打开时才动手 —— 默认关，所以不装 root、或不想要这个行为
 * 的用户，这个 receiver 收到广播后什么都不做就返回。
 *
 * 广播是**必须**的落地方式，不是随手选的：本 App 在开机时根本不会自己启动，
 * 没有别的时机能跑到这段代码。
 */
class RootFixReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            QUICKBOOT -> Unit
            else -> return
        }
        val app = context.applicationContext
        val prefs = Prefs(app)
        if (!prefs.rootAuto) return

        // 自愈里有 su，必须离开主线程；goAsync 让系统在跑完前不要回收进程。
        val pending = goAsync()
        Thread {
            try {
                RootFix.apply(app, Prefs(app))
            } catch (t: Throwable) {
                Trace.log("root fix boot fail ${t.javaClass.simpleName}: ${t.message}")
            } finally {
                runCatching { pending.finish() }
            }
        }.start()
    }

    private companion object {
        /** ColorOS / OPPO 的快捷开机广播，名字不在 Intent 常量里。 */
        const val QUICKBOOT = "android.intent.action.QUICKBOOT_POWERON"
    }
}

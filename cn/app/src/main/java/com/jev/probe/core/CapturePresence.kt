package com.jev.probe.core

/**
 * 本进程里有没有一个**活着的**无障碍采集服务实例。和 `enabled_accessibility_services`
 * 那一格是两件事：那一格只说"用户在设置里开着"，这里说的是"真的在跑"。
 *
 * 无障碍服务和本 App 的界面在同一个进程（清单里没写 `android:process`），
 * 所以这个信号就是主页和"一键修复"能拿到的最准的信号 —— 进程被杀后默认
 * false 也对（服务跟着死了）。
 *
 * 放在 core 是为了让 root（一键修复）不必 import capture：服务写入、工具只读。
 */
object CapturePresence {
    @Volatile
    var live: Boolean = false
        internal set
}

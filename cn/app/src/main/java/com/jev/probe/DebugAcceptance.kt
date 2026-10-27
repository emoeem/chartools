package com.jev.probe

import android.content.Intent

/**
 * 调试验收钩子（试写 tone_check / 一键修复回放 root_fix）的挂载点。
 *
 * [hooks] 只在 debug 变体里有值——`src/debug` 的 [DebugHooksInit]（一个
 * ContentProvider，系统在任何 Activity 之前初始化）注册真实现，而那个
 * provider 和它引用的、会发真实模型请求的代码都只编进 debug 包。release
 * 里 [hooks] 恒为 null，两个入口是空操作。触发命令见 debug 源集的注释。
 */
object DebugAcceptance {

    interface Hooks {
        fun onMainActivityCreate(activity: MainActivity, intent: Intent?)
        fun onSettingsCreate(activity: SettingsActivity)
    }

    @Volatile
    var hooks: Hooks? = null

    fun onMainActivityCreate(activity: MainActivity, intent: Intent?) {
        hooks?.onMainActivityCreate(activity, intent)
    }

    fun onSettingsCreate(activity: SettingsActivity) {
        hooks?.onSettingsCreate(activity)
    }
}

package com.jev.probe.bridge

/**
 * 允许被注入的目标 App 清单 —— 运行期判定的那一份。
 *
 * 必须与 `app/src/main/res/values/arrays.xml` 的 `xposed_scope` 保持一致：
 * 那边是给框架看的「允许范围」，这边是模块入口自己再判一次的门槛。框架的
 * 作用域可能被用户在框架设置里放宽，所以模块不能只信框架。
 *
 * 纯逻辑、不 import 任何 android 或 xposed 的东西，所以 JVM 单测能直接跑，
 * 也能被本 App 自己的进程安全加载（模块入口类则不能，见 JevHookEntry）。
 *
 * 试点只有 Telegram：它的无障碍适配器已经存在，S3 的验收就是「同一聊天页
 * L0 与 L1 逐条对拍」，有一个已经跑通的 L0 才有对拍对象。微信的 L0 最弱
 * （8.0.78 给无障碍的是空树），但它的注入同时也是账号风险最高的一条。
 */
object HookTargets {

    /** 框架被允许加载本模块的包名。 */
    val SCOPED: List<String> = listOf("org.telegram.messenger")

    fun isScoped(pkg: String?): Boolean = pkg != null && pkg in SCOPED

    /**
     * 主进程才算。
     *
     * 目标 App 几乎都有 `:push` / `:service` 之类的子进程，它们的包名和主进程
     * 相同、只有进程名带后缀。只判包名会把模块注进每一个子进程：日志里出现
     * 多份「已加载」，而真正持有 UI 的只有主进程那一份。yanwai 的写法是同时
     * 判 `packageName` 与 `processName`，这里照搬。
     */
    fun isMainProcess(pkg: String?, process: String?): Boolean =
        pkg != null && process != null && pkg == process

    /** 入口处唯一的门槛。返回 false 就立刻 return，绝不做任何别的事。 */
    fun shouldLoad(pkg: String?, process: String?): Boolean =
        isScoped(pkg) && isMainProcess(pkg, process)
}

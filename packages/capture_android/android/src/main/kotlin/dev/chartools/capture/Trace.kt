package dev.chartools.capture

/**
 * 旧仓库 `com.jev.probe.core.Trace` 的占位替身：落盘 trace 文件依赖 App 自己的
 * prefs/生命周期编排，插件里没有对应宿主，这里只保留调用点形状 ——
 * 所有 `Trace.log(...)` 原样可见，走 logcat。
 */
object Trace {
    fun init(ctx: android.content.Context) {}

    fun log(msg: String) {
        android.util.Log.d("CAPTURE", msg)
    }
}

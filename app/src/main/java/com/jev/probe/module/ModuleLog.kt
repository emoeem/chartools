package com.jev.probe.module

/**
 * 注入层的日志出口。
 *
 * 只能走框架日志（`XposedBridge.log`）：这段代码跑在**目标 App 的进程**里，
 * `com.jev.probe.core.Trace` 会写到宿主的 filesDir —— 往别人的私有目录里写
 * 文件是 CLAUDE.md 明令禁止的，而且目标 App 卸载时会连带留下垃圾。
 *
 * 只记包名、进程、开关状态、拒收原因和异常类名。**永远不记消息正文**，也不
 * 记聊天标题。诊断用的有界环形缓冲留在内存里，供 S3 的「模块状态」页读取。
 */
internal object ModuleLog {

    /** 框架日志里的检索标记。验收就是 grep 这个词。 */
    const val TAG = "JEVINJECT"

    private const val RING = 64

    /** 由 [JevHookEntry] 装上；装不上（框架不在）就退化成纯内存环形缓冲。 */
    @Volatile
    var frameworkSink: ((String) -> Unit)? = null

    private val lock = Any()
    private val ring = ArrayDeque<String>(RING)

    fun log(prefix: String, msg: String) {
        val line = "$TAG $prefix $msg"
        synchronized(lock) {
            if (ring.size >= RING) ring.removeFirst()
            ring.addLast(line)
        }
        val sink = frameworkSink
        if (sink != null) {
            // 往框架里打日志不能反过来把宿主弄崩。
            runCatching { sink(line) }
        }
    }

    fun log(msg: String) = log("info", msg)

    /**
     * 异常只留类名、message 与**最上面几帧的类名#方法名**：栈里可能带宿主的类名甚至路径，
     * 所以不整条打；但要定位「是宿主哪个方法把注入层弄崩的」，没有帧就只能靠猜
     * （真机上 `tg.tick: NullPointerException: null` 就是这么卡住的）。帧里只有
     * `类名#方法名`，不含文件路径、不含任何聊天内容。
     */
    fun fail(where: String, t: Throwable) =
        log("fail", "$where: ${t.javaClass.name}: ${t.message} ${frames(t)}")

    private fun frames(t: Throwable): String = runCatching {
        t.stackTrace.take(8).joinToString("<-") { "${it.className}#${it.methodName}" }
    }.getOrDefault("frames=?")

    /** 诊断快照（内存副本，调用方自己决定怎么用）。 */
    fun tail(): List<String> = synchronized(lock) { ring.toList() }
}

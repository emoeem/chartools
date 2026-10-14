package com.jev.probe.root

import java.util.concurrent.TimeUnit

internal data class ShellResult(val code: Int, val output: String) {
    val ok: Boolean get() = code == 0
}

/**
 * 用 `su` 跑一条命令。目标机是 KernelSU（`su -c id` → `context=u:r:ksu:s0`，
 * 二进制在 `/system/bin/su`）；Magisk / APatch 的 su 形状一样（`-c` + 一条命令），
 * 所以这里只认 `su` 这一个入口，不猜路径。
 *
 * 三条硬性要求，都是踩过才知道的：
 *  - **必须在后台线程调用**：第一次 `su` 会弹 KernelSU 的授权框，人不在跟前就是
 *    一直等，在主线程上等就是 ANR。
 *  - **必须有超时并且杀掉进程**：`waitFor` 拿到 false 之后不 `destroyForcibly`，
 *    管道那头会留下一个永远不会退出的 su。
 *  - **stderr 合并进 stdout**：KernelSU 拒绝时把 `permission denied` 写在 stderr，
 *    而它正是"为什么没成功"的唯一线索。输出统一从合并流里读，避免两个管道互相
 *    塞满造成死锁（命令输出都是几十字节，一次读完不会阻塞）。
 */
internal object RootShell {

    /** 首次授权要等人点弹窗，给得宽一点；后续命令用 [FAST_MS]。 */
    const val FIRST_MS = 20_000L
    const val FAST_MS = 10_000L

    fun run(argv: List<String>, timeoutMs: Long): ShellResult {
        val proc = try {
            ProcessBuilder(argv).redirectErrorStream(true).start()
        } catch (t: Throwable) {
            return ShellResult(-1, t.javaClass.simpleName + ": " + (t.message ?: ""))
        }
        return try {
            val done = proc.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
            val text = runCatching { proc.inputStream.bufferedReader().readText() }.getOrDefault("")
            if (!done) {
                proc.destroyForcibly()
                ShellResult(-1, text + "\n（${timeoutMs / 1000}s 没结束，已杀掉：su 可能在等授权弹窗）")
            } else {
                ShellResult(proc.exitValue(), text.trim())
            }
        } catch (t: Throwable) {
            runCatching { proc.destroyForcibly() }
            ShellResult(-1, t.javaClass.simpleName + ": " + (t.message ?: ""))
        } finally {
            runCatching { proc.inputStream.close() }
            runCatching { proc.outputStream.close() }
            runCatching { proc.errorStream.close() }
        }
    }

    fun su(command: String, timeoutMs: Long = FAST_MS): ShellResult =
        run(listOf("su", "-c", command), timeoutMs)

    /** `su -c id` 的原文；认框架只认其中的 SELinux 域（见 [RootProbe.flavorOf]）。 */
    fun id(timeoutMs: Long = FIRST_MS): String = su("id", timeoutMs).output
}

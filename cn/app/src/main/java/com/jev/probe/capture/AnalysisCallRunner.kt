package com.jev.probe.capture

import com.jev.probe.jev.HttpScope
import java.io.IOException
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** Owns per-call HTTP cancellation and timeout handling for analysis requests. */
internal class AnalysisCallRunner : AutoCloseable {

    private val executor = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "jev-http").apply { isDaemon = true }
    }
    private val activeScopes = ConcurrentHashMap.newKeySet<HttpScope>()

    /**
     * Each call owns a scope so a timed-out request closes its socket before
     * interrupting the worker; interrupting alone cannot stop a blocked read.
     */
    fun <T> withHardTimeout(
        timeoutMs: Long,
        description: String,
        body: (HttpScope) -> T
    ): T {
        val scope = HttpScope()
        activeScopes.add(scope)
        val future: Future<T> = try {
            executor.submit(Callable { body(scope) })
        } catch (e: RejectedExecutionException) {
            activeScopes.remove(scope)
            scope.cancel()
            throw e
        }

        return try {
            future.get(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (e: TimeoutException) {
            scope.cancel()
            future.cancel(true)
            throw IOException("$description 超时（${timeoutMs / 1000}秒），请检查网络后重试")
        } catch (e: InterruptedException) {
            scope.cancel()
            future.cancel(true)
            Thread.currentThread().interrupt()
            throw e
        } finally {
            activeScopes.remove(scope)
        }
    }

    fun cancelActiveCalls() {
        activeScopes.forEach { it.cancel() }
        activeScopes.clear()
    }

    override fun close() {
        cancelActiveCalls()
        executor.shutdownNow()
    }
}

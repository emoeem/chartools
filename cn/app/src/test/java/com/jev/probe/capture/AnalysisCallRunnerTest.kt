package com.jev.probe.capture

import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AnalysisCallRunnerTest {

    @Test
    fun timeoutCancelsHttpScopeAndReturnsRetryableError() {
        val runner = AnalysisCallRunner()
        val requestStarted = CountDownLatch(1)
        val socketCancelled = AtomicBoolean(false)

        try {
            val error = try {
                runner.withHardTimeout(1_000, "判断接口") { scope ->
                    scope.attach { socketCancelled.set(true) }
                    requestStarted.countDown()
                    CountDownLatch(1).await()
                    "late response"
                }
                null
            } catch (e: IOException) {
                e
            }

            assertTrue(requestStarted.await(1, TimeUnit.SECONDS))
            assertTrue(error is IOException)
            assertEquals("判断接口 超时（1秒），请检查网络后重试", error?.message)
            assertTrue("timeout should cancel the HTTP scope", socketCancelled.get())
        } finally {
            runner.close()
        }
    }

    @Test
    fun interruptingWaiterCancelsHttpScopeAndRequest() {
        val runner = AnalysisCallRunner()
        val requestStarted = CountDownLatch(1)
        val socketCancelled = AtomicBoolean(false)
        val thrown = AtomicReference<Throwable?>()
        val waiter = Thread {
            try {
                runner.withHardTimeout(30_000, "判断接口") { scope ->
                    scope.attach { socketCancelled.set(true) }
                    requestStarted.countDown()
                    CountDownLatch(1).await()
                    "late response"
                }
            } catch (e: Throwable) {
                thrown.set(e)
            }
        }

        try {
            waiter.start()
            assertTrue(requestStarted.await(1, TimeUnit.SECONDS))
            waiter.interrupt()
            waiter.join(2_000)

            assertTrue("interrupted waiter should stop promptly", !waiter.isAlive)
            assertTrue(thrown.get() is InterruptedException)
            assertTrue("interruption should cancel the HTTP scope", socketCancelled.get())
        } finally {
            runner.close()
            waiter.interrupt()
        }
    }
}

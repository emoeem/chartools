package com.jev.probe.jev

import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * The retry / status / cancel rules of [HttpJson] against a real server.
 *
 * These are the rules that decide whether a failed analysis is retried, reported
 * or abandoned, and they used to be untestable: HttpURLConnection against no
 * server can only produce a transport error. MockWebServer answers with any
 * status, any body and any delay, so each branch is asserted for real.
 */
class HttpJsonTest {

    private lateinit var server: MockWebServer

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        HttpJson.retryBackoffMs = 1L // collapse the backoff: 3 attempts in ~3 ms
    }

    @After
    fun tearDown() {
        HttpJson.retryBackoffMs = 500L
        // HttpJson restores the interrupt flag when it reports a cancelled call
        // (correct in production, where it runs on a pool thread). The tests that
        // cancel on the test thread itself must not hand that flag to MockWebServer.
        Thread.interrupted()
        server.shutdown()
    }

    private fun url() = server.url("/v1/decisions").toString()

    private fun body() = JSONObject().put("model", "m").put("state", JSONObject())

    private fun post(scope: HttpScope? = null): JSONObject =
        HttpJson.post(url(), "test-key", body(), Route.JUDGE, mapOf("X-Test" to "1"), scope)

    @Test
    fun aSuccessfulResponseComesBackWithItsHeadersAndUtf8Body() {
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"answers":{"danger_level":{"noul":0.2}}}"""))

        val resp = post()

        assertEquals(0.2, resp.getJSONObject("answers").getJSONObject("danger_level").getDouble("noul"), 1e-9)
        val sent = server.takeRequest()
        assertEquals("Bearer test-key", sent.getHeader("Authorization"))
        assertEquals("1", sent.getHeader("X-Test"))
        assertTrue(sent.getHeader("Content-Type")!!.startsWith("application/json"))
        val sentBody = JSONObject(sent.body.readUtf8())
        assertEquals("m", sentBody.getString("model"))
        assertNotNull(sentBody.optJSONObject("state"))
    }

    @Test
    fun aBusyServerIsRetriedAndTheSecondAttemptWins() {
        server.enqueue(MockResponse().setResponseCode(429).setBody("busy"))
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"answers":{}}"""))

        val resp = post()

        assertNotNull(resp.optJSONObject("answers"))
        assertEquals(2, server.requestCount)
    }

    @Test
    fun aRejectedKeyIsNotRetriedAndReportsTheRealStatus() {
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":{"message":"bad key"}}"""))

        val e = failure { post() }

        assertTrue(e is ApiException)
        val api = e as ApiException
        assertEquals(401, api.status)
        assertEquals(Route.JUDGE, api.route)
        // The user has to see WHY, not a generic "request failed".
        assertTrue(api.message!!, api.message!!.contains("判断接口 HTTP 401"))
        assertTrue(api.message!!, api.message!!.contains("bad key"))
        assertEquals(1, server.requestCount)
    }

    @Test
    fun aServerErrorIsRetriedThreeTimesAndThenReported() {
        repeat(3) { server.enqueue(MockResponse().setResponseCode(500).setBody("boom")) }

        val e = failure { post() }

        assertEquals(500, (e as ApiException).status)
        assertEquals(3, server.requestCount)
    }

    /** A 200 with nothing in it is a bad gateway masquerading as success. */
    @Test
    fun aBlank200BodyIsAnErrorNotAnEmptyAnswer() {
        repeat(3) { server.enqueue(MockResponse().setResponseCode(200).setBody("")) }

        val e = failure { post() }

        assertTrue((e as ApiException).message!!, e.message!!.contains("响应体为空"))
        assertEquals(3, server.requestCount)
    }

    @Test
    fun aGatewayStatusBecomesAnApiErrorNotAnException() {
        // A proxy answering with HTML must still surface as a status, not crash
        // the round with a JSON parse error.
        server.enqueue(MockResponse().setResponseCode(502).setBody("<html>bad gateway</html>"))
        repeat(2) { server.enqueue(MockResponse().setResponseCode(502).setBody("<html>bad gateway</html>")) }

        val e = failure { post() }

        assertEquals(502, (e as ApiException).status)
    }

    @Test
    fun cancellingTheScopeAbortsARequestThatIsStillWaiting() {
        // The server holds the response until we let go, so the client is parked
        // in a socket read — exactly the state that Future.cancel(true) cannot
        // break. The round must not have to wait out the delay.
        val held = CountDownLatch(1)
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                held.await(10, TimeUnit.SECONDS)
                return MockResponse().setResponseCode(200).setBody("{}")
            }
        }
        val scope = HttpScope()
        val thrown = AtomicReference<Throwable?>()
        val t = Thread { runCatching { post(scope) }.onFailure { thrown.set(it) } }
        val started = System.currentTimeMillis()
        try {
            t.start()
            awaitRequestCount(1)
            scope.cancel()
            t.join(5_000)
            val elapsed = System.currentTimeMillis() - started
            assertTrue("call should be cut, took ${elapsed}ms", elapsed < 3_000)
            assertTrue(
                "expected InterruptedException, got ${thrown.get()}",
                thrown.get() is InterruptedException
            )
        } finally {
            held.countDown()
            t.join(2_000)
        }
    }

    @Test
    fun aCallAttachedAfterTheCancelIsCancelledToo() {
        // Sticky cancellation: a straggler that starts after the round was
        // dropped must not be able to run to completion.
        server.enqueue(MockResponse().setResponseCode(200).setBody("{}"))
        val scope = HttpScope()
        scope.cancel()

        val e = failure { post(scope) }

        assertTrue(e is InterruptedException)
        assertEquals(0, server.requestCount)
    }

    // ------------------------------------------------------------------ SSE

    @Test
    fun aStreamHandsEachPayloadToTheCallerAndReturnsThemJoined() {
        server.enqueue(
            MockResponse()
                .setHeader("Content-Type", "text/event-stream")
                .setBody(
                    "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\n" +
                        ": keep-alive\n\n" +
                        "data: {\"choices\":[{\"delta\":{\"content\":\"呀\"}}]}\n\n" +
                        "data: [DONE]\n\n"
                )
        )
        val seen = ArrayList<String>()

        val raw = HttpJson.stream(url(), "test-key", body(), Route.REPLY) { seen.add(it) }

        assertEquals(2, seen.size)
        assertTrue(seen[0].contains("你好"))
        assertEquals(2, Regex("\"content\"").findAll(raw).count())
        val sent = server.takeRequest()
        assertEquals("text/event-stream", sent.getHeader("Accept"))
        assertEquals("Bearer test-key", sent.getHeader("Authorization"))
    }

    @Test
    fun aStreamRejectedByTheServerReportsItsStatus() {
        server.enqueue(
            MockResponse().setResponseCode(401)
                .setHeader("Content-Type", "text/event-stream")
                .setBody("bad key")
        )

        val e = failure { HttpJson.stream(url(), "test-key", body(), Route.REPLY) { } }

        assertEquals(401, (e as ApiException).status)
    }

    @Test
    fun cancellingTheScopeAbortsAStreamThatIsStillWaiting() {
        // Same guarantee as the buffered path, but the connection is held open for
        // the length of the answer: a dropped round must cut the stream, not wait
        // for the server to finish talking.
        val held = CountDownLatch(1)
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                held.await(10, TimeUnit.SECONDS)
                return MockResponse()
                    .setHeader("Content-Type", "text/event-stream")
                    .setBody("data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\ndata: [DONE]\n\n")
            }
        }
        val scope = HttpScope()
        val thrown = AtomicReference<Throwable?>()
        val t = Thread {
            runCatching { HttpJson.stream(url(), "test-key", body(), Route.REPLY, emptyMap(), scope) { } }
                .onFailure { thrown.set(it) }
        }
        val started = System.currentTimeMillis()
        try {
            t.start()
            awaitRequestCount(1)
            scope.cancel()
            t.join(5_000)
            val elapsed = System.currentTimeMillis() - started
            assertTrue("stream should be cut, took ${elapsed}ms", elapsed < 3_000)
            assertTrue(
                "expected InterruptedException, got ${thrown.get()}",
                thrown.get() is InterruptedException
            )
        } finally {
            held.countDown()
            t.join(2_000)
        }
    }

    private fun awaitRequestCount(n: Int) {
        val deadline = System.currentTimeMillis() + 5_000
        while (server.requestCount < n && System.currentTimeMillis() < deadline) Thread.sleep(10)
    }

    private fun failure(block: () -> Unit): Throwable {
        try {
            block()
        } catch (t: Throwable) {
            return t
        }
        throw AssertionError("expected a failure")
    }
}

package com.jev.probe.jev

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.sse.EventSource
import okhttp3.sse.EventSourceListener
import okhttp3.sse.EventSources
import org.json.JSONObject
import java.io.InterruptedIOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Which of the three API routes a failure came from. Used to build error text
 * the user can act on ("判断接口 HTTP 401：…" vs "回复接口 …").
 */
object Route {
    const val JUDGE = "判断接口"
    const val REPLY = "回复接口"
    const val VISION = "视觉接口"
}

/**
 * Carries the route, the HTTP status (null = transport failure) and the first
 * 120 chars of the response body so the settings page can show the real reason.
 */
class ApiException(
    val route: String,
    val status: Int?,
    val snippet: String
) : RuntimeException(buildMessage(route, status, snippet)) {

    companion object {
        fun buildMessage(route: String, status: Int?, snippet: String): String =
            if (status != null) "$route HTTP $status：${snippet.take(120)}"
            else "$route 请求失败：${snippet.take(120)}"
    }
}

/**
 * Shared POST-JSON helper: UTF-8 body, exponential backoff on 429/529, no retry
 * on other 4xx, and every failure normalized to [ApiException]. Keys are passed
 * in per call and never logged.
 *
 * Runs on OkHttp rather than HttpURLConnection so that an abandoned request can
 * be *cut* rather than merely interrupted (see [HttpScope]): HttpURLConnection
 * bounds connect/read per attempt but not DNS resolution, so one wedged request
 * used to hold its round's thread for good.
 */
object HttpJson {

    private const val MAX_ATTEMPTS = 3
    private const val CONNECT_TIMEOUT_S = 15L
    private const val READ_TIMEOUT_S = 40L

    private val JSON_TYPE = "application/json; charset=utf-8".toMediaType()

    /**
     * One client for the whole process: its connection pool, its thread pool and
     * its route table are the expensive parts, and every request here goes to the
     * same handful of hosts.
     */
    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(CONNECT_TIMEOUT_S, TimeUnit.SECONDS)
            .readTimeout(READ_TIMEOUT_S, TimeUnit.SECONDS)
            .writeTimeout(20, TimeUnit.SECONDS)
            // No overall call deadline: a reasoning model can legitimately think
            // for a while. The round-level watchdog owns the ceiling instead.
            .callTimeout(0, TimeUnit.MILLISECONDS)
            .build()
    }

    /**
     * Backoff between attempts. A var so a unit test can collapse the three
     * attempts from ~3 s of sleeping to ~3 ms; production never writes it.
     */
    @Volatile
    var retryBackoffMs: Long = 500L

    /**
     * @param route one of [Route], used only for error text.
     * @param extraHeaders additional request headers (e.g. OpenRouter attribution).
     * @param scope when given, this call is registered there so [HttpScope.cancel]
     *        closes its socket.
     */
    fun post(
        url: String,
        key: String,
        body: JSONObject,
        route: String,
        extraHeaders: Map<String, String> = emptyMap(),
        scope: HttpScope? = null
    ): JSONObject {
        var attempt = 0
        var last: ApiException? = null
        while (attempt < MAX_ATTEMPTS) {
            if (isAborted(scope)) throw cancelled()
            try {
                return once(url, key, body, route, extraHeaders, scope)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                throw e
            } catch (e: ApiException) {
                // A dropped round is not a failure to retry.
                if (isAborted(scope)) throw cancelled()
                // Client errors are final — except 429 (rate limit) and 529
                // (overloaded), which are the two that mean "come back later".
                if (e.status != null && e.status in 400..499 && e.status != 429) throw e
                last = e
                attempt++
                if (attempt < MAX_ATTEMPTS) sleep(attempt)
            } catch (e: Exception) {
                if (isAborted(scope)) throw cancelled()
                last = ApiException(route, null, describe(e))
                attempt++
                if (attempt < MAX_ATTEMPTS) sleep(attempt)
            }
        }
        throw last ?: ApiException(route, null, "请求失败")
    }

    /**
     * The one authenticated POST shape every route uses: UTF-8 JSON body, bearer
     * key, caller extras. Shared with the SSE path so a streaming request cannot
     * drift from the non-streaming one.
     */
    internal fun jsonRequest(
        url: String,
        key: String,
        body: JSONObject,
        extraHeaders: Map<String, String> = emptyMap()
    ): Request = Request.Builder()
        .url(url)
        .header("Authorization", "Bearer $key")
        .header("Content-Type", "application/json; charset=utf-8")
        .apply { extraHeaders.forEach { (k, v) -> header(k, v) } }
        .post(body.toString().toByteArray(Charsets.UTF_8).toRequestBody(JSON_TYPE))
        .build()

    /** The shared client: the SSE path must reuse this pool and its timeouts. */
    internal fun okHttpClient(): OkHttpClient = client

    /**
     * One Server-Sent-Events round trip (opt-in streaming, off by default).
     *
     * Blocks the calling thread until the server closes the stream, fails, or
     * [scope] is cancelled — every caller already runs on a worker. Returns the
     * concatenated `data:` payloads; [onData] sees each payload as it lands, which
     * is the whole point (the card can show text while the model is still writing).
     *
     * Deliberately NOT retried: a half-delivered stream that restarts would show
     * the same sentence twice. The caller falls back to the buffered path instead.
     */
    fun stream(
        url: String,
        key: String,
        body: JSONObject,
        route: String,
        extraHeaders: Map<String, String> = emptyMap(),
        scope: HttpScope? = null,
        onData: (String) -> Unit
    ): String {
        val request = jsonRequest(url, key, body, extraHeaders)
            .newBuilder()
            .header("Accept", "text/event-stream")
            .build()
        // A stream is long-lived by definition; the 40 s read timeout meant for
        // buffered replies would cut it off mid-sentence.
        val sseClient = client.newBuilder().readTimeout(0, TimeUnit.MILLISECONDS).build()
        val latch = CountDownLatch(1)
        val sb = StringBuilder()
        var done = false
        var failure: Throwable? = null
        var failedResponse: Response? = null

        val listener = object : EventSourceListener() {
            override fun onEvent(eventSource: EventSource, id: String?, type: String?, data: String) {
                if (data.trim() == "[DONE]") {
                    // Some servers never close the connection after [DONE]; waiting
                    // for onClosed there would hang until the round's watchdog.
                    done = true
                    latch.countDown()
                    return
                }
                sb.append(data).append('\n')
                onData(data)
            }

            override fun onClosed(eventSource: EventSource) {
                done = true
                latch.countDown()
            }

            override fun onFailure(eventSource: EventSource, t: Throwable?, response: Response?) {
                failure = t
                failedResponse = response
                latch.countDown()
            }
        }

        val source = EventSources.createFactory(sseClient).newEventSource(request, listener)
        // EventSource has no "am I cancelled" query, so remember it: the round was
        // dropped and the failure that follows is not a reason to retry or report.
        var cancelledByScope = false
        val unhook = { cancelledByScope = true; source.cancel() }
        scope?.attach(unhook)
        try {
            latch.await()
            if (cancelledByScope || isAborted(scope)) throw cancelled()
            failedResponse?.let { r ->
                val snippet = runCatching { r.body?.string().orEmpty() }.getOrDefault("")
                throw ApiException(route, r.code, snippet.ifBlank { "（响应体为空）" })
            }
            failure?.let { t ->
                if (t is java.io.IOException) throw ApiException(route, null, describe(t))
                throw t
            }
            return sb.toString()
        } catch (e: InterruptedException) {
            throw cancelled()
        } finally {
            scope?.detach(unhook)
            if (done) source.cancel()
        }
    }

    /** One attempt. Throws [ApiException] for every HTTP or transport outcome. */
    private fun once(
        url: String,
        key: String,
        body: JSONObject,
        route: String,
        extraHeaders: Map<String, String>,
        scope: HttpScope?
    ): JSONObject {
        val request = jsonRequest(url, key, body, extraHeaders)
        val call = client.newCall(request)
        val unhook = { call.cancel() }
        scope?.attach(unhook)
        try {
            call.execute().use { resp ->
                val code = resp.code
                if (code == 429 || code == 529) throw ApiException(route, code, "服务繁忙，已重试")
                // Branch on the status code FIRST: reading the body must never be
                // able to lose it. A truncated or empty error body still has to
                // surface as the real status, otherwise a 401 gets retried as a
                // transport failure.
                val text = resp.body?.string().orEmpty()
                if (code !in 200..299) {
                    val safeText = if (key.isBlank()) text else text.replace(key, "[key]")
                    throw ApiException(route, code, safeText.ifBlank { "（响应体为空）" })
                }
                if (text.isBlank()) throw ApiException(route, code, "响应体为空")
                return JSONObject(text)
            }
        } catch (e: InterruptedException) {
            throw e
        } catch (e: ApiException) {
            throw e
        } catch (e: java.io.IOException) {
            // OkHttp reports a cancelled call as a plain IOException("Canceled").
            // That is the round being dropped, not a failure worth retrying.
            if (call.isCanceled() || isAborted(scope)) throw cancelled()
            throw ApiException(route, null, describe(e))
        } finally {
            scope?.detach(unhook)
        }
    }

    private fun sleep(attempt: Int) {
        val ms = retryBackoffMs shl attempt
        try {
            Thread.sleep(ms)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            throw InterruptedException("Request cancelled")
        }
    }

    private fun isAborted(scope: HttpScope?): Boolean =
        scope?.isCancelled == true || Thread.currentThread().isInterrupted

    private fun cancelled(): InterruptedException {
        Thread.currentThread().interrupt()
        return InterruptedException("Request cancelled")
    }

    /** OpenRouter wants attribution headers; other hosts reject unknown ones politely. */
    fun headersFor(url: String): Map<String, String> =
        if (url.contains("openrouter.ai", ignoreCase = true))
            mapOf("HTTP-Referer" to "https://jev-assistant.local", "X-Title" to "Jev Assistant")
        else emptyMap()

    /** Human-readable transport failures (no key material ever appears here). */
    private fun describe(e: Exception): String {
        val m = (e.message ?: "") + " " + e.javaClass.simpleName
        return when {
            e is InterruptedIOException || m.contains("timeout", true) || m.contains("timed out") ->
                "网络超时，请检查连接"
            m.contains("Unable to resolve host") || m.contains("UnknownHost") ->
                "域名解析失败，地址填错或无网络"
            m.contains("Failed to connect") || m.contains("ECONNREFUSED") || m.contains("Connection refused") ->
                "无法连接该地址"
            m.contains("CertPath") || m.contains("SSL") || m.contains("certification path", true) ||
                m.contains("Trust anchor", true) || m.contains("Hostname", true) ->
                "HTTPS 证书校验失败"
            else -> e.message ?: e.javaClass.simpleName
        }
    }
}

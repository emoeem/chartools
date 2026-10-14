package com.jev.probe.jev

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 请求体的线上格式。采样惩罚（frequency/presence penalty）只在非 0 时才发：
 * 0 值省略而不是发 `"0"`，让请求和加这个字段之前逐字节一样——拒绝未知参数或
 * 对默认值敏感的服务商不能因为一个反重复开关而不能用。
 */
class ChatRequestBodyTest {

    @Test
    fun zeroPenaltiesAreOmittedNotSent() {
        val body = chatRequestBody(
            "deepseek-chat", "sys", "user", temperature = 0.8, stream = false)
        assertFalse(body.has("frequency_penalty"))
        assertFalse(body.has("presence_penalty"))
        assertEquals("deepseek-chat", body.getString("model"))
        assertEquals(0.8, body.getDouble("temperature"), 1e-9)
        assertFalse(body.getBoolean("stream"))
    }

    @Test
    fun nonZeroPenaltiesRideAlong() {
        val body = chatRequestBody(
            "deepseek-chat", "sys", "user", temperature = 0.9, stream = true,
            frequencyPenalty = 0.3, presencePenalty = 0.5)
        assertEquals(0.3, body.getDouble("frequency_penalty"), 1e-9)
        assertEquals(0.5, body.getDouble("presence_penalty"), 1e-9)
        assertTrue(body.getBoolean("stream"))
    }

    @Test
    fun onePenaltyAloneIsSentAlone() {
        val body = chatRequestBody(
            "m", "sys", "user", temperature = 0.8, stream = false, frequencyPenalty = 0.4)
        assertTrue(body.has("frequency_penalty"))
        assertFalse(body.has("presence_penalty"))
    }

    @Test
    fun messagesKeepSystemThenUserOrder() {
        val body = chatRequestBody("m", "sys", "user", temperature = 0.8, stream = false)
        val messages = body.getJSONArray("messages")
        assertEquals(2, messages.length())
        assertEquals("system", messages.getJSONObject(0).getString("role"))
        assertEquals("sys", messages.getJSONObject(0).getString("content"))
        assertEquals("user", messages.getJSONObject(1).getString("role"))
        assertEquals("user", messages.getJSONObject(1).getString("content"))
    }
}

package com.jev.probe.bridge

import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Msg
import com.jev.probe.core.Provenance
import org.json.JSONArray
import org.json.JSONObject

/**
 * 注入层推给主 App 的那条快照的线上格式。**这一份是唯一的定义**：注入侧
 * `render` 出去、主 App `parse` 回来，往返测试证明两边对同一个格式的理解一致
 * （只写一半的契约，等 S3 真接上才第一次发现对不上，那时已经在别的进程里了）。
 *
 * 为什么过 Bundle 里塞一个字符串而不是结构化字段：Bundle 的字段类型是两边都
 * 得维护的第二份契约，而 JSON 已经是这个项目里判断/回复链路的通用载体
 * （[com.jev.probe.jev.JsonSlice]）。有界性由 [BridgeContract.MAX_PAYLOAD_CHARS]
 * 在接收端强制，不靠发送端自觉。
 *
 * 版本号只前进：`v` 比本端高就整条拒收，宁可不显示也不猜。
 */
object BridgePayload {

    const val VERSION = 1

    fun render(snapshot: ChatSnapshot): String {
        val root = JSONObject()
        root.put("v", VERSION)
        snapshot.title?.let { root.put("title", it) }
        root.put("messages", renderMessages(snapshot.messages))
        if (snapshot.history.isNotEmpty()) root.put("history", renderMessages(snapshot.history))
        return root.toString()
    }

    /** @return null 表示这条 payload 不可信（版本、结构或字段类型不符），调用方降级。 */
    fun parse(raw: String?): ChatSnapshot? {
        if (raw.isNullOrBlank()) return null
        val root = try {
            JSONObject(raw)
        } catch (t: Throwable) {
            return null
        }
        // 版本必须是一个真的数字。org.json 的 optInt 会把字符串 "1" 也当成 1
        // （JVM 上的 org.json 和 Android 上的一样），而版本号是格式契约的护栏：
        // 这里宽松一次，将来 v2 的字段被一个不认识它的旧版读成 v1 就没人拦得住。
        val rawVersion = root.opt("v")
        if (rawVersion !is Number) return null
        val version = rawVersion.toInt()
        if (version <= 0 || version > VERSION) return null
        // messages 是必须的：render 永远会写它，缺了就是别的什么东西冒充快照。
        // history 可以缺 —— 屏幕外的历史本来就是「有就给、没有就没有」。
        if (!root.has("messages")) return null
        val messages = parseMessages(root.optJSONArray("messages"), required = true) ?: return null
        val history = parseMessages(root.optJSONArray("history"), required = false) ?: return null
        val title = if (root.isNull("title")) null else root.optString("title")
        return ChatSnapshot(
            title = title?.takeIf { it.isNotBlank() },
            messages = messages,
            provenance = Provenance.INJECT,
            history = history,
        )
    }

    private fun renderMessages(list: List<Msg>): JSONArray {
        val arr = JSONArray()
        list.forEach { m ->
            val o = JSONObject()
            o.put("side", m.side)
            o.put("text", m.text)
            m.id?.let { o.put("id", it) }
            if (m.at > 0L) o.put("at", m.at)
            m.sender?.let { o.put("sender", it) }
            arr.put(o)
        }
        return arr
    }

    /** 缺 side 或 text 的一条就整段判不可信：半条时间线比没有更坏。 */
    private fun parseMessages(arr: JSONArray?, required: Boolean): List<Msg>? {
        if (arr == null) return if (required) null else emptyList()
        val out = ArrayList<Msg>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: return null
            val side = o.optString("side", "")
            if (side != "me" && side != "other") return null
            if (!o.has("text")) return null
            out.add(
                Msg(
                    side = side,
                    text = o.optString("text", ""),
                    id = if (o.isNull("id")) null else o.optString("id"),
                    at = o.optLong("at", 0L),
                    sender = if (o.isNull("sender")) null else o.optString("sender"),
                )
            )
        }
        return out
    }
}

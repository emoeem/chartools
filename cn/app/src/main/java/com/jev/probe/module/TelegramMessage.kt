package com.jev.probe.module

import com.jev.probe.core.Msg
import java.lang.reflect.Field
import java.lang.reflect.Method
import java.util.concurrent.ConcurrentHashMap

/**
 * Telegram `MessageObject` 的**只读**适配：用反射把一条消息读成 [Msg]。
 *
 * 为什么放 `module/` 而不是 `bridge/`：它会在目标 App 的进程里跑，但**不
 * import 任何 xposed 的东西**，所以 JVM 单测可以拿假的 MessageObject 直接跑
 * （字段名叫什么、继承了几层、`isOut` 是字段还是方法，都是这里最容易错、
 * 也最值得测的地方）。真正的挂载在 [TelegramInjector]。
 *
 * 三档兜底，从强到弱：
 *  1. `messageText`（CharSequence，宿主自己算好的可见正文）
 *  2. 分边：`isOut` 字段 → `isOutOwner()` 方法 → `messageOwner.out`
 *  3. 身份：`getId()` 方法 → `messageOwner.id`；时间：`messageOwner.date`（秒）
 *
 * **任何拿不准都返回 null，绝不猜**：读错一条消息比少读一条坏得多 —— 少读的
 * 那条会让注入层退回无障碍，读错的那条会被当成对方说的话送进判断和回复。
 * 所以没有正文的消息（图片、贴纸、位置）直接跳过，与 L0 只认正文气泡的口径
 * 一致，两级读数才比得起来。
 */
object TelegramMessage {

    /** 一个类上解析好的成员，按类缓存（宿主进程里只解析一次）。 */
    private class Shape(
        val text: Field?,
        val out: Field?,
        val owner: Field?,
        val getId: Method?,
        val outOwner: Method?,
    )

    private val shapes = ConcurrentHashMap<Class<*>, Shape>()

    fun read(item: Any?, sender: (Long) -> String?) : Msg? {
        if (item == null) return null
        val body = text(item) ?: return null
        val side = side(item) ?: return null
        val fromId = fromId(item)
        return Msg(
            side = side,
            text = body,
            id = id(item),
            at = at(item),
            sender = fromId?.let(sender),
        )
    }

    /** 可见正文；空白（图片/贴纸/位置）一律 null。 */
    fun text(item: Any?): String? {
        if (item == null) return null
        val shape = shapeOf(item.javaClass)
        val raw = runCatching { shape.text?.get(item) }.getOrNull() as? CharSequence ?: return null
        return raw.toString().takeIf { it.isNotBlank() }
    }

    /** `"me"` / `"other"`；分不出来就 null（调用方退回 L0）。 */
    fun side(item: Any?): String? {
        if (item == null) return null
        val shape = shapeOf(item.javaClass)
        val direct = runCatching { shape.out?.get(item) }.getOrNull() as? Boolean
        if (direct != null) return if (direct) "me" else "other"
        val called = runCatching { shape.outOwner?.invoke(item) }.getOrNull() as? Boolean
        if (called != null) return if (called) "me" else "other"
        // TLRPC.Message.out 是这一层最后的真相：MessageObject 的两个高层入口
        // 都可能在某些构造路径下没被赋值。
        val owner = runCatching { shape.owner?.get(item) }.getOrNull() ?: return null
        val out = runCatching { field(owner.javaClass, "out")?.get(owner) }.getOrNull() as? Boolean
        return out?.let { if (it) "me" else "other" }
    }

    /** 消息 id（字符串，跨层对拍时 L0 拿不到，所以是可空的）。 */
    fun id(item: Any?): String? {
        if (item == null) return null
        val shape = shapeOf(item.javaClass)
        // getId() 返回 0 是「这条消息还没有 id」（本地未发送/刚构造），不是「id 是 0」，
        // 这时要退回 TLRPC.Message.id —— 直接返回 null 会把一半的消息身份丢掉。
        val fromMethod = (runCatching { shape.getId?.invoke(item) }.getOrNull() as? Number)?.toLong()
        if (fromMethod != null && fromMethod != 0L) return fromMethod.toString()
        val owner = runCatching { shape.owner?.get(item) }.getOrNull() ?: return null
        val fromOwner = (runCatching { field(owner.javaClass, "id")?.get(owner) }.getOrNull() as? Number)?.toLong()
        return fromOwner?.takeIf { it != 0L }?.toString()
    }

    /** 发送时间（毫秒）；宿主给的是秒，拿不到就是 0。 */
    fun at(item: Any?): Long {
        if (item == null) return 0L
        val owner = runCatching { shapeOf(item.javaClass).owner?.get(item) }.getOrNull() ?: return 0L
        val seconds = runCatching { field(owner.javaClass, "date")?.get(owner) }.getOrNull() as? Number
        return seconds?.toLong()?.takeIf { it > 0L }?.times(1000L) ?: 0L
    }

    /**
     * 发送者 id。老版本是 int，新版本是 `Peer`（`user_id` / `channel_id` /
     * `chat_id` 三个字段之一）。两个都读，读不出来就 null。
     */
    fun fromId(item: Any?): Long? {
        if (item == null) return null
        val owner = runCatching { shapeOf(item.javaClass).owner?.get(item) }.getOrNull() ?: return null
        for (name in listOf("from_id", "peer_id")) {
            val raw = runCatching { field(owner.javaClass, name)?.get(owner) }.getOrNull() ?: continue
            when (raw) {
                is Number -> return raw.toLong().takeIf { it != 0L }
                else -> {
                    for (key in listOf("user_id", "channel_id", "chat_id")) {
                        val id = runCatching { field(raw.javaClass, key)?.get(raw) }.getOrNull() as? Number
                        if (id != null && id.toLong() != 0L) return id.toLong()
                    }
                }
            }
        }
        return null
    }

    /** 会话 id（与消息 id 无关，用来认「这是同一个会话」）。 */
    fun dialogId(item: Any?): Long? {
        if (item == null) return null
        val owner = runCatching { shapeOf(item.javaClass).owner?.get(item) }.getOrNull() ?: return null
        val raw = runCatching { field(owner.javaClass, "peer_id")?.get(owner) }.getOrNull() ?: return null
        if (raw is Number) return raw.toLong().takeIf { it != 0L }
        for (key in listOf("user_id", "channel_id", "chat_id")) {
            val id = runCatching { field(raw.javaClass, key)?.get(raw) }.getOrNull() as? Number
            if (id != null && id.toLong() != 0L) return id.toLong()
        }
        return null
    }

    private fun shapeOf(type: Class<*>): Shape = shapes.getOrPut(type) {
        Shape(
            text = field(type, "messageText"),
            out = field(type, "isOut"),
            owner = field(type, "messageOwner"),
            getId = method(type, "getId"),
            outOwner = method(type, "isOutOwner"),
        )
    }

    /** 沿继承链找字段（宿主里这些类常常继承好几层）。 */
    private fun field(type: Class<*>, name: String): Field? =
        generateSequence(type) { it.superclass }.takeWhile { it != Any::class.java }
            .firstNotNullOfOrNull { c -> runCatching { c.getDeclaredField(name).apply { isAccessible = true } }.getOrNull() }

    private fun method(type: Class<*>, name: String): Method? =
        generateSequence(type) { it.superclass }.takeWhile { it != Any::class.java }
            .firstNotNullOfOrNull { c -> runCatching { c.getDeclaredMethod(name).apply { isAccessible = true } }.getOrNull() }
}

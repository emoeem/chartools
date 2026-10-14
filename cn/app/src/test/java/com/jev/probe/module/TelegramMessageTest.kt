package com.jev.probe.module

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [TelegramMessage] 是注入层里唯一「按名字摸宿主字段」的地方，也是版本一变就
 * 会坏的地方。所以这里用**假的 MessageObject** 把三档兜底逐条钉住：
 * `isOut` 字段 / `isOutOwner()` 方法 / `messageOwner.out`，以及 id、时间、
 * 发送者（老版 int 与新版 Peer 对象两种）。
 *
 * 读不准的代价比读不到大得多：读不到会退回无障碍，读错了会被当成对方说的话
 * 直接送进判断和回复。所以「拿不准就 null」这几条是重点。
 */
class TelegramMessageTest {

    // ---- 假的宿主对象：字段名与 Telegram 一致，形状覆盖各版本 ----

    private class Owner(
        @JvmField var date: Int = 0,
        @JvmField var id: Int = 0,
        @JvmField var out: Boolean = false,
        @JvmField var from_id: Any? = null,
        @JvmField var peer_id: Any? = null,
    )

    private class Peer(@JvmField var user_id: Long = 0L)

    private class FullMessage(
        @JvmField var messageText: CharSequence? = "在吗",
        @JvmField var isOut: Boolean = false,
        @JvmField var messageOwner: Owner = Owner(),
    ) {
        private var rawId = 0
        fun getId(): Int = rawId
        fun setId(id: Int) { rawId = id }
    }

    /** 只有 `isOutOwner()` 方法，没有 `isOut` 字段。 */
    private class MethodOnlyMessage(
        @JvmField var messageText: CharSequence? = "在吗",
        private val out: Boolean = false,
    ) {
        fun isOutOwner(): Boolean = out
    }

    /** 只有 `messageOwner.out`，高层入口一个都没有。 */
    private class OwnerOnlyMessage(
        @JvmField var messageText: CharSequence? = "在吗",
        @JvmField var messageOwner: Owner = Owner(out = true),
    )

    /** 连分边信息都没有：只该被丢掉。 */
    private class TextOnlyMessage(@JvmField var messageText: CharSequence? = "在吗")

    /** 正文声明在父类上（宿主里这些类常常继承好几层）。 */
    private open class BaseMessage {
        @JvmField var messageText: CharSequence? = "继承来的"
    }

    private class InheritedMessage : BaseMessage() {
        @JvmField var isOut: Boolean = true
    }

    // ---- 正文 ----

    @Test
    fun aPlainTextMessageReadsIntoAMsg() {
        val owner = Owner(date = 1_700_000_000, id = 42)
        val msg = TelegramMessage.read(FullMessage(messageOwner = owner)) { null }
        assertEquals("在吗", msg?.text)
        assertEquals("other", msg?.side)
        assertEquals("42", msg?.id)
        assertEquals(1_700_000_000_000L, msg?.at)
    }

    @Test
    fun aBlankBodyIsRefused() {
        assertNull(TelegramMessage.read(FullMessage(messageText = "   ")) { null })
        assertNull(TelegramMessage.read(FullMessage(messageText = null)) { null })
    }

    @Test
    fun aMediaMessageWithNoTextIsRefused() {
        // 图片/贴纸/位置没有可见正文 —— 与 L0 只认正文气泡的口径一致，
        // 不然两层的读数根本没法逐条对拍。
        val media = FullMessage(messageText = null, messageOwner = Owner(id = 9))
        assertNull(TelegramMessage.read(media) { null })
        assertNull(TelegramMessage.text(media))
    }

    @Test
    fun nothingAtAllReadsAsNull() {
        assertNull(TelegramMessage.read(null) { null })
        assertNull(TelegramMessage.read("不是消息对象") { null })
        assertNull(TelegramMessage.text(null))
        assertNull(TelegramMessage.side(null))
    }

    // ---- 分边：三档兜底 ----

    @Test
    fun theIsOutFieldWins() {
        assertEquals("me", TelegramMessage.side(FullMessage(isOut = true)))
        assertEquals("other", TelegramMessage.side(FullMessage(isOut = false)))
    }

    @Test
    fun theIsOutOwnerMethodIsTheSecondChoice() {
        assertEquals("me", TelegramMessage.side(MethodOnlyMessage(out = true)))
        assertEquals("other", TelegramMessage.side(MethodOnlyMessage(out = false)))
    }

    @Test
    fun theOwnerOutFlagIsTheLastChoice() {
        assertEquals("me", TelegramMessage.side(OwnerOnlyMessage(messageOwner = Owner(out = true))))
        assertEquals("other", TelegramMessage.side(OwnerOnlyMessage(messageOwner = Owner(out = false))))
    }

    @Test
    fun aMessageWhoseSideCannotBeToldIsRefused() {
        // 分不出「我说的」还是「对方说的」，这条消息会污染判断和回复 ——
        // 宁可少一条，退回无障碍。
        assertNull(TelegramMessage.read(TextOnlyMessage()) { null })
        assertNull(TelegramMessage.side(TextOnlyMessage()))
    }

    @Test
    fun aTextDeclaredOnASuperclassIsStillFound() {
        val msg = TelegramMessage.read(InheritedMessage()) { null }
        assertEquals("继承来的", msg?.text)
        assertEquals("me", msg?.side)
    }

    // ---- id / 时间 ----

    @Test
    fun theIdMethodIsPreferredAndZeroMeansUnknown() {
        val withMethod = FullMessage(messageOwner = Owner(id = 7)).apply { setId(99) }
        assertEquals("99", TelegramMessage.id(withMethod))
        val zeroMethod = FullMessage(messageOwner = Owner(id = 7))
        assertEquals("7", TelegramMessage.id(zeroMethod)) // getId()==0 → 退回 messageOwner.id
        assertEquals(null, TelegramMessage.id(FullMessage(messageOwner = Owner(id = 0))))
    }

    @Test
    fun aMissingDateReadsAsZero() {
        assertEquals(0L, TelegramMessage.at(FullMessage(messageOwner = Owner(date = 0))))
        assertEquals(0L, TelegramMessage.at(TextOnlyMessage()))
    }

    // ---- 发送者：老版 int 与新版 Peer 两种 ----

    @Test
    fun theSenderComesFromFromId() {
        val owner = Owner(from_id = 555)
        val msg = TelegramMessage.read(FullMessage(messageOwner = owner)) { id ->
            if (id == 555L) "张三" else null
        }
        assertEquals("张三", msg?.sender)
    }

    @Test
    fun theSenderAlsoReadsANewStylePeerObject() {
        assertEquals(777L, TelegramMessage.fromId(FullMessage(messageOwner = Owner(from_id = Peer(user_id = 777)))))
        assertEquals(777L, TelegramMessage.fromId(FullMessage(messageOwner = Owner(peer_id = Peer(user_id = 777)))))
    }

    @Test
    fun aZeroSenderIdMeansUnknown() {
        assertNull(TelegramMessage.fromId(FullMessage(messageOwner = Owner(from_id = 0))))
        assertNull(TelegramMessage.fromId(FullMessage(messageOwner = Owner(from_id = Peer(user_id = 0)))))
        assertNull(TelegramMessage.fromId(TextOnlyMessage()))
    }

    @Test
    fun theSenderLambdaIsNotCalledWhenThereIsNoSenderId() {
        var called = false
        val msg = TelegramMessage.read(FullMessage(messageOwner = Owner())) { called = true; "张三" }
        assertNull(msg?.sender)
        assertFalse(called)
    }

    @Test
    fun theDialogIdUsesThePeerId() {
        assertEquals(888L, TelegramMessage.dialogId(FullMessage(messageOwner = Owner(peer_id = Peer(user_id = 888)))))
        assertNull(TelegramMessage.dialogId(TextOnlyMessage()))
    }
}

package dev.chartools.capture

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * fix(kimi-review #1)：空读宽限（EMPTY_READ_GRACE_MS）的判等语义。
 *
 * maybeCapture 的空读分支曾用 `lastNonEmptyTarget == target` 判等：Target 是
 * data class，全等含 messagesSignature——非空读分支存的 Target 带真实指纹、
 * 空读构造的 Target 签名恒为 null（snapshot.takeIf { messages.isNotEmpty() }
 * 为 null），两者永不相等 → 4 秒宽限是死代码，TIM 类「msgs=8 → 0 → null」
 * 瞬时空帧立刻触发截屏 OCR，硬造出一屏会话。修复改用
 * [ConversationSession.Target.sameConversation] 的身份语义（pkg + windowId +
 * title）。
 *
 * 本测试钉住修复依赖的三条事实（maybeCapture 本体是 AccessibilityService，
 * JVM 单测实例化不了，只能把判等谓词钉在这里）：
 *  1. 同一会话（pkg/windowId/title 相同）但 messagesSignature 不同（非空读
 *     vs 空读）→ sameConversation 为 true，宽限必须拦得住；
 *  2. 同一对 Target 的 data class 全等是 false——即修复前判等必然失败的
 *     回归证明：谁改回 ==，这条断言先红，宽限重新变死代码；
 *  3. pkg / windowId / title 任一不同 → 不是同一会话；双 null 标题（微信
 *     空树的常态）→ 同窗口内仍是同一会话（#22 的 OCR 路径靠它保持身份）。
 */
class EmptyReadGraceIdentityTest {

    /** 非空读：targetFor 用 extract 的消息指纹构造 Target（签名非 null）。 */
    private val nonEmptyRead =
        ConversationSession.Target("com.tencent.tim", 42, "产品群", "other:你好|me:好")

    /** 空读：messages 为空集合 → 签名恒为 null。 */
    private val emptyRead =
        ConversationSession.Target("com.tencent.tim", 42, "产品群", null)

    @Test
    fun sameConversationIgnoresMessagesSignatureDifference() {
        // 空读宽限要拦的正是「同一会话、指纹不同」的瞬时空帧。
        assertTrue(nonEmptyRead.sameConversation(emptyRead))
        assertTrue(emptyRead.sameConversation(nonEmptyRead))
    }

    @Test
    fun dataClassEqualityWithDifferingSignatureIsFalse_theDeadCodeRegression() {
        // 修复前 maybeCapture 用 == 判等：这里恒为 false → 宽限从不生效。
        assertFalse(nonEmptyRead == emptyRead)
    }

    @Test
    fun differentIdentityIsNotSameConversation() {
        assertFalse(
            nonEmptyRead.sameConversation(
                ConversationSession.Target("com.tencent.mobileqq", 42, "产品群", "sig")))
        assertFalse(
            nonEmptyRead.sameConversation(
                ConversationSession.Target("com.tencent.tim", 43, "产品群", "sig")))
        assertFalse(
            nonEmptyRead.sameConversation(
                ConversationSession.Target("com.tencent.tim", 42, "另一个群", "sig")))
        // null 标题证明不了是哪个会话：与非空标题互不同一。
        assertFalse(
            nonEmptyRead.sameConversation(
                ConversationSession.Target("com.tencent.tim", 42, null, "sig")))
    }

    @Test
    fun doubleNullTitleWithinSameWindowIsSameConversation() {
        // 微信（WeChatOcrAdapter，#22）：树是空的，Target 标题恒为 null——
        // 同窗口内两次构造必须同一会话，否则每次 OCR 兜底都自我失效。
        val first = ConversationSession.Target("com.tencent.mm", 7, null, null)
        val second = ConversationSession.Target("com.tencent.mm", 7, null, null)
        assertTrue(first.sameConversation(second))
    }
}

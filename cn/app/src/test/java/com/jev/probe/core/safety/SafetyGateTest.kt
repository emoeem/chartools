package com.jev.probe.core.safety

import com.jev.probe.core.kb.PersonaCard
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The gate is the one place the app decides not to help, so the tests are as much
 * about what it lets through as about what it stops.
 *
 * Both failure modes are real. Too loose and it drafts for a thread it should have
 * refused; too eager and a normal message about a game ("未成年不让玩") produces no
 * candidates at all, which the user cannot distinguish from a broken network.
 */
class SafetyGateTest {

    private val card = PersonaCard.parse("关系：主奴\n语域：亲密\n硬边界：不要提家人、不要留痕")

    @Test
    fun ordinaryChatPassesCleanly() {
        val v = SafetyGate.check(listOf("晚上一起吃饭吗", "那家店我订好了"), card)
        assertFalse(v.blocked)
        assertEquals("", v.caution)
    }

    @Test
    fun theUsersOwnSideIsNeverScanned() {
        // ReplyClient passes only the other side; this pins the contract so a
        // refactor cannot start scanning the user's own words back at them.
        val v = SafetyGate.check(
            listOf("我：我不喜欢你这样").map { it.removePrefix("我：") }, card)
        assertFalse(v.blocked)
    }

    @Test
    fun aMinorSignalAloneIsACautionNotARefusal() {
        // "未成年" shows up in ordinary talk. Blocking on the word alone would make
        // the assistant refuse a normal conversation.
        val v = SafetyGate.check(listOf("那个游戏未成年不让玩"), card)
        assertFalse(v.blocked)
        assertTrue(v.caution, v.caution.contains("未成年人"))
    }

    @Test
    fun aMinorSignalWithIntimateContentIsRefused() {
        val v = SafetyGate.check(listOf("我才15岁，你想怎么调教我"), card)
        assertTrue(v.blocked)
        assertTrue(v.blockReason!!, v.blockReason!!.contains("未成年"))
    }

    @Test
    fun aStatedMinorAgeNeverReachesTheDrafter() {
        // The age only blocks together with intimate content, so the intimate half
        // has to be there for this to be the case under test at all.
        for (line in listOf("我17岁", "我今年 16 周岁", "人家9岁啦")) {
            val v = SafetyGate.check(listOf("$line，想跟你文爱"), card)
            assertTrue(line, v.blocked)
        }
        // 18 and up is not a minor signal at all.
        assertFalse(SafetyGate.check(listOf("我18岁，想跟你文爱"), card).blocked)
        assertFalse(SafetyGate.check(listOf("我28岁"), card).blocked)
    }

    @Test
    fun clearIllegalTermsAreRefusedOnTheirOwn() {
        for (line in listOf("我们下药吧", "你敢不敢偷拍", "不给钱就勒索你", "我被人强奸过")) {
            assertTrue(line, SafetyGate.check(listOf(line), card).blocked)
        }
    }

    @Test
    fun selfHarmIsRefusedRatherThanDrafted() {
        val v = SafetyGate.check(listOf("我真的想去跳楼"), card)
        assertTrue(v.blocked)
        assertTrue(v.blockReason!!, v.blockReason!!.contains("安全"))
    }

    @Test
    fun theUsersWrittenHardLimitStopsTheRound() {
        // The card says 不要提家人, which also yields the bare word 家人. Matching is
        // literal, so the message has to actually contain the word the user wrote.
        val v = SafetyGate.check(listOf("你家人知道我们这样吗"), card)
        assertTrue(v.blocked)
        assertTrue(v.blockReason!!, v.blockReason!!.contains("家人"))
        assertTrue(v.blockReason!!, v.blockReason!!.contains("硬边界"))

        // A synonym is not matched — "你妈" is not "家人" to a substring check. That is
        // the deliberate limit of the check (the settings hint tells the user to write
        // the word itself), and it is why this is a hard limit only when written down.
        assertFalse(SafetyGate.check(listOf("你妈知道我们这样吗"), card).blocked)
    }

    @Test
    fun aHardLimitDoesNotFireWithoutACard() {
        // Free text is not scanned for invented limits: the assistant must still
        // help when the user has not written a boundary.
        val free = PersonaCard.parse("我们在暧昧期，喜欢互怼")
        assertFalse(SafetyGate.check(listOf("你家人知道我们这样吗"), free).blocked)
        assertFalse(SafetyGate.check(listOf("你家人知道我们这样吗"), null).blocked)
    }

    @Test
    fun consentAmbiguityBecomesACautionInsideThePrompt() {
        val v = SafetyGate.check(listOf("你今天必须听我的，别逼我生气"), card)
        assertFalse(v.blocked)
        assertTrue(v.caution, v.caution.contains("自愿"))
    }

    @Test
    fun anIntimateThreadThatIsNotAboutMinorsOrLimitsPasses() {
        val v = SafetyGate.check(listOf("过来，今晚照上次说的来"), card)
        assertFalse(v.blocked)
        assertEquals("", v.caution)
    }

    @Test
    fun everyLimitIsCheckedNotJustTheFirst() {
        val multi = PersonaCard.parse("硬边界：不要提家人、不要留痕、不要提分手")
        assertTrue(SafetyGate.check(listOf("要不我们分手吧"), multi).blocked)
        assertTrue(SafetyGate.check(listOf("记得删记录，别留痕"), multi).blocked)
        assertNull(SafetyGate.check(listOf("我到家了"), multi).blockReason)
    }

    @Test
    fun theAgreedSafeWordStopsTheRoundOnTheSpot() {
        // A safe word is an agreement between the two of them, not a heuristic: once
        // it is said the scene is over. The offline run showed the model usually
        // stops on its own — but "usually" is not the contract, and a draft that
        // slides past the stop word is the one failure with no way back.
        val agreed = PersonaCard.parse("关系：主奴\n语域：亲密\n硬边界：不要留痕\n安全词：红灯")
        val v = SafetyGate.check(listOf("红灯。先停一下"), agreed)
        assertTrue(v.blocked)
        assertTrue(v.blockReason!!, v.blockReason!!.contains("安全词"))
        // No safe word written down, nothing to stop on.
        assertFalse(SafetyGate.check(listOf("红灯。先停一下"), card).blocked)
    }

    @Test
    fun aWrittenHardLimitStopsBeingDodgeableByParaphrase() {
        // 不要留痕 only matches the word itself, so "录下来我自己留着" used to slip
        // through — and the real run had all three candidates agreeing to it. This
        // is a caution rather than a refusal, so what matters is that the
        // instruction reaches the prompt.
        val v = SafetyGate.check(listOf("我想把你刚说的那些录下来，就我自己留着"), card)
        assertFalse(v.blocked)
        assertTrue(v.caution, v.caution.contains("硬边界"))
        assertTrue(v.caution, v.caution.contains("留痕"))
        assertTrue(v.caution, v.caution.contains("不要答应"))
    }

    @Test
    fun aPublicPlaceOnlyRaisesACautionWhenTheCardSaysItMatters() {
        val careful = PersonaCard.parse("关系：主奴\n硬边界：不要在外面露出")
        val v = SafetyGate.check(listOf("我在楼道里，室友在屋里"), careful)
        assertFalse(v.blocked)
        assertTrue(v.caution, v.caution.contains("先确认环境"))
        // With no such boundary written down a mention of a place is just a place:
        // flagging every "我在路上" would teach the user to ignore this line.
        assertEquals("", SafetyGate.check(listOf("我在楼道里，室友在屋里"), card).caution)
    }

    @Test
    fun theAgreedYellowLightSlowsTheRoundDownWithoutStoppingIt() {
        // 黄灯是双方约定里的减速信号：要提醒起草先确认状态、降低强度，但不能像
        // 红灯那样把整轮拦掉——2026-10-07 实测里对方说「黄灯哦」之后场景继续，
        // 这正是黄灯的本意。
        val agreed = PersonaCard.parse("关系：主奴\n语域：亲密\n安全词：红灯\n黄灯：黄灯")
        val v = SafetyGate.check(listOf("黄灯哦～"), agreed)
        assertFalse(v.blocked)
        assertTrue(v.caution, v.caution.contains("黄灯信号"))
        assertTrue(v.caution, v.caution.contains("减速"))
        // 黄灯是 caution 不是 block：不带「我不给候选」这类拦截话术。
        assertFalse(v.caution, v.caution.contains("不给候选"))
        // 卡上没写黄灯，「黄灯」两个字只是个词。
        val bare = PersonaCard.parse("关系：主奴\n语域：亲密\n安全词：红灯")
        assertEquals("", SafetyGate.check(listOf("黄灯哦～"), bare).caution)
        // 红灯仍然拦整轮，黄灯信号不能稀释它。
        assertTrue(SafetyGate.check(listOf("红灯"), agreed).blocked)
    }
}

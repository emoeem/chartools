package com.jev.probe.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * The WeChat title-stability rule, which used to be a `when` buried in an OCR
 * callback and is now a pure data class. It matters because the title is half of
 * the session identity: accepting a misread message line as the title makes the
 * in-flight token stale and resets the card mid-conversation.
 */
class WeChatTitleStateTest {

    private fun state(title: String?, windowId: Int = 3, pending: String? = null) =
        WeChatTitleState(title, windowId, pending)

    @Test
    fun theFirstPickBindsTheTitleAndItsWindow() {
        val s = WeChatTitleState().accept("小明", 7)
        assertEquals("小明", s.title)
        assertEquals(7, s.windowId)
        assertNull(s.pending)
    }

    @Test
    fun aChangedPickNeedsTwoConsecutiveReads() {
        val once = state("小明").accept("群聊", 3)
        assertEquals("小明", once.title)      // still showing the stable title
        assertEquals("群聊", once.pending)    // candidate remembered

        val twice = once.accept("群聊", 3)
        assertEquals("群聊", twice.title)
        assertEquals(3, twice.windowId)
        assertNull(twice.pending)
    }

    @Test
    fun aStrayPickNeverOutvotesTheCurrentTitle() {
        val s = state("小明").accept("群聊", 3).accept("小明", 3)
        assertEquals("小明", s.title)
        // Two good reads in a row: the candidate is forgotten, not kept on credit.
        assertNull(s.pending)
    }

    @Test
    fun aMisreadBetweenTwoIdenticalStraysStillNeedsARunOfTwo() {
        val s = state("小明").accept("群聊", 3).accept("小明", 3).accept("群聊", 3)
        assertEquals("小明", s.title)
        assertEquals("群聊", s.pending)
    }

    @Test
    fun aSecondStrayReplacesTheFirstCandidate() {
        val s = state("小明").accept("群聊", 3).accept("同事群", 3)
        assertEquals("小明", s.title)
        assertEquals("同事群", s.pending)
    }

    @Test
    fun aDifferentWindowIsTrustedImmediately() {
        val s = state("小明", windowId = 3).accept("群聊", 9)
        assertEquals("群聊", s.title)
        assertEquals(9, s.windowId)
        assertNull(s.pending)
    }

    @Test
    fun anUnreadableBandKeepsTheLastTitle() {
        val before = state("小明", pending = "群聊")
        assertSame(before, before.accept(null, 3))
        assertSame(before, before.accept(null, 9))
    }

    @Test
    fun anUnreadableBandDoesNotEatAnAlreadySeenCandidate() {
        val seenOnce = state("小明").accept("群聊", 3)
        val afterGap = seenOnce.accept(null, 3)
        assertEquals("小明", afterGap.title)
        assertEquals("群聊", afterGap.pending)
    }

    @Test
    fun titleOnlyServesTheWindowItWasReadIn() {
        val s = state("小明", windowId = 3)
        assertEquals("小明", s.titleForWindow(3))
        assertNull(s.titleForWindow(4))
        assertNull(WeChatTitleState().titleForWindow(3))
    }

    @Test
    fun repeatingTheSamePickIsIdempotent() {
        val once = state("小明").accept("小明", 3)
        assertEquals(once, once.accept("小明", 3))
    }
}

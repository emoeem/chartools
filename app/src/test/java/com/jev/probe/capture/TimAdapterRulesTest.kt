package com.jev.probe.capture

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Drives [timSide] with the `id/n9e` bubble bounds read off a real TIM 4.1.0
 * window (OnePlus PJE110, 1080x2376) on 2026-10-06. Only geometry was taken
 * from the device — no message content was read or recorded.
 *
 * Incoming rows in that sample all started at x=134 (the avatar gutter) and
 * ended between 395 and 809; outgoing rows all ended flush at x=1075.
 */
class TimAdapterRulesTest {

    private val w = 1080

    @Test fun incomingBubblesFromTheSampleAreOther() {
        val sampled = listOf(134 to 668, 134 to 441, 134 to 809, 134 to 579, 134 to 671, 134 to 395)
        for ((left, right) in sampled) {
            assertEquals("incoming [$left,$right]", "other", timSide(left, right, w))
        }
    }

    @Test fun outgoingBubblesFromTheSampleAreMe() {
        for ((left, right) in listOf(908 to 1075, 841 to 1075)) {
            assertEquals("outgoing [$left,$right]", "me", timSide(left, right, w))
        }
    }

    /**
     * The case that rules out a centre-point test: a long outgoing message
     * starts inside the left gutter (x=140 here, i.e. exactly the sampled left
     * edge of incoming bubbles) but is still pinned right.
     */
    @Test fun longOutgoingBubbleStartingAtTheLeftGutterIsStillMine() {
        assertEquals("me", timSide(140, 1075, w))
    }

    /**
     * And the mirror case: a long incoming message reaches past mid-screen but
     * is still pinned left.
     */
    @Test fun longIncomingBubbleReachingPastCentreIsStillOther() {
        assertEquals("other", timSide(134, 1050, w))
    }

    @Test fun shortOutgoingBubbleIsMine() {
        assertEquals("me", timSide(1000, 1075, w))
    }

    /** Same rules on a 1200px-wide screen, where the gutters scale. */
    @Test fun scalesToAWiderScreen() {
        assertEquals("other", timSide(156, 700, 1200))
        assertEquals("me", timSide(900, 1195, 1200))
        assertEquals("other", timSide(156, 1180, 1200))
        assertEquals("me", timSide(162, 1195, 1200))
    }

    /**
     * Neither edge landed on its gutter: the node is the message TextView and
     * the bubble's own padding pushes its bounds a few px inside the bubble, so
     * a long incoming paragraph sits at x=170..1030 — past mid-screen with no
     * pin. The old centre test called that MINE; the nearer gutter (left, 30px
     * away, versus 45px) says otherwise.
     */
    @Test fun anUnpinnedLongIncomingBubbleGoesToTheNearerGutter() {
        assertEquals("other", timSide(170, 1030, w))
    }

    /**
     * The mirror case: bounds sitting just inside a right-pinned bubble. 15px
     * from the right pin beats 260px from the left gutter.
     */
    @Test fun anUnpinnedBubbleNearTheRightEdgeIsMine() {
        assertEquals("me", timSide(400, 1060, w))
    }
}

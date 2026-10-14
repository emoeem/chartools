package com.jev.probe.capture

import com.jev.probe.capture.WeChatBubbles.Box
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pixel rules against synthetic frames. WeChat exposes no node tree at all, so
 * this is the only part of the WeChat path that can be verified without a phone
 * in the loop — hence a frame built by hand for every decision the algorithm
 * makes.
 *
 * Frame: 200x400, so the internal mask runs at 100x200 (STEP=2). Background is
 * 17,17,17 (the sampled dark theme); the input bar is 30,30,30.
 */
class WeChatBubblesTest {

    private val bg = 0xFF111111.toInt()
    private val bar = 0xFF1E1E1E.toInt()
    private val mine = 0xFF3EB575.toInt()    // 62,181,117  sampled
    private val theirs = 0xFF2C2C2C.toInt()  // 44,44,44    sampled

    private fun frame(paint: (IntArray) -> Unit): IntArray {
        val px = IntArray(W * H) { bg }
        paint(px)
        return px
    }

    private fun IntArray.rect(x0: Int, y0: Int, x1: Int, y1: Int, c: Int) {
        for (y in y0..y1) for (x in x0..x1) this[y * W + x] = c
    }

    /** Full-width band with its own colour, like WeChat's input bar. */
    private fun IntArray.inputBar() = rect(0, 360, W - 1, H - 1, bar)

    @Test fun findsBubblesAndReadsSidesFromFillColour() {
        val px = frame {
            it.inputBar()
            it.rect(100, 200, 160, 240, mine)    // right-ish, green
            it.rect(10, 300, 60, 340, theirs)    // left-ish, grey
        }

        val boxes = WeChatBubbles.find(px, W, H)

        assertEquals(2, boxes.size)
        assertEquals("me", boxes[0].side)
        assertEquals(Box(100, 200, 161, 241, "me"), boxes[0])
        assertEquals("other", boxes[1].side)
        assertEquals(Box(10, 300, 61, 341, "other"), boxes[1])
    }

    @Test fun avatarsInTheSideGuttersAreNotBubbles() {
        val px = frame {
            it.inputBar()
            it.rect(0, 120, 24, 180, theirs)      // 112x112 in the real thing
            it.rect(100, 200, 160, 240, mine)
        }

        val boxes = WeChatBubbles.find(px, W, H)

        assertEquals(1, boxes.size)
        assertEquals("me", boxes[0].side)
    }

    @Test fun shortTextFragmentsAreNotBubbles() {
        val px = frame {
            it.inputBar()
            it.rect(40, 60, 46, 64, theirs)       // 4x3 in mask space
        }

        assertTrue(WeChatBubbles.find(px, W, H).isEmpty())
    }

    @Test fun inputBarIsDetectedAndExcluded() {
        val px = frame {
            it.inputBar()
            it.rect(100, 200, 160, 240, mine)
        }

        val boxes = WeChatBubbles.find(px, W, H)

        assertTrue(boxes.none { it.bottom >= 360 })
        assertEquals(1, boxes.size)
    }

    @Test fun aBubbleJustAboveTheInputBarSurvives() {
        // A fixed "crop at 88% of the height" would eat this one; walking up
        // from the bottom to the bar's real edge is what keeps it.
        val px = frame {
            it.inputBar()
            it.rect(10, 330, 120, 358, theirs)
        }

        val boxes = WeChatBubbles.find(px, W, H)

        assertEquals(1, boxes.size)
        assertEquals("other", boxes[0].side)
        assertTrue(boxes[0].bottom > 340 * 0.88)
    }

    @Test fun emptyBackgroundHasNoBubbles() {
        assertTrue(WeChatBubbles.find(frame { }, W, H).isEmpty())
    }

    @Test fun lightThemeUsesTheSameRule() {
        // Untested on a real light-theme screenshot; this at least locks the
        // rule that decides it: green fill = mine, everything else = theirs.
        val light = 0xFFEDEDED.toInt()
        val px = IntArray(W * H) { light }
        px.rect(0, 360, W - 1, H - 1, 0xFFF0F0F0.toInt())
        px.rect(100, 200, 160, 240, 0xFF95EC69.toInt())  // my green, light theme
        px.rect(10, 300, 60, 340, 0xFFFFFFFF.toInt())    // their white

        val boxes = WeChatBubbles.find(px, W, H)

        assertEquals(2, boxes.size)
        assertEquals("me", boxes[0].side)
        assertEquals("other", boxes[1].side)
    }

    @Test fun chatListRowsAreNotBubbles() {
        // The frame that made the first gutter value wrong: a WeChat CHAT LIST
        // has a row avatar in the left column and full-width bars, and at
        // GUTTER=0.14 this produced ten "bubbles" — including the green 微信支付
        // avatar, which read as one of MY messages — so the panel analysed the
        // chat list. Proportions mirror the device (avatar 0.04W..0.17W).
        val px = frame {
            it.rect(0, 60, W - 1, 100, theirs)          // full-width bar
            it.rect(8, 120, 34, 160, 0xFF3A92EA.toInt())  // 0.04W..0.17W avatar
        }

        assertTrue(WeChatBubbles.find(px, W, H).isEmpty())
    }

    @Test fun aGreyBubbleWithMyAvatarBesideItIsMine() {
        // WeChat only fills TEXT bubbles green. On the sampled 文件传输助手
        // screen my PDF card was grey (64,61,61) and read as "other" — fixing it
        // needs the avatar that sits in the right gutter next to it.
        val px = frame {
            it.inputBar()
            it.rect(40, 200, 130, 250, 0xFF403D3D.toInt())  // grey card, NOT in a gutter
            it.rect(174, 200, 194, 220, 0xFF431F40.toInt()) // my avatar, 0.10W, right gutter
        }

        val boxes = WeChatBubbles.find(px, W, H)

        assertEquals(1, boxes.size)
        assertEquals("me", boxes[0].side)
    }

    @Test fun degenerateFramesAreRejectedInsteadOfCrashing() {
        assertTrue(WeChatBubbles.find(IntArray(4), 4, 1).isEmpty())
        assertTrue(WeChatBubbles.find(IntArray(W * H), W, H).isEmpty())
    }

    /**
     * A skin or a card colour that is not the sampled green. Fill colour alone
     * called this "other" even though it is flush against the right edge — the
     * only place MY bubble can be. Geometry supplements the colour, it does not
     * replace it (the green bubble above is at x=100..160, nowhere near the
     * right edge, and must stay "me").
     */
    @Test fun aBubbleFlushAgainstTheRightEdgeIsMineWhateverItsColour() {
        val px = frame {
            it.inputBar()
            it.rect(150, 200, 198, 240, 0xFF403D3D.toInt())  // grey card, right edge 0.99W
        }

        val boxes = WeChatBubbles.find(px, W, H)

        assertEquals(1, boxes.size)
        assertEquals("me", boxes[0].side)
    }

    @Test fun aGreyBubbleInTheMiddleOfTheScreenIsStillTheirs() {
        val px = frame {
            it.inputBar()
            it.rect(40, 200, 130, 250, 0xFF403D3D.toInt())  // right edge only 0.65W
        }

        val boxes = WeChatBubbles.find(px, W, H)

        assertEquals(1, boxes.size)
        assertEquals("other", boxes[0].side)
    }

    private companion object {
        const val W = 200
        const val H = 400
    }
}

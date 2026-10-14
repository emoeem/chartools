package com.jev.probe.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 收起态胶囊的贴边吸附与展开卡的位置钳制。
 *
 * 背景：悬浮卡曾被"放丢"——三套位置状态（全局气泡、按应用卡片位置、默认 top）
 * 互相覆盖，真机上窗口在、分析在跑、屏上找不到卡。重组后只有一个锚点，且收起
 * 态永远吸到左右边缘。这里钉住吸附与钳制的边界行为。
 */
class BubbleSnapTest {

    private val size = 156          // 52dp @3x
    private val screenW = 1080
    private val screenH = 2376
    private val margin = 12         // 4dp
    private val topMin = 72         // 24dp

    @Test
    fun aCapsuleOnTheLeftHalfSnapsToTheLeftEdge() {
        val (x, y) = BubbleSnap.snap(300, 800, size, screenW, screenH, margin, topMin)
        assertEquals(margin, x)
        assertEquals(800, y)
    }

    @Test
    fun aCapsuleOnTheRightHalfSnapsToTheRightEdge() {
        val (x, _) = BubbleSnap.snap(700, 800, size, screenW, screenH, margin, topMin)
        assertEquals(screenW - size - margin, x)
    }

    @Test
    fun yIsClampedIntoTheScreen() {
        val (_, top) = BubbleSnap.snap(300, -500, size, screenW, screenH, margin, topMin)
        assertEquals(topMin, top)
        val (_, bottom) = BubbleSnap.snap(300, screenH, size, screenW, screenH, margin, topMin)
        assertEquals(screenH - size - margin, bottom)
    }

    @Test
    fun aTinyScreenStillYieldsAValidSpot() {
        // 极端参数（横屏小窗、分屏）下钳制不能把坐标越推越偏：left >= topMin 保底。
        val (x, y) = BubbleSnap.snap(50, 50, size, 400, 600, margin, topMin)
        assertTrue(x >= margin)
        assertTrue(y >= topMin)
        assertTrue(x + size <= 400 - margin || x == margin)
    }

    @Test
    fun cardOriginStaysFullyOnScreen() {
        val cardW = 1032
        val (x, y) = BubbleSnap.cardOrigin(2000, 3000, cardW, screenW, screenH, margin, topMin, screenH - 360)
        assertEquals(screenW - cardW - margin, x)
        assertEquals(screenH - 360, y)
    }

    @Test
    fun cardOriginAtTheLeftAnchorSitsAtTheMargin() {
        val (x, _) = BubbleSnap.cardOrigin(12, 415, 1032, screenW, screenH, margin, topMin, screenH - 360)
        assertEquals(margin, x)
    }
}

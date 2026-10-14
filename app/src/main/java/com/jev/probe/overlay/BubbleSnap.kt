package com.jev.probe.overlay

/**
 * 悬浮窗位置数学，纯函数 —— JVM 单测直接钉住。
 *
 * 为什么要有这一层：悬浮卡历史上同时存在三套位置状态（全局气泡坐标、按应用
 * 记忆的卡片位置、默认 top），互相覆盖的结果就是卡被"放丢"——真机实测窗口在、
 * 分析在跑、屏上找不到卡（`_reports/ui-overhaul-investigation_report.md` P0）。
 * 重组后只剩一个锚点（气泡坐标），且**收起态永远贴左右边缘**：用户拖到哪里都
 * 会被吸回来，不会再出现"卡在半空看不见"的状态。
 */
internal object BubbleSnap {

    /**
     * 收起态（胶囊）：x 吸到离松手位置最近的左右边缘，y 钳进屏幕上下界。
     * [topMinPx] 给状态栏留高度；[marginPx] 避开手势条与屏幕边。
     */
    fun snap(
        x: Int,
        y: Int,
        size: Int,
        screenW: Int,
        screenH: Int,
        marginPx: Int,
        topMinPx: Int
    ): Pair<Int, Int> {
        val maxY = (screenH - size - marginPx).coerceAtLeast(topMinPx)
        val clampedY = y.coerceIn(topMinPx, maxY)
        val left = marginPx
        val right = (screenW - size - marginPx).coerceAtLeast(left)
        val centerX = x + size / 2
        val nx = if (centerX <= screenW / 2) left else right
        return nx to clampedY
    }

    /**
     * 展开卡：以胶囊锚点为左上角，横向钳进屏幕、纵向钳在 [topMinPx, maxBottomPx]。
     * 卡片比屏幕窄得多时永远完整可见。
     */
    fun cardOrigin(
        x: Int,
        y: Int,
        cardW: Int,
        screenW: Int,
        screenH: Int,
        marginPx: Int,
        topMinPx: Int,
        maxBottomPx: Int
    ): Pair<Int, Int> {
        val maxX = (screenW - cardW - marginPx).coerceAtLeast(marginPx)
        val clampedX = x.coerceIn(marginPx, maxX)
        val maxY = maxBottomPx.coerceAtLeast(topMinPx)
        val clampedY = y.coerceIn(topMinPx, maxY)
        return clampedX to clampedY
    }
}

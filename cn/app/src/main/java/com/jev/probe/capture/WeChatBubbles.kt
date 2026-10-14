package com.jev.probe.capture

/**
 * Pixel rules that turn one WeChat screenshot into message boxes, each with the
 * side it came from. Pure Kotlin over an ARGB array, so it is unit-testable
 * without a device.
 *
 * Why pixels at all: WeChat 8.0.78 hands accessibility an EMPTY node tree —
 * `uiautomator dump` on an open chat returns one node, 407 bytes, bounds
 * `[0,0][0,0]`, and it does the same with every accessibility service on the
 * phone switched off. So the tree cannot even prove "this is a chat window".
 * The screenshot is not blocked, so the screen is the only readable surface.
 * (CLAUDE.md still holds: nothing here touches WeChat's process or storage.)
 *
 * What the shapes look like on a screenshot (sampled 2026-10-06, WeChat 8.0.78,
 * OnePlus PJE110 1080x2376, dark theme):
 * ```
 * page background         17,17,17     the modal colour of the whole frame
 * my bubble               62,181,117   green — high contrast, trivial to find
 * their bubble            20,20,20 … 44,44,44   grey, only 3 levels off the
 *                                              background in the worst case
 * their avatar            30..140 x   112x112, in the left gutter
 * my avatar               938..1048    in the right gutter
 * sender name label       ~78x26       above a bubble, on the bare background
 * input bar               30,30,30 / 41,41,41  its own background, bottom
 * ```
 * The 3-level gap is the whole reason this is threshold-2 connected components
 * and not an edge detector: the screenshot is an exact pixel copy with no
 * compression noise, so a deliberate 3-level fill is a real signal.
 *
 * Sides come from the fill colour (green = mine), never from geometry — a long
 * incoming bubble reaches past mid-screen, exactly as it does in QQ and TIM.
 */
internal object WeChatBubbles {

    /**
     * One message box in BITMAP coordinates (the caller maps them to the screen
     * with the screenshot's scale and origin). [side] is "me" or "other".
     */
    data class Box(val left: Int, val top: Int, val right: Int, val bottom: Int, val side: String)

    /** Share of the frame height OCR'd for the conversation title. */
    const val TITLE_BAND = 0.11f

    /** Above this: the top bar. Below: the input bar (detected, not assumed). */
    private const val CROP_TOP = 0.11f

    /** Mask resolution divisor. 2 keeps a one-character bubble (128px) findable. */
    private const val STEP = 2

    /** Per-channel distance from the page background that still counts as it. */
    private const val BG_TOL = 2

    /** Smallest box that can be a bubble, as a fraction of the frame. */
    private const val MIN_W = 0.055f
    private const val MIN_H = 0.025f

    /** A box wholly inside this side band is an avatar, not a bubble.
     *
     *  Measured, because the first value was wrong: in an open chat WeChat's
     *  avatar is 112px at x=30..140 (0.13W), but on the CHAT LIST the avatars sit
     *  at x=44..183 (0.17W) and the search/plus buttons at 0.81..0.96W — at 0.14
     *  the list page produced ten "bubbles" (row avatars, including the green
     *  微信支付 one, which read as *my* message) and the panel analysed the chat
     *  list. 0.20 still leaves every real bubble: the narrowest incoming bubble
     *  sampled starts at x=156 (0.14W) and ends at 371+ . */
    private const val GUTTER = 0.20f

    /** Anything this wide is a band (status bar, input bar, tab bar), not a
     *  bubble: the widest real bubble sampled was 767px = 0.71W. */
    private const val MAX_W = 0.90f

    /** A square-ish component this wide, in the right gutter, is my avatar
     *  (sampled 108x108 = 0.10W). */
    private const val AVATAR_MIN = 0.08f
    private const val AVATAR_MAX = 0.14f

    /** How much of an avatar has to line up with a box to call the box mine. */
    private const val AVATAR_OVERLAP = 0.6f

    /**
     * A box whose right edge lands inside the rightmost 3% of the screen is mine.
     * On the sampled device (1080px) my bubbles end at 1075 and the other side's
     * start at the left gutter, so an outgoing bubble is flush right with the
     * window — a rule independent of the fill colour, which is the one thing a
     * custom skin changes. See the side decision in [find].
     */
    private const val RIGHT_SNAP = 0.03f

    /** A row this far background-coloured ends the input bar run. */
    private const val BG_ROW_FRACTION = 0.40f

    fun find(pixels: IntArray, width: Int, height: Int): List<Box> {
        val sw = width / STEP
        val sh = height / STEP
        if (sw < 16 || sh < 32 || pixels.size < width * height) return emptyList()

        val bg = modalColor(pixels, width, height)

        // Foreground mask at 1/STEP resolution. Sampling (not averaging) is
        // enough: every fill here is flat colour, and the boxes are huge
        // compared with one pixel.
        val fg = BooleanArray(sw * sh)
        var k = 0
        for (y in 0 until sh) {
            val row = y * STEP * width
            for (x in 0 until sw) fg[k++] = !close(pixels[row + x * STEP], bg, BG_TOL)
        }

        val y0 = (sh * CROP_TOP).toInt()
        val y1 = minOf(inputBarTop(fg, sw, sh), sh)
        if (y1 - y0 < 8) return emptyList()

        val minW = (sw * MIN_W).toInt()
        val minH = (sh * MIN_H).toInt()
        val maxW = (sw * MAX_W).toInt()
        val gutterL = (sw * GUTTER).toInt()
        val gutterR = sw - gutterL

        val seen = BooleanArray(sw * sh)
        var stack = IntArray(1 shl 14)
        var sp = 0
        val candidates = ArrayList<Raw>()
        val mineAvatars = ArrayList<Box>()

        for (sy in y0 until y1) {
            for (sx in 0 until sw) {
                val start = sy * sw + sx
                if (seen[start] || !fg[start]) continue
                sp = 0
                stack[sp++] = start
                seen[start] = true
                var xmin = sx; var xmax = sx; var ymin = sy; var ymax = sy
                var n = 0; var rs = 0; var gs = 0; var bs = 0
                while (sp > 0) {
                    val idx = stack[--sp]
                    val x = idx % sw
                    val y = idx / sw
                    n++
                    val c = pixels[y * STEP * width + x * STEP]
                    rs += (c shr 16) and 0xFF
                    gs += (c shr 8) and 0xFF
                    bs += c and 0xFF
                    if (x < xmin) xmin = x
                    if (x > xmax) xmax = x
                    if (y < ymin) ymin = y
                    if (y > ymax) ymax = y
                    // 4-neighbourhood, clamped to the scan band: a component that
                    // starts inside it must not leak into the status bar or the
                    // input bar below, or the box is a full-height band.
                    if (x > 0) { val i = idx - 1; if (!seen[i] && fg[i]) { seen[i] = true; if (sp == stack.size) stack = stack.copyOf(stack.size * 2); stack[sp++] = i } }
                    if (x < sw - 1) { val i = idx + 1; if (!seen[i] && fg[i]) { seen[i] = true; if (sp == stack.size) stack = stack.copyOf(stack.size * 2); stack[sp++] = i } }
                    if (y > y0) { val i = idx - sw; if (!seen[i] && fg[i]) { seen[i] = true; if (sp == stack.size) stack = stack.copyOf(stack.size * 2); stack[sp++] = i } }
                    if (y < y1 - 1) { val i = idx + sw; if (!seen[i] && fg[i]) { seen[i] = true; if (sp == stack.size) stack = stack.copyOf(stack.size * 2); stack[sp++] = i } }
                }
                val bw = xmax - xmin + 1
                val bh = ymax - ymin + 1
                if (bw < minW || bh < minH) continue          // text labels: name, time
                val left = xmin * STEP
                val top = ymin * STEP
                val right = (xmax + 1) * STEP - 1
                val bottom = (ymax + 1) * STEP - 1
                val bwPx = right - left + 1
                val bhPx = bottom - top + 1
                if (left >= gutterR * STEP) {
                    // The right gutter holds my avatar — and the chat list's
                    // search / plus buttons, which the size test below rejects.
                    if (bwPx >= width * AVATAR_MIN && bwPx <= width * AVATAR_MAX &&
                        bhPx * 10 >= bwPx * 8 && bhPx * 10 <= bwPx * 13) {
                        mineAvatars.add(Box(left, top, right, bottom, "me"))
                    }
                    continue
                }
                if (bw > maxW) continue                       // status / input / tab bar
                if (xmax <= gutterL) continue                 // avatars on their side
                val r = rs / n; val g = gs / n; val b = bs / n
                candidates.add(Raw(left, top, right, bottom, g > r + 25 && g > b + 20))
            }
        }
        // Colour first, then the avatar, then the flush-right edge. The edge is the
        // one rule that survives a re-skinned bubble: the sampled device pins MY
        // bubbles to width-5 and starts the other side at the left gutter, so a box
        // ending inside the right 3% is mine whatever colour the theme fills it
        // with. (Colour stays first — it is the proven rule, and the pixel tests
        // draw my green bubble mid-screen.)
        return candidates.map { c ->
            val mine = c.green ||
                overlapsMineAvatar(c.top, c.bottom, mineAvatars) ||
                c.right >= width - (width * RIGHT_SNAP)
            Box(c.left, c.top, c.right, c.bottom, if (mine) "me" else "other")
        }.sortedBy { it.top }
    }

    private class Raw(val left: Int, val top: Int, val right: Int, val bottom: Int, val green: Boolean)

    /** Does one of my avatars line up with this box? [AVATAR_OVERLAP] of the
     *  avatar's height must be inside the box, so a bubble that merely touches
     *  the avatar above or below it does not read as mine. */
    private fun overlapsMineAvatar(top: Int, bottom: Int, avatars: List<Box>): Boolean {
        for (a in avatars) {
            val overlap = minOf(bottom, a.bottom) - maxOf(top, a.top)
            if (overlap > 0 && overlap >= (a.bottom - a.top) * AVATAR_OVERLAP) return true
        }
        return false
    }

    /**
     * Top of the input bar, in mask rows: the first row above the bottom whose
     * pixels are dominated by the page background. The bar is a full-width band
     * with its own background colour, so walking up from the bottom to the first
     * background row finds its edge without assuming any height ratio — a fixed
     * `height * 0.88` crop would clip the last message on a tall screen.
     */
    private fun inputBarTop(fg: BooleanArray, sw: Int, sh: Int): Int {
        val maxFg = ((1f - BG_ROW_FRACTION) * (sw / 2).coerceAtLeast(1)).toInt()
        var row = sh - 1
        while (row > sh / 2) {
            var count = 0
            var x = 0
            while (x < sw) { if (fg[row * sw + x]) count++; x += 2 }
            if (count <= maxFg) return row + 1
            row--
        }
        return sh
    }

    /** The page background: the most common colour, sampled coarsely. */
    private fun modalColor(pixels: IntArray, width: Int, height: Int): Int {
        val counts = HashMap<Int, Int>(4096)
        var y = 0
        while (y < height) {
            var x = 0
            while (x < width) {
                val c = pixels[y * width + x]
                counts[c] = (counts[c] ?: 0) + 1
                x += 4
            }
            y += 4
        }
        var best = pixels[0]
        var bestN = 0
        for ((c, n) in counts) if (n > bestN) { bestN = n; best = c }
        return best
    }

    private fun close(c: Int, bg: Int, tol: Int): Boolean =
        Math.abs(((c shr 16) and 0xFF) - ((bg shr 16) and 0xFF)) <= tol &&
            Math.abs(((c shr 8) and 0xFF) - ((bg shr 8) and 0xFF)) <= tol &&
            Math.abs((c and 0xFF) - (bg and 0xFF)) <= tol
}

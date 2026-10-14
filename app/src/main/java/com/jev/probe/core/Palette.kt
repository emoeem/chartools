package com.jev.probe.core

import android.graphics.Color

/**
 * The brand palette, written down once.
 *
 * "#3A7AFE" used to be a literal in eight places across four files, next to a
 * hard-coded "#EAF1FF" tint — so changing the accent meant grepping string
 * literals and hoping nothing was missed.
 */
object Palette {

    /** Accent: buttons, pills, the chevron, the collapsed-card flash. */
    const val BRAND = "#3A7AFE"

    /** The accent at tint strength, behind the top-ranked candidate. */
    const val BRAND_TINT = "#EAF1FF"

    fun brand(): Int = Color.parseColor(BRAND)

    fun brandTint(): Int = Color.parseColor(BRAND_TINT)
}

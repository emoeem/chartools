package com.jev.probe.capture

/**
 * What the overlay should do when the foreground app changes to one this service
 * does not capture.
 *
 * Pulled out of `ChatCaptureService.onAccessibilityEvent` as pure functions so
 * the rules can be asserted in a JVM test. They were wrong before: WeChat is an
 * unadapted app with its own capture path, so every window-state change in WeChat
 * ran `showIdle(null)`, which switches the overlay to BUBBLE mode and rebuilds
 * the window — the card the user was reading vanished and came back, repeatedly
 * ("那个悬浮显示的内容，一会出现一会没有的").
 */
internal object ForegroundPolicy {

    /**
     * Does this app fall into the generic "we cannot capture it" branch? False
     * for the apps we do capture (adapters) and for WeChat, whose pixel path
     * lives outside the adapter map. A null foreground (no active window yet) is
     * not a decision either — guessing there only produced spurious tear-downs.
     */
    fun needsIdlePark(fg: String?, adapters: Set<String>, weChatPkg: String): Boolean =
        fg != null && fg !in adapters && fg != weChatPkg

    /**
     * The overlay must come off entirely: our own screens, the launcher, the
     * system UI. Everywhere else the bubble stays reachable — it is the only way
     * into an unadapted app ("截屏识别一次").
     */
    fun shouldHide(fg: String?, ownPkg: String): Boolean {
        fg ?: return false
        return fg == ownPkg ||
            fg.contains("launcher", ignoreCase = true) ||
            fg == "com.miui.home" ||
            fg == "com.android.systemui"
    }

    /**
     * Re-park the idle bubble? Only when nothing is on screen, or when the card
     * on screen belongs to a different app. `showIdle` switches modes and
     * `setMode` rebuilds the window from scratch, so re-parking while a card for
     * this same app is up is exactly the flicker.
     */
    fun shouldRepark(fg: String, overlayShowing: Boolean, overlayApp: String?): Boolean =
        !overlayShowing || overlayApp != fg
}

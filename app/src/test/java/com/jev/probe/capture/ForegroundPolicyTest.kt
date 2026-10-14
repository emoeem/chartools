package com.jev.probe.capture

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The overlay rules for a window-state change into an app we do not capture.
 * These decide whether the panel the user is reading survives the event.
 */
class ForegroundPolicyTest {

    private val adapters = setOf("com.tencent.tim", "com.tencent.mobileqq", "org.telegram.messenger")
    private val weChat = "com.tencent.mm"
    private val own = "com.jev.probe"
    private val dingTalk = "com.alibaba.android.rimet"

    /**
     * The flicker: WeChat is unadapted but has its own capture path, so it must
     * not be treated as "an app we know nothing about".
     */
    @Test
    fun weChatIsNotAnUnknownApp() {
        assertFalse(ForegroundPolicy.needsIdlePark(weChat, adapters, weChat))
    }

    @Test
    fun adapterAppsAreNotUnknownEither() {
        for (pkg in adapters) assertFalse(pkg, ForegroundPolicy.needsIdlePark(pkg, adapters, weChat))
    }

    @Test
    fun aTrulyUnknownAppStillGetsTheBubble() {
        // The only way into DingTalk is the bubble menu's "截屏识别一次".
        assertTrue(ForegroundPolicy.needsIdlePark(dingTalk, adapters, weChat))
    }

    @Test
    fun noForegroundWindowIsNotADecision() {
        assertFalse(ForegroundPolicy.needsIdlePark(null, adapters, weChat))
    }

    @Test
    fun ourOwnScreensAndTheLauncherHideTheOverlay() {
        assertTrue(ForegroundPolicy.shouldHide(own, own))
        assertTrue(ForegroundPolicy.shouldHide("com.miui.home", own))
        assertTrue(ForegroundPolicy.shouldHide("com.android.systemui", own))
        assertTrue(ForegroundPolicy.shouldHide("com.oppo.launcher", own))
        assertFalse(ForegroundPolicy.shouldHide(dingTalk, own))
        assertFalse(ForegroundPolicy.shouldHide(null, own))
    }

    /**
     * Re-parking while a card for the same app is on screen calls showIdle, which
     * switches modes and rebuilds the window — the card the user was reading
     * disappears and comes back. That is the reported flicker.
     */
    @Test
    fun aCardForThisAppIsNotTornDown() {
        assertFalse(ForegroundPolicy.shouldRepark(dingTalk, overlayShowing = true, overlayApp = dingTalk))
    }

    @Test
    fun aCardForAnotherAppIsReplacedByTheBubble() {
        assertTrue(ForegroundPolicy.shouldRepark(dingTalk, overlayShowing = true, overlayApp = weChat))
    }

    @Test
    fun withNothingOnScreenTheBubbleIsParked() {
        assertTrue(ForegroundPolicy.shouldRepark(dingTalk, overlayShowing = false, overlayApp = null))
    }
}

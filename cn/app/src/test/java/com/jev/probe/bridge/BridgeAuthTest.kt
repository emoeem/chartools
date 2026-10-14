package com.jev.probe.bridge

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 桥的门禁。执行者在**另一个进程**里（目标 App 的进程），所以「谁的 uid」
 * 只能靠 Binder 报上来的值。规则只有一条：本 App 自己，或者允许注入的那个
 * App。
 */
class BridgeAuthTest {

    private val own = 10_123
    private val tgUid = 10_456
    private val otherUid = 10_789

    @Test fun ourOwnProcessIsAlwaysAllowed() {
        assertTrue(BridgeAuth.allows(own, own, emptyList()))
        assertTrue(BridgeAuth.allows(own, own, listOf("com.something.else")))
    }

    @Test fun theScopedAppIsAllowed() {
        assertTrue(BridgeAuth.allows(tgUid, own, listOf("org.telegram.messenger")))
    }

    /** 一个 uid 上挂多个包时，只要有一个命中就放行。 */
    @Test fun aUidIsJudgedByEveryPackageOnIt() {
        assertTrue(BridgeAuth.allows(tgUid, own, listOf("com.example.helper", "org.telegram.messenger")))
    }

    @Test fun anUnrelatedAppIsDenied() {
        assertFalse(BridgeAuth.allows(otherUid, own, listOf("com.tencent.mm")))
        assertFalse(BridgeAuth.allows(otherUid, own, emptyList()))
    }

    /**
     * root 与 system 不特殊对待。本机有 KernelSU，`uid=0` 是能出现的；把 uid 0
     * 当自己人的话，任何拿到 root 的进程都能读走桥上的东西 —— 而 root 恰恰是
     * 本机上最容易出现、也最不该被默认信任的身份。
     */
    @Test fun rootIsNotSpecialCased() {
        assertFalse(BridgeAuth.allows(0, own, emptyList()))
        assertFalse(BridgeAuth.allows(0, own, listOf("com.tencent.mm")))
        assertFalse(BridgeAuth.allows(1_000, own, listOf("android")))
    }

    @Test fun somethingClaimingTheScopedPackageButWithAnotherUidIsJudgedOnlyByItsPackages() {
        // 「自称是 Telegram」这件事本身不构成证据，唯一依据是 PackageManager
        // 从这个 uid 反查出来的包名列表。
        assertFalse(BridgeAuth.allows(otherUid, own, listOf("org.telegram.messenger.helper")))
    }
}

package com.jev.probe.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * 接收端的准入规则。真机教训：注入代码用的是目标 App 的 uid，所以**签名级
 * permission 在这里没用**（它挡的是发送方，而发送方不可能持有本 App 的签名），
 * 准入只能靠这里。
 */
class BridgeSenderTest {

    private val own = 10138

    @Test
    fun ourOwnUidIsAlwaysAllowed() {
        assertNull(BridgeSender.denyReason(own, own, listOf("com.jev.probe")))
        // 即使包名解析不出来，自己的 uid 也放行。
        assertNull(BridgeSender.denyReason(own, own, emptyList()))
    }

    @Test
    fun aScopedAppIsAllowed() {
        assertNull(
            BridgeSender.denyReason(
                senderUid = 10500,
                ownUid = own,
                senderPackages = listOf("org.telegram.messenger"),
            )
        )
    }

    @Test
    fun oneUidWithSeveralPackagesIsAllowedWhenAnyIsScoped() {
        assertNull(
            BridgeSender.denyReason(
                senderUid = 10500,
                ownUid = own,
                senderPackages = listOf("com.jiguro.bettervia", "org.telegram.messenger"),
            )
        )
    }

    @Test
    fun anUnrelatedAppIsDenied() {
        assertEquals(
            BridgeContract.R_NOT_SCOPED,
            BridgeSender.denyReason(10500, own, listOf("com.example.other")),
        )
    }

    /** uid 未知（API<34，或者系统没告诉我们）时宁可拒 —— fail-closed。 */
    @Test
    fun anUnknownSenderUidIsDeniedEvenIfPackagesClaimToBeScoped() {
        assertEquals(
            BridgeContract.R_NO_SENDER_UID,
            BridgeSender.denyReason(
                senderUid = null,
                ownUid = own,
                senderPackages = listOf("org.telegram.messenger"),
            ),
        )
    }

    @Test
    fun aNegativeSenderUidIsTreatedAsUnknown() {
        assertEquals(BridgeContract.R_NO_SENDER_UID, BridgeSender.denyReason(-1, own, listOf("org.telegram.messenger")))
    }

    /** 本机 adb shell 就是 root；uid 0 不是「自己」，不许走特殊通道。 */
    @Test
    fun rootIsNotSpecialCased() {
        assertEquals(BridgeContract.R_NOT_SCOPED, BridgeSender.denyReason(0, own, listOf("com.jev.probe")))
        assertEquals(BridgeContract.R_NOT_SCOPED, BridgeSender.denyReason(1000, own, listOf("android")))
    }

    /** 允许范围是入参，不是写死的常量 —— 试点换 App 时不用改这里。 */
    @Test
    fun theScopedListIsInjectable() {
        assertNull(BridgeSender.denyReason(10500, own, listOf("com.tencent.mm"), listOf("com.tencent.mm")))
        assertEquals(
            BridgeContract.R_NOT_SCOPED,
            BridgeSender.denyReason(10500, own, listOf("org.telegram.messenger"), listOf("com.tencent.mm")),
        )
    }
}

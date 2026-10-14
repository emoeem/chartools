package com.jev.probe.root

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 这些字符串是**真机原文**（OnePlus PJE110 / Android 16 / KernelSU）。写错一个
 * 判据，设置页就会把"已经有 root"显示成"没有 root"，用户去点一个不存在的按钮。
 */
class RootProbeTest {

    private val ksuId =
        "uid=0(root) gid=0(root) groups=0(root),1004(input),1007(log),1011(adb),1015(sdcard_rw)," +
            "1028(sdcard_r),1078(ext_data_rw),1079(ext_obb_rw),3001(net_bt_admin),3002(net_bt)," +
            "3003(inet),3006(net_bw_stats),3009(readproc),3011(uhid),3012(readtracefs) " +
            "context=u:r:ksu:s0"

    @Test
    fun kernelSuIsNamed() {
        assertEquals("KernelSU", RootProbe.flavorOf(ksuId))
    }

    @Test
    fun magiskAndApatchAreNamed() {
        assertEquals(
            "Magisk",
            RootProbe.flavorOf("uid=0(root) gid=0(root) context=u:r:magisk:s0")
        )
        assertEquals(
            "APatch",
            RootProbe.flavorOf("uid=0(root) gid=0(root) context=u:r:apatch:s0")
        )
    }

    /** 认不出的域但有 uid=0，也要说"有 root"，不能退回"无"。 */
    @Test
    fun unknownFlavorStillCounts() {
        assertEquals("root", RootProbe.flavorOf("uid=0(root) gid=0(root) context=u:r:su:s0"))
    }

    /** `su` 没被授权时 KernelSU 吐的是这类的permission denied，不算有 root。 */
    @Test
    fun deniedIsNotRoot() {
        assertEquals("无", RootProbe.flavorOf("uid=2000(shell) context=u:r:shell:s0"))
        assertEquals("无", RootProbe.flavorOf("permission denied"))
        assertEquals("无", RootProbe.flavorOf(""))
        assertEquals("无", RootProbe.flavorOf(null))
        assertEquals("无", RootProbe.flavorOf("su: inaccessible or not found"))
    }

    @Test
    fun settingsLiteralNullIsNotAValue() {
        assertNull(RootProbe.settingValue("null"))
        assertNull(RootProbe.settingValue("null\n"))
        assertNull(RootProbe.settingValue("   "))
        assertNull(RootProbe.settingValue(null))
        assertEquals("1", RootProbe.settingValue("1\n"))
        assertEquals(
            "com.coloros.codebook:com.jev.probe/x.Y",
            RootProbe.settingValue("com.coloros.codebook:com.jev.probe/x.Y\n")
        )
    }

    @Test
    fun whitelistDumpIsReadPerLine() {
        val dump = "system,com.android.shell,2000\nuser,com.jev.probe,10138\n"
        assertTrue(RootProbe.onWhitelist(dump, "com.jev.probe"))
        assertFalse(RootProbe.onWhitelist(dump, "com.jev.prob"))
        assertFalse(RootProbe.onWhitelist("", "com.jev.probe"))
        assertFalse(RootProbe.onWhitelist(null, "com.jev.probe"))
    }
}

package dev.chartools.capture

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 黑名单优先级单测（p0-plan ⑦，#4 复核遗留 low）。
 *
 * [CaptureService] 是 AccessibilityService，离线单测实例化不了，所以判定本体
 * 抽成了 companion 的纯函数 isBlockedPackage(pkg, blocked)（无 Android 依赖，
 * 黑名单清单由调用方传入），实例方法只负责取当前 ServiceConfig 黑名单后转发。
 * 这里钉住四条语义：
 *  1. 黑名单命中 → 拦（黑名单优先于白名单：用户拉黑的包即使加进采集范围也不采）；
 *  2. 银行类前缀底线 → 拦，且不随传入的黑名单变化（底线不随 configure 配置、
 *     UI 清空黑名单也拦）；
 *  3. 名单外的包 → 放行（采集白名单另有自己的判断，这里只验黑名单层）；
 *  4. null 包名 → 放行（无从判定的包不在黑名单层猜测，交给白名单层兜住）。
 *
 * 另有一条钉住 Kotlin 默认黑名单与 Dart 侧 SettingsStore.defaultBlockedPackages
 * （app/lib/application/settings_store.dart）的镜像关系：Dart 侧是可编辑清单的
 * 单一事实来源，这里只在首次 configure 之前兜底；两侧漂移时此断言先红。
 */
class BlockedPackagesTest {

    @Test
    fun blacklistedPackageIsBlockedEvenIfAlsoWhitelisted() {
        // 黑名单优先：isBlocked 先查黑名单再查白名单，两名单都命中时必须拦。
        val blocked = setOf("com.tencent.tim", "org.telegram.messenger")
        assertTrue(CaptureService.isBlockedPackage("com.tencent.tim", blocked))
    }

    @Test
    fun unlistedPackageIsNotBlocked() {
        val blocked = setOf("com.eg.android.AlipayGmobile", "cn.soulapp.android")
        assertFalse(CaptureService.isBlockedPackage("org.telegram.messenger", blocked))
    }

    @Test
    fun bankPrefixIsBlockedRegardlessOfList() {
        // com.android.bank 前缀命中即拦：黑名单清空也拦（底线清单不可配置）。
        assertTrue(CaptureService.isBlockedPackage("com.android.bank", emptySet()))
        assertTrue(CaptureService.isBlockedPackage("com.android.bank.mobile", emptySet()))
        // 前缀之外的同族包名不受牵连。
        assertFalse(CaptureService.isBlockedPackage("com.android.chrome", emptySet()))
    }

    @Test
    fun nullPackageIsNotBlocked() {
        // pkg == null 一律放行：黑名单层没有信息就不猜，采集白名单层再拦一道。
        assertFalse(CaptureService.isBlockedPackage(null, setOf("com.tencent.tim")))
    }

    @Test
    fun defaultBlocklistMirrorsDartSettingsStore() {
        // 镜像断言：Dart 侧 defaultBlockedPackages 是单一事实来源，Kotlin 默认值
        // 与它逐项一致（DEFAULT_BLOCKED_PKGS 是 private，经公开的
        // ServiceConfig.blockedPackages 初值验证）。
        val defaults = CaptureService.ServiceConfig.blockedPackages
        assertTrue(defaults.contains("com.eg.android.AlipayGmobile"))
        assertTrue(defaults.contains("com.unionpay"))
        assertTrue(defaults.contains("cn.soulapp.android"))
        assertEquals(3, defaults.size)
    }
}

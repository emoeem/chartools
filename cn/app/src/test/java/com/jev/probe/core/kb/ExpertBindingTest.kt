package com.jev.probe.core.kb

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * S4 绑定的回归锁。
 *
 * 最重要的一条不是「绑对了」，而是**开关关着时一个字节都不变**：
 * `allowedSkillNames(false, ...)` 必须原样返回全量，否则 S4 就悄悄改变了
 * 所有人的回复内容，而这件事在真机上只表现为「语气有点不一样」。
 */
class ExpertBindingTest {

    private val all = listOf("销售话术", "客服口径", "周报模板")

    @Test
    fun whenTheSwitchIsOffNothingIsFiltered() {
        assertEquals(all, ExpertBinding.allowedSkillNames(false, emptyList(), all))
        // 关键：即使专家写了 refs，开关关着也不许筛 —— 否则灰度开关形同虚设。
        assertEquals(all, ExpertBinding.allowedSkillNames(false, listOf("销售话术"), all))
    }

    @Test
    fun anExpertWithoutRefsKeepsEverySkill() {
        // 空 refs 的语义是「沿用全局」，不是「什么都不要」。
        assertEquals(all, ExpertBinding.allowedSkillNames(true, emptyList(), all))
        assertEquals(all, ExpertBinding.allowedSkillNames(true, listOf(" ", ""), all))
    }

    @Test
    fun withTheSwitchOnOnlyTheNamedSkillsSurvive() {
        assertEquals(
            listOf("销售话术", "客服口径"),
            ExpertBinding.allowedSkillNames(true, listOf("销售话术", "客服口径"), all)
        )
    }

    @Test
    fun refsPointingAtDeletedSkillsAreIgnoredNotFatal() {
        // 专家引用了已被删掉的技能：不生效，但不许把这一轮的技能清空。
        assertEquals(
            listOf("销售话术"),
            ExpertBinding.allowedSkillNames(true, listOf("销售话术", "早就删了"), all)
        )
        // 全都指向已删除的技能 → 空列表（这是用户自己配错了，界面要能看出没技能）。
        assertEquals(
            emptyList<String>(),
            ExpertBinding.allowedSkillNames(true, listOf("早就删了"), all)
        )
    }

    @Test
    fun appPackagesAreLimitedToAdaptedApps() {
        val known = setOf("com.tencent.mm", "org.telegram.messenger")
        assertEquals(
            listOf("com.tencent.mm"),
            ExpertBinding.sanitizeAppPkgs(
                listOf(" com.tencent.mm ", "com.example.never", "/data/local/tmp/x", "com.tencent.mm"),
                known
            )
        )
        assertEquals(emptyList<String>(), ExpertBinding.sanitizeAppPkgs(emptyList(), known))
    }
}

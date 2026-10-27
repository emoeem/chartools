package com.jev.probe.capture

/**
 * 已适配聊天 App 的唯一注册表。加一个新 App = 写一个 [ChatAppAdapter] 实现 +
 * 在 [all] 里加一行；显示名、输入框定位、截屏许可都从适配器契约读，下游
 * （采集分发、填入、主页文案、知识库标签）自动跟上。
 *
 * 测试 [ChatAppsRegistryTest] 会钳住这份清单和 `HookTargets` / `arrays.xml` /
 * Manifest 之间的同步关系。
 */
object ChatApps {

    val all: List<ChatAppAdapter> = listOf(
        QQAdapter(), TimAdapter(), XAdapter(), FeishuAdapter(), WhatsAppAdapter(), TelegramAdapter()
    )

    /** 包名 → 适配器。服务里多处按包名分发用；一般调用方用 [forPackage]。 */
    val byPackage: Map<String, ChatAppAdapter> = all.associateBy { it.pkg }

    /** 已适配包名集合（预计算，事件路径每次都用）。 */
    val packages: Set<String> = byPackage.keys

    fun forPackage(pkg: String?): ChatAppAdapter? = pkg?.let { byPackage[it] }
}

package com.jev.probe.capture

import com.jev.probe.bridge.BridgeLedger
import com.jev.probe.bridge.BridgePayload
import com.jev.probe.bridge.BridgeStore
import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Trace

/**
 * 能力阶梯的 L1：从注入层取一条快照。
 *
 * 这是本片（S2）唯一被主采集路径调用的注入相关代码，而它**永远可以返回
 * null**：开关没开、框架没装、模块刚重启、快照过期、payload 坏了 —— 每一种
 * 情况都走同一个出口，调用方一个 `?:` 就落回 L0。所以「注入层可选」不是一句
 * 配置说明，而是这条路径的结构性质。
 *
 * 降级不是静默的：每次没取到都写一行 Trace（包名 + 原因 + 长度），每次取到
 * 也写（条数 + 距今多久）。验收时要能回答「这一轮到底走的哪一层」。
 *
 * 开关由调用方传进来（而不是这里读 Prefs）：这个类因此在 JVM 单测里不需要
 * 一个真的 Context，规则本身也就能被穷举。
 */
internal class InjectionSource(
    private val latest: (String) -> BridgeLedger.Push? = { BridgeStore.latest(it) },
    private val now: () -> Long = System::currentTimeMillis,
) {

    fun snapshot(pkg: String?, enabled: Boolean): ChatSnapshot? {
        if (pkg.isNullOrBlank() || !enabled) return null
        val push = latest(pkg)
        if (push == null) {
            Trace.log("inject pkg=${pkg} skip=no_data")
            return null
        }
        val parsed = BridgePayload.parse(push.payload)
        if (parsed == null) {
            Trace.log("inject pkg=${pkg} skip=bad_payload len=${push.payload.length}")
            return null
        }
        // 空快照 = 模块**主动撤回**（人退出了聊天页），不是「这个会话没有消息」。
        // 必须在这里落地成 null，不能用一条空的顶掉无障碍的那一份：`ChatCaptureService`
        // 是 `injected ?: adapter.extract(...)`，一个非 null 的空快照会把 L0 也挡掉，
        // 结果比不撤回更坏（明明无障碍读得到，却因为注入层撤回而什么都没了）。
        if (parsed.messages.isEmpty() && parsed.history.isEmpty()) {
            Trace.log("inject pkg=${pkg} skip=empty ageMs=${(now() - push.at).coerceAtLeast(0L)}")
            return null
        }
        Trace.log("inject pkg=${pkg} msgs=${parsed.messages.size} hist=${parsed.history.size} " +
            "ageMs=${(now() - push.at).coerceAtLeast(0L)}")
        return parsed
    }
}

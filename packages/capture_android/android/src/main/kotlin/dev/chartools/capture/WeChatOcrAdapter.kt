package dev.chartools.capture

import android.content.res.Resources
import android.view.accessibility.AccessibilityNodeInfo

/**
 * fix(kimi-review #22)：微信的「OCR 兜底」能力面适配器。
 *
 * 微信对无障碍服务只发布一棵空树（1 个节点 / 407 bytes，旧仓库多台设备交叉
 * 验证过），没有可适配的节点规则——这是 alpha.2 之前不给它适配器的原因。代价
 * 是 UI 上「微信（OCR 兜底）」勾选后自动采集静默不生效：CaptureService.maybeCapture
 * 对无适配器包直接跳过（kimi-review #22），白名单的承诺不兑现。
 *
 * 本适配器不读消息，只做两件事：
 * - 能力面（G2，[AdapterCapabilities]）：canReadMessages=false（树里读不到正文）、
 *   allowsOcrFallback=true 且 [allowScreenshot]=true（运行时闸门一致，由
 *   ChatAppAdapterRulesContractTest 钳住）；canIdentifySender=false——整屏 OCR 的
 *   像素气泡分边（WeChatBubbles.find）在本插件没有真机回归记录（取样记录在旧
 *   仓库 8.0.78），不可靠的行会被 OcrGrouping 标成 unknown-speaker，由 G3 置信度
 *   扣分；verifiedAppVersion=null：未在本插件真机复验微信版本。
 * - 窗口信号：extract 返回带 [ChatSnapshot.note] 的空快照——按适配器契约的
 *   「在聊天窗里但树里没有正文」语义，触发服务既有的「截屏 + 整屏 OCR」兜底
 *   路径（CaptureService.maybeCapture 的空读分支），自动采集由此接管。会话标题
 *   由 targetFor 的微信分支（WeChatTitleState）处理，本快照 title=null。
 *
 * 已知边界（如实记录为行为，不是缺陷）：
 * - 空树分辨不了聊天窗与列表页：微信前台的所有窗口都会走整屏 OCR。同一屏由
 *   ocrSignature / snapshot.signature 去重，换窗（windowId 变）经 observeTarget
 *   重置后各采一次；列表页的 OCR 结果 provenance=ocr、带 unknown-speaker 置信度
 *   扣分与分边提示，由 Dart 侧决定怎么用。
 * - 微信支付与微信同包（com.tencent.mm），无法按包拆分拦阻（见 CaptureService
 *   底线清单 BLOCKED_PKG_KEYWORDS 的注释）——随微信的采集规则走。
 * - extract 不检查树的内容：一旦微信开始向无障碍发布真实节点树，本适配器的
 *   「空树」前提失效，需要像其他适配器升级一样重新取样（见
 *   ChatAppAdapterRulesContractTest ⑦ 的真机项约定）。
 */
class WeChatOcrAdapter : ChatAppAdapter {
    override val pkg = "com.tencent.mm"
    override val displayName = "微信"

    /** OCR 兜底是本适配器唯一的能力，运行时闸门与能力表保持一致（允许截屏）。 */
    override val allowScreenshot: Boolean get() = true

    override val capabilities = AdapterCapabilities(
        canReadMessages = false,
        canIdentifySender = false,
        canReadHistory = false,
        allowsOcrFallback = true,
        verifiedAppVersion = null,
    )

    /** 空快照随行的说明：正文来自截屏 OCR、分边不可靠。自动路径的空快照本身
     *  不发射（它只是 OCR 的触发器），这里主要作为适配器性质的随行文档。 */
    private val ocrNote =
        "微信不给无障碍节点树：这一屏的文字来自截屏 OCR，发言人分边不可靠，仅供参考。"

    override fun extract(root: AccessibilityNodeInfo, res: Resources): ChatSnapshot =
        ChatSnapshot(null, emptyList(), note = ocrNote)
}

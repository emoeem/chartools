package dev.chartools.capture

// 插件本地模型层：旧仓库 `com.jev.probe.core`（ChatModels / CapturePresence）与
// `com.jev.probe.core.ocr`（OcrEngine / OcrLine）里采集路径用到的 7 个类型，
// 类体从原文件逐字拷贝，只改包名。（Analysis / Choice / Score / RankedReply 属于
// jev 编排层，不在本插件的采集范围内，未移植。）

import android.graphics.Bitmap
import android.graphics.Rect

/**
 * 一条快照是从哪一层读到的 —— 能力阶梯的层号。
 *
 * 存在的理由是**可对拍**：同一个聊天页用不同层读出来的东西必须能逐条比，
 * 否则「注入层比无障碍准」只是一句没有证据的话。每一层都在 Trace 里留一行，
 * 分析卡片上显示当前用的是哪一层；降级（注入失败 → 无障碍）不是静默的。
 */
object Provenance {
    /** L0：无障碍节点树。默认路径，任何手机上都在。 */
    const val A11Y = "a11y"

    /** L0'：截屏 + OCR。树里读不到正文时用（微信/飞书自己画字）。 */
    const val OCR = "ocr"

    /** L1：注入层直接读到的会话数据。**可选**，默认关，试点 Telegram。 */
    const val INJECT = "inject"
}

/**
 * One captured chat bubble. side is "me" (right) or "other" (left).
 *
 * [id] / [at] / [sender] 只有注入层填得出来（无障碍节点树不提供消息身份，OCR
 * 更不提供）。默认值让 L0 路径一个字都不用改；S3 之后同一条时间线上的
 * 「同一条消息」才认得出来 —— 这是把两层的读数逐条对拍的前提。
 */
data class Msg(
    val side: String,
    val text: String,
    val id: String? = null,
    val at: Long = 0L,
    val sender: String? = null,
)

/**
 * A bubble the node tree can locate but not read (Feishu draws its message text
 * itself). [rect] is in screen coordinates; [side] is what the tree could infer
 * around the bubble. The service OCRs each rect to get the words.
 */
data class BubbleRect(val rect: Rect, val side: String)

/**
 * A snapshot of the currently-open conversation in whichever chat app is
 * foreground (see ChatAppAdapter).
 *
 * Adapter contract: `extract` returning null means "not in a chat window".
 * Returning a snapshot whose [messages] is empty means "in a chat window, but
 * the tree holds no text" — that is the OCR fallback's cue, and the one case
 * where [bubbleRects] may be populated.
 *
 * [note] is a caveat about how this snapshot was produced, shown verbatim in
 * the analysis panel (OCR captures cannot tell who said what).
 *
 * [provenance] 见 [Provenance]，默认 L0。抓取层（ChatCaptureService）在每一层
 * 的出口把它写对，Trace 里的 `provenance=` 与卡片上的标注都读这一个字段。
 *
 * [history] 是这一层能额外看到的、比当前屏更早的消息（注入层给得出，无障碍
 * 给不出）。留空就等于「只有当前屏」，也就是今天的全部行为。S3/S4 填它之后，
 * 回复提示词里的历史可以来自这里，而不是只能来自落盘的知识库。
 */
data class ChatSnapshot(
    val title: String?,
    val messages: List<Msg>,
    val bubbleRects: List<BubbleRect> = emptyList(),
    val note: String? = null,
    val provenance: String = Provenance.A11Y,
    val history: List<Msg> = emptyList()
) {
    val latestFrom: String? get() = messages.lastOrNull()?.side

    /** A stable signature of the last few messages, to detect real changes. */
    fun signature(): String =
        messages.takeLast(6).joinToString("|") { "${it.side}:${it.text}" }
}

/**
 * 本进程里有没有一个**活着的**无障碍采集服务实例。和 `enabled_accessibility_services`
 * 那一格是两件事：那一格只说"用户在设置里开着"，这里说的是"真的在跑"。
 *
 * 无障碍服务和本 App 的界面在同一个进程（清单里没写 `android:process`），
 * 所以这个信号就是主页和"一键修复"能拿到的最准的信号 —— 进程被杀后默认
 * false 也对（服务跟着死了）。
 *
 * 放在 core 是为了让 root（一键修复）不必 import capture：服务写入、工具只读。
 */
object CapturePresence {
    @Volatile
    var live: Boolean = false
        internal set
}

/** One recognized text line. [bounds] is in the coordinate space the caller
 * works in: screenshot pixels for capture, page pixels for document import. */
data class OcrLine(val text: String, val bounds: Rect)

/**
 * Text recognition over an image.
 *
 * [region] is in BITMAP coordinates (the caller scales node rects by the
 * screenshot's scaleX/scaleY); null means the whole bitmap. The callback is
 * delivered on the main thread and always fires — an engine failure comes back
 * as an empty list, never as an exception on the caller's thread.
 *
 * Lives under `core` so capture is not the only consumer: scanned-PDF import
 * (`core.kb.extract.PdfText`) needs the same abstraction, and a port here is
 * what keeps `core` from importing `capture` back. v1.3 has exactly one
 * implementation, [dev.chartools.capture.ocr.MlKitOcr]. The vision-model OCR is
 * deliberately NOT on this path (see docs/v1.3-plan.md, B stage revision).
 */
interface OcrEngine {
    fun recognize(bitmap: Bitmap, region: Rect?, cb: (List<OcrLine>) -> Unit)
}

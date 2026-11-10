package dev.chartools.capture

import dev.chartools.capture.ocr.OcrGrouping
import kotlin.test.Ignore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * G3 采集置信度的契约算术测试。Kotlin 侧唯一实现是 [snapshotConfidence]
 * （CaptureService.kt 尾部，纯函数）；[CaptureService.snapshotJson] 只负责把
 * 结果装进 JSON。通道契约写死：confidence 0.0..1.0（Dart 缺省视为 1.0），
 * uncertain 原因标签数组（可省略，Dart 缺省空表）。
 *
 * 标签即展示文案：Dart 侧（app/lib/application/capture_session.dart 的
 * uncertainReasonsOf）把标签原样透传上卡、不做映射，所以这里发中文。
 */
class SnapshotConfidenceContractTest {

    private fun snap(
        provenance: String = Provenance.A11Y,
        title: String? = "小美",
        messages: List<Msg> = listOf(Msg("other", "在吗")),
    ) = ChatSnapshot(title, messages, provenance = provenance)

    @Test
    fun a11yBaselineIsFullConfidenceWithoutLabels() {
        val (confidence, uncertain) = snapshotConfidence(snap())
        assertEquals(1.0, confidence)
        assertTrue(uncertain.isEmpty())
    }

    @Test
    fun ocrBaselineIsReducedButNotLabeled() {
        // 0.6 基线本身就是「来自像素」的表达，OCR 来源不再另发标签。
        val (confidence, uncertain) = snapshotConfidence(snap(provenance = Provenance.OCR))
        assertEquals(0.6, confidence, 1e-9)
        assertTrue(uncertain.isEmpty())
    }

    @Test
    fun everyUnknownSpeakerMessageDeductsOneTenth() {
        // side 既非 me 也非 other 即 unknown-speaker：整屏 OCR 的 "？"（无气泡
        // 盖住）与微信群归属不上的 "unknown" 都算；me/other 不扣。
        val messages = listOf(
            Msg(OcrGrouping.SIDE_UNKNOWN, "一"),
            Msg("unknown", "二"),
            Msg("other", "三"),
            Msg("me", "四"),
        )
        val (confidence, uncertain) =
            snapshotConfidence(snap(provenance = Provenance.OCR, messages = messages))
        assertEquals(0.4, confidence, 1e-9)
        assertEquals(listOf(UNCERTAIN_UNKNOWN_SPEAKER), uncertain)
    }

    @Test
    fun titledOcrWithSingleUnknownSpeakerSitsExactlyOnGateThreshold() {
        // 尖锐边界：OCR 基线 0.6 恰扣一条 unknown-speaker = 精确 0.5（双精度
        // 下 0.6-0.1 就是 0.5，不是 0.4999…）。p0-plan G3 要求「说话人不可
        // 归属 → 不自动分析」，所以 Dart 侧门控（CaptureSession.shouldConfirm）
        // 用 ≤：这个值必须停在待确认，不能贴线放行。数值契约钉在这里，
        // 门控比较语义钉在 app 的门控断言里，两侧对照读。
        val (confidence, uncertain) = snapshotConfidence(
            snap(
                provenance = Provenance.OCR,
                messages = listOf(Msg(OcrGrouping.SIDE_UNKNOWN, "一")),
            )
        )
        assertEquals(0.5, confidence, 1e-9)
        assertEquals(listOf(UNCERTAIN_UNKNOWN_SPEAKER), uncertain)
    }

    @Test
    fun missingTitleDeductsFivePointsAndLabels() {
        val (confidence, uncertain) = snapshotConfidence(snap(title = null))
        assertEquals(0.95, confidence, 1e-9)
        assertEquals(listOf(UNCERTAIN_MISSING_TITLE), uncertain)
        // 空白标题同罪（isBlank）。
        val (c2, u2) = snapshotConfidence(snap(title = "   "))
        assertEquals(0.95, c2, 1e-9)
        assertEquals(listOf(UNCERTAIN_MISSING_TITLE), u2)
    }

    @Test
    fun deductionsStackInContractOrder() {
        // 两个原因同时成立：先 unknown-speaker 后 missing_title（顺序即实现，
        // Dart 侧按「、」拼接展示）。
        val messages = listOf(Msg("?", "一"), Msg("me", "二"))
        val (confidence, uncertain) =
            snapshotConfidence(snap(provenance = Provenance.OCR, title = null, messages = messages))
        assertEquals(0.45, confidence, 1e-9)
        assertEquals(listOf(UNCERTAIN_UNKNOWN_SPEAKER, UNCERTAIN_MISSING_TITLE), uncertain)
    }

    @Test
    fun confidenceNeverDropsBelowFloor() {
        // OCR 基线 0.6，8 条 unknown → -0.2，钳到下限 0.2。
        val messages = (1..8).map { Msg("?", "第$it 条") }
        val (confidence, uncertain) =
            snapshotConfidence(snap(provenance = Provenance.OCR, messages = messages))
        assertEquals(0.2, confidence)
        assertEquals(listOf(UNCERTAIN_UNKNOWN_SPEAKER), uncertain)
    }

    @Test
    fun a11yPathAlsoDeductsIfSidesEverUnknown() {
        // 防御性：适配器路径恒 me/other，但算术对任何 provenance 一致。
        val (confidence, uncertain) = snapshotConfidence(snap(messages = listOf(Msg("?", "一"))))
        assertEquals(0.9, confidence, 1e-9)
        assertEquals(listOf(UNCERTAIN_UNKNOWN_SPEAKER), uncertain)
    }

    @Ignore("JSON 装配不可 JVM 单测：snapshotJson 用 org.json，android.jar 桩在 JVM 单测抛 " +
        "\"Stub!\"（本模块未引 Robolectric / org.json:json 测试依赖，build.gradle.kts 不在本次文件" +
        "所有权内）。预期断言（装机后补，或引依赖后转正）：快照 JSON 恒含数值型 confidence；" +
        "uncertain 仅在有原因时出现（无字段 = 空表）；Dart 侧 ChatSnapshot.fromJson 对旧 JSON " +
        "解析不破（confidence 缺省 1.0、uncertain 缺省空表——core 的解析测试已覆盖）。")
    @Test
    fun snapshotJsonEmitsConfidenceAndOptionalUncertain() {
    }
}

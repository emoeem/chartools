package dev.chartools.capture

import dev.chartools.capture.ocr.OcrGrouping
import kotlin.test.Ignore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 双端契约金样测试（kimi-review #17 + #21 的 Kotlin 侧）。
 *
 * 与 Dart 侧 packages/core/test/contract_golden_test.dart 互为镜像：两侧持有
 * **逐字节同内容**的快照 JSON 金样 [GOLDEN] —— 改其中一份必须先改另一份，让
 * 「契约变了」在评审里显式发生。Dart 侧把同一金样喂给 ChatSnapshot.fromJson
 * 断言解析；本侧做三件事：
 *
 * 1. 金样字段集断言：顶层键集恰为 [snapshotJson]（CaptureService 的发射函数）
 *    的契约六字段，messages 逐条恰为 {side,text}。org.json 在 JVM 单测里是抛
 *    "Stub!" 的桩（SnapshotConfidenceContractTest 尾注已记录），解析用测试本地
 *    的最小扫描器，不引新依赖。
 * 2. 金样 ↔ 生产算法绑定：同一份样例快照喂 [snapshotConfidence]，G3 两字段
 *    （confidence=0.5、uncertain=[发言人未知]）必须是算法真实产出，金样不许
 *    自说自话。样例值与 CaptureService 真实 OCR 路径对齐（OCR 基线 0.6 − 一条
 *    unknown-speaker 0.1 = 精确 0.5，恰为 G3 门控阈值）。
 * 3. 签名口径（kimi-review #21）：`Model.kt signature()` 与 Dart models.dart
 *    的 `signature()` 格式一致 —— 末 6 条、每条 `side:text`、`|` 连接，两端口径
 *    一致，允许跨端对拍；两侧钉死同一期望串 [GOLDEN_SIGNATURE]。
 *
 * B8 展示模式字符串（kimi-review #17b）的 Kotlin 侧断言不可 JVM 单测
 * （OverlayController 需 Context/WindowManager，MODE_PRIMARY 是 companion
 * 私有），见文末 @Ignore 占位；两端字面量的机器钳制落在 Dart 侧源码扫描测试。
 */
class SignatureContractTest {

    private companion object {
        /** 金样本体：与 Dart 侧 contract_golden_test.dart 的 goldenSnapshotJson
         *  逐字节同内容（互为镜像，改一份必改另一份）。样例按真实 OCR 路径装配：
         *  note 是 CaptureService 的 OCR_PARTIAL_NOTE 拼法；messages 只带
         *  side/text（snapshotJson 不序列化 id/at/sender/history）。 */
        const val GOLDEN =
            """{"title":"小美","note":"OCR 分边：有 1 条","provenance":"ocr","confidence":0.5,"uncertain":["发言人未知"],"messages":[{"side":"?","text":"在吗"},{"side":"me","text":"刚下班"},{"side":"other","text":"辛苦了"}]}"""

        /** 跨端签名期望串：与 Dart 侧 goldenSignature 同串（kimi-review #21
         *  的「两端口径一致，允许跨端对拍」的锚）。 */
        const val GOLDEN_SIGNATURE = "?:在吗|me:刚下班|other:辛苦了"
    }

    /** 金样对应的采集样例：CaptureService 真实 OCR 路径的形状（一条 unknown
     *  speaker、标题在）。GOLDEN 的 confidence/uncertain 必须是它算出来的。 */
    private val sample = ChatSnapshot(
        title = "小美",
        messages = listOf(
            Msg(OcrGrouping.SIDE_UNKNOWN, "在吗"),
            Msg("me", "刚下班"),
            Msg("other", "辛苦了"),
        ),
        note = "OCR 分边：有 1 条",
        provenance = Provenance.OCR,
    )

    // ---- ① 金样字段集：契约六字段，messages 恰为 {side,text} ----------------

    @Test
    fun goldenFieldSetIsExactlyTheSnapshotJsonContract() {
        // 顶层键集恰为六字段、顺序 = snapshotJson 的发射序（title/note/
        // provenance/confidence/uncertain?/messages，CaptureService.kt 的
        // snapshotJson kdoc）。snapshotJson 本身 JVM 不可调（org.json 桩），
        // 形状由金样字面量钉住；生产端漂移时改金样必过评审。Dart 侧对同一
        // 金样断言同一键序——两端同改才算改。
        assertEquals(
            listOf("title", "note", "provenance", "confidence", "uncertain", "messages"),
            topLevelMembers(GOLDEN).map { it.first },
        )
    }

    @Test
    fun goldenScalarValuesMatchTheSample() {
        val members = topLevelMembers(GOLDEN).toMap()
        assertEquals("小美", stringValue(members.getValue("title"), "title"))
        assertEquals("OCR 分边：有 1 条", stringValue(members.getValue("note"), "note"))
        assertEquals(Provenance.OCR, stringValue(members.getValue("provenance"), "provenance"))
    }

    @Test
    fun goldenMessagesAreSideTextPairsInOrder() {
        // 每条恰为 {"side":"…","text":"…"}：多字段/少字段/换键序/嵌套都进不了
        // 这个形状（msgShape 全量匹配）。
        assertEquals(
            listOf(
                OcrGrouping.SIDE_UNKNOWN to "在吗",
                "me" to "刚下班",
                "other" to "辛苦了",
            ),
            goldenMsgs(),
        )
    }

    // ---- ② 金样 ↔ 生产算法绑定 ---------------------------------------------

    @Test
    fun goldenConfidenceMatchesTheRealAlgorithm() {
        // 金样的 G3 两字段不许自说自话：同一份样例喂 snapshotConfidence
        // （SnapshotConfidenceContractTest 同款算术），0.6 基线 − 一条
        // unknown-speaker 0.1 = 精确 0.5（G3 门控阈值，Dart 侧 ≤ 放行语义）。
        val (confidence, uncertain) = snapshotConfidence(sample)
        assertEquals(0.5, confidence, 1e-9)
        assertEquals(listOf(UNCERTAIN_UNKNOWN_SPEAKER), uncertain)
        // 金样里的两字段与算法产出一致（金样是字符串字面量，算法是活代码）。
        val members = topLevelMembers(GOLDEN).toMap()
        assertEquals(0.5, members.getValue("confidence").toDouble(), 1e-9)
        assertEquals("[\"$UNCERTAIN_UNKNOWN_SPEAKER\"]", members.getValue("uncertain"))
    }

    // ---- ③ 签名口径（kimi-review #21）：两端口径一致，允许跨端对拍 ----------

    @Test
    fun signatureFormatMatchesDartCounterpart() {
        // 口径 = 末 6 条、每条 side:text、`|` 连接，与 Dart models.dart 的
        // signature() 逐字段一致（models.dart:142 的注释与本处互指）。期望串
        // 与 Dart 侧 goldenSignature 同串：任何一端改格式，两边测试同时红。
        assertEquals(GOLDEN_SIGNATURE, sample.signature())

        // 不足六条全取；多于六条取末六（与 Dart 的 skip(len-6) 等价）。
        val seven = ChatSnapshot("t", (0..6).map { Msg("me", "m$it") })
        assertEquals("me:m1|me:m2|me:m3|me:m4|me:m5|me:m6", seven.signature())
        val short = ChatSnapshot("t", listOf(Msg("other", "a"), Msg("me", "b")))
        assertEquals("other:a|me:b", short.signature())
        // 评审口径里的另一种历史写法（/ 连接）不许回潮。
        assertTrue(!short.signature().contains("/"))
    }

    @Test
    fun goldenMessagesProduceTheCrossEndSignature() {
        // 金样 ↔ 签名生产者绑定：从金样解析出的三条消息重建 ChatSnapshot，
        // 签名必须是跨端期望串（Dart 侧对同一金样断言同一串）。
        val rebuilt = ChatSnapshot(
            "小美",
            goldenMsgs().map { Msg(it.first, it.second) },
            provenance = Provenance.OCR,
        )
        assertEquals(GOLDEN_SIGNATURE, rebuilt.signature())
    }

    // ---- ④ B8 展示模式（kimi-review #17b）：JVM 不可达，占位 ----------------

    @Ignore("B8 展示模式的 Kotlin 侧断言不可 JVM 单测：OverlayController 需要 " +
        "Context/WindowManager（android.jar 桩抛 \"Stub!\"），MODE_PRIMARY 又是 " +
        "companion 私有（OverlayController.kt:674），反射读取依赖 const 编译布局、" +
        "不可靠，且本模块未引 Robolectric。两端字面量的机器钳制已落在 Dart 侧 " +
        "contract_golden_test.dart 的源码扫描（settings_store.displayModePrimary/All " +
        "↔ MODE_PRIMARY、通道键 mode 两侧同串）。转正条件：引 Robolectric 后实例化 " +
        "OverlayController，断言 showSuggestions(mode=\"primary\") 走主推分支、" +
        "其它值整列平铺。")
    @Test
    fun displayModePrimaryMirrorsDartConstant() {
    }

    // ---- 测试本地最小 JSON 扫描器（org.json 在 JVM 单测是桩，见类注释）------
    // 只服务 GOLDEN 这一行已知形状的 JSON；不是通用解析器，不处理转义体。

    /** 把一层 JSON 结构的同层成员按 depth-0 逗号切开：字符串字面量内与
     *  嵌套 {}/[] 里的逗号不切。 */
    private fun splitTopLevel(s: String): List<String> {
        val parts = ArrayList<String>()
        val cur = StringBuilder()
        var inString = false
        var escaped = false
        var depth = 0
        for (c in s) {
            when {
                escaped -> { cur.append(c); escaped = false }
                inString && c == '\\' -> { cur.append(c); escaped = true }
                c == '"' -> { inString = !inString; cur.append(c) }
                !inString && (c == '{' || c == '[') -> { depth++; cur.append(c) }
                !inString && (c == '}' || c == ']') -> { depth--; cur.append(c) }
                !inString && c == ',' && depth == 0 -> { parts.add(cur.toString()); cur.setLength(0) }
                else -> cur.append(c)
            }
        }
        parts.add(cur.toString())
        return parts.filter { it.isNotBlank() }
    }

    /** 剥掉首尾的一对包裹字符（{}/[]），并断言配对存在。 */
    private fun unwrapped(s: String, open: Char, close: Char): String {
        assertTrue(s.first() == open && s.last() == close, "包裹不符：$s")
        return s.substring(1, s.length - 1)
    }

    /** `"key":value` → (key, value)。键是纯标识符，取首个 `":` 作分界。 */
    private fun memberOf(part: String): Pair<String, String> {
        assertTrue(part.startsWith("\""), "成员应以键名引号开始：$part")
        val i = part.indexOf("\":")
        assertTrue(i >= 1, "成员缺 `\":` 分界：$part")
        return part.substring(1, i) to part.substring(i + 2)
    }

    /** 顶层对象的同层成员（键 → 原始值串，字符串值含引号）。 */
    private fun topLevelMembers(json: String): List<Pair<String, String>> =
        splitTopLevel(unwrapped(json, '{', '}')).map { memberOf(it) }

    /** 断言成员值是 JSON 字符串并剥引号返回；金样字符串值不含转义，
     *  出现反斜杠即失败（最小扫描器的约定）。 */
    private fun stringValue(raw: String, field: String): String {
        assertTrue(raw.length >= 2 && raw.first() == '"' && raw.last() == '"',
            "$field 应为 JSON 字符串：$raw")
        val body = raw.substring(1, raw.length - 1)
        assertTrue(!body.contains("\\"), "$field 不应含转义：$raw")
        return body
    }

    /** 金样 messages 数组的逐条 (side, text)；条目形状由 [msgShape] 全量钉死。 */
    private fun goldenMsgs(): List<Pair<String, String>> {
        val messagesRaw = topLevelMembers(GOLDEN).toMap().getValue("messages")
        val entries = splitTopLevel(unwrapped(messagesRaw, '[', ']'))
        assertEquals(3, entries.size, "金样 messages 应为三条")
        return entries.map { entry ->
            val m = checkNotNull(msgShape.matchEntire(entry)) {
                "message 条目形状不符（应恰为 {side,text}）：$entry"
            }
            m.groupValues[1] to m.groupValues[2]
        }
    }

    /** message 对象的完整形状：恰为 {"side":"…","text":"…"}，多字段/少字段/
     *  换键序/嵌套都不匹配（snapshotJson 只发 side,text）。matchEntire =
     *  全量匹配，无需再锚 ^$。 */
    private val msgShape =
        Regex("""\{"side":"((?:[^"\\]|\\.)*)","text":"((?:[^"\\]|\\.)*)"\}""")
}

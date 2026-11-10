package dev.chartools.capture

import android.content.res.Resources
import android.graphics.Rect
import android.util.DisplayMetrics
import android.view.accessibility.AccessibilityNodeInfo
import dev.chartools.capture.ocr.OcrGrouping
import org.mockito.Mockito
import kotlin.test.Ignore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * 适配器规则契约测试（p0-plan G4 的 Kotlin 部分）：窗口识别 / 消息解析 /
 * 发送者识别 / 空窗口 / OCR 兜底 / 输入框歧义 / 应用升级 七项验收，对六个
 * 适配器逐项钉住各自头注释记录的规则与真机取样行为。此前本模块没有规则级
 * 测试（仅 BubbleSnapTest / CaptureAndroidPluginTest），本文件是第一份；另附
 * G2 能力表与运行时闸门的一致性钳制。
 *
 * 测试基建的两个决定（都在本机验证过）：
 * - `android.graphics.Rect` 在 JVM 单测里是抛 "Stub!" 的 final 桩类，而生产
 *   代码在 extract 内部自己 `Rect()`。用 Mockito 5 默认的 inline mock maker
 *   的 mockConstruction 拦截构造，把 width/height/centerX 接回公共字段的算术
 *   （字段是真字节码字段，不受桩影响）——见 [withLiveRects]。节点树用声明式
 *   [N] 挂成 AccessibilityNodeInfo 桩。
 * - WhatsApp 的规则本体（[WhatsAppRules] / [WaNode]）刻意无 Android 依赖，
 *   直接喂纯数据树，不进 mock 基建。
 *
 * 不能 JVM 单测的项写成 @Ignore（真机项），说明里写清复验什么、通过后把
 * verifiedAppVersion 更新成什么。
 */
class ChatAppAdapterRulesContractTest {

    // ---- 脚手架 ----------------------------------------------------------

    /**
     * 一个无障碍节点的声明，只含适配器读得着的字段。bounds = [l, t, r, b]
     * （屏幕坐标）；宽 1080 高 2376 与 QQ/TIM/Telegram 取样机型一致。
     */
    private class N(
        val id: String? = null,
        val text: String? = null,
        val desc: String? = null,
        val cls: String? = null,
        val bounds: IntArray? = null,
        val children: List<N> = emptyList(),
        val editable: Boolean = false,
        val scrollable: Boolean = false,
        val visible: Boolean = true,
        val enabled: Boolean = true,
        val password: Boolean = false,
    )

    /** 把声明挂成 Mockito 桩树；getBoundsInScreen 把值写进调用方传入的
     *  （被拦截构造的）Rect 的公共字段。未给 bounds 的节点读界得到全 0。 */
    private fun N.toNode(): AccessibilityNodeInfo {
        val m = Mockito.mock(AccessibilityNodeInfo::class.java)
        id?.let { Mockito.`when`(m.viewIdResourceName).thenReturn(it) }
        text?.let { Mockito.`when`(m.text).thenReturn(it) }
        desc?.let { Mockito.`when`(m.contentDescription).thenReturn(it) }
        cls?.let { Mockito.`when`(m.className).thenReturn(it) }
        Mockito.`when`(m.isEditable).thenReturn(editable)
        Mockito.`when`(m.isVisibleToUser).thenReturn(visible)
        Mockito.`when`(m.isEnabled).thenReturn(enabled)
        Mockito.`when`(m.isPassword).thenReturn(password)
        Mockito.`when`(m.isScrollable).thenReturn(scrollable)
        Mockito.`when`(m.childCount).thenReturn(children.size)
        Mockito.`when`(m.getChild(Mockito.anyInt())).thenAnswer { inv ->
            children.getOrNull(inv.getArgument<Int>(0))?.toNode()
        }
        bounds?.let { b ->
            Mockito.doAnswer { inv ->
                val r: Rect = inv.getArgument(0)
                r.left = b[0]; r.top = b[1]; r.right = b[2]; r.bottom = b[3]
                null
            }.`when`(m).getBoundsInScreen(Mockito.any())
        }
        return m
    }

    /** 在 Rect 构造被拦截的作用域里跑一段代码；所有 `Rect()` 都拿到字段可写、
     *  width/height/centerX 正确的实例（android.jar 桩的构造在 JVM 抛 Stub!）。 */
    private fun <T> withLiveRects(block: () -> T): T =
        Mockito.mockConstruction(Rect::class.java) { mock, _ ->
            Mockito.`when`(mock.width()).thenAnswer { inv -> (inv.mock as Rect).let { it.right - it.left } }
            Mockito.`when`(mock.height()).thenAnswer { inv -> (inv.mock as Rect).let { it.bottom - it.top } }
            Mockito.`when`(mock.centerX()).thenAnswer { inv -> (inv.mock as Rect).let { (it.left + it.right) / 2 } }
        }.use { block() }

    /** 1080×2376（取样机型带宽）。 */
    private fun res(w: Int = 1080, h: Int = 2376): Resources {
        val dm = Mockito.mock(DisplayMetrics::class.java)
        dm.widthPixels = w
        dm.heightPixels = h
        val r = Mockito.mock(Resources::class.java)
        Mockito.`when`(r.displayMetrics).thenReturn(dm)
        return r
    }

    private fun extractOf(adapter: ChatAppAdapter, root: N, w: Int = 1080, h: Int = 2376): ChatSnapshot? =
        withLiveRects { adapter.extract(root.toNode(), res(w, h)) }

    /** WhatsAppRules.read 的纯数据树节点（WaNode 是它专为无设备单测设的接口）。 */
    private class WN(
        override val viewId: String? = null,
        override val text: String? = null,
        val box: IntArray = intArrayOf(0, 0, 0, 0),
        override val isScrollable: Boolean = false,
        private val kids: List<WN> = emptyList(),
    ) : WaNode {
        override val bounds: IntArray get() = box
        override val childCount: Int get() = kids.size
        override fun child(i: Int): WaNode? = kids.getOrNull(i)
    }

    /** 一条 WhatsApp 消息行：行类型 id + 气泡矩形 + 正文；extraKids 放 status/icon。 */
    private fun waRow(rowId: String, left: Int, right: Int, body: String, vararg extraKids: WN): WN =
        WN(rowId, kids = listOf(
            WN("com.whatsapp:id/main_layout", box = intArrayOf(left, 100, right, 200)),
            WN("com.whatsapp:id/message_text", text = body),
        ) + extraKids.toList())

    /** WhatsApp 1:1 会话页：联系人名 + 输入框 + 可滚动消息列表（read 的入场条件）。 */
    private fun waPage(list: WN): WN = WN(kids = listOf(
        WN("com.whatsapp:id/conversation_contact_name", text = "Alice"),
        WN("com.whatsapp:id/entry"),
        list,
    ))

    // ---- ① 窗口识别：不是聊天窗 → null（服务什么都不做）；是聊天窗 → 非空 ----

    @Test
    fun windowRecognition_qq_listScreenWithoutInputBoxIsNull() {
        // 列表页只有标题/昵称类节点：没有 id/input 也没有气泡
        // （QQAdapter 类注释：「No input box → not a chat → null」）。
        val list = N(children = listOf(
            N(id = "com.tencent.mobileqq:id/371", text = "消息"),
            N(id = "com.tencent.mobileqq:id/mjq", text = "张三", bounds = intArrayOf(80, 100, 200, 140)),
        ))
        assertNull(extractOf(QQAdapter(), list))
    }

    @Test
    fun windowRecognition_qq_inputBoxProvesChatWindow() {
        // SplashActivity 单窗口架构：「在不在聊天窗」只能由树回答，id/input 是判据。
        val chat = N(children = listOf(
            N(id = "com.tencent.mobileqq:id/input", bounds = intArrayOf(0, 2100, 1080, 2200)),
        ))
        assertNotNull(extractOf(QQAdapter(), chat))
    }

    @Test
    fun windowRecognition_tim_inputAloneIsNotAChatWindow() {
        // id/input 单独出现不算（未知列表页的搜索框可能复用同 id，误触发 OCR
        // 兜底）：无气泡时还须有 id/fun_btn 组成 composer（TimAdapter 类注释）。
        val inputOnly = N(children = listOf(
            N(id = "com.tencent.tim:id/input", bounds = intArrayOf(0, 2100, 1080, 2200)),
        ))
        assertNull(extractOf(TimAdapter(), inputOnly))
    }

    @Test
    fun windowRecognition_tim_inputPlusComposerProvesChatWindow() {
        val chat = N(children = listOf(
            N(id = "com.tencent.tim:id/input", bounds = intArrayOf(0, 2100, 1080, 2200)),
            N(id = "com.tencent.tim:id/fun_btn", bounds = intArrayOf(980, 2100, 1080, 2200)),
        ))
        assertNotNull(extractOf(TimAdapter(), chat))
    }

    @Test
    fun windowRecognition_telegram_topSearchBoxIsNotAComposer() {
        // 聊天列表的搜索框也是 EditText，但在屏幕上部（< 0.6H）；composer 只在
        // 下部（TelegramAdapter 类注释的 y-band 判据，不依赖本地化 hint）。
        val list = N(children = listOf(
            N(cls = "android.widget.EditText", text = "搜索", bounds = intArrayOf(0, 80, 1080, 160)),
        ))
        assertNull(extractOf(TelegramAdapter(), list))
    }

    @Test
    fun windowRecognition_telegram_bottomComposerProvesChatWindow() {
        val chat = N(children = listOf(
            N(cls = "android.widget.EditText", bounds = intArrayOf(0, 2200, 1080, 2300)),
        ))
        assertNotNull(extractOf(TelegramAdapter(), chat))
    }

    @Test
    fun windowRecognition_whatsapp_needsContactNamePlusEntry() {
        // 会话页 = 顶栏联系人名 + 输入框，缺一即 null（WhatsAppRules.read）。
        assertNull(WhatsAppRules.read(WN(kids = listOf(
            WN("com.whatsapp:id/conversation_contact_name", text = "Alice"),
        ))))
        assertNull(WhatsAppRules.read(WN(kids = listOf(
            WN("com.whatsapp:id/entry"),
        ))))
    }

    @Test
    fun windowRecognition_whatsapp_groupChatsAreNotAChatWindow() {
        // 群聊整页返回 null：服务把它当「不在聊天窗」处理（只读 1:1，类注释）。
        val group = WN(kids = listOf(
            WN("com.whatsapp:id/conversation_contact_name", text = "群"),
            WN("com.whatsapp:id/entry"),
            WN("com.whatsapp:id/name_in_group"),
        ))
        assertNull(WhatsAppRules.read(group))
    }

    @Test
    fun windowRecognition_x_dmListIsNeverAThread() {
        // 「新私信」按钮是 DM 列表的铁证，优先于一切形状证据——即使列表里
        // 有行形状和搜索框也不算线程（XAdapter extract 的第一道闸）。
        val list = N(children = listOf(
            N(desc = "新私信"),
            N(cls = "android.widget.EditText", bounds = intArrayOf(0, 2200, 1080, 2300)),
            N(cls = "android.view.View", desc = "All-In：你好", bounds = intArrayOf(0, 400, 1080, 460)),
        ))
        assertNull(extractOf(XAdapter(), list))
    }

    @Test
    fun windowRecognition_x_listHeadingWithNoRowsIsNotAThread() {
        // 「聊天/Messages」标题 + 无行：DM 列表的第二组显式证据（搜索框的
        // EditText 单独出现不再误判——那是修过的误触发）。
        val list = N(children = listOf(
            N(cls = "android.widget.TextView", text = "聊天", bounds = intArrayOf(0, 100, 300, 160)),
            N(cls = "android.widget.EditText", bounds = intArrayOf(0, 2200, 1080, 2300)),
        ))
        assertNull(extractOf(XAdapter(), list))
    }

    @Test
    fun windowRecognition_feishu_chatProvenByAnyOfTheThreeIds() {
        val notChat = N(children = listOf(
            N(cls = "android.widget.TextView", text = "设置", bounds = intArrayOf(0, 100, 300, 160)),
        ))
        assertNull(extractOf(FeishuAdapter(), notChat))

        // id/message 是 isChat 的三个来源之一（另两个：气泡容器、输入框）。
        val chat = N(children = listOf(
            N(id = "com.ss.android.lark:id/message"),
            N(id = "com.ss.android.lark:id/group_name", text = "产品群"),
        ))
        assertNotNull(extractOf(FeishuAdapter(), chat))
    }

    // ---- ② 消息解析：行/描述 → 正文，顺序保持，chrome 不混入 ----

    @Test
    fun messageParsing_qq_bodiesInOrderWithTitleFallback() {
        // 只收 id/mjn（时间戳、昵称 id/mjq、系统条全排除）；标题 id 缺席时退回
        // 顶栏居中短文本（findTitleInActionBar 契约：firstBubbleTop 之上）。
        val root = N(children = listOf(
            N(cls = "android.widget.TextView", text = "张三", bounds = intArrayOf(300, 20, 780, 68)),
            N(id = "com.tencent.mobileqq:id/mjq", text = "小明", bounds = intArrayOf(80, 380, 200, 420)),
            N(id = "com.tencent.mobileqq:id/mjn", text = "今晚一起吃饭吗？", bounds = intArrayOf(140, 400, 700, 460)),
            N(id = "com.tencent.mobileqq:id/mjn", text = "好，老地方", bounds = intArrayOf(600, 500, 940, 560)),
            N(id = "com.tencent.mobileqq:id/input", bounds = intArrayOf(0, 2100, 1080, 2200)),
        ))
        val snap = assertNotNull(extractOf(QQAdapter(), root))
        assertEquals("张三", snap.title)
        assertEquals(listOf("今晚一起吃饭吗？", "好，老地方"), snap.messages.map { it.text })
    }

    @Test
    fun messageParsing_tim_collapsedSliverRowsAreDropped() {
        // 滚出 RecyclerView 的行保持节点但塌成 1px；真气泡永不退化（类注释），
        // 尺寸校验把塌缩行扔掉。
        val root = N(children = listOf(
            N(id = "com.tencent.tim:id/9u", text = "真实消息", bounds = intArrayOf(134, 400, 809, 460)),
            N(id = "com.tencent.tim:id/9u", text = "塌缩的行", bounds = intArrayOf(134, 300, 134, 300)),
        ))
        val snap = assertNotNull(extractOf(TimAdapter(), root))
        assertEquals(listOf("真实消息"), snap.messages.map { it.text })
    }

    @Test
    fun messageParsing_telegram_documentedRowSamples() {
        // 三个真机样本（TelegramAdapter 类注释，12.10.1 zh）：最后一行的状态行
        // 决定「是不是消息行」与左右；正文剥掉状态行。
        val other = telegramParseCell("媛媛 王 带有管理员标签：所有者\n然后？\n已收到 于 11:49:26 27514\n")
        assertEquals("other", other?.side)
        assertEquals(listOf("媛媛 王 带有管理员标签：所有者", "然后？"), other?.lines)

        val mine = telegramParseCell("那好啊，到时候撸给你\n已发送于 于 11:50:38 27520, 已读\n")
        assertEquals("me", mine?.side)
        assertEquals(listOf("那好啊，到时候撸给你"), mine?.lines)

        val sticker = telegramParseCell("哈 哈\n🤔 贴纸\n已收到 于 11:53\n")
        assertEquals("other", sticker?.side)
        assertEquals(listOf("哈 哈", "🤔 贴纸"), sticker?.lines)

        // 无状态行的行不是消息（日期分隔条、composer、tab……）。
        assertNull(telegramParseCell("2026年11月11日"))
        assertNull(telegramParseCell("单行"))
    }

    @Test
    fun messageParsing_whatsapp_textRowsKeptDeletedStubsDropped() {
        val list = WN("android:id/list", isScrollable = true,
            box = intArrayOf(0, 0, 1080, 2000),
            kids = listOf(
                waRow("com.whatsapp:id/conversation_row_text", 40, 500, "hi"),
                // 已删除消息占位：非文本行类型 + icon → UI 文案而非消息，丢弃。
                waRow("com.whatsapp:id/conversation_row_media", 40, 500, "此消息已删除",
                    WN("com.whatsapp:id/icon")),
            ))
        val read = assertNotNull(WhatsAppRules.read(waPage(list)))
        assertEquals(listOf("hi"), read.messages.map { it.text })
        assertEquals("Alice", read.title)
    }

    @Test
    fun messageParsing_x_documentedDescSamples() {
        // XAdapter 类注释的真机样本（12.25.2 zh）：发送者取第一个分隔符之前，
        // 尾部的回执/时间/「。」粘合按序剥掉；用户自己打的标点（是吗？）保留。
        val root = N(children = listOf(
            N(cls = "android.widget.EditText", bounds = intArrayOf(0, 2200, 1080, 2300)),
            N(cls = "android.view.View", desc = "All-In：重新写了一个😂。10:29 下午。",
                bounds = intArrayOf(0, 400, 1080, 460)),
            N(cls = "android.view.View", desc = "你：你这个说的就是那个虚拟人物，是吗？。8:11 上午。Read。",
                bounds = intArrayOf(0, 500, 1080, 560)),
            N(cls = "android.view.View", desc = "你：他这个东西开源应该问题不大。。。Read。",
                bounds = intArrayOf(0, 600, 1080, 660)),
            N(cls = "android.view.View", desc = "All-In：附加的帖子。。",
                bounds = intArrayOf(0, 700, 1080, 760)),
        ))
        val snap = assertNotNull(extractOf(XAdapter(), root))
        assertEquals(
            listOf("重新写了一个😂", "你这个说的就是那个虚拟人物，是吗？",
                "他这个东西开源应该问题不大", "附加的帖子"),
            snap.messages.map { it.text })
    }

    @Test
    fun messageParsing_feishu_bareTextViewBodiesInBand() {
        // 正文是裸 TextView（无 id）；chrome（标题/发送者/时间/系统条/输入框）
        // 被 isChrome 排除，时间戳被 looksLikeTimestamp 排除；聊天带外（顶栏
        // 14% 以下、输入区以上）不收。
        val root = N(children = listOf(
            N(id = "com.ss.android.lark:id/message"),
            N(id = "com.ss.android.lark:id/group_name", text = "产品群"),
            N(id = "com.ss.android.lark:id/name_tv", cls = "android.widget.TextView",
                text = "小美", bounds = intArrayOf(80, 380, 200, 420)),
            N(id = "com.ss.android.lark:id/date_tv", cls = "android.widget.TextView",
                text = "10:30", bounds = intArrayOf(400, 390, 560, 430)),
            N(cls = "android.widget.TextView", text = "晚上吃什么", bounds = intArrayOf(80, 430, 400, 470)),
            N(cls = "android.widget.TextView", text = "火锅", bounds = intArrayOf(800, 630, 1000, 670)),
        ))
        val snap = assertNotNull(extractOf(FeishuAdapter(), root))
        assertEquals(listOf("晚上吃什么", "火锅"), snap.messages.map { it.text })
        assertEquals("产品群", snap.title)
    }

    // ---- ③ 发送者识别：每条消息的 me/other 归属规则 ----

    @Test
    fun senderAttribution_qq_avatarEdgeNotCenter() {
        // 长消息中心会过中线，中心判定把对方读成自己；比较的是贴哪个头像列
        // （QQAdapter 类注释的回归）。1080 宽：头像列 ≈140。
        val root = N(children = listOf(
            N(id = "com.tencent.mobileqq:id/mjn", text = "对方长消息", bounds = intArrayOf(140, 400, 1000, 460)),
            N(id = "com.tencent.mobileqq:id/mjn", text = "我的消息", bounds = intArrayOf(600, 500, 940, 560)),
        ))
        val snap = assertNotNull(extractOf(QQAdapter(), root))
        assertEquals(listOf("other", "me"), snap.messages.map { it.side })
    }

    @Test
    fun senderAttribution_tim_nickLineAboveBeatsGeometry() {
        // 昵称行只画在别人的消息上方（TIM 对自己的消息隐藏昵称）：右钉边的
        // 气泡本会被几何判成「我」，正上方 40px 有昵称 → 对方赢（NICK_GAP_MAX=60）。
        val root = N(children = listOf(
            N(id = "com.tencent.tim:id/9w", text = "小王", bounds = intArrayOf(700, 540, 800, 560)),
            N(id = "com.tencent.tim:id/9u", text = "好的马上", bounds = intArrayOf(700, 600, 1075, 650)),
            N(id = "com.tencent.tim:id/9u", text = "在路上", bounds = intArrayOf(134, 700, 809, 750)),
            N(id = "com.tencent.tim:id/9u", text = "我也出发", bounds = intArrayOf(700, 800, 1075, 850)),
        ))
        val snap = assertNotNull(extractOf(TimAdapter(), root))
        assertEquals(listOf("other", "other", "me"), snap.messages.map { it.side })
    }

    @Test
    fun senderAttribution_tim_pinnedEdgeGeometryDecides() {
        // 取样几何（OnePlus PJE110，1080 宽）：左 gutter 134≈12.4%，右钉边
        // 1075=宽−5，容差 ~10px。按「哪个边被钉住」判定，不按中心（timSide 注释）。
        assertEquals("other", timSide(134, 809, 1080))
        assertEquals("me", timSide(300, 1075, 1080))
        // 长消息过中线仍按钉边（回归：中心判定曾把长对方消息读成自己）。
        assertEquals("other", timSide(134, 900, 1080))
        // 两边都没钉：更近的 gutter 决定。
        assertEquals("other", timSide(200, 880, 1080))
        assertEquals("me", timSide(240, 1070, 1080))
        // 触到两条 gutter 的满宽气泡（TIM 布局下不应发生）：退回中心判定。
        assertEquals("me", timSide(134, 1075, 1080))
    }

    @Test
    fun senderAttribution_telegram_sideFromStatusLineAndGroupProof() {
        // 状态行动词定左右；两条对方行以同一人开头 → 群证据成立 → 剥首行昵称；
        // 自己的行永远不剥（telegramNameHeadersInUse 的两份独立证明之二）。
        val root = N(children = listOf(
            N(cls = "android.widget.TextView", text = "测试群", bounds = intArrayOf(440, 20, 640, 68)),
            N(cls = "android.view.View",
                text = "媛媛 王 带有管理员标签：所有者\n然后？\n已收到 于 11:49:26 27514\n",
                bounds = intArrayOf(0, 400, 1080, 520)),
            N(cls = "android.view.View",
                text = "那好啊，到时候撸给你\n已发送于 于 11:50:38 27520, 已读\n",
                bounds = intArrayOf(0, 540, 1080, 620)),
            N(cls = "android.view.View",
                text = "媛媛 王 带有管理员标签：所有者\n好的\n已收到 于 11:55 27530\n",
                bounds = intArrayOf(0, 640, 1080, 760)),
            N(cls = "android.widget.EditText", bounds = intArrayOf(0, 2200, 1080, 2300)),
        ))
        val snap = assertNotNull(extractOf(TelegramAdapter(), root))
        assertEquals(listOf("然后？", "那好啊，到时候撸给你", "好的"), snap.messages.map { it.text })
        assertEquals(listOf("other", "me", "other"), snap.messages.map { it.side })
    }

    @Test
    fun senderAttribution_telegram_oneOnOneKeepsItsFirstLine() {
        // 1:1 的多行消息绝不能丢首行：没有群证据（首行不重复、不等于标题）就不剥。
        val cells = listOf(
            TgCell("other", listOf("今天去了那家新的面馆，排队一小时", "味道还行")),
            TgCell("me", listOf("下次带我去")),
        )
        assertFalse(telegramNameHeadersInUse(cells, "小美"))
        // 反例：首行与标题相同（1:1 对方首行报名）或出现两次 → 剥。
        assertTrue(telegramNameHeadersInUse(
            listOf(TgCell("other", listOf("小美", "在吗")), TgCell("me", listOf("嗯"))), "小美"))
        assertTrue(telegramNameHeadersInUse(
            listOf(TgCell("other", listOf("小美", "在吗")), TgCell("other", listOf("小美", "好"))), null))
    }

    @Test
    fun senderAttribution_whatsapp_marginDecidesStatusIconContradicts() {
        // 气泡（main_layout）贴谁那侧的 gutter 就是谁；回执图标只在自己消息上，
        // 贴左却带图标的那行丢弃而非猜测（readRow）。
        val list = WN("android:id/list", isScrollable = true,
            box = intArrayOf(0, 0, 1080, 2000),
            kids = listOf(
                waRow("com.whatsapp:id/conversation_row_text", 40, 500, "对方"),
                waRow("com.whatsapp:id/conversation_row_text", 700, 1060, "我"),
                waRow("com.whatsapp:id/conversation_row_text", 40, 500, "矛盾行",
                    WN("com.whatsapp:id/status")),
            ))
        val read = assertNotNull(WhatsAppRules.read(waPage(list)))
        assertEquals(listOf("对方", "我"), read.messages.map { it.text })
        assertEquals(listOf("other", "me"), read.messages.map { it.side })
    }

    @Test
    fun senderAttribution_x_youLabelMeansMineOthersMeanIncoming() {
        // X 的行全宽，几何无用；分边只认发送者标签「你/You」（XAdapter 类注释）。
        val root = N(children = listOf(
            N(cls = "android.widget.EditText", bounds = intArrayOf(0, 2200, 1080, 2300)),
            N(cls = "android.view.View", desc = "你：好", bounds = intArrayOf(0, 400, 1080, 460)),
            N(cls = "android.view.View", desc = "All-In：好", bounds = intArrayOf(0, 500, 1080, 560)),
        ))
        val snap = assertNotNull(extractOf(XAdapter(), root))
        assertEquals(listOf("me", "other"), snap.messages.map { it.side })
    }

    @Test
    fun senderAttribution_feishu_readStateStripMarksMine() {
        // 只有我的气泡挂回执条（collectFeishuBubbleRects → feishuHasReadState）。
        // 注意：FeishuAdapter 类注释明说该规则未真机验证——能力表
        // canIdentifySender=false 与此一致，这里钉的是「规则的当前形状」。
        val root = N(children = listOf(
            N(id = "com.ss.android.lark:id/bubble_content_container", bounds = intArrayOf(0, 400, 700, 520),
                children = listOf(
                    N(id = "com.ss.android.lark:id/time_read_state_container_align_bubble"))),
            N(id = "com.ss.android.lark:id/bubble_content_container", bounds = intArrayOf(0, 600, 700, 720)),
        ))
        val rects = withLiveRects { collectFeishuBubbleRects(root.toNode(), res()) }
        assertEquals(listOf("me", "other"), rects.map { it.side })
    }

    // ---- ④ 空窗口：在聊天窗里但树上没字 → 空快照（OCR 兜底的引子），不是 null ----

    @Test
    fun emptyWindow_qqInChatWithoutBodiesIsEmptySnapshot() {
        val chat = N(children = listOf(
            N(id = "com.tencent.mobileqq:id/371", text = "张三"),
            N(id = "com.tencent.mobileqq:id/input", bounds = intArrayOf(0, 2100, 1080, 2200)),
        ))
        val snap = assertNotNull(extractOf(QQAdapter(), chat))
        assertTrue(snap.messages.isEmpty())
        assertEquals("张三", snap.title)
    }

    @Test
    fun emptyWindow_timInChatWithoutBodiesIsEmptySnapshot() {
        val chat = N(children = listOf(
            N(id = "com.tencent.tim:id/input", bounds = intArrayOf(0, 2100, 1080, 2200)),
            N(id = "com.tencent.tim:id/fun_btn", bounds = intArrayOf(980, 2100, 1080, 2200)),
        ))
        assertTrue(assertNotNull(extractOf(TimAdapter(), chat)).messages.isEmpty())
    }

    @Test
    fun emptyWindow_telegramInChatWithoutBodiesIsEmptySnapshot() {
        val chat = N(children = listOf(
            N(cls = "android.widget.EditText", bounds = intArrayOf(0, 2200, 1080, 2300)),
        ))
        assertTrue(assertNotNull(extractOf(TelegramAdapter(), chat)).messages.isEmpty())
    }

    @Test
    fun emptyWindow_xEmptyThreadWithPlaceholderIsEmptySnapshot() {
        // 空线程带「私信」占位文本（列表屏没有）：hasInput + 占位 → 空快照。
        val thread = N(children = listOf(
            N(cls = "android.widget.EditText", bounds = intArrayOf(0, 2200, 1080, 2300)),
            N(cls = "android.widget.TextView", text = "私信", bounds = intArrayOf(300, 1200, 700, 1260)),
        ))
        assertTrue(assertNotNull(extractOf(XAdapter(), thread)).messages.isEmpty())
    }

    @Test
    fun emptyWindow_feishuInChatWithoutBodiesIsEmptySnapshotWithRects() {
        // 飞书在聊天窗但树里没字是常态（正文自己画）→ 空快照 + 气泡矩形，
        // 这是它唯一的 OCR 兜底形态（ChatSnapshot 契约：只有空快照可带 rects）。
        val chat = N(children = listOf(
            N(id = "com.ss.android.lark:id/kb_rich_text_content", bounds = intArrayOf(0, 2100, 1080, 2200)),
            N(id = "com.ss.android.lark:id/group_name", text = "产品群"),
            N(id = "com.ss.android.lark:id/bubble_content_container", bounds = intArrayOf(0, 400, 700, 520)),
        ))
        val snap = assertNotNull(extractOf(FeishuAdapter(), chat))
        assertTrue(snap.messages.isEmpty())
        assertEquals(1, snap.bubbleRects.size)
    }

    @Test
    fun emptyWindow_whatsappReturnsNullInsteadOfEmpty() {
        // WhatsApp 契约相反：空快照会触发截屏 OCR，而 WhatsApp 永不截屏 →
        // 读不到文字就 null（WhatsAppAdapter 类注释）。
        assertNull(WhatsAppRules.read(waPage(
            WN("android:id/list", isScrollable = true, box = intArrayOf(0, 0, 1080, 2000)))))
    }

    // ---- ⑤ OCR 兜底：各适配器交给服务的引子与禁区 ----

    @Test
    fun ocrFallback_whatsappNeverScreenshots() {
        // 永不截屏：自动兜底与手动「截屏识别一次」都拦（manualOcr 读这一闸）。
        assertFalse(WhatsAppAdapter().allowScreenshot)
        assertFalse(WhatsAppAdapter().capabilities.allowsOcrFallback)
    }

    @Test
    fun ocrFallback_flatScreenWithoutBubblesIsUnknownSpeaker() {
        // 整屏 OCR：没有像素气泡盖住的行 → side 未知（OcrGrouping.SIDE_UNKNOWN），
        // 有气泡盖住则按气泡。未知 side 正是 G3 置信度 unknown-speaker 扣分的输入。
        withLiveRects {
            fun line(text: String, top: Int, bottom: Int): OcrLine {
                val r = Rect(); r.left = 0; r.right = 900; r.top = top; r.bottom = bottom
                return OcrLine(text, r)
            }
            val msgs = OcrGrouping.group(
                listOf(line("在吗", 400, 450), line("刚下班", 600, 650)), emptyList())
            assertEquals(listOf("在吗", "刚下班"), msgs.map { it.text })
            assertTrue(msgs.all { it.side == OcrGrouping.SIDE_UNKNOWN })

            val box = WeChatBubbles.Box(0, 380, 500, 470, "other")
            assertEquals("other", OcrGrouping.sideFor(400, 450, listOf(box)))
            assertEquals(OcrGrouping.SIDE_UNKNOWN, OcrGrouping.sideFor(600, 650, listOf(box)))
        }
    }

    @Ignore("真机项：服务侧 OCR 闸门——EMPTY_READ_GRACE_MS（TIM msgs=8→0→一帧空读触发截屏" +
        "硬造对话的回归）、ScreenCapture 的 ≥1s 节流与失败退避、OCR 签名去重——都需要活的无障碍" +
        "服务 + MediaProjection + 真实事件流，JVM 单测不可达。回归路径：真机在 TIM 打开群聊滚动，" +
        "看 Trace 的 `cap empty read held` / `ocr` 行。")
    @Test
    fun ocrFallback_serviceSideGatesNeedLiveService() {
    }

    // ---- ⑥ 输入框歧义：写入口宁缺毋滥，歧义退剪贴板 ----

    @Test
    fun inputAmbiguity_singleEligibleEditorIsFound() {
        val root = N(children = listOf(
            N(children = listOf(N(editable = true, bounds = intArrayOf(0, 2100, 1080, 2200)))),
        ))
        assertNotNull(findEditableNode(root.toNode()))
    }

    @Test
    fun inputAmbiguity_twoEligibleEditorsMeansClipboardFallback() {
        // 全树恰好一个合格可编辑节点才算；两个以上视为歧义，宁可剪贴板
        // （findEditableNode 的 KDoc——X/Telegram 的 composer 唯一抓手）。
        val root = N(children = listOf(
            N(editable = true, bounds = intArrayOf(0, 2100, 1080, 2200)),
            N(editable = true, bounds = intArrayOf(0, 1900, 1080, 2000)),
        ))
        assertNull(findEditableNode(root.toNode()))
    }

    @Test
    fun inputAmbiguity_ineligibleEditorsDoNotCount() {
        // 密码框、不可见、禁用的可编辑节点都不是写入口（findEditableNode 的谓词）。
        val root = N(children = listOf(
            N(editable = true, password = true),
            N(editable = true, visible = false),
            N(editable = true, enabled = false),
            N(editable = true, bounds = intArrayOf(0, 2100, 1080, 2200)),
        ))
        assertNotNull(findEditableNode(root.toNode()))
    }

    @Test
    fun inputAmbiguity_qqTimFeishuUseTheirVerifiedComposerId() {
        // 有稳定 id 的适配器直接按 id 找（各自取样过的 composer id）；多个命中
        // 取第一个。
        fun stubRoot(id: String, vararg nodes: AccessibilityNodeInfo): AccessibilityNodeInfo {
            val root = Mockito.mock(AccessibilityNodeInfo::class.java)
            Mockito.`when`(root.findAccessibilityNodeInfosByViewId(id)).thenReturn(nodes.toList())
            return root
        }
        val qqInput = Mockito.mock(AccessibilityNodeInfo::class.java)
        assertSame(qqInput, QQAdapter().findInput(
            stubRoot("com.tencent.mobileqq:id/input", qqInput,
                Mockito.mock(AccessibilityNodeInfo::class.java))))
        val timInput = Mockito.mock(AccessibilityNodeInfo::class.java)
        assertSame(timInput, TimAdapter().findInput(
            stubRoot("com.tencent.tim:id/input", timInput)))
        val feishuInput = Mockito.mock(AccessibilityNodeInfo::class.java)
        assertSame(feishuInput, FeishuAdapter().findInput(
            stubRoot("com.ss.android.lark:id/kb_rich_text_content", feishuInput)))
    }

    @Test
    fun inputAmbiguity_xTelegramComposerIsGenericEditableSearch() {
        // X/Telegram 的 composer 无稳定 id，走通用查找（两个适配器的 findInput
        // 都委托 findEditableNode——见各自类内注释）。
        val single = N(children = listOf(N(editable = true, bounds = intArrayOf(0, 2200, 1080, 2300)))).toNode()
        assertNotNull(TelegramAdapter().findInput(single))
        assertNotNull(XAdapter().findInput(single))
        val ambiguous = N(children = listOf(N(editable = true), N(editable = true))).toNode()
        assertNull(TelegramAdapter().findInput(ambiguous))
        assertNull(XAdapter().findInput(ambiguous))
    }

    // ---- ⑦ 应用升级：真机项 ----
    // 每条 = 升级后在真机上复验什么。复验通过 → 把该适配器 capabilities 的
    // verifiedAppVersion 更新为新版本号；不复验就保持 null（首页显示「兼容性
    // 未知」，G2 的约定）。复验方法：uiautomator dump 真机窗口树，对照本文件
    // ①②③ 里的树形/样本断言。

    @Ignore("真机项：QQ 升级后复验 id 表（mjn/mjq/371/input）是否仍由无障碍发布——上次取样 " +
        "9.3.50 / Xiaomi 14 1200x2670。混淆策略变化或大版本改版都会换 id。")
    @Test
    fun appUpgrade_qq_reSampleIdTableOnDevice() {
    }

    @Ignore("真机项：TIM 升级后复验 AndResGuard 混淆 id（9u/9w/input/fun_btn）——companion 注释" +
        "明说「这些名字随 TIM 构建变」，六个适配器里最高危。上次取样 4.1.0 / OnePlus PJE110。")
    @Test
    fun appUpgrade_tim_reSampleObfuscatedIdsOnDevice() {
    }

    @Ignore("真机项：Telegram 升级或换系统语言后复验状态行动词表（发送/已读/已收到…只认 zh/en，" +
        "类注释的已知缺口：其他语言整行读作对方）。上次取样 12.10.1 / zh。")
    @Test
    fun appUpgrade_telegram_reSampleStatusWordsOnDevice() {
    }

    @Ignore("真机项：WhatsApp 升级后复验 resource id 表（conversation_contact_name/entry/main_layout/" +
        "message_text/status/icon + 四个行类型）与群聊 id 清单。上次取样 2.26.38.73（#73 贡献者的录制）。")
    @Test
    fun appUpgrade_whatsapp_reSampleResourceIdsOnDevice() {
    }

    @Ignore("真机项：X 升级后复验 contentDescription 拼接形状（发送者：正文。时间。回执。）与「你/You」" +
        "标签、列表屏证据（新私信/聊天）。上次取样 12.25.2 / Xiaomi 14 / zh。")
    @Test
    fun appUpgrade_x_reSampleDescriptionShapeOnDevice() {
    }

    @Ignore("真机项：飞书适配器从未整机验证——取样记录只有日期（2026-09-21）没有版本号，分边规则" +
        "（回执条）类注释明说 unverified。首次真机验证 = 复验后缀 id（message/bubble_content_container/" +
        "kb_rich_text_content/group_name/read_state）+ 回执条分边；通过后才谈 verifiedAppVersion。")
    @Test
    fun appUpgrade_feishu_firstVerificationOnDevice() {
    }

    // ---- G2 能力表与运行时闸门的一致性 ----

    @Test
    fun capabilities_allowOcrFallbackMatchesRuntimeScreenshotGate() {
        // allowsOcrFallback 是 allowScreenshot 的展示投影，两者必须一致——运行时
        // 只认后者（CaptureService.maybeCapture / manualOcr 直接读它）。
        for (adapter in ChatApps.all) {
            assertEquals(adapter.allowScreenshot, adapter.capabilities.allowsOcrFallback,
                "${adapter.displayName}: capabilities.allowsOcrFallback 必须等于 allowScreenshot")
        }
    }

    @Test
    fun capabilities_pinRecordedDeviceSamples() {
        // verifiedAppVersion 必须与各适配器头注释记录的真机取样版本一致；没有
        // 版本记录（飞书只记了日期；微信的记录在旧仓库）一律 null。
        val expected = mapOf(
            "com.tencent.mobileqq" to "9.3.50",    // QQAdapter 类注释（Xiaomi 14）
            "com.tencent.tim" to "4.1.0",          // TimAdapter 类注释（OnePlus PJE110）
            "org.telegram.messenger" to "12.10.1", // TelegramAdapter 类注释
            "com.whatsapp" to "2.26.38.73",        // WhatsAppAdapter 类注释（#73 录制）
            "com.twitter.android" to "12.25.2",    // XAdapter 类注释（zh）
            "com.ss.android.lark" to null,         // FeishuAdapter：取样无版本号
        )
        for (adapter in ChatApps.all) {
            assertEquals(expected[adapter.pkg], adapter.capabilities.verifiedAppVersion,
                "${adapter.displayName}: verifiedAppVersion 与头注释的取样记录不符")
            assertFalse(adapter.capabilities.canReadHistory,
                "${adapter.displayName}: 无障碍路径没有当前屏之外的历史源")
        }
    }

    @Test
    fun capabilities_weChatEntryUsesOcrShape() {
        // 微信无适配器：getCapabilities 对它单列「OCR 能力」形状（通道契约：
        // canReadMessages=false + allowsOcrFallback=true）；像素分边在本插件无
        // 真机回归记录 → canIdentifySender=false、版本 null。未适配包名/null → null。
        assertEquals(mapOf<String, Any?>(
            "canReadMessages" to false,
            "canIdentifySender" to false,
            "canReadHistory" to false,
            "allowsOcrFallback" to true,
            "verifiedAppVersion" to null,
        ), CaptureService.capabilitiesFor("com.tencent.mm"))
        assertNull(CaptureService.capabilitiesFor("com.example.unknown"))
        assertNull(CaptureService.capabilitiesFor(null))
    }

    @Test
    fun capabilities_adaptedPackagesRoundTripThroughGetCapabilities() {
        // 六个适配器的能力表按同名键原样透传（Dart 侧按 Map 消费，不再解码）。
        for (adapter in ChatApps.all) {
            val caps = assertNotNull(CaptureService.capabilitiesFor(adapter.pkg),
                "${adapter.displayName}: 已适配包必须查得到能力表")
            assertEquals(adapter.capabilities.canReadMessages, caps["canReadMessages"])
            assertEquals(adapter.capabilities.canIdentifySender, caps["canIdentifySender"])
            assertEquals(adapter.capabilities.canReadHistory, caps["canReadHistory"])
            assertEquals(adapter.capabilities.allowsOcrFallback, caps["allowsOcrFallback"])
            assertEquals(adapter.capabilities.verifiedAppVersion, caps["verifiedAppVersion"])
        }
    }
}

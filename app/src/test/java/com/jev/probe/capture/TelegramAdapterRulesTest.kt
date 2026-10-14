package com.jev.probe.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Telegram carries every message in ONE accessibility string per row, with no
 * resource ids anywhere, so these two pure functions are the whole adapter
 * contract. The samples are copied verbatim from a real dump (Telegram 12.10.1,
 * zh, OnePlus PJE110) — including the translation bug in the outgoing line.
 */
class TelegramAdapterRulesTest {

    // ---- telegramParseCell -------------------------------------------------

    @Test fun incomingGroupRowKeepsItsSenderLine() {
        val cell = telegramParseCell(
            "媛媛 王 带有管理员标签：所有者\n然后？\n已收到 于 11:49:26 27514\n"
        )!!

        assertEquals("other", cell.side)
        assertEquals(listOf("媛媛 王 带有管理员标签：所有者", "然后？"), cell.lines)
    }

    @Test fun outgoingRowIsRecognisedDespiteTelegramsDoubleYuTypo() {
        val cell = telegramParseCell("那好啊，到时候撸给你\n已发送于 于 11:50:38 27520, 已读\n")!!

        assertEquals("me", cell.side)
        assertEquals(listOf("那好啊，到时候撸给你"), cell.lines)
    }

    @Test fun aStickerRowWithoutAMessageIdStillParses() {
        val cell = telegramParseCell("哈 哈\n🤔 贴纸\n已收到 于 11:53\n")!!

        assertEquals("other", cell.side)
        assertEquals(listOf("哈 哈", "🤔 贴纸"), cell.lines)
    }

    @Test fun incomingAndOutgoingAreToldApartByTheStatusVerbOnly() {
        // Identical body, only the status line differs: rows are full width, so
        // nothing geometric could separate these.
        val mine = telegramParseCell("在么\n已发送于 于 09:01 100\n")!!
        val theirs = telegramParseCell("在么\n已收到 于 09:01 101\n")!!

        assertEquals("me", mine.side)
        assertEquals("other", theirs.side)
    }

    @Test fun nonMessageNodesReturnNull() {
        assertNull(telegramParseCell("11:03"))          // date separator
        assertNull(telegramParseCell("未读消息"))          // unread strip
        assertNull(telegramParseCell("搜索聊天"))          // chat-list search box
        assertNull(telegramParseCell("输入消息"))          // composer hint
        assertNull(telegramParseCell(""))               // blank
        assertNull(telegramParseCell("只有一行正文"))      // no status line
    }

    @Test fun aBareTimeOnlyCountsAsAStatusOnAMultiLineCell() {
        // Status = last line has a time OR a verb, deliberately loose: Telegram's
        // translations vary. The cost of that looseness is this case — a two-line
        // cell whose body ends in "11:00" parses as a message. A one-line "11:00"
        // (the real date separator) does not, and that is the case that occurs.
        assertEquals(listOf("开会"), telegramParseCell("开会\n11:00")!!.lines)
        assertNull(telegramParseCell("11:00"))
    }

    // ---- telegramNameHeadersInUse ------------------------------------------

    @Test fun senderLineEqualToTheChatTitleProvesOneOnOneNaming() {
        val cells = listOf(TgCell("other", listOf("Alice", "在么")))
        assertTrue(telegramNameHeadersInUse(cells, "Alice"))
    }

    @Test fun theSameSenderTwiceProvesAGroupNamesItsSenders() {
        val cells = listOf(
            TgCell("other", listOf("媛媛 王", "然后？")),
            TgCell("other", listOf("UIC", "在撸了已经")),
            TgCell("other", listOf("媛媛 王", "你不用撸")),
            TgCell("me", listOf("那好啊"))
        )
        assertTrue(telegramNameHeadersInUse(cells, "涩涩（营业中）"))
    }

    @Test fun oneIncomingRowAndNoTitleMatchKeepsTheFirstLine() {
        // A group with a single incoming row on screen cannot prove anything, so
        // the name stays in the body. Keeping a name is a smaller error than
        // eating the opening words of a real message.
        val cells = listOf(TgCell("other", listOf("然后？", "睡觉")))
        assertFalse(telegramNameHeadersInUse(cells, "涩涩（营业中）"))
    }

    @Test fun outgoingRowsAloneProveNothing() {
        assertFalse(telegramNameHeadersInUse(listOf(TgCell("me", listOf("在么"))), null))
    }

    @Test fun singleLineCellsAreIgnoredByTheNameEvidence() {
        val cells = listOf(TgCell("other", listOf("在么")), TgCell("other", listOf("在么")))
        assertFalse(telegramNameHeadersInUse(cells, "Alice"))
    }
}

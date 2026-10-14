package com.jev.probe.bridge

import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Msg
import com.jev.probe.core.Provenance
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 对拍是 S3 的验收证据：它必须能说出「新的那一头从第几条开始对不上」，
 * 而且**不能**把聊天正文带进日志。
 */
class SnapshotDiffTest {

    private fun m(text: String, side: String = "other") = Msg(side = side, text = text)

    private fun snap(vararg texts: String) =
        ChatSnapshot(title = null, messages = texts.map { m(it) }, provenance = Provenance.INJECT)

    @Test
    fun identicalReadingsLineUpCompletely() {
        val result = SnapshotDiff.compare(
            listOf(m("一"), m("二", "me")),
            listOf(m("一"), m("二", "me")),
        )
        assertEquals(2, result.aligned)
        assertEquals(0, result.sideIndex)
        assertEquals(0, result.textIndex)
        assertTrue(result.same)
    }

    @Test
    fun aShorterWindowStillCountsAsAlignedWhenTheNewestEndMatches() {
        // 无障碍只看到屏上 2 条，注入层看到 4 条 —— 旧的那头对不上是正常的。
        val result = SnapshotDiff.compare(
            listOf(m("二"), m("三")),
            listOf(m("零"), m("一"), m("二"), m("三")),
        )
        assertEquals(2, result.aligned)
        assertTrue(result.same) // min(2,4) == 2
        assertEquals(2, result.leftCount)
        assertEquals(4, result.rightCount)
    }

    @Test
    fun aWrongSideIsReportedAtItsDistanceFromTheNewest() {
        val result = SnapshotDiff.compare(
            listOf(m("在吗", "other"), m("在", "me")),
            listOf(m("在吗", "me"), m("在", "me")),
        )
        assertEquals(1, result.aligned) // 最新那条对上了
        assertEquals(2, result.sideIndex) // 分边从第 2 条开始不对
        assertFalse(result.same)
    }

    @Test
    fun aWrongTextIsReportedAtItsDistanceFromTheNewest() {
        val result = SnapshotDiff.compare(
            listOf(m("一"), m("二"), m("三")),
            listOf(m("一"), m("二错"), m("三")),
        )
        assertEquals(1, result.aligned)
        assertEquals(0, result.sideIndex)
        assertEquals(2, result.textIndex)
        assertFalse(result.same)
    }

    @Test
    fun theFirstMismatchOfEachKindIsKeptSeparately() {
        val result = SnapshotDiff.compare(
            listOf(m("新", "other"), m("中", "me"), m("旧", "other")),
            listOf(m("新", "me"), m("中错", "me"), m("旧", "other")),
        )
        assertEquals(1, result.aligned) // 最新那条（旧）对上了
        assertEquals(3, result.sideIndex) // 分边从第 3 条开始不对
        assertEquals(2, result.textIndex) // 正文从第 2 条开始不对
    }

    @Test
    fun twoEmptyReadingsAreNotEvidenceOfAgreement() {
        val result = SnapshotDiff.compare(emptyList(), emptyList())
        assertFalse(result.same)
        assertEquals(0, result.aligned)
    }

    @Test
    fun anUnreadableA11ySideShowsUpAsZeroAligned() {
        val result = SnapshotDiff.compare(emptyList(), listOf(m("在吗"), m("在")))
        assertEquals(0, result.aligned)
        assertEquals(0, result.leftCount)
        assertEquals(2, result.rightCount)
        assertFalse(result.same)
    }

    @Test
    fun theLineHasTheDocumentedShape() {
        val line = SnapshotDiff.compare(
            listOf(m("二"), m("三")),
            listOf(m("零"), m("一"), m("二"), m("三")),
        ).describe()
        assertEquals("cmp l0=2 l1=4 aligned=2 sideDiff=0 textDiff=0 overlap=2 same=true", line)
    }

    /**
     * 位置对不上（最新那几条 L0 根本没有）时，重叠数必须还能说出「两层读的是同一段
     * 聊天，L1 多出两条」—— 这正是真机上 `aligned=0` 时唯一有用的信息。
     */
    @Test
    fun theOverlapStillNamesTheSameConversationWhenPositionsDoNotLineUp() {
        val result = SnapshotDiff.compare(
            listOf(m("一"), m("二"), m("三"), m("四")),
            listOf(m("一"), m("二"), m("三"), m("四"), m("五"), m("六")),
        )
        assertEquals(0, result.aligned) // 按位置从最新往回比：第 1 条就不同
        assertEquals(4, result.overlap) // 但四条的正文分边全在 L1 里出现过
        assertFalse(result.same)
    }

    /** 重复正文要按多重集合算：两侧各有两条「嗯」，只能算对上两条，不能算四条。 */
    @Test
    fun repeatedLinesAreCountedAsAMultisetNotASet() {
        val result = SnapshotDiff.compare(
            listOf(m("嗯"), m("嗯"), m("嗯"), m("嗯")),
            listOf(m("嗯"), m("嗯")),
        )
        assertEquals(2, result.overlap)
    }

    /** 分边不同就不算同一条：同样的正文自己发的和对方发的不是一回事。 */
    @Test
    fun theOverlapRespectsTheSide() {
        val result = SnapshotDiff.compare(
            listOf(m("嗯", "me")),
            listOf(m("嗯", "other")),
        )
        assertEquals(0, result.overlap)
    }

    @Test
    fun theOverlapIsZeroWhenTheA11ySideIsEmpty() {
        val result = SnapshotDiff.compare(emptyList(), listOf(m("在吗"), m("在")))
        assertEquals(0, result.overlap)
        assertEquals(0, result.aligned)
    }

    @Test
    fun theLineNeverCarriesChatText() {
        val line = SnapshotDiff.describe(
            snap("这是一句私聊正文"),
            snap("这是一句私聊正文，但顺序错了"),
        )
        assertFalse(line.contains("私聊"))
        assertFalse(line.contains("顺序"))
        assertTrue(line.startsWith("cmp l0=1 l1=1"))
    }

    @Test
    fun theSnapshotOverloadComparesTheMessageLists() {
        val line = SnapshotDiff.describe(snap("一", "二", "三"), snap("一", "二", "三"))
        assertEquals("cmp l0=3 l1=3 aligned=3 sideDiff=0 textDiff=0 overlap=3 same=true", line)
    }
}

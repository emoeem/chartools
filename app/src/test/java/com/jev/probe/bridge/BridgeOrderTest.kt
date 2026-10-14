package com.jev.probe.bridge

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 迟到消息判定。规则只有两条，但两条都容易写反：
 * 同一进程比序号，换进程比时间。
 */
class BridgeOrderTest {

    @Test fun theFirstThingEverHeardIsAccepted() {
        assertTrue(BridgeOrder.accept(null, Stamp("a", 1L, 100L)))
    }

    @Test fun withinOneProcessOnlyTheCounterMatters() {
        assertTrue(BridgeOrder.accept(Stamp("a", 1L, 100L), Stamp("a", 2L, 100L)))
        assertFalse(BridgeOrder.accept(Stamp("a", 2L, 100L), Stamp("a", 1L, 100L)))
    }

    @Test fun theSameStampAgainIsNotANewOne() {
        assertFalse(BridgeOrder.accept(Stamp("a", 2L, 100L), Stamp("a", 2L, 100L)))
    }

    /**
     * 目标 App 重启后模块进程也重来，序号从 1 开始。只比序号的话新进程的第一条
     * 永远小于旧进程的 99，模块从此静默失效 —— 这是引入 boot 的唯一理由。
     */
    @Test fun aNewProcessIsJudgedByTimeNotByItsOwnCounter() {
        assertTrue(BridgeOrder.accept(Stamp("a", 99L, 100L), Stamp("b", 1L, 200L)))
    }

    @Test fun aStragglerFromTheOldProcessIsStillRejected() {
        assertFalse(BridgeOrder.accept(Stamp("b", 1L, 200L), Stamp("a", 100L, 150L)))
    }

    /** 时间没往前走的一条（同一个 boot 串理论上不会出现，但坏数据不该被信任）。 */
    @Test fun aNewProcessWithATimestampThatDidNotAdvanceIsRejected() {
        assertFalse(BridgeOrder.accept(Stamp("a", 1L, 200L), Stamp("b", 1L, 200L)))
    }
}

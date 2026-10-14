package com.jev.probe.jev

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A chat model asked for JSON wraps it in prose or a markdown fence often
 * enough that the slice has to survive it, and a candidate reply quoted inside
 * the JSON can contain braces, so the cut cannot be "first { to last }".
 */
class JsonSliceTest {

    @Test fun plainObject() {
        assertEquals("""{"a":1}""", JsonSlice.firstObject("""{"a":1}"""))
    }

    @Test fun markdownFence() {
        val reply = "```json\n{\"answers\":{\"a\":1}}\n```"
        assertEquals("""{"answers":{"a":1}}""", JsonSlice.firstObject(reply))
    }

    @Test fun proseBeforeAndAfter() {
        val reply = "好的，结果如下：{\"a\":1} 以上。"
        assertEquals("""{"a":1}""", JsonSlice.firstObject(reply))
    }

    @Test fun bracesInsideAStringValueDoNotEndTheObject() {
        val reply = """{"text":"} 别这样 {","n":1}"""
        assertEquals(reply, JsonSlice.firstObject(reply))
    }

    @Test fun escapedQuoteInsideAStringDoesNotOpenOne() {
        val reply = """{"text":"他说 \"好\" 了","n":1}"""
        assertEquals(reply, JsonSlice.firstObject(reply))
    }

    @Test fun nestedObjectsAreReturnedWhole() {
        val reply = """{"a":{"b":{"c":1}}}"""
        assertEquals(reply, JsonSlice.firstObject(reply))
    }

    @Test fun onlyTheFirstObjectIsTaken() {
        val reply = """{"a":1} and {"b":2}"""
        assertEquals("""{"a":1}""", JsonSlice.firstObject(reply))
    }

    @Test fun noObjectIsNull() {
        assertNull(JsonSlice.firstObject("抱歉，我无法判断。"))
    }

    @Test fun unterminatedObjectIsNull() {
        assertNull(JsonSlice.firstObject("""{"a":1"""))
    }
}

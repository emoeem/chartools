package com.jev.probe.core.kb.extract

import java.io.ByteArrayInputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Test

class DocImportReadPrefixTest {

    @Test
    fun readsPrefixEvenWhenInputReturnsShortChunks() {
        val input = object : ByteArrayInputStream("abcdef".toByteArray()) {
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
                super.read(buffer, offset, minOf(length, 2))
        }

        assertArrayEquals("abcde".toByteArray(), DocImport.readPrefix(input, 5))
    }

    @Test
    fun returnsAvailableBytesWhenInputEndsBeforeLimit() {
        assertArrayEquals(
            "abc".toByteArray(),
            DocImport.readPrefix(ByteArrayInputStream("abc".toByteArray()), 5)
        )
    }
}

package com.jev.probe.jev

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The two unwrapping steps that make an opt-in stream readable. Both run on every
 * partial chunk, so the interesting cases are all "input stops in the middle of
 * something": half a JSON string, half an escape sequence, one candidate of three.
 */
class StreamTextTest {

    // ---------------------------------------------------------------- transport

    @Test
    fun theDeltaEnvelopeIsUnwrapped() {
        assertEquals("你", StreamText.delta("""{"choices":[{"delta":{"content":"你"}}]}"""))
    }

    @Test
    fun aChunkThatCarriesNoContentIsIgnored() {
        assertNull(StreamText.delta("""{"choices":[{"finish_reason":"stop"}]}"""))
        assertNull(StreamText.delta("""{"choices":[{"delta":{}}]}"""))
        assertNull(StreamText.delta(""))
        assertNull(StreamText.delta("not json at all"))
    }

    // -------------------------------------------------------------- the format

    @Test
    fun aHalfTypedCandidateShowsItsTextSoFar() {
        assertEquals("你好", StreamText.visible("""[{"strategy":"safe","text":"你好"""))
    }

    @Test
    fun finishedCandidatesAppearOnePerLine() {
        val raw = """[{"strategy":"safe","text":"一"},{"strategy":"forward","text":"二"},{"strategy":"angle","text":"三"}]"""
        assertEquals("一\n二\n三", StreamText.visible(raw))
    }

    @Test
    fun jsonEscapesAreDecoded() {
        assertEquals("第一行\n第二行", StreamText.visible("""[{"text":"第一行\n第二行"}]"""))
        assertEquals("他说\"好\"", StreamText.visible("[{\"text\":\"他说\\\"好\\\"\"}]"))
    }

    @Test
    fun aTruncatedEscapeDoesNotCrashOrSwallowTheText() {
        assertEquals("abc", StreamText.visible("[{\"text\":\"abc\\"))
        assertEquals("abc", StreamText.visible("[{\"text\":\"abc\\u00"))
    }

    @Test
    fun proseThatIgnoresTheJsonFormatStillPreviews() {
        assertEquals("你好呀，最近怎么样", StreamText.visible("你好呀，最近怎么样"))
    }

    @Test
    fun nothingArrivedYetMeansNothingToShow() {
        assertEquals("", StreamText.visible(""))
        assertEquals("", StreamText.visible("["))
    }
}

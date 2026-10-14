package com.jev.probe.jev

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * §七.4 of the optimization report called the defensive retry a "待生产验证" leftover.
 * It cannot be verified against production from here, so it is pinned as an explicit
 * rule instead: the retry exists so an unverified field cannot break the analysis,
 * which is a claim about *why the body was rejected* — not about any 4xx.
 */
class JudgeRetryTest {

    @Test
    fun aBodyTheEndpointRejectedIsRetriedWithoutTheUnverifiedFields() {
        listOf(400, 404, 413, 415, 422).forEach {
            assertTrue("HTTP $it should drop background/history", JudgeRetry.shouldDropEnrichment(it))
        }
    }

    @Test
    fun aWrongKeyIsNotABodyProblem() {
        // 401/403: no body would be acceptable, so a second request only delays the
        // real message ("密钥不对") by a whole round trip.
        assertFalse(JudgeRetry.shouldDropEnrichment(401))
        assertFalse(JudgeRetry.shouldDropEnrichment(403))
    }

    @Test
    fun beingToldToSlowDownIsNotABodyProblem() {
        // 429 has already been retried three times by the HTTP layer before it
        // surfaces as an ApiException; resending immediately doubles the load.
        assertFalse(JudgeRetry.shouldDropEnrichment(429))
        assertFalse(JudgeRetry.shouldDropEnrichment(408))
    }

    @Test
    fun aServerFaultIsNotTheFieldsFault() {
        listOf(500, 502, 503, 529).forEach {
            assertFalse("HTTP $it is the server's problem", JudgeRetry.shouldDropEnrichment(it))
        }
    }

    @Test
    fun noStatusMeansNoEvidence() {
        assertFalse(JudgeRetry.shouldDropEnrichment(null))   // timeout / offline
    }

    @Test
    fun codesThatAreNotFailuresAreNotRetried() {
        listOf(0, 3, 200, 302, 600).forEach {
            assertFalse("HTTP $it is not a rejected body", JudgeRetry.shouldDropEnrichment(it))
        }
    }
}

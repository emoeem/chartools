package com.jev.probe.jev

/**
 * The one rule behind [JudgeClient]'s defensive retry.
 *
 * Whether the live `alpha/decisions` endpoint accepts the `background` / `history`
 * state fields is not verified against production, so a request carrying them that
 * is rejected gets sent once more without them: an unverified field may degrade the
 * judgment but must never break it. This is that decision, isolated so it is a
 * stated rule instead of a `status in 400..499` in a catch block.
 *
 * Only codes that mean "this body was rejected" qualify:
 * - 400 bad request, 422 unprocessable — the shape is the complaint
 * - 413 too large — `history` is exactly what makes the body big
 * - 415 unsupported media — a field format the endpoint does not take
 * - 404 not found — the body never reached a handler that could care
 *
 * Deliberately excluded: 401/403 (the key is wrong, no body is acceptable, and
 * retrying only delays the real message), 408/429 (the server asked us to slow
 * down; an immediate retry doubles the load, and 429 has already been retried
 * three times by the HTTP layer by the time it surfaces here), and 5xx (the
 * server's fault, not the field's).
 */
internal object JudgeRetry {

    private val DROP_ENRICHMENT_CODES = setOf(400, 404, 413, 415, 422)

    /** Whether a failed enriched judgment should be retried once without background/history. */
    fun shouldDropEnrichment(status: Int?): Boolean = status != null && status in DROP_ENRICHMENT_CODES
}

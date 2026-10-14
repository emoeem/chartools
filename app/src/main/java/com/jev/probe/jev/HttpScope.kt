package com.jev.probe.jev

import java.util.concurrent.ConcurrentHashMap

/**
 * The HTTP calls that belong to one unit of work (an analysis round, a redraft,
 * a refine), so the watchdog can *close their sockets* instead of only
 * interrupting the thread that is blocked on them.
 *
 * `Future.cancel(true)` sets an interrupt flag, which a thread parked in a
 * socket read never sees: the round looked cancelled but its thread (and the
 * connection, and the quota) stayed alive until the read timeout. OkHttp's
 * `Call.cancel()` tears the connection down immediately — which is what a
 * dropped round actually needs — and an SSE `EventSource` is cancelled through
 * the same hook.
 *
 * Cancelling is sticky: a call attached after [cancel] is cancelled at once, so
 * a late straggler from a dead round cannot slip through.
 */
class HttpScope {

    private val cancels = ConcurrentHashMap.newKeySet<() -> Unit>()

    @Volatile
    private var cancelled = false

    val isCancelled: Boolean get() = cancelled

    /**
     * Register how to tear one in-flight request down. The SAME function
     * instance must be passed to [detach], which is why callers keep it in a
     * local `val` instead of writing the lambda inline twice.
     */
    internal fun attach(cancel: () -> Unit) {
        cancels.add(cancel)
        if (cancelled) cancel()
    }

    internal fun detach(cancel: () -> Unit) {
        cancels.remove(cancel)
    }

    /** Close every socket this scope owns. Safe from any thread, any number of times. */
    fun cancel() {
        cancelled = true
        cancels.forEach { it() }
        cancels.clear()
    }
}

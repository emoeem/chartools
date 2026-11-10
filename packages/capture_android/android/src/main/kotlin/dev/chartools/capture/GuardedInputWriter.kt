package dev.chartools.capture

/**
 * Non-blocking fill sequence. [resolve] must validate the live session on every
 * call: a resolve miss (chat switched, window gone) completes with `false` —
 * exactly one [complete] per fill, so the pending MethodChannel.Result always
 * gets its reply and the caller can fall back to the clipboard.
 */
internal class GuardedInputWriter(
    private val resolve: () -> Input?,
    private val later: (Long, () -> Unit) -> Unit,
    private val copy: (String) -> Unit,
    private val complete: (Boolean) -> Unit
) {
    interface Input {
        val text: String?
        fun setText(text: String): Boolean
        fun focus()
        fun paste()
    }

    fun fill(text: String) {
        val input = resolve() ?: run { complete(false); return }
        input.setText(text)
        later(150) checkFirst@{
            val fresh = resolve() ?: run { complete(false); return@checkFirst }
            if (fresh.text == text) { complete(true); return@checkFirst }
            fresh.focus()
            later(300) retry@{
                val focused = resolve() ?: run { complete(false); return@retry }
                focused.setText(text)
                later(150) checkRetry@{
                    val retryInput = resolve() ?: run { complete(false); return@checkRetry }
                    if (retryInput.text == text) { complete(true); return@checkRetry }
                    copy(text)
                    if (retryInput.setText("")) {
                        // Clearing can itself trigger navigation; resolve before PASTE too.
                        val pasteInput = resolve() ?: run { complete(false); return@checkRetry }
                        pasteInput.paste()
                    }
                    later(150) checkPaste@{
                        val after = resolve() ?: run { complete(false); return@checkPaste }
                        complete(after.text == text)
                    }
                }
            }
        }
    }
}

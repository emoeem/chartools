package com.jev.probe.core

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.SystemClock
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * A tiny on-device trace file, because `adb logcat` is dead on the target
 * device (OnePlus PJE110: `adb logcat -d` returns 0 lines, a live `logcat -s
 * JEVASSIST:V` prints nothing at all) — which left every accessibility decision
 * unverifiable from the outside.
 *
 * Debug builds only: release builds get a no-op. It records COUNTS, package
 * names and verdicts — never message text, never chat titles, never keys.
 *
 * Read it with:
 * ```
 * adb exec-out run-as com.jev.probe cat files/jev-trace.log
 * ```
 */
internal object Trace {
    private const val NAME = "jev-trace.log"

    /** Rotate rather than grow without bound; a session writes a few KB. */
    private const val MAX_BYTES = 256 * 1024

    private val stamp = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    @Volatile private var file: File? = null
    @Volatile private var enabled = false
    private val lock = Any()

    /** Idempotent; call from the accessibility service's connect. */
    fun init(app: Context) {
        if (enabled) return
        enabled = (app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!enabled) return
        val f = File(app.filesDir, NAME)
        synchronized(lock) {
            runCatching { if (f.exists()) f.delete(); f.createNewFile() }
            file = f
        }
        log("trace start")
    }

    fun log(msg: String) {
        if (!enabled) return
        val f = file ?: return
        val line = "${stamp.format(Date())} ${SystemClock.uptimeMillis() % 1000000} $msg\n"
        synchronized(lock) {
            runCatching {
                if (f.length() > MAX_BYTES) f.delete()
                f.appendText(line)
            }
        }
    }
}

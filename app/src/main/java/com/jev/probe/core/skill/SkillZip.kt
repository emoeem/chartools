package com.jev.probe.core.skill

import java.io.File
import java.io.InputStream
import java.util.zip.ZipInputStream

/**
 * Reading a skill out of a zip. Separated from [SkillStore] because this is the
 * part that faces hostile input, and keeping it free of any Android type means
 * the guards below are exercised by plain JVM unit tests.
 *
 * Every entry name is checked before it is used: no absolute paths, no `..`
 * segments, no NUL, and hard caps on entry count and bytes so a hostile (or
 * merely enormous) archive cannot fill the disk. Symlinks are not a concern
 * here — the archive is read through [ZipInputStream] and all this ever does is
 * write plain files.
 */
internal object SkillZip {

    /** Total files allowed in one archive. */
    const val MAX_ENTRIES = 2000

    /** Bytes allowed for any single extracted file. */
    const val MAX_FILE_BYTES = 8L * 1024 * 1024

    /** Bytes allowed across the whole archive. */
    const val MAX_TOTAL_BYTES = 32L * 1024 * 1024

    /**
     * Extract [input] under [into].
     *
     * @return how many files were written.
     * @throws IllegalArgumentException when an entry name is unsafe.
     * @throws IllegalStateException when a size or count cap is exceeded.
     */
    fun extract(input: InputStream, into: File): Int {
        var count = 0
        var total = 0L
        ZipInputStream(input).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val name = entry.name
                if (name.endsWith("/")) { zip.closeEntry(); continue }
                if (++count > MAX_ENTRIES) throw IllegalStateException("条目过多")
                if (!safeEntryName(name)) throw IllegalArgumentException("非法条目名")
                if (entry.size > MAX_FILE_BYTES) throw IllegalStateException("单个文件过大")
                val out = File(into, name)
                out.parentFile?.mkdirs()
                out.outputStream().use { os ->
                    val buf = ByteArray(16 * 1024)
                    var written = 0L
                    while (true) {
                        val r = zip.read(buf)
                        if (r <= 0) break
                        written += r
                        total += r
                        if (written > MAX_FILE_BYTES || total > MAX_TOTAL_BYTES) {
                            throw IllegalStateException("压缩包过大")
                        }
                        os.write(buf, 0, r)
                    }
                }
                zip.closeEntry()
            }
        }
        return count
    }

    /** True when [name] may be joined onto the destination directory as-is. */
    fun safeEntryName(name: String): Boolean {
        if (name.isBlank() || name.indexOf('\u0000') >= 0) return false
        if (name.startsWith("/") || name.startsWith("\\")) return false
        if (name.length >= 2 && name[1] == ':') return false        // C:\...
        return name.split('/', '\\').none { it == ".." }
    }
}

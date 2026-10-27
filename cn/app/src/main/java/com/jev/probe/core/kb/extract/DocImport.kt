package com.jev.probe.core.kb.extract

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import java.io.File
import java.io.InputStream
import com.jev.probe.core.ocr.OcrEngine

/**
 * Import a document the user picked into plain-text chunks.
 *
 * One entry point, [import], and one rule: **call it off the main thread**. It
 * copies the picked document, parses it, and for a scanned PDF renders and OCRs
 * up to [PdfText.MAX_OCR_PAGES] pages — seconds to minutes of work that would
 * freeze the UI. Nothing here touches the network or reads any file the user did
 * not choose: the URI goes through `contentResolver`, the bytes land in this
 * app's own cache directory, and the copy is deleted before returning.
 *
 * The result is text, not notes. Saving is the caller's job, so this stays
 * testable and so the UI can decide titles and tags.
 */
object DocImport {

    /**
     * Ceiling on extracted characters per file. At roughly 4 bytes per CJK
     * character this is ~8 MB of text, far more than a useful note, and it is low
     * enough that the resulting chunk list stays in memory comfortably.
     */
    const val MAX_CHARS = 2_000_000

    /**
     * Target chunk size. Each chunk becomes one knowledge note.
     *
     * Was 1200. Measured against [ContextBuilder.BUDGET_TOKENS]: a 1200-character
     * Chinese chunk costs ~1200 tokens, so a 3000-token budget fit two of them
     * and a single hit crowded out the conversation. Halving the chunk roughly
     * doubles how many notes fit in the same budget and makes each hit one
     * argument instead of one chapter.
     */
    const val CHUNK_CHARS = 600

    /**
     * Ceiling on notes created from one file. 2000 notes × 600 characters covers
     * [MAX_CHARS] entirely.
     *
     * The old cap was 400 because saving a note rewrote the whole note file, so
     * N chunks cost O(N²) writes. [KbStore.saveNotes] writes once for the whole
     * batch, which removes that reason; the cap is now only a memory guard.
     */
    const val MAX_CHUNKS = 2000

    /**
     * Documents larger than this are refused before parsing. PDFBox keeps the
     * whole document in memory while it parses, so a 200 MB PDF is an
     * `OutOfMemoryError` rather than a slow import.
     */
    const val MAX_FILE_BYTES = 64L * 1024 * 1024

    /** What one import produced. [error] is empty exactly when it succeeded. */
    data class Result(
        val format: DocFormat,
        val displayName: String,
        val text: String,
        val chunks: List<String>,
        val truncated: Boolean,
        val note: String,
        val error: String
    ) {
        val ok: Boolean get() = error.isEmpty()
        val chunkCount: Int get() = chunks.size
    }

    @Volatile
    private var pdfReady = false

    /**
     * Initialise PDFBox's resources. Mandatory before the first PDF: without it
     * PDFBox cannot find its glyph list, and the failure mode is an exception
     * deep inside text extraction rather than anything obviously about init.
     * Safe to call repeatedly; cheap after the first call. Called automatically
     * by [import], and worth calling in `Application.onCreate`/`Activity.onCreate`
     * so the first import is not slowed by it.
     */
    fun prepare(context: Context) {
        if (pdfReady) return
        synchronized(this) {
            if (pdfReady) return
            PDFBoxResourceLoader.init(context.applicationContext)
            pdfReady = true
        }
    }

    /** True once [prepare] has run in this process. */
    fun isPrepared(): Boolean = pdfReady

    /**
     * Extract [uri] to text and chunks.
     *
     * @param allowOcr run on-device OCR when a PDF turns out to have no text
     *        layer. False turns a scanned PDF into a clear error instead.
     * @param ocr the OCR engine for scanned PDFs. The activity constructs it;
     *        null means a scanned PDF reports the same clear error as
     *        `allowOcr = false` instead of reaching into capture from here.
     */
    fun import(
        context: Context, uri: Uri, allowOcr: Boolean = true, ocr: OcrEngine? = null
    ): Result {
        val name = displayName(context, uri)
        val mime = runCatching { context.contentResolver.getType(uri) }.getOrNull()

        val copy = try {
            copyToCache(context, uri, name)
        } catch (e: Exception) {
            return failure(DocFormat.UNKNOWN, name, e.message ?: "读取文件失败")
        }

        try {
            val format = sniffFormat(copy, name, mime)
            return extract(context, format, name, copy, allowOcr, ocr)
        } catch (e: OutOfMemoryError) {
            // OutOfMemoryError is not an Exception; catching it is deliberate —
            // a document too large to parse should produce a message, and by the
            // time it is thrown the large allocations are already unreachable.
            return failure(DocFormat.UNKNOWN, name, "文件太大，内存不足，无法解析")
        } catch (e: Exception) {
            return failure(DocFormat.UNKNOWN, name, "解析失败：${e.javaClass.simpleName}")
        } catch (e: LinkageError) {
            // A dependency class that is missing at runtime surfaces as an
            // Error, not an Exception, so it needs its own arm or the user gets
            // a force-close instead of a sentence. The concrete case: pdfbox's
            // public-key encryption classes are compiled against BouncyCastle,
            // which this build deliberately excludes, so opening a
            // certificate-encrypted PDF can raise NoClassDefFoundError.
            return failure(DocFormat.UNKNOWN, name, "解析失败：${e.javaClass.simpleName}")
        } finally {
            copy.delete()
        }
    }

    // ------------------------------------------------------------- extraction

    /**
     * Fetch [url] and extract it the same way a picked file would be.
     *
     * A page is fetched into the cache first, for the same reason a picked file
     * is copied: PDFBox buffers a whole stream on the heap and `PdfRenderer`
     * seeks, so both need a real, seekable file. The format is decided from the
     * response's Content-Type and the URL's extension; anything that is not a
     * document is treated as an HTML page, because `sniffFormat` would otherwise
     * call raw markup "plain text" and the note would be full of tags.
     */
    fun importUrl(
        context: Context, url: String, allowOcr: Boolean = true, ocr: OcrEngine? = null
    ): Result {
        val clean = url.trim()
        if (!clean.startsWith("http://") && !clean.startsWith("https://")) {
            return failure(DocFormat.UNKNOWN, clean, "只支持 http/https 开头的网址")
        }
        val name = nameForUrl(clean)
        val copy = File.createTempFile("url-import-", ".part", context.cacheDir)
        val mime = try {
            download(clean, copy)
        } catch (e: Exception) {
            copy.delete()
            return failure(DocFormat.UNKNOWN, name, "下载失败：${e.message ?: e.javaClass.simpleName}")
        }
        try {
            val bySniff = sniffFormat(copy, name, mime)
            // Only trust the sniff when it recognises a real container; whatever
            // is left (an .html page, a URL with no extension) is a web page.
            val format = if (bySniff == DocFormat.UNKNOWN || bySniff == DocFormat.TEXT) {
                if (looksLikeHtml(copy)) DocFormat.HTML else bySniff
            } else {
                bySniff
            }
            return extract(context, format, name, copy, allowOcr, ocr)
        } catch (e: OutOfMemoryError) {
            return failure(DocFormat.UNKNOWN, name, "网页内容太大，内存不足，无法解析")
        } catch (e: Exception) {
            return failure(DocFormat.UNKNOWN, name, "解析失败：${e.javaClass.simpleName}")
        } catch (e: LinkageError) {
            return failure(DocFormat.UNKNOWN, name, "解析失败：${e.javaClass.simpleName}")
        } finally {
            copy.delete()
        }
    }

    /** The last path segment, else the host — what the note will be called. */
    private fun nameForUrl(url: String): String {
        val path = url.substringBefore('?').substringBefore('#')
        val last = path.trimEnd('/').substringAfterLast('/')
        if (last.isNotBlank() && last != path) return last.take(120)
        return runCatching { java.net.URL(url).host }.getOrNull() ?: "网页"
    }

    private fun looksLikeHtml(file: File): Boolean {
        val head = String(file.inputStream().use { readPrefix(it, 2048) }, Charsets.UTF_8)
            .trimStart().lowercase()
        return head.startsWith("<!doctype html") || head.startsWith("<html") ||
            head.contains("<head") || head.contains("<body")
    }

    internal fun readPrefix(input: InputStream, maxBytes: Int): ByteArray {
        require(maxBytes >= 0) { "maxBytes must not be negative" }
        val buffer = ByteArray(maxBytes)
        var count = 0
        while (count < buffer.size) {
            val read = input.read(buffer, count, buffer.size - count)
            if (read < 0) break
            if (read == 0) {
                val next = input.read()
                if (next < 0) break
                buffer[count++] = next.toByte()
            } else {
                count += read
            }
        }
        return if (count == buffer.size) buffer else buffer.copyOf(count)
    }

    /**
     * Download [url] into [into], following a few redirects by hand (the JDK's
     * follow-redirects would silently drop the headers). Returns the
     * Content-Type, which is the only format hint a web server gives us.
     */
    private fun download(url: String, into: File): String? {
        var current = url
        repeat(6) {
            val conn = java.net.URL(current).openConnection() as java.net.HttpURLConnection
            conn.connectTimeout = 15_000
            conn.readTimeout = 20_000
            conn.instanceFollowRedirects = false
            // Some sites answer a bare Java user agent with a 403.
            conn.setRequestProperty(
                "User-Agent",
                "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) JevAssistant/1.0"
            )
            conn.setRequestProperty("Accept", "text/html,application/xhtml+xml,*/*;q=0.8")
            val code = conn.responseCode
            if (code in 300..399) {
                val target = conn.getHeaderField("Location")
                conn.disconnect()
                if (target.isNullOrBlank()) throw java.io.IOException("重定向到空地址")
                current = java.net.URL(java.net.URL(current), target).toString()
                return@repeat
            }
            if (code !in 200..299) {
                conn.disconnect()
                throw java.io.IOException("服务器返回 $code")
            }
            val type = conn.contentType
            var written = 0L
            conn.inputStream.use { source ->
                into.outputStream().use { target ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = source.read(buf)
                        if (n < 0) break
                        written += n
                        if (written > MAX_FILE_BYTES) {
                            throw java.io.IOException("网页超过 ${MAX_FILE_BYTES / 1024 / 1024} MB")
                        }
                        target.write(buf, 0, n)
                    }
                }
            }
            conn.disconnect()
            if (written == 0L) throw java.io.IOException("网页是空的")
            return type
        }
        throw java.io.IOException("重定向次数过多")
    }

    // ------------------------------------------------------------- extraction

    private fun extract(
        context: Context,
        format: DocFormat,
        name: String,
        file: File,
        allowOcr: Boolean,
        ocr: OcrEngine?
    ): Result {
        val sink = TextSink(MAX_CHARS)
        var text: String? = null
        var note = ""
        var truncated = false

        when (format) {
            DocFormat.PDF -> {
                prepare(context)
                val opened = try {
                    PdfText.extractText(file, sink)
                } catch (e: InvalidPasswordException) {
                    // A password-protected PDF is a common thing to pick by
                    // accident, and "解析失败：InvalidPasswordException" would be
                    // a poor way to say so.
                    return failure(format, name, "这个 PDF 已加密（需要密码），无法读取")
                }
                if (!opened) {
                    return failure(format, name, "无法读取该 PDF（文件损坏或不是有效的 PDF）")
                }
                val digital = sink.toString()
                truncated = sink.truncated
                when {
                    PdfText.hasTextLayer(digital) -> text = digital

                    // Nothing to read. Some scans carry a stray text layer (a page
                    // number, a watermark); it is kept only if OCR finds nothing.
                    !allowOcr || ocr == null -> return failure(
                        format, name, "这是扫描件（没有文字层）；OCR 关闭时无法导入"
                    )

                    else -> {
                        val ocrSink = TextSink(MAX_CHARS)
                        val pages = try {
                            PdfText.extractScanned(file, PdfText.MAX_OCR_PAGES, ocrSink, ocr)
                        } catch (e: Exception) {
                            return failure(format, name, "OCR 失败：${e.javaClass.simpleName}")
                        }
                        truncated = truncated || ocrSink.truncated
                        val ocrText = ocrSink.toString()
                        when {
                            ocrText.isNotBlank() -> {
                                text = ocrText
                                note = PdfText.scannedMessage(pages)
                            }
                            digital.isNotBlank() -> {
                                text = digital
                                note = PdfText.scannedMessage(pages)
                            }
                            else -> return failure(format, name, PdfText.scannedMessage(0))
                        }
                    }
                }
            }

            DocFormat.DOCX ->
                if (!extractDocx(file, AndroidXml, sink)) return failure(format, name, unreadable(name))

            DocFormat.ODT ->
                if (!extractOdt(file, AndroidXml, sink)) return failure(format, name, unreadable(name))

            DocFormat.EPUB ->
                if (!extractEpub(file, AndroidXml, sink)) return failure(format, name, unreadable(name))

            DocFormat.PPTX ->
                if (!extractPptx(file, AndroidXml, sink)) return failure(format, name, unreadable(name))

            DocFormat.XLSX ->
                if (!extractXlsx(file, AndroidXml, sink)) return failure(format, name, unreadable(name))

            DocFormat.HTML ->
                if (!extractHtml(file, MAX_CHARS, sink)) return failure(format, name, unreadable(name))

            DocFormat.MARKDOWN, DocFormat.TEXT ->
                if (!extractPlainText(file, MAX_CHARS, sink)) return failure(format, name, unreadable(name))

            DocFormat.OLD_OFFICE -> return failure(
                format, name, "暂不支持老版 .doc/.xls/.ppt，请另存为 .docx/.xlsx/.pptx 后再导入"
            )

            DocFormat.UNKNOWN -> return failure(
                format, name,
                "无法识别这个文件的格式；目前支持 PDF/DOCX/ODT/EPUB/PPTX/XLSX/HTML/MD/TXT"
            )
        }

        // Every extractor's output goes through here before anything reads it, so
        // text that cannot be retrieved (spaced-out OCR, Kangxi radicals) never
        // reaches a note. See [TextNorm] for the measurements.
        val body = TextNorm.canonical(text ?: sink.toString())
        truncated = truncated || sink.truncated
        if (body.isBlank()) return failure(format, name, "文件里没有可用的文字")

        val allChunks = DocChunker.split(body, CHUNK_CHARS)
        if (allChunks.isEmpty()) return failure(format, name, "文件里没有可用的文字")
        val chunks = if (allChunks.size > MAX_CHUNKS) allChunks.subList(0, MAX_CHUNKS) else allChunks
        if (allChunks.size > MAX_CHUNKS) {
            note = joinNote(note, "内容较多，仅导入前 $MAX_CHUNKS 段")
        }
        if (truncated) note = joinNote(note, "内容过长，已截断")

        return Result(
            format = format,
            displayName = name,
            text = body,
            chunks = ArrayList(chunks),
            truncated = truncated,
            note = note,
            error = ""
        )
    }

    private fun unreadable(name: String) = "「$name」解析不出文字，文件可能已损坏"

    private fun joinNote(existing: String, extra: String): String =
        if (existing.isEmpty()) extra else "$existing；$extra"

    private fun failure(format: DocFormat, name: String, message: String) =
        Result(format, name, "", emptyList(), false, "", message)

    // ---------------------------------------------------------------- picking

    /** The document's own name, as the picker reports it. */
    private fun displayName(context: Context, uri: Uri): String {
        val fromProvider = runCatching {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst() && cursor.columnCount > 0) cursor.getString(0) else null
                }
        }.getOrNull()
        if (!fromProvider.isNullOrBlank()) return fromProvider
        val last = uri.lastPathSegment?.substringAfterLast('/')
        return if (last.isNullOrBlank()) "文档" else last
    }

    /**
     * Copy the picked document into the cache directory and hand back the file.
     *
     * A real file is required, not a convenience: PDFBox's stream overload buffers
     * the whole document on the heap, and `PdfRenderer` seeks. The copy also
     * means one `openInputStream` call per import, which is what content
     * providers expect.
     *
     * The caller deletes the file. Throws with a user-facing message on failure.
     */
    private fun copyToCache(context: Context, uri: Uri, name: String): File {
        val suffix = name.substringAfterLast('.', "").let { if (it.isEmpty()) "" else ".$it" }
        val temp = File.createTempFile("doc-import-", suffix, context.cacheDir)
        var written = 0L
        try {
            val input = context.contentResolver.openInputStream(uri)
                ?: throw IllegalStateException("打不开这个文件（没有读取权限或文件已不存在）")
            input.use { source ->
                temp.outputStream().use { target ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = source.read(buf)
                        if (n < 0) break
                        written += n
                        if (written > MAX_FILE_BYTES) {
                            throw IllegalStateException(
                                "文件超过 ${MAX_FILE_BYTES / 1024 / 1024} MB，暂不支持导入"
                            )
                        }
                        target.write(buf, 0, n)
                    }
                }
            }
            if (written == 0L) throw IllegalStateException("这个文件是空的")
        } catch (e: Exception) {
            temp.delete()
            throw e
        }
        return temp
    }

    // ------------------------------------------------------------- note shape

    /** `<文件名> (1/3)` — what one chunk is called in the knowledge base. */
    fun chunkTitle(displayName: String, index: Int, total: Int): String =
        "$displayName ($index/$total)"

    /**
     * The tags every chunk of one import carries.
     *
     * @param topic 当前人设卡的主题（可为空）。非空时一并写进标签 —— 于是
     *  「选网调人设 → 导入 → 以后只捞网调」这条链在导入的当下就闭合了，而不是
     *  等用户事后一条条补标签。空主题不多写任何标签（老行为，逐字不变）。
     */
    fun chunkTags(displayName: String, topic: String = ""): List<String> {
        val t = topic.trim()
        return if (t.isEmpty()) listOf("文档导入", displayName)
        else listOf("文档导入", displayName, t)
    }
}

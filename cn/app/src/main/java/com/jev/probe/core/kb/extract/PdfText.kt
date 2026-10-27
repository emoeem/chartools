package com.jev.probe.core.kb.extract

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.jev.probe.core.ocr.OcrEngine
import com.jev.probe.core.ocr.OcrLine
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * PDF text, the two ways a PDF can hold it.
 *
 * A digital PDF carries a text layer, and PDFBox reads it directly. A scanned
 * PDF is a stack of images and has none, so its pages are rendered and handed to
 * the OCR engine that already ships with this app — no PDF-specific OCR
 * machinery, and nothing downloaded.
 *
 * Both paths take a **file**, never a stream. That is the single most important
 * detail here: `PDDocument.load(InputStream)` buffers the entire document on the
 * Java heap (a 100 MB PDF becomes a 100 MB byte array before parsing even
 * starts), and `PdfRenderer` cannot use a pipe at all because it seeks. The
 * caller therefore copies the picked URI into the app's cache directory first,
 * and this code reads from disk.
 */
internal object PdfText {

    /** Fewer non-whitespace characters than this and the PDF is treated as scanned. */
    const val MIN_TEXT_CHARS = 100

    /** Pages OCR'd in one import. A 500-page scan is hours of work, not a note. */
    const val MAX_OCR_PAGES = 20

    /** Longest a single page may take before it is given up on. */
    private const val OCR_TIMEOUT_SECONDS = 60L

    /** How wide a rendered page may be, in pixels, before it is scaled down. */
    private const val OCR_TARGET_MAX_PX = 2000f

    /** Rendering scale is capped so a tiny page does not blow up to a huge bitmap. */
    private const val OCR_MAX_SCALE = 2.0f

    /**
     * Read a digital PDF's text layer. False when the document cannot be opened
     * at all (corrupt, or the file is not really a PDF).
     */
    fun extractText(file: File, sink: TextSink): Boolean {
        val doc = PDDocument.load(file) ?: return false
        return doc.use {
            sink.append(PDFTextStripper().getText(it))
            true
        }
    }

    /**
     * Render and OCR up to [maxPages] pages.
     *
     * The caller must not be the main thread: the OCR callback is delivered on
     * the main looper, so blocking here while waiting for it would deadlock.
     * The engine is injected: core.kb.extract must not construct capture's
     * [com.jev.probe.capture.ocr.MlKitOcr] itself (that import would point
     * core back at capture).
     *
     * @return how many pages were actually recognized.
     */
    fun extractScanned(file: File, maxPages: Int, sink: TextSink, ocr: OcrEngine): Int {
        var done = 0
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
            PdfRenderer(fd).use { renderer ->
                val pages = minOf(renderer.pageCount, maxPages)
                for (index in 0 until pages) {
                    // The explicit label matters: `use` is nested three deep
                    // here, and a bare `return@use` is ambiguous to the reader
                    // (the compiler warns about it, correctly).
                    renderer.openPage(index).use page@{ page ->
                        // A page PdfRenderer reports as 0×0 would make an
                        // illegal bitmap; skip rather than throw.
                        if (page.width <= 0 || page.height <= 0) return@page
                        val scale = minOf(
                            OCR_MAX_SCALE,
                            OCR_TARGET_MAX_PX / maxOf(page.width, page.height)
                        )
                        val w = maxOf(1, (page.width * scale).toInt())
                        val h = maxOf(1, (page.height * scale).toInt())
                        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                        try {
                            // ML Kit reads a transparent bitmap as an empty page,
                            // so the background has to be painted first.
                            bitmap.eraseColor(Color.WHITE)
                            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            val lines = recognize(ocr, bitmap)
                            if (index > 0) sink.newline()
                            for (line in lines) {
                                if (line.text.isBlank()) continue
                                sink.appendFlow(line.text)
                                sink.newline()
                            }
                            done++
                        } finally {
                            bitmap.recycle()
                        }
                    }
                    if (sink.truncated) break
                }
            }
        }
        return done
    }

    /**
     * Bridge ML Kit's asynchronous, main-thread callback into the blocking call
     * this background worker wants. Returns an empty list on timeout — a page
     * that will not recognize is not worth failing the whole import over.
     */
    private fun recognize(ocr: OcrEngine, bitmap: Bitmap): List<OcrLine> {
        val latch = CountDownLatch(1)
        var result: List<OcrLine> = emptyList()
        ocr.recognize(bitmap, null) { lines ->
            result = lines
            latch.countDown()
        }
        latch.await(OCR_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        return result
    }

    /** Whether a text layer is substantial enough to be worth keeping. */
    fun hasTextLayer(text: String): Boolean =
        text.count { !it.isWhitespace() } >= MIN_TEXT_CHARS

    /** A short, human-readable reason for a PDF that yielded nothing. */
    fun scannedMessage(pages: Int): String =
        if (pages == 0) "PDF 无文字层，OCR 未识别出内容"
        else "PDF 无文字层，已用 OCR 识别前 $pages 页"
}

package com.jev.probe.core.ocr

import android.graphics.Bitmap
import android.graphics.Rect

/** One recognized text line. [bounds] is in the coordinate space the caller
 * works in: screenshot pixels for capture, page pixels for document import. */
data class OcrLine(val text: String, val bounds: Rect)

/**
 * Text recognition over an image.
 *
 * [region] is in BITMAP coordinates (the caller scales node rects by the
 * screenshot's scaleX/scaleY); null means the whole bitmap. The callback is
 * delivered on the main thread and always fires — an engine failure comes back
 * as an empty list, never as an exception on the caller's thread.
 *
 * Lives under `core` so capture is not the only consumer: scanned-PDF import
 * (`core.kb.extract.PdfText`) needs the same abstraction, and a port here is
 * what keeps `core` from importing `capture` back. v1.3 has exactly one
 * implementation, [com.jev.probe.capture.ocr.MlKitOcr]. The vision-model OCR is
 * deliberately NOT on this path (see docs/v1.3-plan.md, B stage revision).
 */
interface OcrEngine {
    fun recognize(bitmap: Bitmap, region: Rect?, cb: (List<OcrLine>) -> Unit)
}

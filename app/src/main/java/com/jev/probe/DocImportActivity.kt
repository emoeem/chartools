package com.jev.probe

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import com.jev.probe.core.Prefs
import com.jev.probe.core.kb.KbStore
import com.jev.probe.core.kb.Note
import com.jev.probe.core.kb.TopicScope
import com.jev.probe.core.kb.extract.DocImport

/**
 * Pick documents, turn them into text, save that text as knowledge notes.
 *
 * The whole screen is one flow: choose files → extract (off the main thread,
 * with a progress bar) → look at what came out → save it or clear it. Nothing
 * leaves the device: extraction is local, and the only thing written is the
 * notes, through the same [KbStore] the knowledge screen uses.
 *
 * The activity deliberately does not import a document and save it in one
 * gesture. Extraction can produce hundreds of chunks and can take minutes on a
 * scanned PDF, so the user gets to see the result — and the size of it — before
 * anything is written to the knowledge base.
 */
class DocImportActivity : AppCompatActivity() {

    /**
     * One chunk waiting to be saved. The note is not built until the user asks
     * for it, so clearing the screen costs nothing and the preview and the saved
     * notes can never disagree.
     */
    private class Pending(val title: String, val content: String, val tags: List<String>)

    private val pending = ArrayList<Pending>()
    private val report = ArrayList<String>()
    private val preview = StringBuilder()
    private var busy = false

    /**
     * 导入时写进标签的人设主题（没填人设时为空）。
     *
     * 有了它，「在设置里选网调人设 → 导入的文件 → 以后只捞网调」这条链在导入的
     * 当下就闭合了；否则用户得像做数据治理一样，事后一条条给几百条笔记补标签。
     * 惰性求值，因为文件选择器回来之前一次都不会用到。
     */
    private val personaTopic: String by lazy { TopicScope.topicOf(Prefs(this)) }

    private lateinit var pickButton: Button
    private lateinit var saveButton: Button
    private lateinit var clearButton: Button
    private lateinit var progress: ProgressBar
    private lateinit var status: TextView
    private lateinit var previewView: TextView

    /** The picker, launched with our own intent so the MIME filter is explicit. */
    private val picker = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode != RESULT_OK) return@registerForActivityResult
        val uris = pickedUris(result.data)
        if (uris.isEmpty()) return@registerForActivityResult
        startImport(uris)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_doc_import)
        findViewById<View>(R.id.docRoot).padForSystemBars()

        pickButton = findViewById(R.id.docPick)
        saveButton = findViewById(R.id.docSave)
        clearButton = findViewById(R.id.docClear)
        progress = findViewById(R.id.docProgress)
        status = findViewById(R.id.docStatus)
        previewView = findViewById(R.id.docPreview)

        // PDFBox cannot find its glyph list until this runs; doing it now rather
        // than at the first import keeps that first import from stalling.
        DocImport.prepare(this@DocImportActivity)

        pickButton.setOnClickListener { launchPicker() }
        findViewById<Button>(R.id.docUrl).setOnClickListener { askForUrl() }
        saveButton.setOnClickListener { save() }
        clearButton.setOnClickListener { reset() }
        render()
    }

    // ------------------------------------------------------------------ pick

    private fun launchPicker() {
        if (busy) return
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, MIME_TYPES)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        // No takePersistableUriPermission: this screen reads the text out of the
        // chosen file straight away and keeps no reference to it afterwards, so
        // a persisted grant would be a permission the app never uses again.
        runCatching { picker.launch(intent) }
            .onFailure { toast("没有可用的文件选择器") }
    }

    private fun pickedUris(data: Intent?): List<Uri> {
        if (data == null) return emptyList()
        val out = ArrayList<Uri>()
        data.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) clip.getItemAt(i)?.uri?.let { out.add(it) }
        }
        if (out.isEmpty()) data.data?.let { out.add(it) }
        // One import can create hundreds of notes; a hundred files at once is a
        // mistake, not a request.
        return if (out.size > MAX_FILES) out.subList(0, MAX_FILES).toList() else out
    }

    // ---------------------------------------------------------------- import

    private fun startImport(uris: List<Uri>) {
        if (busy) return
        busy = true
        busyUi(true)
        status.text = "正在解析 ${uris.size} 个文件…"

        Thread {
            val newPending = ArrayList<Pending>()
            val lines = ArrayList<String>()
            val text = StringBuilder()
            for (uri in uris) {
                val result = try {
                    DocImport.import(this@DocImportActivity, uri)
                } catch (e: Exception) {
                    null
                }
                if (result == null) {
                    lines.add("✗ 有一个文件解析失败（${uri.lastPathSegment ?: "未知"}）")
                    continue
                }
                accumulate(result, lines, newPending, text)
            }
            val previewText = text.toString()
            runOnUiThread {
                pending.addAll(newPending)
                report.addAll(lines)
                if (previewText.isNotEmpty() && preview.length < PREVIEW_LIMIT) {
                    preview.append(previewText.take(PREVIEW_LIMIT - preview.length))
                }
                busy = false
                busyUi(false)
                render()
            }
        }.start()
    }

    /**
     * Fetch a web page and run it through the same pipeline as a picked file.
     * The user's chosen formats include "网页链接（存正文）", and a link is the
     * only one of them that never touches the file picker.
     */
    private fun importUrl(url: String) {
        if (busy) return
        busy = true
        busyUi(true)
        status.text = "正在下载并解析网页…"

        Thread {
            val newPending = ArrayList<Pending>()
            val lines = ArrayList<String>()
            val text = StringBuilder()
            val result = try {
                DocImport.importUrl(this@DocImportActivity, url)
            } catch (e: Exception) {
                null
            }
            if (result == null) {
                lines.add("✗ 网页解析失败")
            } else {
                accumulate(result, lines, newPending, text)
            }
            val previewText = text.toString()
            runOnUiThread {
                pending.addAll(newPending)
                report.addAll(lines)
                if (previewText.isNotEmpty() && preview.length < PREVIEW_LIMIT) {
                    preview.append(previewText.take(PREVIEW_LIMIT - preview.length))
                }
                busy = false
                busyUi(false)
                render()
            }
        }.start()
    }

    /** Fold one parsed document into this session's pending notes and preview. */
    private fun accumulate(
        result: DocImport.Result,
        lines: MutableList<String>,
        newPending: MutableList<Pending>,
        text: StringBuilder
    ) {
        if (!result.ok) {
            lines.add("✗ ${result.displayName}：${result.error}")
            return
        }
        val tags = DocImport.chunkTags(result.displayName, personaTopic)
        result.chunks.forEachIndexed { index, chunk ->
            newPending.add(
                Pending(
                    DocImport.chunkTitle(result.displayName, index + 1, result.chunks.size),
                    chunk,
                    tags
                )
            )
        }
        val extra = if (result.note.isEmpty()) "" else "（${result.note}）"
        lines.add(
            "✓ ${result.displayName} · ${result.format.name} · " +
                "${result.text.length} 字 · ${result.chunks.size} 段$extra"
        )
        if (text.length < PREVIEW_LIMIT) {
            text.append("［${result.displayName}］\n")
            text.append(result.text.take(PREVIEW_LIMIT - text.length))
            text.append("\n\n")
        }
    }

    private fun askForUrl() {
        if (busy) return
        val input = android.widget.EditText(this).apply {
            hint = "https://…"
            setSingleLine(true)
            inputType = android.text.InputType.TYPE_TEXT_VARIATION_URI
            // Pasting the link is the whole point of this dialog, so prefill from
            // the clipboard when there is something URL-shaped on it.
            getSystemService(CLIPBOARD_SERVICE)?.let { svc ->
                val cm = svc as android.content.ClipboardManager
                val clip = cm.primaryClip?.takeIf { it.itemCount > 0 }
                    ?.getItemAt(0)?.coerceToText(this@DocImportActivity)?.toString()?.trim()
                if (clip != null && (clip.startsWith("http://") || clip.startsWith("https://"))) {
                    setText(clip)
                }
            }
        }
        val wrap = android.widget.FrameLayout(this).apply {
            val pad = (16 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad / 2, pad, 0)
            addView(input)
        }
        androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("粘贴网页链接")
            .setMessage("只抓取这一页的正文文字，存成本机笔记。")
            .setView(wrap)
            .setPositiveButton("抓取") { _, _ ->
                val url = input.text.toString().trim()
                if (url.isNotEmpty()) importUrl(url)
            }
            .setNegativeButton("取消", null)
            .show()
    }

    // ------------------------------------------------------------------ save

    private fun save() {
        if (busy || pending.isEmpty()) return
        val store = KbStore.get(this@DocImportActivity)
        val batch = ArrayList(pending)
        busy = true
        busyUi(true)
        status.text = "正在保存 ${batch.size} 条笔记…"

        Thread {
            val notes = batch.map {
                Note(id = KbStore.newId(), title = it.title, content = it.content, tags = it.tags)
            }
            // Skip anything the knowledge base already has, verbatim. Re-importing
            // the same file used to double every chunk, and the copies then
            // competed with each other for the (five) note slots in a prompt —
            // measured on the real library: 10 of 113 enabled notes were exact
            // duplicates. Also de-duplicates within this batch, since two of the
            // source documents overlap.
            val stored = try {
                store.notes().mapTo(HashSet()) { it.content }
            } catch (e: Exception) {
                HashSet()
            }
            val fresh = ArrayList<Note>(notes.size)
            for (n in notes) if (stored.add(n.content)) fresh.add(n)
            val skipped = notes.size - fresh.size
            // One call, one serialisation, one write. Saving note by note would
            // re-write the whole file once per note — quadratic, and a 20-file
            // import is 300-odd notes.
            val saved = try {
                store.saveNotes(fresh)
            } catch (e: Exception) {
                0
            }
            runOnUiThread {
                busy = false
                busyUi(false)
                if (saved == 0 && fresh.isNotEmpty()) {
                    // Nothing reached disk. Keep every extracted chunk on screen:
                    // retrying must not mean picking twenty files again.
                    report.add("✗ 保存失败：没有写入知识库，内容还留在本页，可以再试一次")
                    render()
                    toast("保存失败，内容还留着，可以再试一次")
                } else {
                    if (skipped > 0) report.add("— 跳过 $skipped 条：知识库里已经有同样的内容")
                    pending.clear()
                    report.clear()
                    preview.setLength(0)
                    render()
                    toast(
                        if (skipped > 0) "已保存 $saved 条，跳过 $skipped 条重复"
                        else "已保存 $saved 条笔记"
                    )
                }
            }
        }.start()
    }

    private fun reset() {
        if (busy) return
        pending.clear()
        report.clear()
        preview.setLength(0)
        render()
    }

    // ------------------------------------------------------------------- ui

    private fun busyUi(working: Boolean) {
        progress.visibility = if (working) View.VISIBLE else View.GONE
        pickButton.isEnabled = !working
        clearButton.isEnabled = !working
        saveButton.isEnabled = !working && pending.isNotEmpty()
    }

    private fun render() {
        if (report.isEmpty()) {
            status.text = "还没有选择文件"
        } else {
            val chunkCount = pending.size
            status.text = report.joinToString("\n") +
                (if (chunkCount > 0) "\n共 $chunkCount 段，可保存为 $chunkCount 条笔记" else "")
        }
        previewView.text = if (preview.isEmpty()) {
            "选好文件后，这里会显示提取出来的文字。"
        } else {
            preview.toString()
        }
        saveButton.isEnabled = !busy && pending.isNotEmpty()
    }

    private fun toast(message: String) =
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()

    private companion object {
        /** More files than this in one pick is a mistake, not a request. */
        const val MAX_FILES = 20

        /** How much extracted text is shown on screen. The notes hold all of it. */
        const val PREVIEW_LIMIT = 4000

        /**
         * A wildcard type on its own would hide the files this screen exists for
         * behind an "all files" filter, and a strict list would hide DOCX on the
         * providers that report it as a generic binary type. Both are needed.
         */
        val MIME_TYPES = arrayOf(
            "application/pdf",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.oasis.opendocument.text",
            "application/epub+zip",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "text/html",
            "text/markdown",
            "text/plain",
            "application/octet-stream"
        )
    }
}

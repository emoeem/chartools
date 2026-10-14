package com.jev.probe.core.skill

import android.content.Context
import android.util.Log
import com.jev.probe.core.Trace
import java.io.File
import java.io.InputStream
import java.util.UUID

/**
 * Skills on disk: `<filesDir>/skills/<name>/SKILL.md`, exactly the layout the
 * Agent Skills specification describes, so an imported skill stays a normal
 * skill (and can be exported back out unchanged).
 *
 * Import is a zip: staged under `.staging/<uuid>/`, validated while staging, and
 * only then moved into place with one rename — the same "never leave a half
 * written entry visible" rule [com.jev.probe.core.kb.KbStore] uses.
 *
 * Nothing here executes anything. A skill's `scripts/` are kept as files and
 * shown as resources; they are never run.
 */
class SkillStore private constructor(app: Context) {

    private val root = File(app.filesDir, DIR)

    /** Every skill that parsed, newest directory first is not meaningful — sorted by name. */
    fun list(): List<Skill> {
        val dirs = root.listFiles { f -> f.isDirectory && !f.name.startsWith(".") } ?: return emptyList()
        val out = ArrayList<Skill>(dirs.size)
        for (dir in dirs.sortedBy { it.name }) {
            val md = File(dir, SkillMd.FILE_NAME)
            if (!md.isFile) continue
            val parsed = try {
                SkillMd.parse(md.readText(Charsets.UTF_8))
            } catch (e: Exception) {
                Log.w(TAG, "skill ${dir.name}: unreadable (${e.javaClass.simpleName})")
                null
            }
            if (parsed == null) {
                Log.w(TAG, "skill ${dir.name}: frontmatter invalid, skipped")
                continue
            }
            val (frontmatter, body) = parsed
            if (frontmatter.name != dir.name) {
                // The specification requires the directory name to equal `name`;
                // a mismatch would make the same skill load under two identities.
                Log.w(TAG, "skill ${dir.name}: name=${frontmatter.name} does not match directory, skipped")
                continue
            }
            out.add(
                Skill(
                    frontmatter, body, dir,
                    enabled = !File(dir, DISABLED).exists(),
                    always = File(dir, ALWAYS).exists()
                )
            )
        }
        return out
    }

    fun enabledRefs(): List<SkillRef> =
        list().filter { it.enabled }.map { SkillRef(it.name, it.description) }

    fun find(name: String): Skill? = list().firstOrNull { it.name == name }

    fun setEnabled(name: String, on: Boolean) {
        val dir = File(root, name)
        if (!dir.isDirectory) return
        val marker = File(dir, DISABLED)
        runCatching { if (on) marker.delete() else marker.createNewFile() }
    }

    /** Turn "inject this body every round" on or off. Only meaningful when on. */
    fun setAlways(name: String, on: Boolean) {
        val dir = File(root, name)
        if (!dir.isDirectory) return
        val marker = File(dir, ALWAYS)
        runCatching { if (on) marker.createNewFile() else marker.delete() }
        Trace.log("skill always name=$name on=$on")
    }

    fun delete(name: String): Boolean {
        val dir = File(root, name)
        if (!dir.isDirectory) return false
        return runCatching { dir.deleteRecursively() }.getOrDefault(false)
    }

    /**
     * Import one skill from a zip stream.
     *
     * The zip may hold `SKILL.md` at its root, or inside a single top-level
     * directory (what `zip -r my-skill/` and GitHub's "Download ZIP" produce) —
     * that wrapper is stripped. The installed directory is named after the
     * frontmatter `name`, not after whatever the archive happened to call it.
     *
     * @return a message for the user; never throws.
     */
    fun importZip(input: InputStream): String {
        val staging = File(root, "$STAGING/${UUID.randomUUID()}")
        try {
            if (!staging.mkdirs()) return "无法创建临时目录"
            val entries = SkillZip.extract(input, staging)
            if (entries == 0) return "压缩包里没有文件"
            val holder = locateSkillDir(staging) ?: return "压缩包里没有 ${SkillMd.FILE_NAME}"
            val md = File(holder, SkillMd.FILE_NAME)
            val parsed = try {
                SkillMd.parse(md.readText(Charsets.UTF_8))
            } catch (e: Exception) {
                null
            } ?: return "${SkillMd.FILE_NAME} 的 frontmatter 不合法（需要 name/description）"
            val (frontmatter, _) = parsed
            val target = File(root, frontmatter.name)
            if (target.exists() && !target.deleteRecursively()) return "同名技能已存在且删不掉：${frontmatter.name}"
            if (!holder.renameTo(target)) {
                // Different mount or a stale handle: copy then drop the staging copy.
                if (!holder.copyRecursively(target, overwrite = true)) return "安装失败：${frontmatter.name}"
                holder.deleteRecursively()
            }
            // Imported skills start OFF: an arbitrary prompt block must never
            // silently join every round just because it was imported.
            runCatching { File(target, DISABLED).createNewFile() }
            runCatching { File(target, ALWAYS).delete() }
            Trace.log("skill import name=${frontmatter.name} entries=$entries")
            return "已导入技能：${frontmatter.name}"
        } catch (e: Exception) {
            Log.w(TAG, "skill import failed: ${e.javaClass.simpleName}")
            Trace.log("skill import failed ${e.javaClass.simpleName}")
            return "导入失败：${e.javaClass.simpleName}"
        } finally {
            runCatching { staging.deleteRecursively() }
            runCatching { File(root, STAGING).delete() } // succeeds only when empty
        }
    }

    /** Import a bare SKILL.md (the whole file, frontmatter included). */
    fun importSkillMd(text: String): String {
        val parsed = SkillMd.parse(text) ?: return "${SkillMd.FILE_NAME} 的 frontmatter 不合法（需要 name/description）"
        val (frontmatter, _) = parsed
        val target = File(root, frontmatter.name)
        if (target.exists() && !target.deleteRecursively()) return "同名技能已存在且删不掉：${frontmatter.name}"
        if (!target.mkdirs()) return "安装失败：${frontmatter.name}"
        return runCatching {
            File(target, SkillMd.FILE_NAME).writeText(text, Charsets.UTF_8)
            // A freshly imported skill is off until the user turns it on: an
            // arbitrary prompt block should never silently join every round.
            File(target, DISABLED).createNewFile()
            runCatching { File(target, ALWAYS).delete() }
            Trace.log("skill import md name=${frontmatter.name}")
            "已导入技能：${frontmatter.name}"
        }.getOrElse { "写入失败：${it.javaClass.simpleName}" }
    }

    /**
     * Import a skill pack bundled in the app's own assets (`assets/skills/<dirName>/`).
     *
     * The whole directory is copied into place, frontmatter parsed first so the
     * install lands under the name the skill declares. An existing install is
     * left untouched — delete it first to refresh from the bundle.
     *
     * @param enable install with the skill switched ON. The zip path defaults new
     *        skills to off because an arbitrary import must never silently join
     *        every round; the bundled pack is curated and the UI button says
     *        "导入并启用", so here the choice is explicit, not silent.
     * @return a message for the user; never throws.
     */
    fun importBundled(app: Context, dirName: String, enable: Boolean): String {
        val md = runCatching {
            app.assets.open("$ASSET_DIR/$dirName/${SkillMd.FILE_NAME}")
                .bufferedReader(Charsets.UTF_8).use { it.readText() }
        }.getOrElse { return "内置技能包缺失：$dirName" }
        val parsed = SkillMd.parse(md) ?: return "内置技能包的 frontmatter 不合法"
        val name = parsed.first.name
        val target = File(root, name)
        if (target.isDirectory) return "「$name」已安装（先删除才能重新导入）"
        if (!target.mkdirs()) return "安装失败：$name"
        return runCatching {
            copyAssetDir(app, "$ASSET_DIR/$dirName", target)
            if (enable) File(target, DISABLED).delete() else File(target, DISABLED).createNewFile()
            Trace.log("skill bundled import name=$name enable=$enable")
            if (enable) "已导入并启用：$name" else "已导入：$name（默认关闭）"
        }.getOrElse {
            target.deleteRecursively()
            "安装失败：${it.javaClass.simpleName}"
        }
    }

    /** Recursively copy an assets directory tree onto disk. */
    private fun copyAssetDir(app: Context, assetPath: String, target: File) {
        val children = app.assets.list(assetPath) ?: return
        if (children.isEmpty()) {
            app.assets.open(assetPath).use { input -> target.outputStream().use { input.copyTo(it) } }
            return
        }
        target.mkdirs()
        for (child in children) copyAssetDir(app, "$assetPath/$child", File(target, child))
    }

    /** `SKILL.md` at the root, or the single top-level directory holding it. */
    private fun locateSkillDir(staging: File): File? {
        if (File(staging, SkillMd.FILE_NAME).isFile) return staging
        val children = staging.listFiles()?.filter { it.isDirectory } ?: return null
        return children.firstOrNull { File(it, SkillMd.FILE_NAME).isFile }
    }

    companion object {
        private const val TAG = "JEVASSIST"
        private const val DIR = "skills"
        private const val STAGING = ".staging"

        /** Where bundled packs live inside the APK's assets. */
        const val ASSET_DIR = "skills"

        /** The bundled methodology pack (狗头军师, MIT) shipped in assets. */
        const val BUNDLED_PACK = "goutoujunshi"

        /** Marker file that turns a skill off; kept inside the skill directory so
         *  export/import of the skill itself never carries state. */
        private const val DISABLED = ".disabled"

        /** Marker that keeps the body in every round. Also never leaves this install. */
        private const val ALWAYS = ".always"

        @Volatile private var instance: SkillStore? = null

        fun get(app: Context): SkillStore =
            instance ?: synchronized(this) {
                instance ?: SkillStore(app.applicationContext).also { instance = it }
            }
    }
}

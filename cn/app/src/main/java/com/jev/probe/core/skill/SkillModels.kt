package com.jev.probe.core.skill

import java.io.File

/**
 * The frontmatter fields of the Agent Skills specification
 * (<https://agentskills.io/specification>). Kept field-for-field identical to
 * Google's Kotlin implementation in `com.google.adk:google-adk-kotlin-core-android`
 * so a skill written for one is importable by the other.
 */
data class SkillFrontmatter(
    val name: String,
    val description: String,
    val license: String? = null,
    val compatibility: String? = null,
    val allowedTools: String? = null,
    val metadata: Map<String, String> = emptyMap()
)

/** A skill on disk: `<filesDir>/skills/<name>/SKILL.md` plus whatever it ships beside it. */
data class Skill(
    val frontmatter: SkillFrontmatter,
    val body: String,
    val dir: File,
    val enabled: Boolean,
    /**
     * Inject the body on *every* round, not only when the local matcher scores a
     * hit. Matching is deliberately strict (two shared terms), so a skill the
     * user always wants — a house style, a fixed persona — needs a way to say so
     * without relying on the chat happening to mention the right words.
     */
    val always: Boolean = false
) {
    val name: String get() = frontmatter.name
    val description: String get() = frontmatter.description

    /** Files next to SKILL.md, relative paths, sorted — the L3 layer. */
    fun resources(): List<String> = dir.walkTopDown()
        .filter { it.isFile && it.name != SkillMd.FILE_NAME }
        .map { it.relativeTo(dir).path.replace(File.separatorChar, '/') }
        .filterNot { it.startsWith(".") }
        .sorted()
        .toList()
}

/** The L1 entry: what stays in the prompt as a catalogue. */
data class SkillRef(val name: String, val description: String)

/** A skill whose body was pulled in for one round, and why. */
data class SkillHit(
    val ref: SkillRef,
    val body: String,
    val score: Double,
    /**
     * L3：从技能自带的资源文件里按本轮对话挑出来的参考资料（狗头军师的
     * references 目录下的 markdown 这类）。空串表示没有或没命中。由
     * [SkillResources.select] 生成，长度已在选择时封顶；注入时随正文一起进提示词。
     */
    val extra: String = ""
)

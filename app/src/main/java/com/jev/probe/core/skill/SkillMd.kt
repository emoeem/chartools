package com.jev.probe.core.skill

/**
 * The SKILL.md reader: a `---` fenced block of scalars, then the body.
 *
 * Hand-written rather than pulled in. The reference implementation
 * (`SkillMdParsing.kt` in google/adk-kotlin) reaches for snakeyaml, and taking
 * the ADK artifact to get it drags in google-genai, Room, appsearch,
 * google-auth, opentelemetry and kxml2 with it — for six scalars and a string
 * map. The subset that the specification actually uses is parsed below in full.
 *
 * Anything malformed returns null; the caller logs and skips that one skill
 * rather than failing the round.
 */
object SkillMd {

    const val FILE_NAME = "SKILL.md"
    const val NAME_MAX = 64
    const val DESCRIPTION_MAX = 1024
    const val COMPATIBILITY_MAX = 500

    private val NAME_OK = Regex("^[a-z0-9]+(-[a-z0-9]+)*$")

    /** name/description (and the separators) per the specification; `allowed-tools`
     *  is a space-separated string there — a YAML list is invalid, not coerced. */
    fun parse(text: String): Pair<SkillFrontmatter, String>? {
        val lines = text.replace("\r\n", "\n").replace('\r', '\n').split('\n')
        if (lines.isEmpty() || lines[0].trim() != "---") return null
        var end = -1
        for (i in 1 until lines.size) {
            if (lines[i].trim() == "---") { end = i; break }
        }
        if (end < 0) return null

        val scalars = HashMap<String, String>()
        val metadata = LinkedHashMap<String, String>()
        var nested: String? = null
        for (i in 1 until end) {
            val raw = lines[i]
            if (raw.isBlank()) continue
            if (raw[0] == ' ' || raw[0] == '\t') {
                // Continuation of a nested block; only `metadata` is a string map.
                val key = raw.trim().substringBefore(':').trim()
                val value = raw.trim().substringAfter(':', "").trim()
                if (nested == "metadata" && key.isNotEmpty()) metadata[key] = unquote(value)
                continue
            }
            val key = raw.substringBefore(':').trim()
            val value = raw.substringAfter(':', "").trim()
            if (key.isEmpty()) continue
            if (value.isEmpty()) { nested = key; continue }
            nested = null
            scalars[key] = unquote(value)
        }

        val name = scalars["name"]?.trim().orEmpty()
        val description = scalars["description"]?.trim().orEmpty()
        if (!validName(name)) return null
        if (description.isEmpty() || description.length > DESCRIPTION_MAX) return null
        val compatibility = scalars["compatibility"]?.trim()
        if (compatibility != null && compatibility.length > COMPATIBILITY_MAX) return null
        val allowed = scalars["allowed-tools"]?.trim()

        val body = lines.drop(end + 1).joinToString("\n").trim()
        return SkillFrontmatter(
            name = name,
            description = description,
            license = scalars["license"]?.trim()?.ifBlank { null },
            compatibility = compatibility?.ifBlank { null },
            allowedTools = allowed?.ifBlank { null },
            metadata = metadata
        ) to body
    }

    /** `[a-z0-9-]`, at most [NAME_MAX], no leading/trailing/doubled hyphen. */
    fun validName(name: String): Boolean =
        name.isNotEmpty() && name.length <= NAME_MAX && NAME_OK.matches(name)

    private fun unquote(value: String): String {
        if (value.length >= 2) {
            val first = value[0]
            val last = value[value.length - 1]
            if ((first == '"' && last == '"') || (first == '\'' && last == '\'')) {
                return value.substring(1, value.length - 1)
            }
        }
        return value
    }
}

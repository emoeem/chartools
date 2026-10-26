package com.jev.probe.core.kb

/**
 * Local knowledge base data model (v1.3, D stage).
 *
 * Everything here lives only in the app-private `filesDir/kb` directory as plain
 * JSON — no database, no network, no export. The user can wipe all of it from
 * settings ("清空知识库与历史"), which deletes that directory and nothing else.
 */

/**
 * [Note.type] marking a few-shot sample of the user's own writing voice rather
 * than a fact. The reply prompt quotes such a note as `<user_style_examples>`;
 * it is deliberately kept OUT of [ChatContext.background], because the judge
 * reads the background to understand the situation and a style sample is not
 * something anyone actually said.
 */
const val NOTE_TYPE_STYLE_SAMPLE = "style_sample"

/** One free-text knowledge note the user maintains by hand. */
data class Note(
    val id: String,
    val title: String,
    val content: String,
    val tags: List<String> = emptyList(),
    /** Always injected regardless of what the conversation is about. */
    val alwaysOn: Boolean = false,
    val enabled: Boolean = true,
    val updatedAt: Long = System.currentTimeMillis(),
    val type: String = "note"
)

/**
 * One person (or group) the user chats with. [aliases] is what makes a contact
 * cross-app: the same person shows up as different conversation titles in
 * QQ / Feishu / X, and each of those titles can be listed here.
 */
data class Contact(
    val id: String,
    val name: String,
    val aliases: List<String> = emptyList(),
    /** Package names this contact has been seen in, e.g. com.tencent.mobileqq. */
    val apps: List<String> = emptyList(),
    val relationship: String = "",
    val notes: String = "",
    val persona: String = "",
    /** Reserved for the (deferred) auto-summary; never written in v1.3. */
    val autoSummary: String = "",
    val updatedAt: Long = System.currentTimeMillis()
)

/** One remembered chat line. side is "me" / "other", matching [com.jev.probe.core.Msg]. */
data class LogEntry(val side: String, val text: String, val ts: Long, val app: String)

/**
 * What one analysis gets to see beyond the on-screen messages: who the other
 * party is, older history for them, and the knowledge notes that matched.
 */
data class ChatContext(
    val contact: Contact?,
    val history: List<LogEntry>,
    val notes: List<Note>,
    /**
     * Skills pulled in for THIS round (normally zero or one), already scored —
     * see [com.jev.probe.core.skill.SkillMatcher]. The always-on L1 catalogue
     * travels separately, in the reply prompt, since every enabled skill
     * contributes to it.
     */
    val skills: List<com.jev.probe.core.skill.SkillHit> = emptyList(),
    /**
     * The L1 catalogue (`<available_skills>…`) of every enabled skill, or "".
     * Always-on for the reply prompt, never part of [background] — Jev judges
     * the conversation, it has no business reading instructions for the writer.
     */
    val catalogue: String = "",
    /**
     * S1 会话台账：整段对话预扫出来的结构化卡片（称呼 / 关系 / 语气基线 /
     * 在办的事 / 已明确的边界 / 固定说法），见 [Ledger]。
     *
     * 只进**回复**提示词，不进 Jev 的 state：台账是给写手看的既定情况，
     * 判断侧读的是 [background] 与 [history] 两份原始事实。
     */
    val ledger: Ledger? = null
) {

    /** True when there is nothing extra to inject (then no field is sent at all). */
    fun isEmpty(): Boolean = history.isEmpty() && notes.isEmpty() &&
        (contact == null || (contact.relationship.isBlank() &&
            contact.notes.isBlank() && contact.autoSummary.isBlank()))

    /**
     * The `background` string injected into Jev's state and the reply prompt:
     * relationship + contact notes + auto-summary + each matched note as
     * "title: content". Blank when there is nothing to say — callers must then
     * omit the field entirely rather than send an empty one.
     *
     * @param defaultRelationship unused when the contact carries no relationship
     *        of its own — that global default already goes out separately as
     *        `chat.relationship`, so repeating it here would just duplicate it.
     *        A contact with no relationship set simply omits the "关系：" line.
     */
    fun background(defaultRelationship: String): String {
        val sb = StringBuilder()
        contact?.let { c ->
            val rel = c.relationship.trim()
            if (rel.isNotEmpty()) sb.append("关系：").append(rel).append('\n')
            if (c.notes.isNotBlank()) sb.append("关于").append(c.name).append("：")
                .append(c.notes.trim()).append('\n')
            if (c.autoSummary.isNotBlank()) sb.append("过往摘要：")
                .append(c.autoSummary.trim()).append('\n')
        }
        notes.filter { it.type != NOTE_TYPE_STYLE_SAMPLE }.forEach { n ->
            sb.append(n.title.trim()).append(": ").append(n.content.trim()).append('\n')
        }
        return sb.toString().trim()
    }
}

/**
 * 这一轮真正生效的关系：联系人自己写的关系优先，没写才用全局设置。
 *
 * 为什么必须是它：起草、判断、复查三条路都要拿「对方和我是什么关系」，
 * 各自直读全局设置的话，一个存了联系人的会话里会出现两行打架的「关系：」
 * （背景块里是联系人写的关系，正文行是全局的）——模型两头都想贴，
 * 写出来的就是那种既不像客户服务又不像朋友聊天的怪腔。
 */
fun ChatContext?.effectiveRelationship(default: String): String {
    val contactRel = this?.contact?.relationship?.trim().orEmpty()
    return contactRel.ifEmpty { default }
}

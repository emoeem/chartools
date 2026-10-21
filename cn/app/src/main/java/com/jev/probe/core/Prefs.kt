package com.jev.probe.core

import android.content.Context
import android.util.Log

/**
 * App-private config store. Holds the three API routes (judge / reply / vision),
 * the relationship description used in Jev's state, the conversation whitelist,
 * plus the context (D stage) and OCR (B stage) switches.
 *
 * API keys are AES-GCM encrypted with an Android Keystore key before they are
 * stored in app-private SharedPreferences. Only key lengths are ever logged.
 */
class Prefs(context: Context, prefsName: String = PREFS_MAIN) {

    private val sp = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
    private val apiKeyVault = ApiKeyVault(sp)
    private val keyStorageFailures = mutableSetOf<String>()

    /**
     * Only the real config migrates — and only the real config logs it. The
     * throwaway instances behind the settings test buttons and the KB self-check
     * have nothing to carry over, and used to print one migration line per tap.
     */
    init {
        if (prefsName == PREFS_MAIN) {
            migrateIfNeeded()
            migrateApiKeys()
            unseedBochaDefaultIfUnconfigured()
        }
    }

    /**
     * v1.2 -> v1.3: the single `openrouter_key` becomes the judge route's key.
     * `reply_model` keeps its old storage key, so it carries over untouched.
     */
    private fun migrateIfNeeded() {
        if (sp.getBoolean(K_MIGRATED_V13, false)) return   // runs exactly once
        val legacy = sp.getString(K_LEGACY_KEY, "") ?: ""
        val current = sp.getString(K_JUDGE_KEY, "") ?: ""
        val e = sp.edit().putBoolean(K_MIGRATED_V13, true)
        if (current.isBlank() && legacy.isNotBlank()) {
            e.putString(K_JUDGE_KEY, legacy)
            Log.i(TAG, "prefs migrated judgeKey.len=${legacy.length}")
        } else {
            Log.i(TAG, "prefs migrated judgeKey.len=${current.length} (no legacy key to copy)")
        }
        e.apply()
    }

    /**
     * Fresh install only: default the judge route to Bocha Jev (limited-time free).
     * Runs ONLY when there is no judge config whatsoever — the provider key was
     * never written AND both the current judge key and the legacy OpenRouter key
     * are blank. Any existing or migrated user is left completely untouched, so an
     * OpenRouter key can never be redirected to jev.bocha.cn. The [judgeProvider]
     * getter default stays OpenRouter on purpose; this only seeds a truly new sp.
     */
    /**
     * v1.4.0 seeded fresh installs to Bocha Jev; v1.4.1 restores OpenRouter as the
     * default (Bocha stays available, now second in the list). Undo that earlier
     * auto-seed exactly once, and only when the user never entered a key and never
     * picked a provider by hand — a saved key, or any non-Bocha provider, means a
     * real choice we must not touch. Fresh installs now get no seed at all: the
     * getters already default to OpenRouter.
     */
    private fun unseedBochaDefaultIfUnconfigured() {
        if (sp.getBoolean(K_UNSEEDED_BOCHA, false)) return
        val e = sp.edit().putBoolean(K_UNSEEDED_BOCHA, true)
        val prov = sp.getString(K_JUDGE_PROVIDER, null)
        val key = sp.getString(K_JUDGE_KEY, "") ?: ""
        if (prov == PROVIDER_BOCHA && key.isBlank()) {
            e.remove(K_JUDGE_PROVIDER).remove(K_JUDGE_BASE).remove(K_JUDGE_MODEL)
            Log.i(TAG, "prefs: reverted auto-seeded bocha default to openrouter")
        }
        e.apply()
    }

    // ---------------------------------------------------------------- judge

    /** "bocha" | "openrouter" | "typesafe" | "vercel" | "zen" | "custom". */
    var judgeProvider: String
        get() = sp.getString(K_JUDGE_PROVIDER, PROVIDER_OPENROUTER) ?: PROVIDER_OPENROUTER
        set(v) = sp.edit().putString(K_JUDGE_PROVIDER, v.trim()).apply()

    /** Host root; the path is appended per provider (see [judgeEndpoint]). */
    var judgeBaseUrl: String
        get() = sp.getString(K_JUDGE_BASE, DEFAULT_JUDGE_BASE_OPENROUTER) ?: DEFAULT_JUDGE_BASE_OPENROUTER
        set(v) = sp.edit().putString(K_JUDGE_BASE, v.trim()).apply()

    var judgeKey: String
        get() = readApiKey(K_JUDGE_KEY)
        set(v) = writeApiKey(K_JUDGE_KEY, v)

    var judgeModel: String
        get() = sp.getString(K_JUDGE_MODEL, DEFAULT_JUDGE_MODEL_OPENROUTER) ?: DEFAULT_JUDGE_MODEL_OPENROUTER
        set(v) = sp.edit().putString(K_JUDGE_MODEL, v.trim()).apply()

    /**
     * How the judge route speaks: [PROTO_DECISIONS] (the Jev/TypeSafe question
     * protocol) or [PROTO_CHAT] (an OpenAI-compatible chat model answering the
     * same question set, see [com.jev.probe.jev.ChatJudge]).
     *
     * Blank means "not chosen yet" — an install that predates this field, or the
     * settings test probe — and falls back to what the provider implies. Nothing
     * is migrated and no existing install changes route.
     */
    var judgeProtocol: String
        get() = sp.getString(K_JUDGE_PROTO, "") ?: ""
        set(v) = sp.edit().putString(K_JUDGE_PROTO, v.trim()).apply()

    /** The protocol actually used: the explicit choice, else the provider's own. */
    fun effectiveJudgeProtocol(): String = judgeProtocol.ifBlank {
        if (judgeProvider == PROVIDER_DEEPSEEK) PROTO_CHAT else PROTO_DECISIONS
    }

    /** Back-compat alias so older call sites keep compiling. */
    var openRouterKey: String
        get() = judgeKey
        set(v) { judgeKey = v }

    // ---------------------------------------------------------------- reply

    /** OpenAI-compatible base, up to and including `/v1`. */
    var replyBaseUrl: String
        get() = sp.getString(K_REPLY_BASE, DEFAULT_REPLY_BASE) ?: DEFAULT_REPLY_BASE
        set(v) = sp.edit().putString(K_REPLY_BASE, v.trim()).apply()

    /** Blank = fall back to [judgeKey]. */
    var replyKey: String
        get() = readApiKey(K_REPLY_KEY)
        set(v) = writeApiKey(K_REPLY_KEY, v)

    /** Generative model for drafting the 3 candidate replies. */
    var replyModel: String
        get() = sp.getString(K_REPLY_MODEL, DEFAULT_REPLY_MODEL) ?: DEFAULT_REPLY_MODEL
        set(v) = sp.edit().putString(K_REPLY_MODEL, v.trim()).apply()

    // --------------------------------------------------------------- vision

    /**
     * Blank = the OpenRouter vision default. Deliberately does NOT follow
     * [replyBaseUrl]: a reply host like DeepSeek has no vision endpoint, so
     * inheriting it would silently break OCR.
     */
    var visionBaseUrl: String
        get() = sp.getString(K_VISION_BASE, DEFAULT_VISION_BASE) ?: DEFAULT_VISION_BASE
        set(v) = sp.edit().putString(K_VISION_BASE, v.trim()).apply()

    /** Blank = fall back to [replyKey] then [judgeKey]. */
    var visionKey: String
        get() = readApiKey(K_VISION_KEY)
        set(v) = writeApiKey(K_VISION_KEY, v)

    var visionModel: String
        get() = sp.getString(K_VISION_MODEL, DEFAULT_VISION_MODEL) ?: DEFAULT_VISION_MODEL
        set(v) = sp.edit().putString(K_VISION_MODEL, v.trim()).apply()

    // -------------------------------------------------------- context (D)

    /**
     * Record per-contact history and inject it into analysis. Default OFF:
     * nothing about the user's chats is written to disk unless they opt in
     * (v1.3 revision, D stage).
     */
    var contextEnabled: Boolean
        get() = sp.getBoolean(K_CTX_ENABLED, false)
        set(v) = sp.edit().putBoolean(K_CTX_ENABLED, v).apply()

    // ----------------------------------------------------- ledger & review (S1)

    /**
     * S1 会话台账：把整段历史预扫成一张结构化卡片（称呼 / 关系 / 语气基线 /
     * 在办的事 / 已明确的边界 / 固定说法），每轮注入回复提示词。
     *
     * 默认开着，但它**只在 [contextEnabled] 已经打开时才有数据**：台账是从
     * 已经落盘的历史推导出来的，不引入任何新的采集。所以默认值跟着「已经不
     * 介意落盘」的用户走，而不是再问一次。
     */
    var ledgerEnabled: Boolean
        get() = sp.getBoolean(K_LEDGER, true)
        set(v) = sp.edit().putBoolean(K_LEDGER, v).apply()

    /**
     * S1 证据复查：候选排完序之后，再让模型带着理由过一遍，指出哪条站不住、
     * 该往哪个方向改（wenyi 的 evidence-driven review）。
     *
     * 默认**关**：它比排序多一次模型调用，是真金白银和延迟，让用户自己决定。
     */
    var reviewEnabled: Boolean
        get() = sp.getBoolean(K_REVIEW, false)
        set(v) = sp.edit().putBoolean(K_REVIEW, v).apply()

    /**
     * 复查路由。三个字段都留空表示沿用回复路由 —— 这是 wenyi 的
     * per-operation 模型路由的最小形态：先给一条独立的路，但默认不增加配置负担。
     */
    var reviewBaseUrl: String
        get() = sp.getString(K_REVIEW_BASE, "") ?: ""
        set(v) = sp.edit().putString(K_REVIEW_BASE, v.trim()).apply()

    var reviewKey: String
        get() = readApiKey(K_REVIEW_KEY)
        set(v) = writeApiKey(K_REVIEW_KEY, v)

    /** Non-secret explanation shown in Settings when a saved key cannot be read. */
    val keyStorageError: String?
        @Synchronized get() = if (keyStorageFailures.isEmpty()) null
        else "无法读取或安全保存部分 API 密钥，请在设置中重新录入并保存。"

    @Synchronized
    fun clearApiKeysForRecovery(): Boolean {
        val cleared = sp.edit()
            .remove(K_JUDGE_KEY)
            .remove(K_REPLY_KEY)
            .remove(K_VISION_KEY)
            .remove(K_REVIEW_KEY)
            .remove(K_LEGACY_KEY)
            .commit()
        if (cleared) keyStorageFailures.clear()
        return cleared
    }

    private fun migrateApiKeys() {
        for (key in listOf(K_JUDGE_KEY, K_REPLY_KEY, K_VISION_KEY, K_REVIEW_KEY, K_LEGACY_KEY)) {
            readApiKey(key)
        }
        val legacy = try {
            apiKeyVault.read(K_LEGACY_KEY)
        } catch (e: Exception) {
            setKeyStorageError(K_LEGACY_KEY, e)
            return
        }
        if (K_JUDGE_KEY !in keyStorageFailures && judgeKey.isBlank() && legacy.isNotBlank()) {
            writeApiKey(K_JUDGE_KEY, legacy)
        }
        if (K_LEGACY_KEY !in keyStorageFailures && K_JUDGE_KEY !in keyStorageFailures) {
            writeApiKey(K_LEGACY_KEY, "")
        }
    }

    @Synchronized
    private fun readApiKey(name: String): String {
        return try {
            apiKeyVault.read(name).also { keyStorageFailures.remove(name) }
        } catch (e: Exception) {
            setKeyStorageError(name, e)
            ""
        }
    }

    @Synchronized
    private fun writeApiKey(name: String, value: String) {
        try {
            apiKeyVault.write(name, value.trim())
            keyStorageFailures.remove(name)
        } catch (e: Exception) {
            setKeyStorageError(name, e)
        }
    }

    @Synchronized
    private fun setKeyStorageError(name: String, error: Exception) {
        keyStorageFailures.add(name)
        Log.e(TAG, "API key storage failed for $name: ${error.javaClass.simpleName}")
    }

    var reviewModel: String
        get() = sp.getString(K_REVIEW_MODEL, "") ?: ""
        set(v) = sp.edit().putString(K_REVIEW_MODEL, v.trim()).apply()

    /** How many recent history entries to inject. */
    var contextHistoryCount: Int
        get() = sp.getInt(K_CTX_COUNT, 30)
        set(v) = sp.edit().putInt(K_CTX_COUNT, v).apply()

    /** Auto-summarize a contact once enough history accumulates. */
    var autoSummary: Boolean
        get() = sp.getBoolean(K_AUTO_SUMMARY, true)
        set(v) = sp.edit().putBoolean(K_AUTO_SUMMARY, v).apply()

    /**
     * Drop remembered history older than this many days; 0 keeps everything
     * (the per-contact file is already capped at `KbStore.MAX_LOG` entries).
     * A privacy knob as much as a storage one: "什么都不会留超过 N 天".
     */
    var logRetentionDays: Int
        get() = sp.getInt(K_LOG_RETENTION, 0).let { if (it in RETENTION_CHOICES) it else 0 }
        set(v) = sp.edit().putInt(K_LOG_RETENTION, if (v in RETENTION_CHOICES) v else 0).apply()

    // ------------------------------------------------------------ OCR (B)

    /** Run generic OCR capture on apps with no dedicated adapter. */
    var ocrForUnknownApps: Boolean
        get() = sp.getBoolean(K_OCR_UNKNOWN, true)
        set(v) = sp.edit().putBoolean(K_OCR_UNKNOWN, v).apply()

    /** Fall back to OCR when an adapted app's node tree comes back empty. */
    var ocrFallback: Boolean
        get() = sp.getBoolean(K_OCR_FALLBACK, true)
        set(v) = sp.edit().putBoolean(K_OCR_FALLBACK, v).apply()

    /** OCR polling interval: 3 / 5 / 10 seconds. */
    var ocrPollIntervalSeconds: Int
        get() = sp.getInt(K_OCR_INTERVAL, 3).let { if (it == 5 || it == 10) it else 3 }
        set(v) = sp.edit().putInt(K_OCR_INTERVAL, if (v == 5 || v == 10) v else 3).apply()

    /** Auto-analyze in OCR mode (default off: OCR costs a screenshot each time). */
    var ocrAutoAnalyze: Boolean
        get() = sp.getBoolean(K_OCR_AUTO, false)
        set(v) = sp.edit().putBoolean(K_OCR_AUTO, v).apply()

    // ------------------------------------------------------------- existing

    /** Free-text describing who the other person is; goes into Jev's state. */
    var relationship: String
        get() = sp.getString(K_REL, DEFAULT_REL) ?: DEFAULT_REL
        set(v) = sp.edit().putString(K_REL, v).apply()

    /**
     * Optional free-text tone/persona note for the reply drafter, e.g.
     * "我们在暧昧期，喜欢互怼，别太正经". Empty means the built-in defaults.
     * The user's own words for how they want to come across, since a fixed
     * strategy list in the prompt can only ever suit one kind of thread.
     */
    var style: String
        get() = sp.getString(K_STYLE, "") ?: ""
        set(v) = sp.edit().putString(K_STYLE, v).apply()

    /** Reply language: follow | zh | en. */
    var replyLanguage: String
        get() = sp.getString(K_REPLY_LANGUAGE, LANG_FOLLOW) ?: LANG_FOLLOW
        set(v) = sp.edit().putString(K_REPLY_LANGUAGE, v).apply()

    /** Reply length: short | standard | detailed. */
    var replyLength: String
        get() = sp.getString(K_REPLY_LENGTH, LENGTH_STANDARD) ?: LENGTH_STANDARD
        set(v) = sp.edit().putString(K_REPLY_LENGTH, v).apply()

    /** Advanced reply sampling temperature. */
    var replyTemperature: Double
        get() = sp.getFloat(K_REPLY_TEMPERATURE, 0.8f).toDouble().coerceIn(0.0, 1.5)
        set(v) = sp.edit().putFloat(K_REPLY_TEMPERATURE, v.coerceIn(0.0, 1.5).toFloat()).apply()

    /**
     * 采样惩罚（OpenAI 兼容字段），token 级反重复 —— 与消息级的 avoid 环互补。
     * 0.0 表示**不发字段**：请求体和加这两个参数之前逐字节一样，服务商兼容性不变。
     * 只加在生成类调用（起草 / 流式 / 单条微调）上；摘要、台账、复查这类归纳任务
     * 需要术语重复来保持一致性，永远不带惩罚。
     */
    var replyFrequencyPenalty: Double
        get() = sp.getFloat(K_REPLY_FREQ_PENALTY, 0f).toDouble().coerceIn(-2.0, 2.0)
        set(v) = sp.edit().putFloat(K_REPLY_FREQ_PENALTY, v.coerceIn(-2.0, 2.0).toFloat()).apply()

    var replyPresencePenalty: Double
        get() = sp.getFloat(K_REPLY_PRES_PENALTY, 0f).toDouble().coerceIn(-2.0, 2.0)
        set(v) = sp.edit().putFloat(K_REPLY_PRES_PENALTY, v.coerceIn(-2.0, 2.0).toFloat()).apply()

    /**
     * Opt-in streaming: show the reply being written instead of a skeleton. Off by
     * default — a provider, or a proxy in front of it, that buffers SSE turns this
     * into a slower version of the normal path, so it stays a deliberate choice.
     */
    var streamReplies: Boolean
        get() = sp.getBoolean(K_STREAM, false)
        set(v) = sp.edit().putBoolean(K_STREAM, v).apply()

    /** Request hard timeout in seconds. */
    var requestTimeoutSeconds: Int
        get() = sp.getInt(K_REQUEST_TIMEOUT, 30).coerceIn(30, 60)
        set(v) = sp.edit().putInt(K_REQUEST_TIMEOUT, v.coerceIn(30, 60)).apply()

    /** Master on/off for showing the overlay + running analysis. */
    var enabled: Boolean
        get() = sp.getBoolean(K_ENABLED, true)
        set(v) = sp.edit().putBoolean(K_ENABLED, v).apply()

    /**
     * Conversation whitelist: titles the assistant is allowed to act on. Empty
     * set means "all conversations". Stored as a plain string set.
     */
    var whitelist: Set<String>
        get() = sp.getStringSet(K_WHITELIST, emptySet()) ?: emptySet()
        set(v) = sp.edit().putStringSet(K_WHITELIST, v).apply()

    /** Overlay panel opacity, 60..100 (%). Lower lets the chat show through. */
    var overlayOpacity: Int
        get() = sp.getInt(K_OPACITY, 92).coerceIn(60, 100)
        set(v) = sp.edit().putInt(K_OPACITY, v.coerceIn(60, 100)).apply()

    /** Remembered vertical position of the bubble (px); -1 = default. */
    var bubbleY: Int
        get() = sp.getInt(K_BUBBLE_Y, -1)
        set(v) = sp.edit().putInt(K_BUBBLE_Y, v).apply()

    /** Remembered horizontal position of the bubble (px); -1 = default. */
    var bubbleX: Int
        get() = sp.getInt(K_BUBBLE_X, -1)
        set(v) = sp.edit().putInt(K_BUBBLE_X, v).apply()

    /** How many candidate replies to draft (1..3). With 1 the Jev ranking round is skipped. */
    var candidateCount: Int
        get() = sp.getInt(K_CANDIDATES, 3).coerceIn(1, 3)
        set(v) = sp.edit().putInt(K_CANDIDATES, v.coerceIn(1, 3)).apply()

    /** Where the analysis card sits in [pkg] (px), or null for the default top position. */
    fun cardPosition(pkg: String): Pair<Int, Int>? {
        val x = sp.getInt(K_CARD_X + pkg, -1)
        val y = sp.getInt(K_CARD_Y + pkg, -1)
        return if (x < 0 || y < 0) null else x to y
    }

    fun saveCardPosition(pkg: String, x: Int, y: Int) {
        sp.edit().putInt(K_CARD_X + pkg, x).putInt(K_CARD_Y + pkg, y).apply()
    }

    /** Auto-analyze on every incoming message; if false, user taps to analyze. */
    var autoAnalyze: Boolean
        get() = sp.getBoolean(K_AUTO, true)
        set(v) = sp.edit().putBoolean(K_AUTO, v).apply()

    /**
     * Per-app opt-out layered on the global switch: the escape hatch for one noisy
     * or sensitive app while the others keep analyzing on their own. Stored as the
     * set of muted packages; the card's long-press menu toggles it.
     */
    fun autoAnalyzeFor(pkg: String?): Boolean = autoAnalyze && !isAppMuted(pkg)

    fun isAppMuted(pkg: String?): Boolean =
        !pkg.isNullOrBlank() && mutedApps().contains(pkg)

    fun setAppMuted(pkg: String?, muted: Boolean) {
        if (pkg.isNullOrBlank()) return
        val next = mutedApps().toMutableSet()
        if (muted) next.add(pkg) else next.remove(pkg)
        sp.edit().putStringSet(K_MUTED_APPS, next).apply()
    }

    private fun mutedApps(): Set<String> = sp.getStringSet(K_MUTED_APPS, emptySet()) ?: emptySet()

    // ------------------------------------------------ 注入增强（可选，默认关）

    /**
     * 逐 App 的注入开关。
     *
     * 默认**关**，而且关得彻底：模块入口在目标 App 的进程里问的就是这个值，
     * 拿到 false 之后一个钩子都不装。所以「没开」不只是「不用结果」，而是
     * 目标进程里根本没有本模块的活动代码 —— 这也是 CLAUDE.md 要求的默认姿态。
     *
     * 与 [isAppMuted] 是两个方向的东西：那个是已经能读、但不想分析；这个是
     * 连读都不读。
     */
    fun injectionEnabled(pkg: String?): Boolean =
        !pkg.isNullOrBlank() && injectedApps().contains(pkg)

    fun setInjectionEnabled(pkg: String?, enabled: Boolean) {
        if (pkg.isNullOrBlank()) return
        val next = injectedApps().toMutableSet()
        if (enabled) next.add(pkg) else next.remove(pkg)
        sp.edit().putStringSet(K_INJECT_APPS, next).apply()
    }

    private fun injectedApps(): Set<String> =
        sp.getStringSet(K_INJECT_APPS, emptySet()) ?: emptySet()

    /**
     * 对拍（诊断）：同一个聊天页同时用无障碍和注入层各读一遍，把两层的差别
     * 写一行 Trace。默认关 —— 开着会让每次采集多读一遍无障碍树。
     */
    fun compareSources(): Boolean = sp.getBoolean(K_COMPARE_SOURCES, false)

    fun setCompareSources(on: Boolean) = sp.edit().putBoolean(K_COMPARE_SOURCES, on).apply()

    // ------------------------------------------------------------ root（可选增强）

    /**
     * root 自愈：启动 / 开机 / 覆盖安装之后，自己把无障碍和悬浮窗重新打开，
     * 不用每次手动去点。默认**关** —— 它不是功能，只省几步点击，而打开它就意味着
     * 调用 `su`（第一次必然弹一次 KernelSU 的授权框，由用户在主页点「一键修复」
     * 触发）。关掉它，App 与没有 root 时完全一样。
     */
    var rootAuto: Boolean
        get() = sp.getBoolean(K_ROOT_AUTO, false)
        set(v) = sp.edit().putBoolean(K_ROOT_AUTO, v).apply()

    /** 上次探测到的 root 框架（空 = 还没探过）。缓存它，免得每次进主页都 spawn 一个 su。 */
    var rootFlavor: String
        get() = sp.getString(K_ROOT_FLAVOR, "") ?: ""
        set(v) = sp.edit().putString(K_ROOT_FLAVOR, v.trim()).apply()

    /** 上次自愈的时间戳（毫秒，0 = 从未），主页回显用。 */
    var rootFixAt: Long
        get() = sp.getLong(K_ROOT_FIX_AT, 0L)
        set(v) = sp.edit().putLong(K_ROOT_FIX_AT, v).apply()

    /** 上次自愈的逐项真实结果（一行一项），主页把它原文贴出来，不转述。 */
    var rootFixReport: String
        get() = sp.getString(K_ROOT_FIX_REPORT, "") ?: ""
        set(v) = sp.edit().putString(K_ROOT_FIX_REPORT, v).apply()

    // ------------------------------------------------------------- helpers

    /** Reply route key, falling back to the judge key. */
    fun effectiveReplyKey(): String = replyKey.ifBlank { judgeKey }

    /** Vision route key, falling back to reply then judge. */
    fun effectiveVisionKey(): String = visionKey.ifBlank { effectiveReplyKey() }

    /** 复查路由 key，依次回退到回复路由和判断路由。 */
    fun effectiveReviewKey(): String = reviewKey.ifBlank { effectiveReplyKey() }

    /** 复查用的模型：留空沿用回复模型。 */
    fun effectiveReviewModel(): String = reviewModel.ifBlank { replyModel }

    /** 复查路由的完整地址；留空沿用回复路由。 */
    fun reviewEndpoint(): String {
        val base = reviewBaseUrl.trim().ifBlank { replyBaseUrl.trim() }
        return "${base.trimEnd('/')}/chat/completions"
    }

    /**
     * Full POST URL for the judge call. The path follows the PROTOCOL, not the
     * provider: a chat model (DeepSeek official) is served at
     * `{base}/chat/completions` however it was selected, while the decisions
     * protocol keeps its per-provider paths.
     */
    fun judgeEndpoint(): String {
        val base = judgeBaseUrl.trim().trimEnd('/')
        if (effectiveJudgeProtocol() == PROTO_CHAT) {
            // Blank means the field was cleared: a chat judge with no address is
            // DeepSeek official, the only host that preset exists for.
            val host = base.ifBlank { DEFAULT_JUDGE_BASE_DEEPSEEK }
            // A custom entry may already be the full URL; anything else is a base.
            return if (host.endsWith(CHAT_COMPLETIONS_PATH)) host else "$host$CHAT_COMPLETIONS_PATH"
        }
        return when (judgeProvider) {
            PROVIDER_BOCHA -> "$base/v1/systemone"    // same path as TypeSafe
            PROVIDER_TYPESAFE -> "$base/v1/systemone"
            PROVIDER_VERCEL -> "$base/v1/systemone"   // TypeSafe-compatible gateway
            PROVIDER_ZEN -> "$base/v1/systemone"      // TypeSafe-compatible gateway
            PROVIDER_CUSTOM -> judgeBaseUrl.trim()   // user supplies the full URL
            else -> "$base/alpha/decisions"
        }
    }

    /** Full POST URL for the OpenAI-compatible chat completions call. */
    fun replyEndpoint(): String = "${replyBaseUrl.trim().trimEnd('/')}/chat/completions"

    /** Same shape as [replyEndpoint]; blank falls back to the OpenRouter default. */
    fun visionEndpoint(): String {
        val base = visionBaseUrl.trim().ifBlank { DEFAULT_VISION_BASE }
        return "${base.trimEnd('/')}/chat/completions"
    }

    fun isAllowed(title: String?): Boolean {
        val wl = whitelist
        if (wl.isEmpty()) return true
        if (title == null) return false
        return wl.any { title.contains(it) }
    }

    /** Readiness gate: the judge route is the one that must be configured. */
    fun hasKey(): Boolean = judgeKey.isNotBlank()

    companion object {
        private const val TAG = "JEVASSIST"

        /** The one real config file. Anything else is a scratch instance. */
        const val PREFS_MAIN = "jev_assistant"

        private const val K_LEGACY_KEY = "openrouter_key"
        private const val K_MIGRATED_V13 = "prefs_migrated_v13"
        private const val K_UNSEEDED_BOCHA = "unseeded_bocha_v141"
        private const val K_JUDGE_PROVIDER = "judge_provider"
        private const val K_JUDGE_BASE = "judge_base_url"
        private const val K_JUDGE_KEY = "judge_key"
        private const val K_JUDGE_MODEL = "judge_model"
        private const val K_JUDGE_PROTO = "judge_protocol"
        private const val K_REPLY_BASE = "reply_base_url"
        private const val K_REPLY_KEY = "reply_key"
        private const val K_REPLY_MODEL = "reply_model"
        private const val K_VISION_BASE = "vision_base_url"
        private const val K_VISION_KEY = "vision_key"
        private const val K_VISION_MODEL = "vision_model"
        private const val K_CTX_ENABLED = "context_enabled"
        private const val K_LEDGER = "ledger_enabled"
        private const val K_REVIEW = "review_enabled"
        private const val K_REVIEW_BASE = "review_base_url"
        private const val K_REVIEW_KEY = "review_key"
        private const val K_REVIEW_MODEL = "review_model"
        private const val K_CTX_COUNT = "context_history_count"
        private const val K_AUTO_SUMMARY = "auto_summary"
        private const val K_MUTED_APPS = "muted_auto_apps"
        private const val K_INJECT_APPS = "inject_apps"
        private const val K_COMPARE_SOURCES = "compare_sources"
        private const val K_ROOT_AUTO = "root_auto"
        private const val K_ROOT_FLAVOR = "root_flavor"
        private const val K_ROOT_FIX_AT = "root_fix_at"
        private const val K_ROOT_FIX_REPORT = "root_fix_report"
        private const val K_LOG_RETENTION = "log_retention_days"
        private const val K_OCR_UNKNOWN = "ocr_unknown_apps"
        private const val K_OCR_FALLBACK = "ocr_fallback"
        private const val K_OCR_AUTO = "ocr_auto_analyze"
        private const val K_OCR_INTERVAL = "ocr_poll_interval"
        private const val K_REL = "relationship"
        private const val K_STYLE = "reply_style"
        private const val K_REPLY_LANGUAGE = "reply_language"
        private const val K_REPLY_LENGTH = "reply_length"
        private const val K_REPLY_TEMPERATURE = "reply_temperature"
        private const val K_REPLY_FREQ_PENALTY = "reply_frequency_penalty"
        private const val K_REPLY_PRES_PENALTY = "reply_presence_penalty"
        private const val K_REQUEST_TIMEOUT = "request_timeout_seconds"
        private const val K_STREAM = "stream_replies"
        private const val K_ENABLED = "enabled"
        private const val K_WHITELIST = "whitelist"
        private const val K_OPACITY = "overlay_opacity"
        private const val K_BUBBLE_Y = "bubble_y"
        private const val K_BUBBLE_X = "bubble_x"
        private const val K_AUTO = "auto_analyze"
        private const val K_CANDIDATES = "candidate_count"
        private const val K_CARD_X = "card_x_"
        private const val K_CARD_Y = "card_y_"

        const val PROVIDER_BOCHA = "bocha"
        const val PROVIDER_OPENROUTER = "openrouter"
        const val PROVIDER_TYPESAFE = "typesafe"
        const val PROVIDER_VERCEL = "vercel"
        const val PROVIDER_ZEN = "zen"
        const val PROVIDER_DEEPSEEK = "deepseek"
        const val PROVIDER_CUSTOM = "custom"

        // Judge protocols. DECISIONS is the Jev/TypeSafe question protocol (one
        // POST returning "answers"); CHAT is an OpenAI-compatible chat model
        // answering the same question set as a prompt (see ChatJudge).
        const val PROTO_DECISIONS = "decisions"
        const val PROTO_CHAT = "chat"
        const val CHAT_COMPLETIONS_PATH = "/chat/completions"

        const val LANG_FOLLOW = "follow"
        const val LANG_ZH = "zh"
        const val LANG_EN = "en"
        const val LENGTH_SHORT = "short"
        const val LENGTH_STANDARD = "standard"
        const val LENGTH_DETAILED = "detailed"

        /** History retention choices offered in settings; 0 = keep everything. */
        val RETENTION_CHOICES = listOf(0, 7, 30, 90)

        // Judge route presets.
        // Bocha Jev: same protocol/path as TypeSafe (/v1/systemone). Limited-time free.
        const val DEFAULT_JUDGE_BASE_BOCHA = "https://jev.bocha.cn"
        const val DEFAULT_JUDGE_MODEL_BOCHA = "bocha-jev-v1"
        const val DEFAULT_JUDGE_BASE_OPENROUTER = "https://openrouter.ai/api"
        const val DEFAULT_JUDGE_MODEL_OPENROUTER = "typesafe/jev-1.13"
        const val DEFAULT_JUDGE_BASE_TYPESAFE = "https://api.typesafe.ai"
        const val DEFAULT_JUDGE_MODEL_TYPESAFE = "jev-latest"
        // Vercel AI Gateway's TypeSafe-compatible API. Same /v1/systemone body
        // and noul answers as TypeSafe direct; model id is the gateway's.
        const val DEFAULT_JUDGE_BASE_VERCEL = "https://ai-gateway.vercel.sh/typesafe"
        const val DEFAULT_JUDGE_MODEL_VERCEL = "typesafe-ai/jev"
        // OpenCode Zen's TypeSafe-compatible API. Same /v1/systemone body and
        // noul answers; jev-1.13 is free on output ($0.042/M input, ~1k tokens
        // per judgment), jev-1.13-free is fully free but capability-limited.
        const val DEFAULT_JUDGE_BASE_ZEN = "https://opencode.ai/zen"
        const val DEFAULT_JUDGE_MODEL_ZEN = "jev-1.13"

        // Reply route presets (OpenAI-compatible chat completions).
        const val DEFAULT_REPLY_BASE = "https://openrouter.ai/api/v1"
        const val DEFAULT_REPLY_MODEL = "deepseek/deepseek-chat-v3.1"
        const val DEEPSEEK_BASE = "https://api.deepseek.com/v1"
        const val DEEPSEEK_MODEL = "deepseek-chat"
        // DeepSeek official serves no Jev judgment model, so as a JUDGE it runs
        // the chat protocol on the same host/model as the reply route.
        const val DEFAULT_JUDGE_BASE_DEEPSEEK = DEEPSEEK_BASE
        const val DEFAULT_JUDGE_MODEL_DEEPSEEK = DEEPSEEK_MODEL
        const val DASHSCOPE_BASE = "https://dashscope.aliyuncs.com/compatible-mode/v1"
        const val DASHSCOPE_MODEL = "qwen-plus"

        // Vision route preset (OpenRouter region-available; user may change).
        const val DEFAULT_VISION_BASE = "https://openrouter.ai/api/v1"
        const val DEFAULT_VISION_MODEL = "qwen/qwen2.5-vl-72b-instruct"
        const val DASHSCOPE_VISION_MODEL = "qwen-vl-max"

        const val DEFAULT_REL = "对方是我的伴侣；from=me 的是我发的，from=other 的是对方发的"
    }
}

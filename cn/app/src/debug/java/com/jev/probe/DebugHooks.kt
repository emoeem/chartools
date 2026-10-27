package com.jev.probe

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.widget.Toast
import com.jev.probe.core.Analysis
import com.jev.probe.core.ChatSnapshot
import com.jev.probe.core.Choice
import com.jev.probe.core.Msg
import com.jev.probe.core.Score
import com.jev.probe.jev.ReplyClient
import java.io.File

/**
 * 调试验收钩子的真实现 + 注册入口。本文件在 `src/debug` 源集，只编进 debug
 * 变体；release 用 main 里 [DebugAcceptance] 的空钩子。
 *
 * 注册走 ContentProvider：系统在任何 Activity 之前初始化 provider，所以
 * MainActivity.onCreate 里钩子一定已经挂上。两个入口都不是 exported 组件，
 * 只能 adb 手动触发：
 *
 *   adb shell am start -n com.jev.probe/.MainActivity --ez tone_check true
 *   adb shell am start -n com.jev.probe/.SettingsActivity --ez tone_check true
 *   adb shell am start -n com.jev.probe/.MainActivity --ez root_fix true
 *
 * root_fix 单独存在，是因为真实触发路径（开机 / 覆盖安装广播）不重启不重装
 * 就没法用 adb 回放。
 */
internal object DebugHooks : DebugAcceptance.Hooks {

    override fun onMainActivityCreate(activity: MainActivity, intent: Intent?) {
        if (intent?.getBooleanExtra("tone_check", false) == true) {
            activity.startActivity(
                Intent(activity, SettingsActivity::class.java).putExtra("tone_check", true)
            )
        }
        if (intent?.getBooleanExtra("root_fix", false) == true) activity.runRootFix(quiet = false)
    }

    override fun onSettingsCreate(activity: SettingsActivity) {
        if (activity.intent?.getBooleanExtra("tone_check", false) != true) return

        // 回复自然度 P0 的验收要打真模型：起草提示词是不是"先判后写"，只有
        // 真跑一轮才知道。固定的一段轻调侃对话 + 一条硬编码判断，让写手必须
        // 跟着判断走，而不是对着想象中的危机发挥。
        val probe = activity.draftPrefs(SettingsActivity.SCRATCH_REPLY) {
            judgeBaseUrl = activity.prefs.judgeBaseUrl
            judgeProtocol = activity.prefs.judgeProtocol
            judgeModel = activity.prefs.judgeModel
            judgeKey = activity.prefs.judgeKey
            replyBaseUrl = activity.prefs.replyBaseUrl
            replyKey = activity.prefs.replyKey
            replyModel = activity.prefs.replyModel
            contextHistoryCount = activity.prefs.contextHistoryCount
        }
        activity.worker.execute {
            val demo = ChatSnapshot("试写", listOf(
                Msg("other", "你今天怎么这么晚才回我？"),
                Msg("me", "刚忙完，想你了"),
                Msg("other", "切，谁信啊，说好的周末陪我去看电影呢")
            ))
            val judgment = Analysis(
                trueIntent = Choice("casual_chat", 0.7, emptyMap()),
                dangerLevel = Score(1.0, 0.8, 9),
                sheNeeds = Choice("nothing", 0.5, emptyMap()),
                shouldReplyNow = 0.9,
                bestAction = Choice("make_plan", 0.5, emptyMap()),
                tensionResolved = 0.2, literalQuestion = 0.8,
                rankedReplies = emptyList(), latencyMs = 0
            )
            val out = try {
                ReplyClient(probe).draft(demo, activity.prefs.relationship, null, 3, emptyList(), judgment, activity.prefs.style)
            } catch (e: Exception) {
                listOf("FAILED: ${e.message}")
            }
            runCatching {
                File(activity.filesDir, "jev-tone-check.txt").writeText(out.joinToString("\n---\n"))
            }
            activity.main.post {
                Toast.makeText(activity, "试写完成：${out.size} 条", Toast.LENGTH_LONG).show()
            }
        }
    }
}

/** 什么都不存；存在的意义只是 [DebugHooks] 在任何 Activity 之前注册自己。 */
class DebugHooksInit : ContentProvider() {

    override fun onCreate(): Boolean {
        DebugAcceptance.hooks = DebugHooks
        return true
    }

    override fun query(uri: Uri, p: Array<String>?, s: String?, a: Array<String>?, o: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<String>?): Int = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<String>?): Int = 0
}

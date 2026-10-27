package com.jev.probe

import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Bundle
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.jev.probe.capture.ChatCaptureService
import com.jev.probe.core.Palette
import com.jev.probe.core.Prefs
import com.jev.probe.root.FixStep
import com.jev.probe.root.RootFix
import com.jev.probe.capture.ChatApps
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Home / setup screen. Card-based layout with a live readiness summary, a
 * guided permission checklist (each row reflects its real granted state), a
 * prominent on/off switch, and a link to settings.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var prefs: Prefs
    private lateinit var container: LinearLayout

    /** True while a root fix is in flight — the button reads it, so a double tap can't queue two. */
    private var fixing = false
    private var showAdvancedSetup = false
    private val a11yComponent =
        "com.jev.probe/com.jev.probe.capture.ChatCaptureService"

    private val accent = Palette.brand()
    private val green = Color.parseColor("#16A34A")
    private val red = Color.parseColor("#DC2626")
    private val ink = Color.parseColor("#111827")
    private val sub = Color.parseColor("#6B7280")

    private fun dp(v: Int) = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).roundToInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        prefs = Prefs(this)
        window.decorView.setBackgroundColor(Color.parseColor("#F2F3F5"))

        val scroll = ScrollView(this)
        container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(22), dp(18), dp(28))
        }
        container.padForSystemBars()   // edge-to-edge: keep the title off the status bar
        scroll.addView(container)
        setContentView(scroll)

        // 调试验收钩子（tone_check / root_fix 回放）：真实现只在 src/debug，
        // release 是 main 的空实现。见 debug 变体 DebugAcceptance 的注释。
        DebugAcceptance.onMainActivityCreate(this, intent)

        // Self-heal on launch. This is the "I have to tap accessibility again every
        // time I open the app" complaint: the setting may still say enabled while
        // nothing is bound, so the app fixes it instead of asking.
        if (prefs.rootAuto) runRootFix(quiet = true)
    }

    override fun onResume() {
        super.onResume()
        build()
    }

    private fun build() {
        container.removeAllViews()

        container.addView(text("小助手", 24f, ink, bold = true))
        container.addView(text("在聊天 App 旁读对方消息（已支持 " + ChatApps.all.joinToString("、") { it.displayName } + "、微信），给出判断和候选回复。发送始终由你手动点。",
            13f, sub).apply { setPadding(0, dp(6), 0, dp(16)) })

        val a11y = isA11yEnabled()
        // Setting says on ≠ service is running. Measured on this device: after
        // `adb install -r` / a force-stop the setting survives while
        // `dumpsys accessibility` loses its `Bound services` line. Readiness has
        // to require the live service, or the app claims "已就绪" while nothing
        // is actually reading messages — which is the user's complaint verbatim.
        val a11yLive = ChatCaptureService.live
        val overlay = Settings.canDrawOverlays(this)
        val key = prefs.hasKey()   // judge route key: the one analysis cannot run without
        val ready = a11y && a11yLive && overlay && key

        // Readiness card
        container.addView(statusCard(ready, a11y, a11yLive, overlay, key))
        prefs.keyStorageError?.let {
            container.addView(text("$it 请到设置页清除失效密钥后重新录入。", 13f, sub)
                .apply { setPadding(dp(4), dp(4), dp(4), dp(12)) })
        }
        container.addView(privacyHint())
        container.addView(platformRiskHint())

        container.addView(setupCard(a11y, a11yLive, overlay, key))

        // Actions
        container.addView(sectionLabel("其他"))
        container.addView(actionRow("设置", "密钥 · 模型 · 关系 · 透明度 · 会话白名单") {
            startActivity(Intent(this, SettingsActivity::class.java))
        })

        // Master toggle
        val toggle = bigToggle(prefs.enabled)
        toggle.setOnClickListener {
            prefs.enabled = !prefs.enabled
            build()
        }
        container.addView(toggle)

        val advanced = TextView(this).apply {
            text = if (showAdvancedSetup) "收起兼容性设置 ▲" else "更多设置：国产手机省电与 root 增强 ▾"
            textSize = 13f
            setTextColor(sub)
            setPadding(dp(2), dp(18), dp(2), dp(10))
            setOnClickListener {
                showAdvancedSetup = !showAdvancedSetup
                build()
            }
        }
        container.addView(advanced)
        if (showAdvancedSetup) {
            container.addView(sectionLabel("兼容性设置（按需）"))
            container.addView(permCard("自启动 + 省电无限制", "小米 / HyperOS 等国产手机可能需要，避免系统冻结后台服务", null) {
                systemScreen(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
            })
            container.addView(sectionLabel("root 增强（可选）"))
            container.addView(rootCard())
        }
    }

    // ---------------------------------------------------------------- cards

    private fun setupCard(a11y: Boolean, a11yLive: Boolean, overlay: Boolean, key: Boolean): View {
        val c = cardBox()
        val a11yReady = a11y && a11yLive
        val step = when {
            !a11yReady -> 1
            !overlay -> 2
            !key -> 3
            else -> 0
        }
        val (title, description, actionLabel, action) = when (step) {
            1 -> Quadruple(
                if (a11y && !a11yLive) "重新开启无障碍服务" else "开启无障碍权限",
                if (a11y && !a11yLive)
                    "系统权限还在，但服务没有运行。请在列表中找到「小助手 - 聊天读取服务」，关闭后重新开启。"
                else "在无障碍服务列表中找到「小助手 - 聊天读取服务」并开启，确认系统提示后返回。",
                "去开启"
            ) { systemScreen(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }
            2 -> Quadruple(
                "开启悬浮窗权限",
                "允许分析卡片显示在聊天应用上方。开启后返回此页继续。",
                "去开启"
            ) {
                systemScreen(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
            }
            3 -> Quadruple(
                "配置 API Key",
                "只需先配置判断接口。回复和视觉接口可按需使用默认继承设置。",
                "去设置"
            ) { startActivity(Intent(this, SettingsActivity::class.java)) }
            else -> Quadruple(
                "准备完成，可以开始使用",
                "打开受支持的聊天应用即可。发送候选内容始终由你手动确认。",
                ""
            ) {}
        }

        c.addView(text(if (step == 0) title else "$title（$step/3）", 17f, ink, bold = true))
        c.addView(text(description, 13f, sub).apply { setPadding(0, dp(5), 0, dp(12)) })
        if (actionLabel.isNotEmpty()) {
            c.addView(btn(actionLabel, true, action).apply {
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
                )
            })
        }
        return c
    }

    private data class Quadruple(
        val title: String,
        val description: String,
        val actionLabel: String,
        val action: () -> Unit
    )

    private fun statusCard(
        ready: Boolean, a11y: Boolean, a11yLive: Boolean, overlay: Boolean, key: Boolean
    ): View {
        val c = cardBox()
        val head = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        head.addView(dot(if (ready) green else red).apply {
            (layoutParams as LinearLayout.LayoutParams).rightMargin = dp(10)
        })
        head.addView(text(if (ready) "已就绪，可以用了" else "尚未就绪", 16f, if (ready) green else ink, bold = true))
        c.addView(head)
        // Three states, not two: off / on-but-dead / on-and-running. The middle one
        // is the one that used to be reported as ✓ and then did nothing.
        if (a11y && !a11yLive) {
            c.addView(checkLine("无障碍权限开着，但服务没在跑", false, noWord = ""))
            c.addView(text(
                "覆盖安装、重启或被系统冻结后就是这样：设置里还开着，实际没人干活。" +
                    "用下面的一键修复，或者自己进系统设置把它关掉再打开一次。",
                12f, sub
            ).apply { setPadding(dp(22), dp(2), 0, 0) })
        } else {
            c.addView(checkLine("无障碍", a11y))
        }
        c.addView(checkLine("悬浮窗", overlay))
        c.addView(checkLine("密钥", key, okWord = "已设", noWord = "未设"))
        // History recording is opt-in (off by default). Mention it here, never block on it.
        if (!prefs.contextEnabled) {
            c.addView(text("关联上下文未开启，可在设置里开启", 12f, sub).apply {
                setPadding(0, dp(8), 0, 0)
            })
        }
        return c
    }

    /** One tappable line under the readiness card, opening the privacy policy page. */
    private fun privacyHint(): View = text("读取的聊天内容只发往你自己配置的接口 · 隐私政策", 11f, sub).apply {
        setPadding(dp(2), dp(8), 0, 0)
        setOnClickListener { openUrl(PRIVACY_URL) }
    }

    /** One line under the privacy hint: using it inside third-party chat apps is at the user's own risk. */
    private fun platformRiskHint(): View =
        text("在第三方聊天 App 里使用可能不符合其用户协议，账号有被限制的风险，请自行判断", 11f, sub).apply {
            setPadding(dp(2), dp(4), 0, 0)
        }

    /** Opens an external link; swallows the failure with a toast rather than crashing. */
    private fun openUrl(url: String) {
        runCatching {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.onFailure {
            Toast.makeText(this, "打不开浏览器", Toast.LENGTH_SHORT).show()
        }
    }

    private fun checkLine(label: String, ok: Boolean, okWord: String = "已开", noWord: String = "未开"): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(5), 0, 0)
        }
        row.addView(text(if (ok) "✓" else "✗", 14f, if (ok) green else red, bold = true).apply {
            (this as TextView).width = dp(22)
        })
        row.addView(text(label + (if (ok) okWord else noWord), 13f, sub))
        return row
    }

    private fun permCard(title: String, desc: String, granted: Boolean?, onClick: () -> Unit): View {
        val c = cardBox()
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val left = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        left.addView(text(title, 15f, ink, bold = true))
        left.addView(text(desc, 12f, sub).apply { setPadding(0, dp(3), 0, 0) })
        if (granted == true) left.addView(text("✓ 已开启", 12f, green, bold = true).apply { setPadding(0, dp(4), 0, 0) })
        row.addView(left)
        row.addView(btn(if (granted == true) "已开启" else "去开启", granted != true, onClick))
        c.addView(row)
        return c
    }

    /**
     * root 增强：状态 + 一键修复 + 自动修复开关。
     *
     * 这里**不主动探测** root —— 探测要 spawn 一个 `su`，首次还会弹授权框，主页
     * 每次 onResume 都探一遍是拿启动速度换一句废话。状态文本读上次的结果。
     */
    /**
     * 能不能直接改系统设置。这也是**真机上唯一走得通的阶梯**：本机 KernelSU 的
     * `su` 对 App uid 是隐藏的（`run-as` 里 `/system/bin/su` 都看不见），所以
     * 「有没有 root」不是这一页的关键判据，「有没有这一条权限」才是。
     */
    private fun canWriteSecure(): Boolean =
        checkSelfPermission(RootFix.SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    private fun rootCard(): View {
        val c = cardBox()
        val flavor = prefs.rootFlavor
        val has = flavor.isNotEmpty() && flavor != "无"
        val head = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
        }
        head.addView(dot(if (has) green else sub).apply {
            (layoutParams as LinearLayout.LayoutParams).rightMargin = dp(10)
        })
        head.addView(text("root：" + when {
            flavor.isEmpty() -> "未检测"
            else -> flavor
        }, 15f, if (has) green else ink, bold = true))
        c.addView(head)
        c.addView(text(
            when {
                canWriteSecure() ->
                    "不需要 root：写系统设置的权限已经开通，一键修复直接改；覆盖安装 / 开机之后也会自己修。"
                flavor == "无" ->
                    "这台机器上 su 对 App 是隐藏的（本 App 拿不到 root），要先一次性开通下面那条权限 —— 开通之后同样不用 root。"
                else ->
                    "需要 root：第一次会弹一次授权框，点允许之后就全自动了。"
            },
            12f, sub
        ).apply { setPadding(0, dp(4), 0, 0) })

        // Last run, verbatim. The fix already truncated each line; nothing here is a summary.
        val report = prefs.rootFixReport
        if (report.isNotBlank()) {
            c.addView(text("上次修复（${stampOf(prefs.rootFixAt)}）", 12f, sub, bold = true).apply {
                setPadding(0, dp(10), 0, dp(2))
            })
            for (line in report.split('\n')) {
                c.addView(text(line, 12f, if (line.startsWith("✓")) green else red).apply {
                    setPadding(dp(2), dp(2), 0, 0)
                })
            }
        }

        c.addView(btn(if (fixing) "修复中…" else "一键修复", !fixing) { runRootFix(quiet = false) }
            .apply {
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
                ).apply { topMargin = dp(12) }
            })
        c.addView(toggleRow(
            "自动修复",
            if (prefs.rootAuto) "启动 / 开机 / 覆盖安装后自动修，不用再手点。"
            else "关着：每次覆盖安装后要自己来点一次。打开一次，以后就不用管了。",
            prefs.rootAuto
        ) {
            prefs.rootAuto = !prefs.rootAuto
            build()
        })
        c.addView(text(
            when {
                canWriteSecure() ->
                    "写系统设置权限已开通。实际执行：settings put secure " +
                        "enabled_accessibility_services（关→开各写一次，强制重绑）、" +
                        "appops set SYSTEM_ALERT_WINDOW allow、cmd deviceidle whitelist。" +
                        "写无障碍那一格只合并，不覆盖其它无障碍服务。"
                flavor == "无" ->
                    "一次性开通（二选一，都只做一次）：① 电脑上 adb shell pm grant " +
                        "com.jev.probe android.permission.WRITE_SECURE_SETTINGS；" +
                        "② su -c pm grant com.jev.probe android.permission.WRITE_SECURE_SETTINGS。" +
                        "开通后这一页就不用 root 了。写无障碍那一格只合并，不覆盖其它无障碍服务。"
                else ->
                    "实际执行：pm grant WRITE_SECURE_SETTINGS、settings put secure " +
                        "enabled_accessibility_services、appops set SYSTEM_ALERT_WINDOW allow、" +
                        "cmd deviceidle whitelist。写无障碍那一格只合并，不覆盖其它无障碍服务。"
            },
            11f, sub
        ).apply { setPadding(0, dp(10), 0, 0) })
        return c
    }

    /** 开关样式的行。用普通 View 而不是 Switch，和这页其它控件保持一致。 */
    private fun toggleRow(title: String, desc: String, on: Boolean, onClick: () -> Unit): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(12), 0, 0)
        }
        row.setOnClickListener { onClick() }
        val left = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        left.addView(text(title, 14f, ink, bold = true))
        left.addView(text(desc, 12f, sub).apply { setPadding(0, dp(3), dp(8), 0) })
        row.addView(left)
        row.addView(text(if (on) "已开" else "已关", 13f, if (on) green else sub, bold = true))
        return row
    }

    private fun stampOf(at: Long): String =
        if (at <= 0) "从未" else SimpleDateFormat("MM-dd HH:mm", Locale.US).format(Date(at))

    /**
     * 把自愈放到后台线程。`su` 可能一直在等 KernelSU 的授权框 —— 那正是这块按钮
     * 这辈子第一次被点到的情况，在主线程上等就是 ANR。
     */
    internal fun runRootFix(quiet: Boolean) {
        if (fixing) return
        fixing = true
        val app = this
        build()   // 按钮立刻变「修复中…」
        Thread {
            val steps: List<FixStep> = try {
                RootFix.apply(app, prefs)
            } catch (t: Throwable) {
                listOf(FixStep("root 自愈", false, t.javaClass.simpleName + ": " + (t.message ?: "")))
            }
            runOnUiThread {
                fixing = false
                if (isFinishing || isDestroyed) return@runOnUiThread
                build()
                if (!quiet) {
                    Toast.makeText(
                        app, "修复完成：${steps.count { it.ok }}/${steps.size} 项", Toast.LENGTH_LONG
                    ).show()
                }
            }
        }.start()
    }

    private fun actionRow(title: String, desc: String, onClick: () -> Unit): View {
        val c = cardBox()
        c.setOnClickListener { onClick() }
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val left = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        left.addView(text(title, 15f, ink, bold = true))
        left.addView(text(desc, 12f, sub).apply { setPadding(0, dp(3), 0, 0) })
        row.addView(left)
        row.addView(text("›", 22f, sub))
        c.addView(row)
        return c
    }

    private fun bigToggle(on: Boolean): View {
        return TextView(this).apply {
            text = if (on) "助手已开启 · 点击关闭" else "助手已关闭 · 点击开启"
            textSize = 15f; gravity = Gravity.CENTER; setTypeface(typeface, Typeface.BOLD)
            setTextColor(if (on) Color.WHITE else accent)
            background = roundBg(dp(14), if (on) accent else Color.WHITE, stroke = !on)
            setPadding(dp(16), dp(15), dp(16), dp(15))
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(18) }
        }
    }

    // ---------------------------------------------------------------- atoms

    private fun cardBox(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background = roundBg(dp(14), Color.WHITE)
        setPadding(dp(14), dp(13), dp(14), dp(13))
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply { topMargin = dp(10) }
    }

    private fun sectionLabel(t: String) = text(t, 12f, sub, bold = true).apply {
        setPadding(dp(2), dp(18), 0, dp(2))
    }

    private fun text(t: String, size: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
        text = t; textSize = size; setTextColor(color)
        if (bold) setTypeface(typeface, Typeface.BOLD)
    }

    private fun dot(color: Int) = View(this).apply {
        background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(color) }
        layoutParams = LinearLayout.LayoutParams(dp(10), dp(10))
    }

    private fun btn(label: String, enabled: Boolean, onClick: () -> Unit) = TextView(this).apply {
        text = label; textSize = 13f; gravity = Gravity.CENTER; setTypeface(typeface, Typeface.BOLD)
        setTextColor(if (enabled) Color.WHITE else sub)
        background = roundBg(dp(10), if (enabled) accent else Color.parseColor("#E5E7EB"))
        setPadding(dp(16), dp(8), dp(16), dp(8))
        if (enabled) setOnClickListener { onClick() }
    }

    private fun roundBg(radius: Int, color: Int, stroke: Boolean = false) = GradientDrawable().apply {
        cornerRadius = radius.toFloat(); setColor(color)
        if (stroke) setStroke(dp(1), accent)
    }

    private fun isA11yEnabled(): Boolean {
        val enabled = Settings.Secure.getString(contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        return enabled.contains(a11yComponent)
    }

    /** Open system settings outside this app's task and explain if the device has no matching screen. */
    private fun systemScreen(intent: Intent) {
        runCatching { startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            .onFailure {
                Toast.makeText(this, "无法打开系统设置，请在系统设置中手动查找对应权限", Toast.LENGTH_LONG).show()
            }
    }

    companion object {
        private const val PRIVACY_URL = "https://chatjevs.com/privacy.html"
    }
}

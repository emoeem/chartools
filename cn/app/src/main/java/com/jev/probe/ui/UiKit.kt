package com.jev.probe.ui

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import com.jev.probe.core.Palette
import kotlin.math.roundToInt

/**
 * 共享的「原子控件」：dp / text / round / card / edit / label / header / section / chip。
 *
 * 为什么是 **`Context` 扩展函数**而不是 `UiKit.dp(this, 12)`：
 * `SettingsActivity` 里 `dp(` 有 123 个调用点。逐个改成带 receiver 的静态调用是
 * 273 处机械 diff，纯风险无收益；而 `Activity` 本身就是 `Context`，所以只要把
 * 私有 `private fun dp(` 删掉、把这个扩展 import 进来，文件里所有 `dp(12)`
 * **自动解析到扩展函数，调用点一个都不用动**。编译通过就是证明 —— 少了会直接
 * `Unresolved reference: dp`。
 *
 * 颜色取的是 `SettingsActivity` 原来的那几个字面量（`#111827` / `#6B7280`），
 * 因为这里的函数是从那里**逐字搬过来**的：搬迁不改视觉，只改归属。
 */
object UiKitColors {
    val ink: Int = Color.parseColor("#111827")
    val sub: Int = Color.parseColor("#6B7280")
    val hintText: Int = Color.parseColor("#9CA3AF")
    val field: Int = Color.parseColor("#F3F4F6")
    val pageBg: Int = Color.parseColor("#F2F3F5")
}

/** dp → 像素。整机唯一定义，别再各页写一份。 */
fun Context.dp(v: Int): Int = TypedValue.applyDimension(
    TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics
).roundToInt()

fun Context.text(t: String, size: Float, color: Int, bold: Boolean = false): TextView =
    TextView(this).apply {
        text = t; textSize = size; setTextColor(color); if (bold) setTypeface(typeface, Typeface.BOLD)
    }

fun Context.round(radius: Int, color: Int, stroke: Boolean = false): GradientDrawable =
    GradientDrawable().apply {
        cornerRadius = radius.toFloat(); setColor(color); if (stroke) setStroke(dp(1), Palette.brand())
    }

fun Context.card(): LinearLayout = LinearLayout(this).apply {
    orientation = LinearLayout.VERTICAL
    background = round(dp(14), Color.WHITE)
    setPadding(dp(14), dp(4), dp(14), dp(14))
    layoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
    ).apply { topMargin = dp(10) }
}

fun Context.edit(value: String, hint: String, password: Boolean = false): EditText =
    EditText(this).apply {
        setText(value); this.hint = hint; textSize = 14f; setTextColor(UiKitColors.ink)
        setHintTextColor(UiKitColors.hintText)
        background = round(dp(8), UiKitColors.field)
        setPadding(dp(10), dp(10), dp(10), dp(10))
        // Masked, not VISIBLE_PASSWORD: an API key should not sit in plain sight.
        if (password) inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply { topMargin = dp(2) }
    }

fun Context.label(t: String): TextView =
    text(t, 13f, UiKitColors.ink, bold = true).apply { setPadding(0, dp(12), 0, dp(4)) }

fun Context.header(t: String): TextView =
    text(t, 24f, UiKitColors.ink, bold = true).apply { setPadding(0, 0, 0, dp(4)) }

fun Context.section(t: String): TextView =
    text(t, 12f, UiKitColors.sub, bold = true).apply { setPadding(dp(2), dp(16), 0, dp(6)) }

/**
 * 小胶囊按钮（「用」「改」「⋯」这种行内动作）。
 *
 * [on] = true 时是实心（表示当前选中/生效），否则白底描边。
 */
fun Context.chip(label: String, on: Boolean, onClick: () -> Unit): TextView =
    TextView(this).apply {
        text = label; textSize = 12.5f; gravity = Gravity.CENTER
        setTypeface(typeface, Typeface.BOLD)
        val accent = Palette.brand()
        setTextColor(if (on) Color.WHITE else accent)
        background = round(dp(8), if (on) accent else Color.WHITE, stroke = !on)
        setPadding(dp(14), dp(7), dp(14), dp(7))
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply { rightMargin = dp(8) }
        setOnClickListener { onClick() }
    }

/** 平铺的筛选胶囊（分类 / 排序），`selected` 决定高亮。 */
fun Context.filterChip(label: String, selected: Boolean, onClick: () -> Unit): TextView =
    TextView(this).apply {
        text = label; textSize = 12.5f; gravity = Gravity.CENTER
        val accent = Palette.brand()
        setTextColor(if (selected) Color.WHITE else UiKitColors.ink)
        background = round(dp(16), if (selected) accent else Color.WHITE, stroke = !selected)
        setPadding(dp(14), dp(7), dp(14), dp(7))
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply { rightMargin = dp(8) }
        setOnClickListener { onClick() }
        if (selected) setTypeface(typeface, Typeface.BOLD)
    }

/** 卡片里的小标题（比 [label] 大一号）。 */
fun Context.cardTitle(t: String): TextView =
    text(t, 16f, UiKitColors.ink, bold = true).apply { setPadding(0, dp(10), 0, dp(4)) }

/** 某个接口测试按钮下面那行结果回显。 */
fun Context.resultText(): TextView =
    text("", 12.5f, UiKitColors.sub).apply { setPadding(0, dp(10), 0, dp(2)) }

/** 主操作按钮（整宽实心）。 */
fun Context.primaryBtn(label: String, onClick: () -> Unit): TextView = TextView(this).apply {
    text = label; textSize = 15f; gravity = Gravity.CENTER; setTypeface(typeface, Typeface.BOLD)
    setTextColor(Color.WHITE); background = round(dp(12), Palette.brand())
    setPadding(dp(16), dp(13), dp(16), dp(13))
    layoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
    ).apply { topMargin = dp(18) }
    setOnClickListener { onClick() }
}

/** 卡片内的次要按钮（白底描边）。 */
fun Context.cardBtn(label: String, onClick: () -> Unit): TextView = TextView(this).apply {
    text = label; textSize = 14f; gravity = Gravity.CENTER; setTypeface(typeface, Typeface.BOLD)
    setTextColor(Palette.brand()); background = round(dp(10), Color.WHITE, stroke = true)
    setPadding(dp(14), dp(10), dp(14), dp(10))
    layoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
    ).apply { topMargin = dp(14) }
    setOnClickListener { onClick() }
}

/**
 * 折叠组：一页平铺几十个控件块、真机要滚六屏以上，按「连接 / 人设 / 行为 / 高级」
 * 分组，默认只展开前面的组。控件本身一行不动，只是从 root 换进组容器。
 */
fun Context.foldSection(title: String, defaultOpen: Boolean, body: LinearLayout): View {
    var open = defaultOpen
    val chev = TextView(this).apply {
        textSize = 15f; setTextColor(UiKitColors.sub); setPadding(dp(8), 0, 0, 0)
    }
    val head = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(2), dp(12), dp(2), dp(12))
        setOnClickListener {
            open = !open
            chev.text = if (open) "▾" else "▸"
            body.visibility = if (open) View.VISIBLE else View.GONE
        }
    }
    head.addView(TextView(this).apply {
        text = title; textSize = 16f; setTextColor(UiKitColors.ink)
        setTypeface(typeface, Typeface.BOLD)
        layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
    })
    head.addView(chev)
    chev.text = if (open) "▾" else "▸"
    body.visibility = if (open) View.VISIBLE else View.GONE
    return LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        addView(head); addView(body)
    }
}

/** Opens an external link; swallows the failure with a toast rather than crashing. */
fun Context.openUrl(url: String) {
    runCatching {
        startActivity(
            android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }.onFailure {
        Toast.makeText(this, "打不开浏览器", Toast.LENGTH_SHORT).show()
    }
}

fun Context.versionLabel(): String = try {
    val pi = packageManager.getPackageInfo(packageName, 0)
    "版本 v${pi.versionName}（${pi.longVersionCode}）"
} catch (e: Exception) {
    "版本 —"
}

fun Context.pct(d: Double?): String =
    if (d == null) "?" else "${(d * 100).roundToInt()}%"

fun Context.toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()

/** 目标 App 的显示名；没装就退回包名。只是查一下，不触发任何加载。 */
fun Context.appLabel(pkg: String): String = runCatching {
    @Suppress("DEPRECATION")
    val info = packageManager.getApplicationInfo(pkg, 0)
    packageManager.getApplicationLabel(info).toString()
}.getOrNull()?.takeIf { it.isNotBlank() } ?: pkg

/** 一句确认框：套模板这类会盖掉用户手写内容的动作都得先问。 */
fun Context.confirm(title: String, msg: String, onYes: () -> Unit) {
    androidx.appcompat.app.AlertDialog.Builder(this)
        .setTitle(title).setMessage(msg)
        .setPositiveButton("确定") { _, _ -> onYes() }
        .setNegativeButton("取消", null)
        .show()
}

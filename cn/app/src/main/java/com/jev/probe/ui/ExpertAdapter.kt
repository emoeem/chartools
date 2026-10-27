package com.jev.probe.ui

import android.graphics.Color
import android.graphics.Typeface
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import com.jev.probe.core.Palette
import com.jev.probe.core.kb.PersonaProfile

/**
 * 专家库的 2 列网格。
 *
 * 用 [ListAdapter] + `DiffUtil` 而不是 `removeAllViews()` 重建：搜索框每输入一个字
 * 都会重画一次列表，全量重建会让滚动位置和点击反馈一起抖；`DiffUtil` 只动真正变了
 * 的那几张卡。
 *
 * 间距用 `LayoutParams` 的 margin 而不是 `ItemDecoration`：`GridLayoutManager` 的
 * 分割线要自己算「哪些位置是列尾」，两列布局里最容易写错的就是这一处 —— 右侧那列
 * 的右边距被算成内边距，看起来就是「网格被裁」。margin 没有这个歧义。
 */
class ExpertAdapter(
    private val onTap: (PersonaProfile) -> Unit,
    private val onHold: (PersonaProfile) -> Unit
) : ListAdapter<PersonaProfile, ExpertAdapter.Holder>(DIFF) {

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): Holder {
        val ctx = parent.context
        val box = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            background = ctx.round(ctx.dp(14), Color.WHITE)
            setPadding(ctx.dp(12), ctx.dp(12), ctx.dp(12), ctx.dp(12))
            layoutParams = RecyclerView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(ctx.dp(4), ctx.dp(4), ctx.dp(4), ctx.dp(4)) }
        }
        val avatar = TextView(ctx).apply { textSize = 20f }
        val name = TextView(ctx).apply {
            textSize = 14f
            setTextColor(UiKitColors.ink)
            setTypeface(typeface, Typeface.BOLD)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            setPadding(0, ctx.dp(6), 0, 0)
        }
        val blurb = TextView(ctx).apply {
            textSize = 11f
            setTextColor(UiKitColors.sub)
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            setPadding(0, ctx.dp(4), 0, 0)
        }
        val tags = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, ctx.dp(6), 0, 0)
        }
        val footer = TextView(ctx).apply {
            textSize = 10.5f
            setTextColor(Palette.brand())
            setPadding(0, ctx.dp(8), 0, 0)
        }
        box.addView(avatar); box.addView(name); box.addView(blurb)
        box.addView(tags); box.addView(footer)
        return Holder(box, avatar, name, blurb, tags, footer)
    }

    override fun onBindViewHolder(holder: Holder, position: Int) {
        val p = getItem(position)
        val card = ExpertCard.of(p)
        holder.avatar.text = card.avatar
        holder.name.text = card.name
        holder.blurb.text = card.blurb
        holder.blurb.visibility = if (card.blurb.isBlank()) View.GONE else View.VISIBLE
        holder.footer.text = if (card.category.isNotBlank()) "${card.usage} · ${card.category}" else card.usage

        val ctx = holder.itemView.context
        holder.tags.removeAllViews()
        card.tags.forEach { tag ->
            holder.tags.addView(TextView(ctx).apply {
                text = tag
                textSize = 10f
                setTextColor(UiKitColors.sub)
                background = ctx.round(ctx.dp(6), UiKitColors.field)
                setPadding(ctx.dp(6), ctx.dp(2), ctx.dp(6), ctx.dp(2))
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
                ).apply { rightMargin = ctx.dp(4) }
            })
        }
        holder.tags.visibility = if (card.hasTags) View.VISIBLE else View.GONE

        holder.itemView.setOnClickListener { onTap(p) }
        holder.itemView.setOnLongClickListener {
            onHold(p)
            true
        }
    }

    class Holder(
        itemView: View,
        val avatar: TextView,
        val name: TextView,
        val blurb: TextView,
        val tags: LinearLayout,
        val footer: TextView
    ) : RecyclerView.ViewHolder(itemView)

    private companion object {
        val DIFF = object : DiffUtil.ItemCallback<PersonaProfile>() {
            override fun areItemsTheSame(oldItem: PersonaProfile, newItem: PersonaProfile) =
                oldItem.id == newItem.id

            // 卡面上出现的每一个字段都要参与比较：只比 id 的话，改完名字回到列表
            // 仍然是旧名字，用户会以为保存没生效。
            override fun areContentsTheSame(oldItem: PersonaProfile, newItem: PersonaProfile) =
                oldItem.name == newItem.name &&
                    oldItem.description == newItem.description &&
                    oldItem.avatar == newItem.avatar &&
                    oldItem.tags == newItem.tags &&
                    oldItem.category == newItem.category &&
                    oldItem.usedCount == newItem.usedCount
        }
    }
}

package com.jev.probe.core.kb

/**
 * 「当前生效」那段文本的**写入口**。
 *
 * 生产实现是 `Prefs.style`（见 `ExpertActivity` 里的适配器），测试实现是一个内存变量
 * 或一个会抛异常的实现。这样 [ExpertApply] 就能在 JVM 单测里被逼出各种失败路径 ——
 * 而失败路径正是这个类存在的理由。
 *
 * 定义成一个接口而不是直接依赖 `Prefs`：`Prefs` 绑在 `Context` / `SharedPreferences` 上，
 * 而 [ExpertApply] 要留在纯 Kotlin 层（`global/` 也要用同一套套用语义）。
 */
interface StyleSink {
    var style: String
}

/**
 * **「用这位专家」的唯一实现**：`install → touch → 换 reply_style`，要么全成，要么不留半截。
 *
 * ## 为什么要有这个类
 *
 * 之前这三步散在 `ExpertActivity.applyExpert()` 里，顺序是**先把 `prefs.style` 换掉，
 * 再在后台线程 install / touch**。后果很具体：磁盘写失败（空间不够、没有写权限）时，
 * 设置里那句人设**已经变成新专家了**，而我的专家库里没有这一条 —— 界面显示「已套用」，
 * 用户下次打开专家库却发现「我的」里没有它，热度也记不上。这不是「失败」，这是
 * **半截状态**：看起来成功了，数据和显示不一致，而且没有任何报错。
 *
 * 现在顺序固定成三步，任一步失败都往回退：
 *
 * 1. **落库**（`install` / 取已有条目）。这一步失败就**立刻返回，`style` 一个字节都不动**。
 *    它是唯一可能写坏用户数据的步骤，所以必须先做、必须成败分明。
 * 2. **记热度**（`touch`）。失败**不阻塞** —— 热度是计数器，丢一票只是「最热」少一次，
 *    没道理为了它让用户用不上专家。降级成 [Result.warning] 告诉界面。
 * 3. **换 `style`**。放在最后，且写失败时**回滚到进来时的那句文本**。
 *
 * ## 关于「负向的」第 3 步失败
 *
 * `style` 写失败时，第 1 步已经把条目存进库了。这里**不删它**：那是一条完整、合法的
 * 人设卡（用户点了「用」，本来就想留下它），删掉才是二次破坏。返回的 [Result.problem]
 * 会说清「库里有了，但设置没换成」，界面照实显示。
 *
 * ## 不变量
 *
 * 只写 `body`。`avatar` / `description` / `tags` / `category` / `usedCount` 一律不进
 * `style` —— `style` 是 [PersonaCard] 的唯一输入，也就是提示词的唯一来源。
 */
class ExpertApply(
    private val store: PersonaStore,
    private val sink: StyleSink
) {

    /**
     * @param ok 三步都成了。
     * @param profile 最终落库的那一条（`ok=false` 时也可能非 null，见类注释）。
     * @param warning 降级说明：热度没记上之类，不影响使用。
     * @param problem 失败原因，给界面直接显示。
     */
    data class Result(
        val ok: Boolean,
        val profile: PersonaProfile? = null,
        val warning: String = "",
        val problem: String = ""
    )

    /** 目录里的专家（用户点「用」时它还没进我的库）。 */
    fun apply(preset: PersonaPreset): Result = run(preset, null)

    /**
     * 已经在「我的专家库」里的条目。
     *
     * @param preset 目录条目对应的预设（在目录里时传，用来保证库里有这一条）；
     *        用户自建的条目传 null。
     */
    fun apply(profile: PersonaProfile, preset: PersonaPreset? = null): Result = run(preset, profile)

    private fun run(preset: PersonaPreset?, profile: PersonaProfile?): Result {
        if (preset == null && profile == null) {
            return Result(ok = false, problem = "没有可套用的专家")
        }
        val name = preset?.name ?: profile?.name.orEmpty()
        // 进来时的那句文本：第 3 步失败要原样退回去。
        val before = runCatching { sink.style }.getOrDefault("")

        // 0) 正文是唯一进提示词的东西。空正文套上去等于把用户的人设清空。
        val body = (preset?.body ?: profile?.body.orEmpty()).trim()
        if (body.isBlank()) {
            return Result(ok = false, problem = "「$name」没有正文，没套用")
        }

        // 1) 落库。失败 → style 一个字节都不动（这是整个类最要紧的一条）。
        val entry = if (preset != null) {
            store.install(preset)
        } else {
            profile?.let { store.get(it.id) ?: it }
        }
        if (entry == null) {
            return Result(
                ok = false,
                problem = "没能把「$name」存进我的专家库，设置里那句人设没有改动"
            )
        }

        // 2) 热度。失败降级成 warning，不阻塞套用。
        val touched = store.touch(entry.id)
        val warning = if (touched == null) "热度没记上，不影响使用" else ""
        val live = touched ?: entry

        // 3) 换 style —— 最后一步，失败回滚。
        val failure = runCatching { sink.style = live.body }.exceptionOrNull()
        if (failure != null) {
            runCatching { sink.style = before }
            return Result(
                ok = false,
                profile = live,
                warning = warning,
                problem = "设置里那句人设没写成（${failure.message ?: failure.javaClass.simpleName}），" +
                    "已经还原成原来那句；「$name」还在我的专家库里"
            )
        }

        return Result(ok = true, profile = live, warning = warning)
    }
}

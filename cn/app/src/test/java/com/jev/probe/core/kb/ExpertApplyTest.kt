package com.jev.probe.core.kb

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * 套用链路的**原子性与失败兜底**（E2）。
 *
 * ## 它治的是什么
 *
 * 老的 `applyExpert()` 顺序是「先换 `prefs.style`，再后台 install」：磁盘写失败时
 * 设置里已经变成新专家、库里却没有这一条，界面还弹「已套用」。用户看到的是
 * **一个看起来成功、实际半截的状态**，而且没有任何报错。这里把三条失败路径逐一
 * 逼出来，每一条都断言「`style` 没有被改成半截」。
 *
 * ## 失败是怎么造出来的
 *
 * 不打桩、不改生产代码：把 `kb/` 目录 **chmod 成只读**，真实的 JSON 原子写就会在
 * 创建 `.tmp` 时失败。这样测的是 `writeLocked` 的真行为，而不是「我 mock 了一个
 * 返回 null 的函数」。
 *
 * 第三种失败（`style` 写失败）没法用文件权限造 —— 它是 `SharedPreferences` 的事，
 * 所以用一个会抛异常的 [StyleSink]，并断言回滚到进来时那句文本。
 */
class ExpertApplyTest {

    private lateinit var dir: File
    private lateinit var ctx: ExpertTestContext
    private lateinit var store: PersonaStore

    /** 内存里的 StyleSink；可选「写入即抛异常」。 */
    private class MemSink(initial: String = "", private val failOnSet: Boolean = false) : StyleSink {
        private var value = initial
        override var style: String
            get() = value
            set(v) {
                if (failOnSet) throw IllegalStateException("磁盘满了")
                value = v
            }
    }

    private fun preset(key: String, name: String, body: String = "称呼：你\n主题：$key\n"): PersonaPreset =
        PersonaPreset(
            key = key,
            name = name,
            body = body,
            category = "技术工程",
            tags = listOf("测试", key),
            description = "$name 的简介",
            avatar = "🧪"
        )

    private fun setUp() {
        dir = Files.createTempDirectory("jev-apply-").toFile()
        ctx = ExpertTestContext(dir)
        store = PersonaStore.create(ctx)
    }

    @After
    fun tearDown() {
        // 失败注入会把目录改成只读，先恢复再删，否则删不掉。
        File(dir, "kb").setWritable(true)
        dir.setWritable(true)
        dir.deleteRecursively()
    }

    private fun kbDir(): File = File(dir, "kb")

    private fun goReadOnly() {
        assertTrue("没法把 kb/ 改成只读，这条测试的前提不成立", kbDir().setWritable(false))
    }

    // ------------------------------------------------------------ 正常路径

    @Test
    fun applyInstallsTheExpertAndWritesItsBodyIntoTheStyle() {
        setUp()
        val sink = MemSink(initial = "旧人设")
        val p = preset("agency.test-a", "测试专家A")

        val r = ExpertApply(store, sink).apply(p)

        assertTrue("套用失败：${r.problem}", r.ok)
        assertEquals("style 没换成专家正文", p.body.trim(), sink.style)
        val onDisk = PersonaStore.create(ctx).list().firstOrNull { it.presetKey == p.key }
        assertNotNull("专家没落库", onDisk)
        assertEquals("落库的正文和目录不一致", p.body.trim(), onDisk!!.body)
    }

    @Test
    fun applyBumpsTheHeatOnceAndItSticks() {
        setUp()
        val sink = MemSink()
        val p = preset("agency.test-b", "测试专家B")
        val apply = ExpertApply(store, sink)

        apply.apply(p)
        apply.apply(p)

        val onDisk = PersonaStore.create(ctx).list().first { it.presetKey == p.key }
        assertEquals("两次套用应该记两次热度", 2, onDisk.usedCount)
        assertEquals("重复套用不该在库里留下两条", 1, PersonaStore.create(ctx).list().count { it.presetKey == p.key })
    }

    @Test
    fun anEntryAlreadyInMyLibraryCanBeAppliedWithoutTheDirectoryPreset() {
        setUp()
        val sink = MemSink()
        val mine = store.save("我自己的专家", "称呼：你\n主题：自建\n")!!
        val r = ExpertApply(store, sink).apply(mine, preset = null)

        assertTrue("自建条目套用失败：${r.problem}", r.ok)
        assertEquals(mine.body.trim(), sink.style)
        assertEquals("自建条目套用后热度没记", 1, PersonaStore.create(ctx).get(mine.id)!!.usedCount)
    }

    // ------------------------------------------------------ 失败路径（重点）

    @Test
    fun aFailedInstallLeavesTheCurrentStyleUntouched() {
        setUp()
        val sink = MemSink()
        val apply = ExpertApply(store, sink)

        // 先让 A 正常生效，作为「用户当前的人设」。
        val a = preset("agency.test-a", "测试专家A")
        assertTrue(apply.apply(a).ok)
        assertEquals(a.body.trim(), sink.style)

        // 再换一位，但这次磁盘写不进去。
        goReadOnly()
        val b = preset("agency.test-b", "测试专家B")
        val r = apply.apply(b)

        assertFalse("写盘失败了却报告成功", r.ok)
        assertEquals("install 失败却把 style 换掉了（半截状态）", a.body.trim(), sink.style)
        assertTrue("失败原因没说清：${r.problem}", r.problem.contains("没有改动"))
        assertNull(
            "install 失败了，B 不该出现在库里",
            PersonaStore.create(ctx).list().firstOrNull { it.presetKey == b.key }
        )
    }

    @Test
    fun aFailedTouchDoesNotBlockTheSwitchButIsReported() {
        setUp()
        val sink = MemSink()
        val apply = ExpertApply(store, sink)
        val a = preset("agency.test-a", "测试专家A")

        assertTrue(apply.apply(a).ok)   // 先落库（可写状态下）
        goReadOnly()                    // 之后的写都会失败

        // 再套用同一位：install 直接返回已有条目（不写盘），touch 才写盘 → 失败。
        val r = apply.apply(a)

        assertTrue("热度记不上不该挡住套用：${r.problem}", r.ok)
        assertTrue("热度失败没有降级成 warning", r.warning.isNotBlank())
        assertEquals(a.body.trim(), sink.style)
        assertEquals("只读盘上热度不该变", 1, PersonaStore.create(ctx).get(r.profile!!.id)!!.usedCount)
    }

    @Test
    fun aFailingStyleSinkRollsBackToWhatWasThereBefore() {
        setUp()
        val sink = MemSink(initial = "用户原来写的人设", failOnSet = true)
        val p = preset("agency.test-c", "测试专家C")

        val r = ExpertApply(store, sink).apply(p)

        assertFalse("写入抛异常却报告成功", r.ok)
        assertEquals("回滚失败：style 停在了半截状态", "用户原来写的人设", sink.style)
        assertTrue("失败原因没说清：${r.problem}", r.problem.contains("还原"))
        // 条目仍然留在库里：它是一条完整合法的卡，删掉才是二次破坏。
        assertNotNull(
            "落库的条目不该因为 style 写失败被删掉",
            PersonaStore.create(ctx).list().firstOrNull { it.presetKey == p.key }
        )
    }

    @Test
    fun aBlankBodyIsRefusedBeforeAnythingIsWritten() {
        setUp()
        val sink = MemSink(initial = "旧人设")
        val blank = preset("agency.test-d", "空正文专家", body = "   \n  ")

        val r = ExpertApply(store, sink).apply(blank)

        assertFalse("空正文被套用了", r.ok)
        assertEquals("空正文不该动 style", "旧人设", sink.style)
        assertNull(
            "空正文不该落库",
            PersonaStore.create(ctx).list().firstOrNull { it.presetKey == blank.key }
        )
    }

    // ------------------------------------------------------ 生效 / 数据安全

    @Test
    fun theNextDraftSeesTheNewStyleImmediatelyAndNothingStales() {
        setUp()
        val sink = MemSink()
        val apply = ExpertApply(store, sink)
        val a = preset("agency.test-a", "测试专家A")
        val b = preset("agency.test-b", "测试专家B")

        apply.apply(a)
        // 「下一次起草」读到的就是此刻的 style，没有中间缓存。
        val cardA = PersonaCard.parse(sink.style)
        assertTrue("A 生效后解析成了自由文本", cardA.structured)
        assertTrue("A 的主题没进提示词", cardA.promptText().contains("主题：${cardA.topic}"))

        apply.apply(b)
        val cardB = PersonaCard.parse(sink.style)
        assertEquals("B 的正文没读回来", b.body.trim(), sink.style)
        assertTrue("B 的主题没进提示词", cardB.promptText().contains("主题：${cardB.topic}"))
        assertFalse("换到 B 之后 A 的主题还在", cardB.promptText().contains("主题：${cardA.topic}"))
        // 起草链路按 style 反查条目（`touchActive`），换人之后必须反查到 B。
        assertEquals(b.key, PersonaStore.create(ctx).activeOf(sink.style)?.presetKey)
    }

    @Test
    fun aCorruptLibraryFileIsBackedUpNotSilentlyEmptied() {
        setUp()
        // 先把目录写坏，模拟用户文件被截断 / 手改坏。
        val kb = kbDir()
        kb.mkdirs()
        val broken = "{ 这不是 JSON"
        File(kb, "personas.json").writeText(broken, Charsets.UTF_8)

        val sink = MemSink()
        val p = preset("agency.test-e", "测试专家E")
        val r = ExpertApply(store, sink).apply(p)

        assertTrue("坏文件挡不住套用：${r.problem}", r.ok)
        assertEquals(p.body.trim(), sink.style)
        val backup = kb.listFiles()?.firstOrNull { it.name.startsWith("personas.corrupt-") }
        assertNotNull("坏文件没有备份，用户数据被直接覆盖了", backup)
        assertEquals("备份内容和原始坏文件不一致", broken, backup!!.readText(Charsets.UTF_8))
    }
}

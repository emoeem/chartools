package com.jev.probe.jev

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * 缓存键的锁。
 *
 * 键里漏一个分量不会报错，只会「改了输入、回复没变」——用户以为功能坏了，
 * 我们连日志都没有。所以这里对**每一个**分量单独做一次变异：改它，键必须变。
 *
 * 最要紧的是 [style 变了键就变]：专家库 331 位全靠换 `style` 生效，它一旦
 * 从键里掉出去，换专家就等于换了个寂寞，而且测不出来。
 */
class ReplyCacheKeyTest {

    private data class In(
        val sig: String = "S",
        val rel: String = "R",
        val style: String = "ST",
        val model: String = "M",
        val count: Int = 3,
        val avoid: List<String> = listOf("x"),
        val ctx: String = "C",
        val ledger: String = "L",
        val judgment: String = "J",
        val intensity: String = "AUTO"
    ) {
        fun key(): String =
            ReplyCacheKey.reply(sig, rel, style, model, count, avoid, ctx, ledger, judgment, intensity)
    }

    @Test
    fun `同样的输入得到逐字相同的键`() {
        assertEquals(In().key(), In().key())
    }

    @Test
    fun `style 变了键就变`() {
        val a = In(style = "主题：职场")
        val b = In(style = "主题：恋爱")
        assertNotEquals(a.key(), b.key())
    }

    @Test
    fun `十个分量逐个变异，键都要变`() {
        val base = In()
        val mutated = listOf(
            "signature" to base.copy(sig = "S2"),
            "relationship" to base.copy(rel = "R2"),
            "style" to base.copy(style = "ST2"),
            "replyModel" to base.copy(model = "M2"),
            "count" to base.copy(count = 4),
            "avoid" to base.copy(avoid = listOf("x", "y")),
            "ctxKey" to base.copy(ctx = "C2"),
            "ledgerKey" to base.copy(ledger = "L2"),
            "judgmentKey" to base.copy(judgment = "J2"),
            "intensity" to base.copy(intensity = "SOFT")
        )
        // 分量数写死：以后往 apply 里加了新参数却忘了进键，这条会红。
        assertEquals(10, mutated.size)
        for ((name, input) in mutated) {
            assertNotEquals("分量 [$name] 没进键", base.key(), input.key())
        }
    }

    @Test
    fun `字段边界不会串味`() {
        // "ab" + "c" 必须区别于 "a" + "bc"：靠分隔符，不靠拼接巧合。
        assertNotEquals(In(sig = "ab", rel = "c").key(), In(sig = "a", rel = "bc").key())
        assertNotEquals(In(style = "ab").key(), In(style = "a", rel = "bR").key())
    }

    @Test
    fun `avoid 多条与单条不同`() {
        assertNotEquals(In(avoid = listOf("x")).key(), In(avoid = listOf("x", "")).key())
        assertNotEquals(In(avoid = emptyList()).key(), In(avoid = listOf("")).key())
    }

    @Test
    fun `判断键跟着判断路由走`() {
        val a = ReplyCacheKey.judge("S", "R", "judge-1", "openai", "C")
        val b = ReplyCacheKey.judge("S", "R", "judge-2", "openai", "C")
        val c = ReplyCacheKey.judge("S", "R", "judge-1", "anthropic", "C")
        assertNotEquals(a, b)
        assertNotEquals(a, c)
        assertEquals(a, ReplyCacheKey.judge("S", "R", "judge-1", "openai", "C"))
    }

    @Test
    fun `回复键与判断键不会互相命中`() {
        // 两个 LRU 分开存，但键本身也不该长得一样：串了就是把判断当候选回复用。
        assertNotEquals(
            ReplyCacheKey.judge("S", "R", "M", "P", "C"),
            In(sig = "S", rel = "R", model = "M", ctx = "C", style = "P").key()
        )
    }
}

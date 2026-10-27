package com.jev.probe.core.kb

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import java.io.File

/**
 * JVM 单测里能用的 `SharedPreferences`：一个 `HashMap` 支撑的假实现。
 *
 * 为什么需要它：`ExpertApplyEndToEndTest` 要断言的是「切了专家之后，**真正喂给
 * 起草链路的那句 `Prefs.style`** 变成了新 body」。如果用一个自定义的
 * `var style: String` 变量代替 `Prefs`，那这条断言就绕过了被测对象本身 ——
 * 测的是「我自己的变量能赋值」，而不是「`Prefs` 读出来的东西变了」。
 *
 * `Prefs` 的构造函数只有一句 `context.getSharedPreferences(...)`，所以只要这里
 * 把那个方法接住，真实的 `Prefs` 就能在 JVM 里跑起来。注意 `Prefs` 的 `init`
 * 里那三段迁移只在 `PREFS_MAIN` 名下执行，测试用别的名字，顺带绕开了
 * `ApiKeyVault` 对 AndroidKeyStore 的依赖（那个在 JVM 里必然不可用）。
 */
class FakeSharedPreferences : SharedPreferences {

    private val map = HashMap<String, Any?>()
    private val listeners = LinkedHashSet<SharedPreferences.OnSharedPreferenceChangeListener>()

    override fun getAll(): MutableMap<String, *> = HashMap(map)

    override fun getString(key: String?, defValue: String?): String? =
        if (map.containsKey(key)) map[key] as? String else defValue

    override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
        if (map.containsKey(key)) (map[key] as? Set<*>)?.mapTo(LinkedHashSet()) { it as String } else defValues

    override fun getInt(key: String?, defValue: Int): Int = (map[key] as? Int) ?: defValue

    override fun getLong(key: String?, defValue: Long): Long = (map[key] as? Long) ?: defValue

    override fun getFloat(key: String?, defValue: Float): Float = (map[key] as? Float) ?: defValue

    override fun getBoolean(key: String?, defValue: Boolean): Boolean = (map[key] as? Boolean) ?: defValue

    override fun contains(key: String?): Boolean = map.containsKey(key)

    override fun edit(): SharedPreferences.Editor = Editor()

    override fun registerOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?
    ) {
        if (listener != null) listeners += listener
    }

    override fun unregisterOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?
    ) {
        if (listener != null) listeners -= listener
    }

    private inner class Editor : SharedPreferences.Editor {
        private val pending = LinkedHashMap<String, Any?>()
        private val removals = LinkedHashSet<String>()
        private var wipe = false

        override fun putString(key: String?, value: String?): SharedPreferences.Editor {
            pending[key.orEmpty()] = value
            return this
        }

        override fun putStringSet(key: String?, values: MutableSet<String>?): SharedPreferences.Editor {
            pending[key.orEmpty()] = values?.toSet()
            return this
        }

        override fun putInt(key: String?, value: Int): SharedPreferences.Editor {
            pending[key.orEmpty()] = value
            return this
        }

        override fun putLong(key: String?, value: Long): SharedPreferences.Editor {
            pending[key.orEmpty()] = value
            return this
        }

        override fun putFloat(key: String?, value: Float): SharedPreferences.Editor {
            pending[key.orEmpty()] = value
            return this
        }

        override fun putBoolean(key: String?, value: Boolean): SharedPreferences.Editor {
            pending[key.orEmpty()] = value
            return this
        }

        override fun remove(key: String?): SharedPreferences.Editor {
            removals += key.orEmpty()
            return this
        }

        override fun clear(): SharedPreferences.Editor {
            wipe = true
            return this
        }

        override fun commit(): Boolean {
            if (wipe) map.clear()
            removals.forEach { map.remove(it) }
            map.putAll(pending)
            listeners.toList().forEach { it.onSharedPreferenceChanged(this@FakeSharedPreferences, null) }
            return true
        }

        override fun apply() {
            commit()
        }
    }
}

/**
 * 一个够用的 `Context`：只实现 `PersonaStore` 和 `Prefs` 真正会调的那两个方法。
 *
 * 和 `PersonaMigrationTest` 里的 `TestContext` 是同一套思路，区别只在这里多接管
 * 了 `getSharedPreferences`，好让真实的 `Prefs` 能在 JVM 里被构造出来。
 */
class ExpertTestContext(private val dir: File) : ContextWrapper(null) {

    private val prefs = FakeSharedPreferences()

    override fun getApplicationContext(): Context = this

    override fun getFilesDir(): File = dir

    override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences = prefs
}

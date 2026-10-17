package com.jev.probe.core

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ApiKeyVaultTest {

    private lateinit var context: Context
    private lateinit var preferences: android.content.SharedPreferences

    @Before
    fun setUp() {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        context = object : ContextWrapper(target) {
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                target.getSharedPreferences(TEST_PREFS_NAME, mode)
        }
        preferences = target.getSharedPreferences(TEST_PREFS_NAME, Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
    }

    @After
    fun tearDown() {
        preferences.edit().clear().commit()
    }

    @Test
    fun savesApiKeysEncryptedAndReadsThemAcrossInstances() {
        val first = Prefs(context)
        first.judgeKey = "judge-secret"
        first.replyKey = "reply-secret"
        first.visionKey = "vision-secret"
        first.reviewKey = "review-secret"

        for (name in listOf("judge_key", "reply_key", "vision_key", "review_key")) {
            val stored = preferences.getString(name, null)
            assertTrue("$name should be encrypted", stored?.startsWith(ApiKeyVault.PREFIX) == true)
            assertFalse(stored.orEmpty().contains("secret"))
        }

        val reloaded = Prefs(context)
        assertEquals("judge-secret", reloaded.judgeKey)
        assertEquals("reply-secret", reloaded.replyKey)
        assertEquals("vision-secret", reloaded.visionKey)
        assertEquals("review-secret", reloaded.reviewKey)
    }

    @Test
    fun migratesLegacyPlaintextKeyIntoEncryptedJudgeSlot() {
        preferences.edit()
            .putString("openrouter_key", "legacy-secret")
            .putBoolean("prefs_migrated_v13", false)
            .commit()

        val prefs = Prefs(context)

        assertEquals("legacy-secret", prefs.judgeKey)
        assertTrue(preferences.getString("judge_key", null)?.startsWith(ApiKeyVault.PREFIX) == true)
        assertFalse(preferences.contains("openrouter_key"))
        assertNullStorageError(prefs)
    }

    @Test
    fun removingApiKeyDeletesCiphertext() {
        val prefs = Prefs(context)
        prefs.judgeKey = "remove-me"
        prefs.judgeKey = ""

        assertFalse(preferences.contains("judge_key"))
        assertEquals("", Prefs(context).judgeKey)
    }

    @Test
    fun preservesLegacyKeyWhenJudgeCiphertextCannotBeRead() {
        preferences.edit()
            .putString("judge_key", "${ApiKeyVault.PREFIX}invalid:invalid")
            .putString("openrouter_key", "legacy-secret")
            .putBoolean("prefs_migrated_v13", true)
            .commit()

        val prefs = Prefs(context)

        assertTrue(preferences.getString("openrouter_key", null)?.startsWith(ApiKeyVault.PREFIX) == true)
        assertTrue(prefs.keyStorageError != null)
    }

    @Test
    fun recoveryClearRemovesAllSavedApiKeys() {
        val prefs = Prefs(context)
        prefs.judgeKey = "judge-secret"
        prefs.replyKey = "reply-secret"
        prefs.visionKey = "vision-secret"
        prefs.reviewKey = "review-secret"

        assertTrue(prefs.clearApiKeysForRecovery())
        for (name in listOf("judge_key", "reply_key", "vision_key", "review_key", "openrouter_key")) {
            assertFalse(preferences.contains(name))
        }
        assertEquals(null, prefs.keyStorageError)
    }

    private fun assertNullStorageError(prefs: Prefs) {
        assertEquals(null, prefs.keyStorageError)
    }

    private companion object {
        const val TEST_PREFS_NAME = "api_key_vault_instrumentation_test"
    }
}

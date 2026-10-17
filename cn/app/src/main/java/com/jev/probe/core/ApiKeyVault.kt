package com.jev.probe.core

import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class ApiKeyVault(private val preferences: SharedPreferences) {

    @Synchronized
    fun read(name: String): String {
        val stored = preferences.getString(name, null) ?: return ""
        if (stored.isEmpty()) return ""
        if (!stored.startsWith(PREFIX)) {
            val encrypted = encrypt(stored)
            check(preferences.edit().putString(name, encrypted).commit()) {
                "Could not migrate API key into encrypted storage."
            }
            return stored
        }

        val parts = stored.removePrefix(PREFIX).split(':', limit = 2)
        check(parts.size == 2) { "Stored API key has an invalid encrypted format." }
        val iv = Base64.decode(parts[0], Base64.NO_WRAP)
        val data = Base64.decode(parts[1], Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_LENGTH_BITS, iv))
        return String(cipher.doFinal(data), Charsets.UTF_8)
    }

    @Synchronized
    fun write(name: String, value: String) {
        val editor = preferences.edit()
        if (value.isBlank()) {
            check(editor.remove(name).commit()) { "Could not remove API key from app settings." }
            return
        }
        check(editor.putString(name, encrypt(value)).commit()) {
            "Could not save encrypted API key to app settings."
        }
    }

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val iv = Base64.encodeToString(cipher.iv, Base64.NO_WRAP)
        val data = Base64.encodeToString(cipher.doFinal(value.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
        return "$PREFIX$iv:$data"
    }

    private fun secretKey(): SecretKey = synchronized(KEY_LOCK) {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return@synchronized it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setUserAuthenticationRequired(false)
                .build()
        )
        generator.generateKey()
    }

    internal companion object {
        const val PREFIX = "jev-aes-gcm-v1:"
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "jev_api_keys_v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val TAG_LENGTH_BITS = 128
        val KEY_LOCK = Any()
    }
}

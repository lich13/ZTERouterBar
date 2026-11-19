package com.zte.routerbar.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

interface CredentialRepository {
    fun readPassword(profileId: String): String?
    fun writePassword(profileId: String, password: String)
    fun deletePassword(profileId: String)
    fun hasPassword(profileId: String): Boolean
}

class AndroidCredentialStore(context: Context) : CredentialRepository {
    private val baseDir: File = context.applicationContext.noBackupFilesDir
    private val keyStore: KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private val lock = Any()

    override fun hasPassword(profileId: String): Boolean = synchronized(lock) {
        if (profileId.isBlank()) return false
        credentialFile(identity(profileId)).baseFile.exists()
    }

    override fun readPassword(profileId: String): String? = synchronized(lock) {
        if (profileId.isBlank()) return null
        return try {
            val id = identity(profileId)
            val saved = credentialFile(id)
            if (!saved.baseFile.exists()) return null
            val secret = getOrCreateSecretKey(id, create = false) ?: return null
            val json = JSONObject(saved.openRead().use { it.readBytes().toString(Charsets.UTF_8) })
            val iv = Base64.decode(json.getString("iv"), Base64.NO_WRAP)
            val ciphertext = Base64.decode(json.getString("ciphertext"), Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(128, iv))
            cipher.updateAAD(profileId.toByteArray(Charsets.UTF_8))
            cipher.doFinal(ciphertext).toString(Charsets.UTF_8).takeIf { it.isNotEmpty() }
        } catch (_: Exception) {
            null
        }
    }

    override fun writePassword(profileId: String, password: String) {
        synchronized(lock) {
            require(profileId.isNotBlank() && profileId.length <= 256)
            val trimmed = password.trim()
            require(trimmed.isNotEmpty() && trimmed.length <= 4096)

            val id = identity(profileId)
            val secret = requireNotNull(getOrCreateSecretKey(id, create = true))
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, secret)
            cipher.updateAAD(profileId.toByteArray(Charsets.UTF_8))
            val encrypted = cipher.doFinal(trimmed.toByteArray(Charsets.UTF_8))

            val payload = JSONObject()
                .put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                .put("ciphertext", Base64.encodeToString(encrypted, Base64.NO_WRAP))
                .toString()
                .toByteArray(Charsets.UTF_8)

            val target = credentialFile(id)
            val stream = target.startWrite()
            try {
                stream.write(payload)
                target.finishWrite(stream)
            } catch (err: Exception) {
                target.failWrite(stream)
                throw err
            }
        }
    }

    override fun deletePassword(profileId: String) {
        synchronized(lock) {
            if (profileId.isBlank()) return
            val id = identity(profileId)
            runCatching { credentialFile(id).delete() }
            runCatching {
                if (keyStore.containsAlias(alias(id))) {
                    keyStore.deleteEntry(alias(id))
                }
            }
        }
    }

    private fun identity(profileId: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(profileId.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }

    private fun alias(id: String): String = "zterouterbar.cred.$id"

    private fun credentialFile(id: String): AtomicFile =
        AtomicFile(File(baseDir, "credential-$id.json"))

    private fun getOrCreateSecretKey(id: String, create: Boolean): SecretKey? {
        (keyStore.getKey(alias(id), null) as? SecretKey)?.let { return it }
        if (!create) return null
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(
                KeyGenParameterSpec.Builder(
                    alias(id),
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .setRandomizedEncryptionRequired(true)
                    .build()
            )
        }.generateKey()
    }
}

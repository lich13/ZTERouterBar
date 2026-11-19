package com.zte.routerbar.core

import java.security.MessageDigest
import java.util.Locale

enum class AuthHashPreference(val wireValue: String, val displayName: String) {
    AUTO("auto", "自动识别 (推荐)"),
    SHA256("sha256", "SHA-256 (MU5120 / MC888 / MC889)"),
    MD5("md5", "MD5 (旧款 ZTE 固件)");

    companion object {
        fun fromWireValue(raw: String?): AuthHashPreference {
            val normalized = raw?.trim()?.lowercase(Locale.ROOT).orEmpty()
            return entries.firstOrNull { it.wireValue == normalized } ?: AUTO
        }
    }
}

enum class ResolvedHashAlgorithm {
    SHA256,
    MD5;

    companion object {
        private val LEGACY_MD5_MARKERS = listOf("MC801", "MC802", "MF286", "MF289", "MF297", "MF9")

        fun resolve(
            waInnerVersion: String,
            preference: AuthHashPreference
        ): ResolvedHashAlgorithm = when (preference) {
            AuthHashPreference.SHA256 -> SHA256
            AuthHashPreference.MD5 -> MD5
            AuthHashPreference.AUTO -> {
                val upper = waInnerVersion.uppercase(Locale.ROOT)
                if (LEGACY_MD5_MARKERS.any { upper.contains(it) }) MD5 else SHA256
            }
        }
    }
}

object RouterCrypto {
    private val UPPER_HEX = "0123456789ABCDEF".toCharArray()
    private val LOWER_HEX = "0123456789abcdef".toCharArray()

    fun sha256Upper(input: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(input.toByteArray(Charsets.UTF_8))
        return toHex(digest, UPPER_HEX)
    }

    fun md5Lower(input: String): String {
        val digest = MessageDigest.getInstance("MD5")
            .digest(input.toByteArray(Charsets.UTF_8))
        return toHex(digest, LOWER_HEX)
    }

    fun computeLoginPassword(plainPassword: String, ld: String): String {
        val baseHash = sha256Upper(plainPassword)
        return sha256Upper(baseHash + ld)
    }

    fun computeAD(
        waInnerVersion: String,
        crVersion: String,
        rd: String,
        algorithm: ResolvedHashAlgorithm
    ): String = when (algorithm) {
        ResolvedHashAlgorithm.SHA256 -> {
            val versionHash = sha256Upper(waInnerVersion + crVersion)
            sha256Upper(versionHash + rd)
        }
        ResolvedHashAlgorithm.MD5 -> {
            val versionHash = md5Lower(waInnerVersion + crVersion)
            md5Lower(versionHash + rd)
        }
    }

    private fun toHex(bytes: ByteArray, alphabet: CharArray): String {
        val out = CharArray(bytes.size * 2)
        for (i in bytes.indices) {
            val v = bytes[i].toInt() and 0xFF
            out[i * 2] = alphabet[v ushr 4]
            out[i * 2 + 1] = alphabet[v and 0x0F]
        }
        return String(out)
    }
}

package com.zte.routerbar.data

import android.content.Context
import android.util.AtomicFile
import com.zte.routerbar.core.AuthHashPreference
import com.zte.routerbar.core.RouterProfile
import com.zte.routerbar.core.RouterStatusParser
import java.io.File
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

data class StoredAppSettings(
    val profiles: List<RouterProfile>,
    val activeProfileId: String,
    val autoMatchByGateway: Boolean = true,
    val pollingIntervalSec: Int = 3
) {
    val activeProfile: RouterProfile
        get() = profiles.firstOrNull { it.id == activeProfileId } ?: profiles.first()

    companion object {
        val ALLOWED_POLL_INTERVALS = listOf(2, 3, 5, 10)

        fun defaultSettings(): StoredAppSettings {
            val defaultProfile = RouterProfile(
                id = UUID.randomUUID().toString(),
                name = "默认路由器",
                routerUrlString = "http://192.168.8.1",
                hashPreference = AuthHashPreference.AUTO
            )
            return StoredAppSettings(
                profiles = listOf(defaultProfile),
                activeProfileId = defaultProfile.id,
                autoMatchByGateway = true,
                pollingIntervalSec = 3
            )
        }

        fun normalizePollingSec(sec: Int): Int =
            if (sec in ALLOWED_POLL_INTERVALS) sec else 3
    }
}

interface ProfileRepository {
    fun load(): StoredAppSettings
    fun save(settings: StoredAppSettings)
}

class AndroidProfileStore(context: Context) : ProfileRepository {
    private val atomicFile = AtomicFile(File(context.applicationContext.noBackupFilesDir, "profiles-v1.json"))
    private val lock = Any()

    override fun load(): StoredAppSettings = synchronized(lock) {
        if (!atomicFile.baseFile.exists()) {
            val defaults = StoredAppSettings.defaultSettings()
            writeLocked(defaults)
            return defaults
        }
        return runCatching {
            val raw = atomicFile.openRead().use { it.readBytes().toString(Charsets.UTF_8) }
            decodeSettingsJson(raw)
        }.getOrElse {
            val defaults = StoredAppSettings.defaultSettings()
            writeLocked(defaults)
            defaults
        }
    }

    override fun save(settings: StoredAppSettings) = synchronized(lock) {
        writeLocked(settings)
    }

    private fun writeLocked(settings: StoredAppSettings) {
        val bytes = encodeSettingsJson(settings).toByteArray(Charsets.UTF_8)
        val stream = atomicFile.startWrite()
        try {
            stream.write(bytes)
            atomicFile.finishWrite(stream)
        } catch (err: Exception) {
            atomicFile.failWrite(stream)
            throw err
        }
    }

    companion object {
        fun encodeSettingsJson(settings: StoredAppSettings): String {
            val profilesArray = JSONArray()
            for (profile in settings.profiles) {
                profilesArray.put(
                    JSONObject()
                        .put("id", profile.id)
                        .put("name", profile.name)
                        .put("routerUrlString", profile.routerUrlString)
                        .put("hashPreference", profile.hashPreference.wireValue)
                )
            }
            return JSONObject()
                .put("profiles", profilesArray)
                .put("activeProfileId", settings.activeProfileId)
                .put("autoMatchByGateway", settings.autoMatchByGateway)
                .put("pollingIntervalSec", StoredAppSettings.normalizePollingSec(settings.pollingIntervalSec))
                .toString()
        }

        fun decodeSettingsJson(raw: String): StoredAppSettings {
            val obj = JSONObject(raw)
            val arr = obj.optJSONArray("profiles") ?: JSONArray()
            val profiles = ArrayList<RouterProfile>(arr.length())
            for (i in 0 until arr.length()) {
                val item = arr.optJSONObject(i) ?: continue
                val id = RouterStatusParser.cleanField(item, "id").trim().ifEmpty { UUID.randomUUID().toString() }
                val name = RouterStatusParser.cleanField(item, "name").trim().ifEmpty { "路由器配置 ${i + 1}" }
                val url = RouterStatusParser.cleanField(item, "routerUrlString").trim().ifEmpty { "http://192.168.8.1" }
                val hash = AuthHashPreference.fromWireValue(RouterStatusParser.cleanField(item, "hashPreference"))
                profiles.add(RouterProfile(id = id, name = name, routerUrlString = url, hashPreference = hash))
            }
            if (profiles.isEmpty()) {
                return StoredAppSettings.defaultSettings()
            }
            val savedActive = RouterStatusParser.cleanField(obj, "activeProfileId").trim()
            val activeId = if (profiles.any { it.id == savedActive }) savedActive else profiles.first().id
            val autoMatch = if (obj.has("autoMatchByGateway") && !obj.isNull("autoMatchByGateway")) {
                obj.optBoolean("autoMatchByGateway", true)
            } else {
                true
            }
            val pollSec = StoredAppSettings.normalizePollingSec(obj.optInt("pollingIntervalSec", 3))
            return StoredAppSettings(
                profiles = profiles,
                activeProfileId = activeId,
                autoMatchByGateway = autoMatch,
                pollingIntervalSec = pollSec
            )
        }
    }
}

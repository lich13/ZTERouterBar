package com.zte.routerbar.core

import java.net.URI
import java.util.Locale
import java.util.UUID

sealed class WANConnectionState(open val rawStatus: String) {
    data class Connected(override val rawStatus: String) : WANConnectionState(rawStatus)
    data class Connecting(override val rawStatus: String) : WANConnectionState(rawStatus)
    data class Disconnecting(override val rawStatus: String) : WANConnectionState(rawStatus)
    data class Disconnected(override val rawStatus: String) : WANConnectionState(rawStatus)
    data class Unknown(override val rawStatus: String) : WANConnectionState(rawStatus)

    val isConnected: Boolean get() = this is Connected
    val isDisconnected: Boolean get() = this is Disconnected
    val isTransitioning: Boolean get() = this is Connecting || this is Disconnecting

    val localizedLabel: String
        get() = when (this) {
            is Connected -> "外网已连接"
            is Connecting -> "正在连接外网…"
            is Disconnecting -> "正在断开外网…"
            is Disconnected -> "外网已断开"
            is Unknown -> if (rawStatus.isEmpty()) "状态未知" else "状态: $rawStatus"
        }

    companion object {
        fun fromPppStatus(pppStatus: String): WANConnectionState {
            return when (pppStatus.trim().lowercase(Locale.ROOT)) {
                "ppp_connected", "ipv6_connected", "ipv4_ipv6_connected" -> Connected(pppStatus)
                "ppp_connecting" -> Connecting(pppStatus)
                "ppp_disconnecting" -> Disconnecting(pppStatus)
                "ppp_disconnected" -> Disconnected(pppStatus)
                else -> Unknown(pppStatus)
            }
        }
    }
}

data class LTECellInfo(
    val id: Int,
    val isPrimary: Boolean,
    val pci: String,
    val band: String,
    val earfcn: String,
    val bandwidthMHz: String,
    val rssi: String,
    val rsrpList: List<String>,
    val rsrq: String,
    val sinrList: List<String>
)

data class NRCellInfo(
    val id: Int,
    val isPrimary: Boolean,
    val pci: String,
    val band: String,
    val arfcn: String,
    val bandwidthMHz: String,
    val rsrp1: String,
    val rsrp2: String,
    val rsrq: String,
    val sinr: String
)

data class UMTSCellInfo(
    val band: String,
    val rscp: List<String>,
    val ecio: List<String>
)

data class NeighborCellInfo(
    val id: String,
    val frequency: String,
    val pci: String,
    val rsrp: String,
    val rsrq: String,
    val rssi: String,
    val rawLine: String
)

data class TemperatureReading(
    val id: String,
    val label: String,
    val celsius: Double
)

enum class ConnectedDeviceKind(val wireValue: String) {
    WIRELESS("wireless"),
    WIRED("wired")
}

data class ConnectedStation(
    val hostname: String,
    val ipAddress: String,
    val macAddress: String,
    val interfaceType: String,
    val connectTimeSeconds: Int,
    val ssidIndex: String,
    val deviceKind: ConnectedDeviceKind = ConnectedDeviceKind.WIRELESS
) {
    val id: String get() = "${deviceKind.wireValue}-$ipAddress-$macAddress-$ssidIndex"

    val displayConnectionType: String
        get() = when (deviceKind) {
            ConnectedDeviceKind.WIRED -> "有线 / USB"
            ConnectedDeviceKind.WIRELESS -> "无线 Wi-Fi"
        }
}

data class RouterVersionInfo(
    val waInnerVersion: String,
    val crVersion: String
)

data class RouterStatusSnapshot(
    val fetchedAtMs: Long,
    val connectionState: WANConnectionState,
    val wanConnectStatus: String,
    val modemMainState: String,
    val networkType: String,
    val providerName: String,
    val mcc: String,
    val mnc: String,
    val bandSummary: String,
    val is5G: Boolean,
    val is5GSA: Boolean,
    val is5GNSA: Boolean,
    val isLTE: Boolean,
    val isUMTS: Boolean,
    val isLTECarrierAggregationActive: Boolean,
    val lteCells: List<LTECellInfo>,
    val nrCells: List<NRCellInfo>,
    val umtsInfo: UMTSCellInfo?,
    val neighborCells: List<NeighborCellInfo>,
    val temperatures: List<TemperatureReading>,
    val cellID: String,
    val nr5gCellID: String,
    val wanIPv4: String,
    val wanIPv6: String,
    val wanAPN: String,
    val dnsMode: String,
    val preferDNSManual: String,
    val standbyDNSManual: String,
    val currentNetworkMode: String,
    val opmsWanMode: String,
    val sessionDurationSeconds: Int,
    val sessionRxBytes: Long,
    val sessionTxBytes: Long,
    val monthlyRxBytes: Long,
    val monthlyTxBytes: Long,
    val batteryPercent: Int?,
    val batteryCharging: String,
    val signalBars: Int?,
    val wifiAccessStationCount: Int?,
    val wifi24GCount: Int?,
    val wifi5GCount: Int?,
    val wifiStations: List<ConnectedStation>,
    val lanStations: List<ConnectedStation>,
    val versionInfo: RouterVersionInfo
) {
    val wirelessDeviceCount: Int
        get() = maxOf(wifiAccessStationCount ?: 0, wifiStations.size)

    val wiredDeviceCount: Int
        get() = lanStations.size

    val totalConnectedDevices: Int
        get() = wirelessDeviceCount + wiredDeviceCount

    val isUnauthenticatedEmptySnapshot: Boolean
        get() {
            val state = connectionState
            if (state is WANConnectionState.Unknown && state.rawStatus.isEmpty()) {
                return modemMainState.isEmpty() &&
                    wanConnectStatus.isEmpty() &&
                    networkType.isEmpty() &&
                    wanIPv4.isEmpty()
            }
            return false
        }

    val displayProvider: String
        get() = when (providerName.uppercase(Locale.ROOT)) {
            "CMCC" -> "中国移动 (CMCC)"
            "CUCC", "UNICOM", "CHN-UNICOM" -> "中国联通 ($providerName)"
            "CTCC", "TELECOM", "CHN-CT" -> "中国电信 ($providerName)"
            "CBN" -> "中国广电 (CBN)"
            else -> providerName
        }
}

data class RouterProfile(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val routerUrlString: String,
    val hashPreference: AuthHashPreference = AuthHashPreference.AUTO
) {
    val normalizedHost: String?
        get() = runCatching {
            RouterEndpointConfig.parse(routerUrlString, hashPreference).host.lowercase(Locale.ROOT)
        }.getOrNull()
}

data class RouterEndpointConfig(
    val baseUrl: String,
    val host: String,
    val hashPreference: AuthHashPreference = AuthHashPreference.AUTO
) {
    companion object {
        fun parse(
            baseUrlString: String,
            hashPreference: AuthHashPreference = AuthHashPreference.AUTO
        ): RouterEndpointConfig {
            val trimmed = baseUrlString.trim()
            if (trimmed.isEmpty()) {
                throw ZteRouterException.InvalidBaseUrl(baseUrlString)
            }
            val normalized = if (trimmed.contains("://")) trimmed else "http://$trimmed"
            val uri = try {
                URI(normalized)
            } catch (_: Exception) {
                throw ZteRouterException.InvalidBaseUrl(baseUrlString)
            }
            val scheme = uri.scheme?.lowercase(Locale.ROOT).orEmpty()
            val host = uri.host.orEmpty()
            if ((scheme != "http" && scheme != "https") || host.isEmpty()) {
                throw ZteRouterException.InvalidBaseUrl(baseUrlString)
            }
            val clean = URI(scheme, null, host, uri.port, null, null, null).toString()
            return RouterEndpointConfig(
                baseUrl = clean,
                host = host.removePrefix("[").removeSuffix("]"),
                hashPreference = hashPreference
            )
        }
    }
}

object RouterProfileMatcher {
    /**
     * Zero-permission profile matching via the active Wi-Fi IPv4 gateway.
     * If the currently active profile already targets `gatewayIp`, keeps it selected
     * so multiple profiles sharing `192.168.8.1` are not overridden involuntarily.
     */
    fun matchByGateway(
        gatewayIp: String?,
        profiles: List<RouterProfile>,
        activeProfileId: String? = null
    ): RouterProfile? {
        val target = gatewayIp?.trim()?.lowercase(Locale.ROOT).orEmpty()
        if (target.isEmpty()) return null
        if (activeProfileId != null) {
            val active = profiles.firstOrNull { it.id == activeProfileId }
            if (active != null && active.normalizedHost == target) {
                return active
            }
        }
        return profiles.firstOrNull { it.normalizedHost == target }
    }
}

data class WANIPSnapshot(
    val ipv4: String = "",
    val ipv6: String = ""
) {
    val normalizedIpv4: String = ipv4.trim()
    val normalizedIpv6: String = ipv6.trim()

    val isEmpty: Boolean
        get() = normalizedIpv4.isEmpty() && normalizedIpv6.isEmpty()

    fun hasChanged(previous: WANIPSnapshot): Boolean {
        if (normalizedIpv4.isNotEmpty() && previous.normalizedIpv4.isNotEmpty() && normalizedIpv4 != previous.normalizedIpv4) {
            return true
        }
        if (normalizedIpv6.isNotEmpty() && previous.normalizedIpv6.isNotEmpty() && normalizedIpv6 != previous.normalizedIpv6) {
            return true
        }
        if (normalizedIpv4 != previous.normalizedIpv4 && (normalizedIpv4.isNotEmpty() || previous.normalizedIpv4.isNotEmpty())) {
            return true
        }
        return false
    }

    companion object {
        fun fromSnapshot(snapshot: RouterStatusSnapshot?): WANIPSnapshot = WANIPSnapshot(
            ipv4 = snapshot?.wanIPv4.orEmpty(),
            ipv6 = snapshot?.wanIPv6.orEmpty()
        )
    }
}

object WANIPChangeFormatter {
    fun formatBannerSummary(
        state: WANConnectionState,
        before: WANIPSnapshot,
        after: WANIPSnapshot
    ): Pair<String, String> {
        val changed = after.hasChanged(before)
        val title = when {
            !state.isConnected -> "重连指令已发送（${state.localizedLabel}）"
            changed -> "外网重连完成 · IP 已变更"
            else -> "外网重连完成 · IP 未变化"
        }
        val parts = mutableListOf<String>()
        formatDeltaLine("IPv4", before.normalizedIpv4, after.normalizedIpv4)?.let(parts::add)
        if (before.normalizedIpv6.isNotEmpty() || after.normalizedIpv6.isNotEmpty()) {
            formatDeltaLine("IPv6", before.normalizedIpv6, after.normalizedIpv6)?.let(parts::add)
        }
        val detail = if (parts.isEmpty()) "暂未读取到重连前后 WAN IP" else parts.joinToString("\n")
        return title to detail
    }

    private fun formatDeltaLine(label: String, before: String, after: String): String? {
        if (before.isEmpty() && after.isEmpty()) return null
        val b = before.ifEmpty { "未知" }
        val a = after.ifEmpty { "未获取" }
        return if (before.isNotEmpty() && after.isNotEmpty() && before == after) {
            "$label: $a（未变化）"
        } else {
            "$label: $b → $a"
        }
    }
}

data class ProbeEndpoint(
    val id: String,
    val name: String,
    val urlString: String,
    val timeoutSec: Int = DEFAULT_TIMEOUT_SEC
) {
    val isValidHttpUrl: Boolean
        get() {
            val trimmed = urlString.trim()
            if (trimmed.isEmpty()) return false
            val uri = runCatching { URI(trimmed) }.getOrNull() ?: return false
            val scheme = uri.scheme?.lowercase(Locale.ROOT).orEmpty()
            val host = uri.host.orEmpty()
            return (scheme == "http" || scheme == "https") && host.isNotEmpty()
        }

    val displayTitle: String
        get() {
            val clean = name.trim()
            if (clean.isNotEmpty()) return clean
            val host = runCatching { URI(urlString.trim()).host }.getOrNull().orEmpty()
            return when {
                host.isNotEmpty() -> host
                urlString.isNotEmpty() -> urlString
                else -> "未命名节点"
            }
        }

    companion object {
        const val DEFAULT_TIMEOUT_SEC = 10

        fun defaultPresets(): List<ProbeEndpoint> = listOf(
            ProbeEndpoint(
                id = "661313-204",
                name = "661313 204",
                urlString = "https://661313.xyz/test/generate_204",
                timeoutSec = DEFAULT_TIMEOUT_SEC
            ),
            ProbeEndpoint(
                id = "youtube-204",
                name = "YouTube 204",
                urlString = "https://www.youtube.com/generate_204",
                timeoutSec = DEFAULT_TIMEOUT_SEC
            ),
            ProbeEndpoint(
                id = "cloudflare-doh",
                name = "Cloudflare DoH",
                urlString = "https://cloudflare-dns.com/cdn-cgi/trace",
                timeoutSec = DEFAULT_TIMEOUT_SEC
            ),
            ProbeEndpoint(
                id = "telegram-api",
                name = "Telegram API",
                urlString = "https://api.telegram.org/",
                timeoutSec = DEFAULT_TIMEOUT_SEC
            )
        )
    }
}

data class EndpointProbeOutcome(
    val id: String,
    val name: String,
    val urlString: String,
    val reachable: Boolean,
    val statusCode: Int? = null,
    val elapsedMs: Int = 0,
    val errorMessage: String? = null,
    val checkedAtMs: Long = 0L
)

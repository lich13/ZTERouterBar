package com.zte.routerbar.core

import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

object RouterStatusParser {
    val primarySignalCmds: List<String> = listOf(
        "wa_inner_version", "cr_version",
        "ppp_status", "wan_connect_status", "modem_main_state",
        "network_type", "network_provider", "network_provider_fullname", "rmcc", "rmnc", "mdm_mcc", "mdm_mnc",
        "wan_active_channel", "wan_lte_ca", "wan_apn", "wan_ipaddr", "ipv6_wan_ipaddr",
        "cell_id", "dns_mode", "prefer_dns_manual", "standby_dns_manual",
        "bandwidth",
        "rscp_1", "ecio_1", "rscp_2", "ecio_2", "rscp_3", "ecio_3", "rscp_4", "ecio_4",
        "ngbr_cell_info",
        "lte_multi_ca_scell_info", "lte_multi_ca_scell_sig_info",
        "lte_band", "lte_rsrp", "lte_rsrq", "lte_rssi", "lte_snr",
        "lte_ca_pcell_band", "lte_ca_pcell_freq", "lte_ca_pcell_bandwidth",
        "lte_rsrp_1", "lte_rsrp_2", "lte_rsrp_3", "lte_rsrp_4",
        "lte_snr_1", "lte_snr_2", "lte_snr_3", "lte_snr_4",
        "lte_pci",
        "5g_rx0_rsrp", "5g_rx1_rsrp", "Z5g_rsrp", "Z5g_rsrq", "Z5g_SINR",
        "nr5g_cell_id", "nr5g_pci", "nr5g_action_channel", "nr5g_action_band", "nr5g_action_nsa_band",
        "nr_ca_pcell_band", "nr_ca_pcell_freq", "nr_multi_ca_scell_info",
        "nr5g_sa_band_lock", "nr5g_nsa_band_lock",
        "pm_sensor_ambient", "pm_sensor_mdm", "pm_sensor_5g", "pm_modem_5g", "pm_sensor_pa1", "wifi_chip_temp"
    )

    val secondaryDashboardCmds: List<String> = listOf(
        "net_select", "opms_wan_mode",
        "realtime_time",
        "realtime_tx_bytes", "realtime_rx_bytes", "monthly_tx_bytes", "monthly_rx_bytes",
        "battery_value", "battery_charging", "signalbar",
        "wifi_access_sta_num",
        "wifi_chip1_ssid1_access_sta_num", "wifi_chip1_ssid2_access_sta_num",
        "wifi_chip2_ssid1_access_sta_num", "wifi_chip2_ssid2_access_sta_num"
    )

    val statusCmds: List<String> = primarySignalCmds + secondaryDashboardCmds + listOf("loginfo")

    private val UMTS_TYPES = setOf(
        "HSPA", "HSDPA", "HSUPA", "HSPA+", "DC-HSPA+",
        "UMTS", "CDMA", "CDMA_EVDO", "EVDO_EHRPD", "TDSCDMA"
    )
    private val LTE_TYPES = setOf("LTE", "ENDC", "EN-DC", "LTE-NSA")
    private val NSA_TYPES = setOf("ENDC", "EN-DC", "LTE-NSA")

    fun parseJsonTexts(
        jsonTexts: List<String>,
        fetchedAtMs: Long = System.currentTimeMillis()
    ): RouterStatusSnapshot {
        val objects = jsonTexts.mapNotNull { text ->
            runCatching { JSONObject(text) }.getOrNull()
        }
        return parse(objects, fetchedAtMs)
    }

    fun parse(
        jsonObjects: List<JSONObject>,
        fetchedAtMs: Long = System.currentTimeMillis()
    ): RouterStatusSnapshot {
        val rawStrings = LinkedHashMap<String, String>()
        var wifiStations: List<ConnectedStation> = emptyList()
        var lanStations: List<ConnectedStation> = emptyList()

        for (obj in jsonObjects) {
            val keys = obj.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                if (!obj.has(key) || obj.isNull(key)) {
                    rawStrings[key] = ""
                    continue
                }
                val value = obj.opt(key)
                if (key == "station_list" && value is JSONArray) {
                    wifiStations = decodeStations(value, ConnectedDeviceKind.WIRELESS)
                } else if (key == "lan_station_list" && value is JSONArray) {
                    lanStations = decodeStations(value, ConnectedDeviceKind.WIRED)
                }
                rawStrings[key] = stringifyJsonValue(value)
            }
        }

        fun field(key: String): String = rawStrings[key]?.trim().orEmpty()

        val waInnerVersion = field("wa_inner_version")
        val networkType = field("network_type")
        val wanLTECA = field("wan_lte_ca")

        val isUMTS = networkType in UMTS_TYPES
        val isLTE = networkType in LTE_TYPES
        val is5GSA = networkType == "SA"
        val is5GNSA = networkType in NSA_TYPES
        val is5GNSAActive = is5GNSA && networkType != "LTE-NSA"
        val is5G = is5GSA || is5GNSA

        val nr5gCellID = field("nr5g_cell_id")
        val useDecimalPCI = isDecimalPCIFirmware(waInnerVersion, nr5gCellID)

        val lteCells = parseLTECells(::field, isLTE, useDecimalPCI)
        val nrCells = parseNRCells(::field, is5G, is5GNSA, is5GNSAActive, useDecimalPCI)

        val lteBandsSummary = formatBandSummary(lteCells.map { it.band to it.bandwidthMHz })
        val nrBandsSummary = formatBandSummary(nrCells.map { it.band to it.bandwidthMHz })
        val combinedBands = listOf(lteBandsSummary, nrBandsSummary)
            .filter { it.isNotEmpty() }
            .joinToString(" + ")

        val umtsInfo = parseUMTSInfo(::field, isUMTS)
        val neighborCells = parseNeighborCells(field("ngbr_cell_info"), isLTE)
        val temperatures = parseTemperatures(::field)

        val providerFull = field("network_provider_fullname")
        val providerShort = field("network_provider")
        val providerName = providerFull.ifEmpty { providerShort }

        val mcc = field("mdm_mcc").ifEmpty { field("rmcc") }
        val mnc = field("mdm_mnc").ifEmpty { field("rmnc") }

        val c1s1 = field("wifi_chip1_ssid1_access_sta_num").toIntOrNull()
        val c1s2 = field("wifi_chip1_ssid2_access_sta_num").toIntOrNull()
        val c2s1 = field("wifi_chip2_ssid1_access_sta_num").toIntOrNull()
        val c2s2 = field("wifi_chip2_ssid2_access_sta_num") .toIntOrNull()

        val wifi24GCount: Int? = if (c1s1 != null || c1s2 != null) (c1s1 ?: 0) + (c1s2 ?: 0) else null
        val wifi5GCount: Int? = if (c2s1 != null || c2s2 != null) (c2s1 ?: 0) + (c2s2 ?: 0) else null
        val staCountFromChips: Int? = if (wifi24GCount != null || wifi5GCount != null) {
            (wifi24GCount ?: 0) + (wifi5GCount ?: 0)
        } else {
            null
        }
        val wifiAccessStationCount = field("wifi_access_sta_num").toIntOrNull() ?: staCountFromChips

        return RouterStatusSnapshot(
            fetchedAtMs = fetchedAtMs,
            connectionState = WANConnectionState.fromPppStatus(field("ppp_status")),
            wanConnectStatus = field("wan_connect_status"),
            modemMainState = field("modem_main_state"),
            networkType = networkType,
            providerName = providerName,
            mcc = mcc,
            mnc = mnc,
            bandSummary = combinedBands,
            is5G = is5G,
            is5GSA = is5GSA,
            is5GNSA = is5GNSA,
            isLTE = isLTE,
            isUMTS = isUMTS,
            isLTECarrierAggregationActive = wanLTECA == "ca_activated",
            lteCells = lteCells,
            nrCells = nrCells,
            umtsInfo = umtsInfo,
            neighborCells = neighborCells,
            temperatures = temperatures,
            cellID = field("cell_id"),
            nr5gCellID = nr5gCellID,
            wanIPv4 = field("wan_ipaddr"),
            wanIPv6 = field("ipv6_wan_ipaddr"),
            wanAPN = field("wan_apn"),
            dnsMode = field("dns_mode"),
            preferDNSManual = field("prefer_dns_manual"),
            standbyDNSManual = field("standby_dns_manual"),
            currentNetworkMode = field("net_select"),
            opmsWanMode = field("opms_wan_mode"),
            sessionDurationSeconds = field("realtime_time").toIntOrNull() ?: 0,
            sessionRxBytes = parseByteCounter(field("realtime_rx_bytes")),
            sessionTxBytes = parseByteCounter(field("realtime_tx_bytes")),
            monthlyRxBytes = parseByteCounter(field("monthly_rx_bytes")),
            monthlyTxBytes = parseByteCounter(field("monthly_tx_bytes")),
            batteryPercent = field("battery_value").toIntOrNull(),
            batteryCharging = field("battery_charging"),
            signalBars = field("signalbar").toIntOrNull(),
            wifiAccessStationCount = wifiAccessStationCount,
            wifi24GCount = wifi24GCount,
            wifi5GCount = wifi5GCount,
            wifiStations = wifiStations,
            lanStations = lanStations,
            versionInfo = RouterVersionInfo(
                waInnerVersion = waInnerVersion,
                crVersion = field("cr_version")
            )
        )
    }

    internal fun cleanField(obj: JSONObject, key: String): String {
        if (!obj.has(key) || obj.isNull(key)) return ""
        return stringifyJsonValue(obj.opt(key))
    }

    private fun stringifyJsonValue(value: Any?): String = when (value) {
        null, JSONObject.NULL -> ""
        is String -> value
        is Boolean -> if (value) "1" else "0"
        is Number -> value.toString()
        else -> value.toString()
    }

    private fun parseByteCounter(raw: String): Long {
        if (raw.isEmpty()) return 0L
        return raw.toLongOrNull()?.coerceAtLeast(0L)
            ?: raw.toULongOrNull()?.let { u ->
                if (u > Long.MAX_VALUE.toULong()) Long.MAX_VALUE else u.toLong()
            }
            ?: 0L
    }

    private fun decodeStations(array: JSONArray, kind: ConnectedDeviceKind): List<ConnectedStation> {
        val result = ArrayList<ConnectedStation>(array.length())
        for (i in 0 until array.length()) {
            val item = array.optJSONObject(i) ?: continue
            val connectTime = if (!item.has("connect_time") || item.isNull("connect_time")) {
                0
            } else {
                when (val ct = item.opt("connect_time")) {
                    is Number -> ct.toInt()
                    is String -> ct.trim().toIntOrNull() ?: 0
                    else -> 0
                }
            }
            result.add(
                ConnectedStation(
                    hostname = cleanField(item, "hostname"),
                    ipAddress = cleanField(item, "ip_addr"),
                    macAddress = cleanField(item, "mac_addr"),
                    interfaceType = cleanField(item, "interfacetype"),
                    connectTimeSeconds = connectTime,
                    ssidIndex = cleanField(item, "ssid_index"),
                    deviceKind = kind
                )
            )
        }
        return result
    }

    private fun isDecimalPCIFirmware(waInnerVersion: String, nr5gCellID: String): Boolean {
        val upper = waInnerVersion.uppercase(Locale.ROOT)
        if (upper.contains("MU5120") || upper.contains("FLYMODEM")) return true
        if (nr5gCellID.length >= 8 && nr5gCellID.all { it.isDigit() }) return true
        return false
    }

    private fun parsePCI(raw: String, useDecimal: Boolean): String {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return ""
        val hasHexLetters = trimmed.any { it in 'a'..'f' || it in 'A'..'F' }
        if (hasHexLetters || !useDecimal) {
            trimmed.toIntOrNull(16)?.let { return it.toString() }
        }
        return trimmed
    }

    private fun cleanBandwidth(raw: String): String {
        return raw.replace(Regex("mhz", RegexOption.IGNORE_CASE), "")
            .replace(".0", "")
            .trim()
    }

    private fun normalizeNRBand(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.isEmpty() || trimmed == "-1") return "n??"
        if (trimmed.startsWith("n", ignoreCase = true)) {
            val body = trimmed.drop(1)
            return if (body.isEmpty()) "n??" else "n$body"
        }
        return "n$trimmed"
    }

    private fun formatBandSummary(pairs: List<Pair<String, String>>): String {
        return pairs.mapNotNull { (band, bw) ->
            if (band.isEmpty()) null else if (bw.isEmpty()) band else "$band(${bw}MHz)"
        }.joinToString(" + ")
    }

    private fun parseLTECells(
        field: (String) -> String,
        isLTE: Boolean,
        useDecimalPCI: Boolean
    ): List<LTECellInfo> {
        if (!isLTE) return emptyList()
        val cells = mutableListOf<LTECellInfo>()

        val mainBandRaw = field("lte_ca_pcell_band").ifEmpty { field("lte_band") }
        val mainBand = when {
            mainBandRaw.isEmpty() -> "B??"
            mainBandRaw.startsWith("B", ignoreCase = true) -> mainBandRaw
            else -> "B$mainBandRaw"
        }
        val earfcn = field("lte_ca_pcell_freq").ifEmpty { field("wan_active_channel") }
        val bwRaw = field("lte_ca_pcell_bandwidth").ifEmpty { field("bandwidth") }

        val rsrps = listOf("lte_rsrp_1", "lte_rsrp_2", "lte_rsrp_3", "lte_rsrp_4")
            .map(field)
            .filter { it.isNotEmpty() }
        val fallbackRSRP = if (rsrps.isNotEmpty()) {
            rsrps
        } else {
            field("lte_rsrp").takeIf { it.isNotEmpty() }?.let(::listOf) ?: emptyList()
        }

        val sinrs = listOf("lte_snr_1", "lte_snr_2", "lte_snr_3", "lte_snr_4")
            .map(field)
            .filter { it.isNotEmpty() }
        val fallbackSINR = if (sinrs.isNotEmpty()) {
            sinrs
        } else {
            field("lte_snr").takeIf { it.isNotEmpty() }?.let(::listOf) ?: emptyList()
        }

        cells.add(
            LTECellInfo(
                id = 0,
                isPrimary = true,
                pci = parsePCI(field("lte_pci"), useDecimalPCI),
                band = mainBand,
                earfcn = earfcn,
                bandwidthMHz = cleanBandwidth(bwRaw),
                rssi = field("lte_rssi"),
                rsrpList = fallbackRSRP,
                rsrq = field("lte_rsrq"),
                sinrList = fallbackSINR
            )
        )

        val scellInfos = field("lte_multi_ca_scell_info").split(";").filter { it.isNotEmpty() }
        val scellSigInfos = field("lte_multi_ca_scell_sig_info").split(";").filter { it.isNotEmpty() }

        for ((index, infoLine) in scellInfos.withIndex()) {
            val cols = infoLine.split(",").filter { it.isNotEmpty() }
            if (cols.size < 6) continue
            val sigCols = if (index < scellSigInfos.size) {
                scellSigInfos[index].split(",").filter { it.isNotEmpty() }
            } else {
                emptyList()
            }
            if (sigCols.isNotEmpty() && sigCols.size < 3) continue

            val rsrp = sigCols.firstOrNull()?.let { if (it == "-44.0") "N/A" else it }.orEmpty()
            val rsrq = sigCols.getOrNull(1).orEmpty()
            val sinr = sigCols.getOrNull(2).orEmpty()

            cells.add(
                LTECellInfo(
                    id = index + 1,
                    isPrimary = false,
                    pci = parsePCI(cols[1], useDecimalPCI),
                    band = if (cols[3].startsWith("B", ignoreCase = true)) cols[3] else "B${cols[3]}",
                    earfcn = cols[4],
                    bandwidthMHz = cleanBandwidth(cols[5]),
                    rssi = "",
                    rsrpList = if (rsrp.isEmpty()) emptyList() else listOf(rsrp),
                    rsrq = rsrq,
                    sinrList = if (sinr.isEmpty()) emptyList() else listOf(sinr)
                )
            )
        }
        return cells
    }

    private fun parseNRCells(
        field: (String) -> String,
        is5G: Boolean,
        is5GNSA: Boolean,
        is5GNSAActive: Boolean,
        useDecimalPCI: Boolean
    ): List<NRCellInfo> {
        if (!is5G) return emptyList()
        if (is5GNSA && !is5GNSAActive) return emptyList()

        val nrActionChannel = field("nr5g_action_channel")
        val nrCaPCellFreq = field("nr_ca_pcell_freq")
        val isCA = nrCaPCellFreq.isEmpty() || nrActionChannel == nrCaPCellFreq

        val rx0 = field("5g_rx0_rsrp").ifEmpty { field("Z5g_rsrp") }
        val rx1 = field("5g_rx1_rsrp")
        val rsrq = field("Z5g_rsrq")
        val rawSinr = field("Z5g_SINR")
        val sinr = if (rawSinr == "-20.0" || rawSinr == "-3276.8") "N/A" else rawSinr

        val cells = mutableListOf<NRCellInfo>()
        if (!isCA) {
            val bandRaw = if (is5GNSA) field("nr5g_action_nsa_band") else field("nr5g_action_band")
            cells.add(
                NRCellInfo(
                    id = 0,
                    isPrimary = true,
                    pci = parsePCI(field("nr5g_pci"), useDecimalPCI),
                    band = normalizeNRBand(bandRaw),
                    arfcn = nrActionChannel,
                    bandwidthMHz = if (is5GNSA) "" else cleanBandwidth(field("bandwidth")),
                    rsrp1 = rx0,
                    rsrp2 = rx1,
                    rsrq = rsrq,
                    sinr = sinr
                )
            )
            return cells
        }

        val fallbackBand = if (is5GNSA) {
            field("nr5g_action_nsa_band").ifEmpty { field("nr5g_action_band") }
        } else {
            field("nr5g_action_band")
        }
        val pccBandRaw = field("nr_ca_pcell_band").ifEmpty { fallbackBand }
        val pccFreq = nrCaPCellFreq.ifEmpty { nrActionChannel.ifEmpty { "??" } }

        cells.add(
            NRCellInfo(
                id = 0,
                isPrimary = true,
                pci = parsePCI(field("nr5g_pci"), useDecimalPCI),
                band = normalizeNRBand(pccBandRaw),
                arfcn = pccFreq,
                bandwidthMHz = cleanBandwidth(field("bandwidth")),
                rsrp1 = rx0,
                rsrp2 = rx1,
                rsrq = rsrq,
                sinr = sinr
            )
        )

        val allowedLockRaw = if (is5GNSA) field("nr5g_nsa_band_lock") else field("nr5g_sa_band_lock")
        val allowedBands = allowedLockRaw.split(",")
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .toSet()

        val scellLines = field("nr_multi_ca_scell_info").split(";").filter { it.isNotEmpty() }
        for ((idx, line) in scellLines.withIndex()) {
            val cols = line.split(",").filter { it.isNotEmpty() }
            if (cols.size < 10) continue
            val bandNum = cols[3].replace(Regex("n", RegexOption.IGNORE_CASE), "")
            if (allowedBands.isNotEmpty() && bandNum !in allowedBands) continue
            cells.add(
                NRCellInfo(
                    id = idx + 1,
                    isPrimary = false,
                    pci = cols[1],
                    band = normalizeNRBand(cols[3]),
                    arfcn = cols[4],
                    bandwidthMHz = cleanBandwidth(cols[5]),
                    rsrp1 = cols[7],
                    rsrp2 = "",
                    rsrq = cols[8],
                    sinr = if (cols[9] == "0.0") "N/A" else cols[9]
                )
            )
        }
        return cells
    }

    private fun parseUMTSInfo(field: (String) -> String, isUMTS: Boolean): UMTSCellInfo? {
        if (!isUMTS) return null
        val rscp = listOf("rscp_1", "rscp_2", "rscp_3", "rscp_4").map(field).filter { it.isNotEmpty() }
        val ecio = listOf("ecio_1", "ecio_2", "ecio_3", "ecio_4").map(field).filter { it.isNotEmpty() }
        return UMTSCellInfo(band = field("lte_ca_pcell_band"), rscp = rscp, ecio = ecio)
    }

    private fun parseNeighborCells(raw: String, isLTE: Boolean): List<NeighborCellInfo> {
        if (raw.isEmpty()) return emptyList()
        return raw.split(";").mapIndexedNotNull { index, segment ->
            val line = segment.trim()
            if (line.isEmpty()) return@mapIndexedNotNull null
            val cols = line.split(",").filter { it.isNotEmpty() }
            if (isLTE && cols.size >= 4) {
                NeighborCellInfo(
                    id = "$index-${cols[1]}",
                    frequency = cols[0],
                    pci = cols[1],
                    rsrp = cols[3],
                    rsrq = cols[2],
                    rssi = cols.getOrNull(4).orEmpty(),
                    rawLine = line
                )
            } else {
                NeighborCellInfo(
                    id = "$index-$line",
                    frequency = "",
                    pci = "",
                    rsrp = "",
                    rsrq = "",
                    rssi = "",
                    rawLine = line
                )
            }
        }
    }

    private fun parseTemperatures(field: (String) -> String): List<TemperatureReading> {
        val candidates = listOf(
            Triple("ambient", "环境 (A)", field("pm_sensor_ambient")),
            Triple("mdm", "基带 (MDM)", field("pm_sensor_mdm")),
            Triple("5g", "5G 模组", field("pm_sensor_5g").ifEmpty { field("pm_modem_5g") }),
            Triple("pa1", "功放 (PA1)", field("pm_sensor_pa1")),
            Triple("wifi", "Wi-Fi 芯片", field("wifi_chip_temp"))
        )
        return candidates.mapNotNull { (id, label, raw) ->
            val value = raw.toDoubleOrNull() ?: return@mapNotNull null
            if (value <= -40.0) return@mapNotNull null
            TemperatureReading(id = id, label = label, celsius = value)
        }
    }
}

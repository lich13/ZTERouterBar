import Foundation

public enum RouterStatusParser {
    /// Core signal, connection, and station count fields queried with `multi_data=1`.
    public static let primarySignalCmds: [String] = [
        "wa_inner_version", "cr_version", "hardware_version", "web_version",
        "ppp_status", "wan_connect_status", "modem_main_state",
        "network_type", "network_provider", "network_provider_fullname", "rmcc", "rmnc", "mdm_mcc", "mdm_mnc",
        "wan_active_band", "wan_active_channel", "wan_lte_ca", "wan_apn", "wan_ipaddr", "ipv6_wan_ipaddr",
        "cell_id", "dns_mode", "prefer_dns_manual", "standby_dns_manual", "ip_passthrough_enabled",
        "bandwidth", "tx_power",
        "rscp_1", "ecio_1", "rscp_2", "ecio_2", "rscp_3", "ecio_3", "rscp_4", "ecio_4",
        "ngbr_cell_info",
        "lte_multi_ca_scell_info", "lte_multi_ca_scell_sig_info",
        "lte_band", "lte_rsrp", "lte_rsrq", "lte_rssi", "lte_snr",
        "lte_ca_pcell_band", "lte_ca_pcell_freq", "lte_ca_pcell_bandwidth",
        "lte_ca_scell_band", "lte_ca_scell_bandwidth",
        "lte_rsrp_1", "lte_rsrp_2", "lte_rsrp_3", "lte_rsrp_4",
        "lte_snr_1", "lte_snr_2", "lte_snr_3", "lte_snr_4",
        "lte_pci",
        "5g_rx0_rsrp", "5g_rx1_rsrp", "Z5g_rsrp", "Z5g_rsrq", "Z5g_SINR",
        "nr5g_cell_id", "nr5g_pci", "nr5g_action_channel", "nr5g_action_band", "nr5g_action_nsa_band",
        "nr_ca_pcell_band", "nr_ca_pcell_freq", "nr_multi_ca_scell_info",
        "nr5g_sa_band_lock", "nr5g_nsa_band_lock",
        "pm_sensor_ambient", "pm_sensor_mdm", "pm_sensor_5g", "pm_modem_5g", "pm_sensor_pa1", "wifi_chip_temp"
    ]

    /// Dashboard throughput, traffic, battery, and `wifi_access_sta_num` queried with `multi_data=1`.
    /// Note: `station_list` and `lan_station_list` must be fetched separately WITHOUT `multi_data=1`.
    public static let secondaryDashboardCmds: [String] = [
        "net_select", "opms_wan_mode",
        "realtime_tx_thrpt", "realtime_rx_thrpt", "realtime_time",
        "realtime_tx_bytes", "realtime_rx_bytes", "monthly_tx_bytes", "monthly_rx_bytes",
        "battery_value", "battery_charging", "signalbar",
        "wifi_access_sta_num",
        "wifi_chip1_ssid1_access_sta_num", "wifi_chip1_ssid2_access_sta_num",
        "wifi_chip2_ssid1_access_sta_num", "wifi_chip2_ssid2_access_sta_num"
    ]

    public static func parse(
        jsonDataList: [Data],
        fetchedAt: Date = Date()
    ) throws -> RouterStatusSnapshot {
        var rawStrings: [String: String] = [:]
        var wifiStations: [ConnectedStation] = []
        var lanStations: [ConnectedStation] = []

        for data in jsonDataList {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            for (key, value) in object {
                if key == "station_list", let stations = decodeStations(from: value, kind: .wireless) {
                    wifiStations = stations
                } else if key == "lan_station_list", let stations = decodeStations(from: value, kind: .wired) {
                    lanStations = stations
                }
                rawStrings[key] = stringify(value)
            }
        }

        func field(_ key: String) -> String {
            rawStrings[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        let waInnerVersion = field("wa_inner_version")
        let networkType = field("network_type")
        let wanLTECA = field("wan_lte_ca")

        let isUMTS = [
            "HSPA", "HSDPA", "HSUPA", "HSPA+", "DC-HSPA+",
            "UMTS", "CDMA", "CDMA_EVDO", "EVDO_EHRPD", "TDSCDMA"
        ].contains(networkType)

        let isLTE = ["LTE", "ENDC", "EN-DC", "LTE-NSA"].contains(networkType)
        let is5GSA = networkType == "SA"
        let is5GNSA = ["ENDC", "EN-DC", "LTE-NSA"].contains(networkType)
        let is5GNSAActive = is5GNSA && networkType != "LTE-NSA"
        let is5G = is5GSA || is5GNSA

        let nr5gCellID = field("nr5g_cell_id")
        let useDecimalPCI = isDecimalPCIFirmware(waInnerVersion: waInnerVersion, nr5gCellID: nr5gCellID)

        let lteCells = parseLTECells(field: field, isLTE: isLTE, useDecimalPCI: useDecimalPCI)
        let nrCells = parseNRCells(
            field: field,
            is5G: is5G,
            is5GNSA: is5GNSA,
            is5GNSAActive: is5GNSAActive,
            useDecimalPCI: useDecimalPCI
        )

        let lteBandsSummary = formatBandSummary(lteCells.map { ($0.band, $0.bandwidthMHz) })
        let nrBandsSummary = formatBandSummary(nrCells.map { ($0.band, $0.bandwidthMHz) })
        let combinedBands = [lteBandsSummary, nrBandsSummary]
            .filter { !$0.isEmpty }
            .joined(separator: " + ")

        let umtsInfo = parseUMTSInfo(field: field, isUMTS: isUMTS)
        let neighborCells = parseNeighborCells(raw: field("ngbr_cell_info"), isLTE: isLTE)
        let temperatures = parseTemperatures(field: field)

        let txPowerRaw = field("tx_power")
        let txPowerText: String
        if !txPowerRaw.isEmpty, isLTE, !is5GNSA, let dbm = Double(txPowerRaw) {
            let mw = pow(10.0, dbm / 10.0)
            txPowerText = String(format: "%.1f dBm (%.3f mW)", dbm, mw)
        } else {
            txPowerText = ""
        }

        let providerFull = field("network_provider_fullname")
        let providerShort = field("network_provider")
        let providerName = !providerFull.isEmpty ? providerFull : providerShort

        let mcc = !field("mdm_mcc").isEmpty ? field("mdm_mcc") : field("rmcc")
        let mnc = !field("mdm_mnc").isEmpty ? field("mdm_mnc") : field("rmnc")

        let c1s1 = Int(field("wifi_chip1_ssid1_access_sta_num"))
        let c1s2 = Int(field("wifi_chip1_ssid2_access_sta_num"))
        let c2s1 = Int(field("wifi_chip2_ssid1_access_sta_num"))
        let c2s2 = Int(field("wifi_chip2_ssid2_access_sta_num"))

        let wifi24GCount: Int? = (c1s1 != nil || c1s2 != nil) ? (c1s1 ?? 0) + (c1s2 ?? 0) : nil
        let wifi5GCount: Int? = (c2s1 != nil || c2s2 != nil) ? (c2s1 ?? 0) + (c2s2 ?? 0) : nil

        let staCountFromChips: Int? = {
            if wifi24GCount != nil || wifi5GCount != nil {
                return (wifi24GCount ?? 0) + (wifi5GCount ?? 0)
            }
            return nil
        }()
        let wifiAccessStationCount = Int(field("wifi_access_sta_num")) ?? staCountFromChips

        return RouterStatusSnapshot(
            fetchedAt: fetchedAt,
            rawFields: rawStrings,
            connectionState: WANConnectionState(pppStatus: field("ppp_status")),
            wanConnectStatus: field("wan_connect_status"),
            modemMainState: field("modem_main_state"),
            networkType: networkType,
            providerName: providerName,
            mcc: mcc,
            mnc: mnc,
            bandSummary: combinedBands,
            is5G: is5G,
            is5GSA: is5GSA,
            is5GNSA: is5GNSA,
            isLTE: isLTE,
            isUMTS: isUMTS,
            isLTECarrierAggregationActive: wanLTECA == "ca_activated",
            lteCells: lteCells,
            nrCells: nrCells,
            umtsInfo: umtsInfo,
            neighborCells: neighborCells,
            temperatures: temperatures,
            cellID: field("cell_id"),
            nr5gCellID: nr5gCellID,
            txPowerText: txPowerText,
            wanIPv4: field("wan_ipaddr"),
            wanIPv6: field("ipv6_wan_ipaddr"),
            wanAPN: field("wan_apn"),
            dnsMode: field("dns_mode"),
            preferDNSManual: field("prefer_dns_manual"),
            standbyDNSManual: field("standby_dns_manual"),
            ipPassthroughEnabled: field("ip_passthrough_enabled"),
            currentNetworkMode: field("net_select"),
            opmsWanMode: field("opms_wan_mode"),
            rxBytesPerSec: Double(field("realtime_rx_thrpt")) ?? 0,
            txBytesPerSec: Double(field("realtime_tx_thrpt")) ?? 0,
            sessionDurationSeconds: Int(field("realtime_time")) ?? 0,
            sessionRxBytes: UInt64(field("realtime_rx_bytes")) ?? 0,
            sessionTxBytes: UInt64(field("realtime_tx_bytes")) ?? 0,
            monthlyRxBytes: UInt64(field("monthly_rx_bytes")) ?? 0,
            monthlyTxBytes: UInt64(field("monthly_tx_bytes")) ?? 0,
            batteryPercent: Int(field("battery_value")),
            batteryCharging: field("battery_charging"),
            signalBars: Int(field("signalbar")),
            wifiAccessStationCount: wifiAccessStationCount,
            wifi24GCount: wifi24GCount,
            wifi5GCount: wifi5GCount,
            wifiStations: wifiStations,
            lanStations: lanStations,
            versionInfo: RouterVersionInfo(
                hardwareVersion: field("hardware_version"),
                webVersion: field("web_version"),
                waInnerVersion: waInnerVersion,
                crVersion: field("cr_version")
            )
        )
    }

    // MARK: - Private Helpers

    private static func decodeStations(from value: Any, kind: ConnectedDeviceKind) -> [ConnectedStation]? {
        guard let array = value as? [[String: Any]] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: array) else { return nil }
        guard var decoded = try? JSONDecoder().decode([ConnectedStation].self, from: data) else { return nil }
        for index in decoded.indices {
            decoded[index].deviceKind = kind
        }
        return decoded
    }

    private static func stringify(_ value: Any) -> String {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            return n.stringValue
        case is NSNull:
            return ""
        default:
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return String(describing: value)
        }
    }

    private static func isDecimalPCIFirmware(waInnerVersion: String, nr5gCellID: String) -> Bool {
        let upper = waInnerVersion.uppercased()
        if upper.contains("MU5120") || upper.contains("FLYMODEM") {
            return true
        }
        if nr5gCellID.count >= 8 && nr5gCellID.allSatisfy(\.isNumber) {
            return true
        }
        return false
    }

    private static func parsePCI(_ raw: String, useDecimal: Bool) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let hasHexLetters = trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefABCDEF")) != nil
        if hasHexLetters || !useDecimal {
            if let hexInt = Int(trimmed, radix: 16) {
                return String(hexInt)
            }
        }
        return trimmed
    }

    private static func cleanBandwidth(_ raw: String) -> String {
        raw.replacingOccurrences(of: "MHz", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeNRBand(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-1" else { return "n??" }
        if trimmed.lowercased().hasPrefix("n") {
            let body = String(trimmed.dropFirst())
            return body.isEmpty ? "n??" : "n\(body)"
        }
        return "n\(trimmed)"
    }

    private static func formatBandSummary(_ pairs: [(String, String)]) -> String {
        pairs.compactMap { band, bw in
            guard !band.isEmpty else { return nil }
            return bw.isEmpty ? band : "\(band)(\(bw)MHz)"
        }.joined(separator: " + ")
    }

    private static func parseLTECells(
        field: (String) -> String,
        isLTE: Bool,
        useDecimalPCI: Bool
    ) -> [LTECellInfo] {
        guard isLTE else { return [] }

        var cells: [LTECellInfo] = []
        let mainBandRaw = !field("lte_ca_pcell_band").isEmpty ? field("lte_ca_pcell_band") : field("lte_band")
        let mainBand = mainBandRaw.isEmpty ? "B??" : (mainBandRaw.uppercased().hasPrefix("B") ? mainBandRaw : "B\(mainBandRaw)")
        let earfcn = !field("lte_ca_pcell_freq").isEmpty ? field("lte_ca_pcell_freq") : field("wan_active_channel")
        let bwRaw = !field("lte_ca_pcell_bandwidth").isEmpty ? field("lte_ca_pcell_bandwidth") : field("bandwidth")

        let rsrps = [
            field("lte_rsrp_1"), field("lte_rsrp_2"), field("lte_rsrp_3"), field("lte_rsrp_4")
        ].filter { !$0.isEmpty }
        let fallbackRSRP = rsrps.isEmpty ? (field("lte_rsrp").isEmpty ? [] : [field("lte_rsrp")]) : rsrps

        let sinrs = [
            field("lte_snr_1"), field("lte_snr_2"), field("lte_snr_3"), field("lte_snr_4")
        ].filter { !$0.isEmpty }
        let fallbackSINR = sinrs.isEmpty ? (field("lte_snr").isEmpty ? [] : [field("lte_snr")]) : sinrs

        cells.append(LTECellInfo(
            id: 0,
            isPrimary: true,
            pci: parsePCI(field("lte_pci"), useDecimal: useDecimalPCI),
            band: mainBand,
            earfcn: earfcn,
            bandwidthMHz: cleanBandwidth(bwRaw),
            rssi: field("lte_rssi"),
            rsrpList: fallbackRSRP,
            rsrq: field("lte_rsrq"),
            sinrList: fallbackSINR
        ))

        let scellInfos = field("lte_multi_ca_scell_info").split(separator: ";").map(String.init).filter { !$0.isEmpty }
        let scellSigInfos = field("lte_multi_ca_scell_sig_info").split(separator: ";").map(String.init).filter { !$0.isEmpty }

        for (index, infoLine) in scellInfos.enumerated() {
            let cols = infoLine.split(separator: ",").map(String.init)
            guard cols.count >= 6 else { continue }
            let sigCols = index < scellSigInfos.count ? scellSigInfos[index].split(separator: ",").map(String.init) : []
            if !sigCols.isEmpty && sigCols.count < 3 { continue }

            let rsrp = sigCols.first.map { $0 == "-44.0" ? "N/A" : $0 } ?? ""
            let rsrq = sigCols.count > 1 ? sigCols[1] : ""
            let sinr = sigCols.count > 2 ? sigCols[2] : ""

            cells.append(LTECellInfo(
                id: index + 1,
                isPrimary: false,
                pci: parsePCI(cols[1], useDecimal: useDecimalPCI),
                band: cols[3].uppercased().hasPrefix("B") ? cols[3] : "B\(cols[3])",
                earfcn: cols[4],
                bandwidthMHz: cleanBandwidth(cols[5]),
                rssi: "",
                rsrpList: rsrp.isEmpty ? [] : [rsrp],
                rsrq: rsrq,
                sinrList: sinr.isEmpty ? [] : [sinr]
            ))
        }

        return cells
    }

    private static func parseNRCells(
        field: (String) -> String,
        is5G: Bool,
        is5GNSA: Bool,
        is5GNSAActive: Bool,
        useDecimalPCI: Bool
    ) -> [NRCellInfo] {
        guard is5G else { return [] }
        if is5GNSA && !is5GNSAActive { return [] }

        let nrActionChannel = field("nr5g_action_channel")
        let nrCaPCellFreq = field("nr_ca_pcell_freq")
        let isCA = nrCaPCellFreq.isEmpty || nrActionChannel == nrCaPCellFreq

        let rx0 = !field("5g_rx0_rsrp").isEmpty ? field("5g_rx0_rsrp") : field("Z5g_rsrp")
        let rx1 = field("5g_rx1_rsrp")
        let rsrq = field("Z5g_rsrq")
        let rawSinr = field("Z5g_SINR")
        let sinr = (rawSinr == "-20.0" || rawSinr == "-3276.8") ? "N/A" : rawSinr

        var cells: [NRCellInfo] = []

        if !isCA {
            let bandRaw = is5GNSA ? field("nr5g_action_nsa_band") : field("nr5g_action_band")
            cells.append(NRCellInfo(
                id: 0,
                isPrimary: true,
                pci: parsePCI(field("nr5g_pci"), useDecimal: useDecimalPCI),
                band: normalizeNRBand(bandRaw),
                arfcn: nrActionChannel,
                bandwidthMHz: is5GNSA ? "" : cleanBandwidth(field("bandwidth")),
                rsrp1: rx0,
                rsrp2: rx1,
                rsrq: rsrq,
                sinr: sinr
            ))
            return cells
        }

        let fallbackBand = is5GNSA
            ? (!field("nr5g_action_nsa_band").isEmpty ? field("nr5g_action_nsa_band") : field("nr5g_action_band"))
            : field("nr5g_action_band")
        let pccBandRaw = !field("nr_ca_pcell_band").isEmpty ? field("nr_ca_pcell_band") : fallbackBand
        let pccFreq = !nrCaPCellFreq.isEmpty ? nrCaPCellFreq : (nrActionChannel.isEmpty ? "??" : nrActionChannel)

        cells.append(NRCellInfo(
            id: 0,
            isPrimary: true,
            pci: parsePCI(field("nr5g_pci"), useDecimal: useDecimalPCI),
            band: normalizeNRBand(pccBandRaw),
            arfcn: pccFreq,
            bandwidthMHz: cleanBandwidth(field("bandwidth")),
            rsrp1: rx0,
            rsrp2: rx1,
            rsrq: rsrq,
            sinr: sinr
        ))

        let allowedLockRaw = is5GNSA ? field("nr5g_nsa_band_lock") : field("nr5g_sa_band_lock")
        let allowedBands = Set(allowedLockRaw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })

        let scellLines = field("nr_multi_ca_scell_info").split(separator: ";").map(String.init).filter { !$0.isEmpty }
        for (idx, line) in scellLines.enumerated() {
            let cols = line.split(separator: ",").map(String.init)
            guard cols.count >= 10 else { continue }
            let bandNum = cols[3].replacingOccurrences(of: "n", with: "", options: .caseInsensitive)
            if !allowedBands.isEmpty && !allowedBands.contains(bandNum) {
                continue
            }
            cells.append(NRCellInfo(
                id: idx + 1,
                isPrimary: false,
                pci: cols[1],
                band: normalizeNRBand(cols[3]),
                arfcn: cols[4],
                bandwidthMHz: cleanBandwidth(cols[5]),
                rsrp1: cols[7],
                rsrp2: "",
                rsrq: cols[8],
                sinr: cols[9] == "0.0" ? "N/A" : cols[9]
            ))
        }

        return cells
    }

    private static func parseUMTSInfo(field: (String) -> String, isUMTS: Bool) -> UMTSCellInfo? {
        guard isUMTS else { return nil }
        let rscp = [field("rscp_1"), field("rscp_2"), field("rscp_3"), field("rscp_4")].filter { !$0.isEmpty }
        let ecio = [field("ecio_1"), field("ecio_2"), field("ecio_3"), field("ecio_4")].filter { !$0.isEmpty }
        return UMTSCellInfo(band: field("lte_ca_pcell_band"), rscp: rscp, ecio: ecio)
    }

    private static func parseNeighborCells(raw: String, isLTE: Bool) -> [NeighborCellInfo] {
        guard !raw.isEmpty else { return [] }
        return raw.split(separator: ";").enumerated().compactMap { index, segment in
            let line = String(segment).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let cols = line.split(separator: ",").map(String.init)
            if isLTE && cols.count >= 4 {
                return NeighborCellInfo(
                    id: "\(index)-\(cols[1])",
                    frequency: cols[0],
                    pci: cols[1],
                    rsrp: cols[3],
                    rsrq: cols[2],
                    rssi: cols.count > 4 ? cols[4] : "",
                    rawLine: line
                )
            }
            return NeighborCellInfo(
                id: "\(index)-\(line)",
                frequency: "",
                pci: "",
                rsrp: "",
                rsrq: "",
                rssi: "",
                rawLine: line
            )
        }
    }

    private static func parseTemperatures(field: (String) -> String) -> [TemperatureReading] {
        let candidates: [(String, String, String)] = [
            ("ambient", "环境 (A)", field("pm_sensor_ambient")),
            ("mdm", "基带 (MDM)", field("pm_sensor_mdm")),
            ("5g", "5G 模组", !field("pm_sensor_5g").isEmpty ? field("pm_sensor_5g") : field("pm_modem_5g")),
            ("pa1", "功放 (PA1)", field("pm_sensor_pa1")),
            ("wifi", "Wi-Fi 芯片", field("wifi_chip_temp"))
        ]
        return candidates.compactMap { id, label, raw in
            guard !raw.isEmpty, let value = Double(raw), value > -40 else { return nil }
            return TemperatureReading(id: id, label: label, celsius: value)
        }
    }
}

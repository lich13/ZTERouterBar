import Foundation

public enum WANConnectionState: Equatable, Sendable {
    case connected(rawStatus: String)
    case connecting(rawStatus: String)
    case disconnecting(rawStatus: String)
    case disconnected(rawStatus: String)
    case unknown(rawStatus: String)

    public init(pppStatus: String) {
        let normalized = pppStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "ppp_connected", "ipv6_connected", "ipv4_ipv6_connected":
            self = .connected(rawStatus: pppStatus)
        case "ppp_connecting":
            self = .connecting(rawStatus: pppStatus)
        case "ppp_disconnecting":
            self = .disconnecting(rawStatus: pppStatus)
        case "ppp_disconnected":
            self = .disconnected(rawStatus: pppStatus)
        default:
            self = .unknown(rawStatus: pppStatus)
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isDisconnected: Bool {
        if case .disconnected = self { return true }
        return false
    }

    public var isTransitioning: Bool {
        switch self {
        case .connecting, .disconnecting: true
        default: false
        }
    }

    public var localizedLabel: String {
        switch self {
        case .connected: "外网已连接"
        case .connecting: "正在连接外网…"
        case .disconnecting: "正在断开外网…"
        case .disconnected: "外网已断开"
        case let .unknown(raw): raw.isEmpty ? "状态未知" : "状态: \(raw)"
        }
    }
}

public struct LTECellInfo: Equatable, Sendable, Identifiable {
    public let id: Int
    public let isPrimary: Bool
    public let pci: String
    public let band: String
    public let earfcn: String
    public let bandwidthMHz: String
    public let rssi: String
    public let rsrpList: [String]
    public let rsrq: String
    public let sinrList: [String]
}

public struct NRCellInfo: Equatable, Sendable, Identifiable {
    public let id: Int
    public let isPrimary: Bool
    public let pci: String
    public let band: String
    public let arfcn: String
    public let bandwidthMHz: String
    public let rsrp1: String
    public let rsrp2: String
    public let rsrq: String
    public let sinr: String
}

public struct UMTSCellInfo: Equatable, Sendable {
    public let band: String
    public let rscp: [String]
    public let ecio: [String]
}

public struct NeighborCellInfo: Equatable, Sendable, Identifiable {
    public let id: String
    public let frequency: String
    public let pci: String
    public let rsrp: String
    public let rsrq: String
    public let rssi: String
    public let rawLine: String
}

public struct TemperatureReading: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let celsius: Double
}

public struct ConnectedStation: Equatable, Sendable, Identifiable, Codable {
    public var id: String { "\(ipAddress)-\(macAddress)-\(interfaceType)" }
    public let hostname: String
    public let ipAddress: String
    public let macAddress: String
    public let interfaceType: String
    public let connectTimeSeconds: Int
    public let ssidIndex: String

    enum CodingKeys: String, CodingKey {
        case hostname
        case ipAddress = "ip_addr"
        case macAddress = "mac_addr"
        case interfaceType = "interfacetype"
        case connectTimeSeconds = "connect_time"
        case ssidIndex = "ssid_index"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostname = (try? container.decode(String.self, forKey: .hostname)) ?? ""
        ipAddress = (try? container.decode(String.self, forKey: .ipAddress)) ?? ""
        macAddress = (try? container.decode(String.self, forKey: .macAddress)) ?? ""
        interfaceType = (try? container.decode(String.self, forKey: .interfaceType)) ?? ""
        ssidIndex = (try? container.decode(String.self, forKey: .ssidIndex)) ?? ""
        if let intVal = try? container.decode(Int.self, forKey: .connectTimeSeconds) {
            connectTimeSeconds = intVal
        } else if let strVal = try? container.decode(String.self, forKey: .connectTimeSeconds),
                  let parsed = Int(strVal) {
            connectTimeSeconds = parsed
        } else {
            connectTimeSeconds = 0
        }
    }

    public init(
        hostname: String,
        ipAddress: String,
        macAddress: String,
        interfaceType: String,
        connectTimeSeconds: Int,
        ssidIndex: String
    ) {
        self.hostname = hostname
        self.ipAddress = ipAddress
        self.macAddress = macAddress
        self.interfaceType = interfaceType
        self.connectTimeSeconds = connectTimeSeconds
        self.ssidIndex = ssidIndex
    }
}

public struct RouterVersionInfo: Equatable, Sendable {
    public let hardwareVersion: String
    public let webVersion: String
    public let waInnerVersion: String
    public let crVersion: String
}

public struct RouterStatusSnapshot: Equatable, Sendable {
    public let fetchedAt: Date
    public let rawFields: [String: String]

    public let connectionState: WANConnectionState
    public let wanConnectStatus: String
    public let modemMainState: String
    public let networkType: String
    public let providerName: String
    public let mcc: String
    public let mnc: String

    public let bandSummary: String
    public let is5G: Bool
    public let is5GSA: Bool
    public let is5GNSA: Bool
    public let isLTE: Bool
    public let isUMTS: Bool
    public let isLTECarrierAggregationActive: Bool

    public let lteCells: [LTECellInfo]
    public let nrCells: [NRCellInfo]
    public let umtsInfo: UMTSCellInfo?
    public let neighborCells: [NeighborCellInfo]
    public let temperatures: [TemperatureReading]

    public let cellID: String
    public let nr5gCellID: String
    public let txPowerText: String
    public let wanIPv4: String
    public let wanIPv6: String
    public let wanAPN: String
    public let dnsMode: String
    public let preferDNSManual: String
    public let standbyDNSManual: String
    public let ipPassthroughEnabled: String
    public let currentNetworkMode: String
    public let opmsWanMode: String

    public let rxBytesPerSec: Double
    public let txBytesPerSec: Double
    public let sessionDurationSeconds: Int
    public let sessionRxBytes: UInt64
    public let sessionTxBytes: UInt64
    public let monthlyRxBytes: UInt64
    public let monthlyTxBytes: UInt64

    public let batteryPercent: Int?
    public let batteryCharging: String
    public let signalBars: Int?

    public let wifiAccessStationCount: Int?
    public let wifiStations: [ConnectedStation]
    public let lanStations: [ConnectedStation]
    public let versionInfo: RouterVersionInfo

    public var wirelessDeviceCount: Int {
        max(wifiAccessStationCount ?? 0, wifiStations.count)
    }

    public var wiredDeviceCount: Int {
        lanStations.count
    }

    public var totalConnectedDevices: Int {
        wirelessDeviceCount + wiredDeviceCount
    }

    public var displayProvider: String {
        switch providerName.uppercased() {
        case "CMCC": "中国移动 (CMCC)"
        case "CUCC", "UNICOM", "CHN-UNICOM": "中国联通 (\(providerName))"
        case "CTCC", "TELECOM", "CHN-CT": "中国电信 (\(providerName))"
        case "CBN": "中国广电 (CBN)"
        default: providerName
        }
    }
}

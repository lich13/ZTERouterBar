import Foundation

public enum EndpointProxyMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case system
    case direct
    case http
    case socks5

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: "跟随系统代理"
        case .direct: "直连 (无代理)"
        case .http: "HTTP 代理"
        case .socks5: "SOCKS5 代理"
        }
    }

    public var shortName: String {
        switch self {
        case .system: "系统代理"
        case .direct: "直连"
        case .http: "HTTP"
        case .socks5: "SOCKS5"
        }
    }
}

public enum WatchdogTriggerPolicy: String, CaseIterable, Codable, Sendable, Identifiable {
    case weighted
    case allUnreachable
    case anyUnreachable

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .weighted: "按端点权重占比判定 (推荐，可达权重须过半)"
        case .allUnreachable: "全部启用端点均不可达才重连"
        case .anyUnreachable: "任一启用端点不可达即触发重连"
        }
    }
}

public struct WatchdogEndpoint: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var isEnabled: Bool
    public var name: String
    public var urlString: String
    public var proxyMode: EndpointProxyMode
    public var proxyHost: String
    public var proxyPort: Int
    public var proxyUsername: String
    public var proxyPassword: String
    public var weight: Int
    public var expectedResponseText: String

    enum CodingKeys: String, CodingKey {
        case id, isEnabled, name, urlString, proxyMode, proxyHost, proxyPort, proxyUsername, proxyPassword, weight, expectedResponseText
    }

    public init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        name: String = "",
        urlString: String = "",
        proxyMode: EndpointProxyMode = .system,
        proxyHost: String = "127.0.0.1",
        proxyPort: Int = 7890,
        proxyUsername: String = "",
        proxyPassword: String = "",
        weight: Int = 1,
        expectedResponseText: String = ""
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.name = name
        self.urlString = urlString
        self.proxyMode = proxyMode
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.proxyUsername = proxyUsername
        self.proxyPassword = proxyPassword
        self.weight = min(max(weight, 1), 10)
        self.expectedResponseText = expectedResponseText
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        urlString = try container.decodeIfPresent(String.self, forKey: .urlString) ?? ""
        proxyMode = try container.decodeIfPresent(EndpointProxyMode.self, forKey: .proxyMode) ?? .system
        proxyHost = try container.decodeIfPresent(String.self, forKey: .proxyHost) ?? "127.0.0.1"
        proxyPort = try container.decodeIfPresent(Int.self, forKey: .proxyPort) ?? 7890
        proxyUsername = try container.decodeIfPresent(String.self, forKey: .proxyUsername) ?? ""
        proxyPassword = try container.decodeIfPresent(String.self, forKey: .proxyPassword) ?? ""
        weight = min(max(try container.decodeIfPresent(Int.self, forKey: .weight) ?? 1, 1), 10)
        expectedResponseText = try container.decodeIfPresent(String.self, forKey: .expectedResponseText) ?? ""
    }

    public var isValidHTTPURL: Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    public var displayTitle: String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanName.isEmpty { return cleanName }
        if let host = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))?.host {
            return host
        }
        return urlString.isEmpty ? "未命名端点" : urlString
    }

    /// URLs shipped in earlier versions, used only for one-time migration of untouched configs.
    public static let legacyV102PresetURLs: [String] = [
        "https://cp.cloudflare.com/generate_204",
        "https://www.gstatic.com/generate_204",
        "https://captive.apple.com/hotspot-detect.html"
    ]

    public static let legacyV103PresetURLs: [String] = [
        "https://www.youtube.com/generate_204",
        "https://cloudflare-dns.com/cdn-cgi/trace",
        "https://github.githubassets.com/favicons/favicon.svg",
        "https://www.dropbox.com/robots.txt"
    ]

    /// Highest-weight primary self-hosted probe (`661313.xyz/test/success.txt`, returning uncached `200 success`)
    /// paired with secondary GFW-listed probes (`YouTube 204`, `Cloudflare DoH`).
    public static var defaultPresets: [WatchdogEndpoint] {
        [
            WatchdogEndpoint(
                isEnabled: true,
                name: "661313 节点",
                urlString: "https://661313.xyz/test/success.txt",
                proxyMode: .system,
                weight: 3,
                expectedResponseText: "success"
            ),
            WatchdogEndpoint(
                isEnabled: true,
                name: "YouTube 204",
                urlString: "https://www.youtube.com/generate_204",
                proxyMode: .system,
                weight: 1
            ),
            WatchdogEndpoint(
                isEnabled: true,
                name: "Cloudflare DoH",
                urlString: "https://cloudflare-dns.com/cdn-cgi/trace",
                proxyMode: .system,
                weight: 1
            )
        ]
    }
}

public struct WatchdogConfig: Codable, Equatable, Sendable {
    public var autoStart: Bool
    public var checkTimeoutMs: Int
    public var pollIntervalSec: Int
    public var recheckBeforeAct: Int
    public var recheckIntervalSec: Int
    public var maxConsecutiveReconnects: Int
    public var cooldownSec: Int
    public var triggerPolicy: WatchdogTriggerPolicy
    public var onlyWhenWiFiMatched: Bool
    public var endpoints: [WatchdogEndpoint]

    public static let defaultCheckTimeoutMs = 4000
    public static let defaultPollIntervalSec = 33
    public static let defaultRecheckBeforeAct = 1
    public static let defaultRecheckIntervalSec = 3
    public static let defaultMaxConsecutiveReconnects = 3
    public static let defaultCooldownSec = 60

    public init(
        autoStart: Bool = true,
        checkTimeoutMs: Int = WatchdogConfig.defaultCheckTimeoutMs,
        pollIntervalSec: Int = WatchdogConfig.defaultPollIntervalSec,
        recheckBeforeAct: Int = WatchdogConfig.defaultRecheckBeforeAct,
        recheckIntervalSec: Int = WatchdogConfig.defaultRecheckIntervalSec,
        maxConsecutiveReconnects: Int = WatchdogConfig.defaultMaxConsecutiveReconnects,
        cooldownSec: Int = WatchdogConfig.defaultCooldownSec,
        triggerPolicy: WatchdogTriggerPolicy = .weighted,
        onlyWhenWiFiMatched: Bool = false,
        endpoints: [WatchdogEndpoint] = WatchdogEndpoint.defaultPresets
    ) {
        self.autoStart = autoStart
        self.checkTimeoutMs = checkTimeoutMs
        self.pollIntervalSec = pollIntervalSec
        self.recheckBeforeAct = recheckBeforeAct
        self.recheckIntervalSec = recheckIntervalSec
        self.maxConsecutiveReconnects = maxConsecutiveReconnects
        self.cooldownSec = cooldownSec
        self.triggerPolicy = triggerPolicy
        self.onlyWhenWiFiMatched = onlyWhenWiFiMatched
        self.endpoints = endpoints
    }

    public var enabledValidEndpoints: [WatchdogEndpoint] {
        endpoints.filter {
            $0.isEnabled && !$0.urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public func clamped() -> WatchdogConfig {
        var copy = self
        copy.checkTimeoutMs = min(max(checkTimeoutMs, 500), 30000)
        copy.pollIntervalSec = min(max(pollIntervalSec, 5), 3600)
        copy.recheckBeforeAct = min(max(recheckBeforeAct, 0), 10)
        copy.recheckIntervalSec = min(max(recheckIntervalSec, 1), 60)
        copy.maxConsecutiveReconnects = min(max(maxConsecutiveReconnects, 1), 10)
        copy.cooldownSec = min(max(cooldownSec, 10), 600)
        for idx in copy.endpoints.indices {
            copy.endpoints[idx].weight = min(max(copy.endpoints[idx].weight, 1), 10)
        }
        return copy
    }

    /// One-time migration from v1.0.2/v1.0.3 defaults to v1.0.4 weighted `661313.xyz` + 2-fail reconnect defaults.
    public func migratingLegacyDefaults(fromVersion version: Int) -> WatchdogConfig {
        var copy = self
        if version < 2 {
            if copy.endpoints.map(\.urlString) == WatchdogEndpoint.legacyV102PresetURLs {
                copy.endpoints = WatchdogEndpoint.defaultPresets
            }
            if copy.pollIntervalSec == 15 {
                copy.pollIntervalSec = WatchdogConfig.defaultPollIntervalSec
            }
        }
        if version < 3 {
            let currentURLs = copy.endpoints.map(\.urlString)
            if currentURLs == WatchdogEndpoint.legacyV103PresetURLs || currentURLs == WatchdogEndpoint.legacyV102PresetURLs {
                copy.endpoints = WatchdogEndpoint.defaultPresets
            } else {
                // Remove retired GitHub/Dropbox presets if present and ensure 661313 primary endpoint leads with highest weight.
                copy.endpoints.removeAll {
                    $0.urlString.contains("github.githubassets.com") || $0.urlString.contains("dropbox.com/robots.txt")
                }
                if !copy.endpoints.contains(where: { $0.urlString.contains("661313.xyz/test/success.txt") }) {
                    copy.endpoints.insert(
                        WatchdogEndpoint(
                            isEnabled: true,
                            name: "661313 节点",
                            urlString: "https://661313.xyz/test/success.txt",
                            proxyMode: .system,
                            weight: 3,
                            expectedResponseText: "success"
                        ),
                        at: 0
                    )
                }
            }
            if copy.triggerPolicy == .allUnreachable {
                copy.triggerPolicy = .weighted
            }
            if copy.recheckBeforeAct == 3 {
                copy.recheckBeforeAct = WatchdogConfig.defaultRecheckBeforeAct
            }
        }
        return copy.clamped()
    }

    /// Returns a copy keeping current endpoints while restoring all strategy and timing parameters to recommended defaults.
    public func withDefaultParameters() -> WatchdogConfig {
        WatchdogConfig(
            autoStart: true,
            checkTimeoutMs: WatchdogConfig.defaultCheckTimeoutMs,
            pollIntervalSec: WatchdogConfig.defaultPollIntervalSec,
            recheckBeforeAct: WatchdogConfig.defaultRecheckBeforeAct,
            recheckIntervalSec: WatchdogConfig.defaultRecheckIntervalSec,
            maxConsecutiveReconnects: WatchdogConfig.defaultMaxConsecutiveReconnects,
            cooldownSec: WatchdogConfig.defaultCooldownSec,
            triggerPolicy: .weighted,
            onlyWhenWiFiMatched: false,
            endpoints: endpoints
        )
    }
}

public struct EndpointProbeOutcome: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let urlString: String
    public let proxyMode: EndpointProxyMode
    public let weight: Int
    public let reachable: Bool
    public let statusCode: Int?
    public let elapsedMs: Int
    public let errorMessage: String?
    public let checkedAt: Date

    public init(
        id: UUID,
        name: String,
        urlString: String,
        proxyMode: EndpointProxyMode,
        weight: Int = 1,
        reachable: Bool,
        statusCode: Int? = nil,
        elapsedMs: Int = 0,
        errorMessage: String? = nil,
        checkedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.proxyMode = proxyMode
        self.weight = max(1, weight)
        self.reachable = reachable
        self.statusCode = statusCode
        self.elapsedMs = elapsedMs
        self.errorMessage = errorMessage
        self.checkedAt = checkedAt
    }
}

public enum WatchdogPhase: Equatable, Sendable {
    case idle
    case monitoring
    case rechecking(attempt: Int, total: Int)
    case reconnecting
    case verifyingAfterReconnect
    case coolingDown(seconds: Int)
    case paused(reason: String)

    public var isActive: Bool {
        if case .idle = self { return false }
        return true
    }

    public var displayLabel: String {
        switch self {
        case .idle:
            return "未启动"
        case .monitoring:
            return "守护运行中"
        case let .rechecking(attempt, total):
            return "抖动复检中 (\(attempt)/\(total))"
        case .reconnecting:
            return "正在自动重连外网…"
        case .verifyingAfterReconnect:
            return "重连后复检确认中…"
        case let .coolingDown(seconds):
            return "连续重连冷却 (\(seconds)s)"
        case let .paused(reason):
            return "已暂停：\(reason)"
        }
    }
}

public enum WatchdogLogLevel: String, Sendable {
    case info
    case success
    case warning
    case error
}

public struct WatchdogLogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: WatchdogLogLevel
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: WatchdogLogLevel = .info,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

public enum WatchdogEvent: Sendable {
    case phaseChanged(WatchdogPhase)
    case probeRoundCompleted([EndpointProbeOutcome], overallHealthy: Bool)
    case autoReconnectTriggered(reason: String)
    case autoReconnectFinished(state: WANConnectionState)
    case log(WatchdogLogEntry)
}

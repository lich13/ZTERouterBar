import Foundation

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
    public var weight: Int
    public var intervalSec: Int
    public var timeoutSec: Int

    public static let defaultWeight = 1
    public static let defaultIntervalSec = 33
    public static let defaultTimeoutSec = 4

    enum CodingKeys: String, CodingKey {
        case id, isEnabled, name, urlString, weight, intervalSec, timeoutSec
    }

    public init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        name: String = "",
        urlString: String = "",
        weight: Int = WatchdogEndpoint.defaultWeight,
        intervalSec: Int = WatchdogEndpoint.defaultIntervalSec,
        timeoutSec: Int = WatchdogEndpoint.defaultTimeoutSec
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.name = name
        self.urlString = urlString
        self.weight = min(max(weight, 1), 10)
        self.intervalSec = min(max(intervalSec, 5), 3600)
        self.timeoutSec = min(max(timeoutSec, 1), 30)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        urlString = try container.decodeIfPresent(String.self, forKey: .urlString) ?? ""
        weight = min(max(try container.decodeIfPresent(Int.self, forKey: .weight) ?? Self.defaultWeight, 1), 10)
        intervalSec = min(max(try container.decodeIfPresent(Int.self, forKey: .intervalSec) ?? Self.defaultIntervalSec, 5), 3600)
        timeoutSec = min(max(try container.decodeIfPresent(Int.self, forKey: .timeoutSec) ?? Self.defaultTimeoutSec, 1), 30)
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

    public func clamped() -> WatchdogEndpoint {
        WatchdogEndpoint(
            id: id,
            isEnabled: isEnabled,
            name: name,
            urlString: urlString,
            weight: weight,
            intervalSec: intervalSec,
            timeoutSec: timeoutSec
        )
    }

    /// URLs shipped in earlier versions, used only for one-time migration of untouched configs.
    public static let legacyPresetURLSets: [[String]] = [
        [
            "https://cp.cloudflare.com/generate_204",
            "https://www.gstatic.com/generate_204",
            "https://captive.apple.com/hotspot-detect.html"
        ],
        [
            "https://www.youtube.com/generate_204",
            "https://cloudflare-dns.com/cdn-cgi/trace",
            "https://github.githubassets.com/favicons/favicon.svg",
            "https://www.dropbox.com/robots.txt"
        ],
        [
            "https://661313.xyz/test/success.txt",
            "https://www.youtube.com/generate_204",
            "https://cloudflare-dns.com/cdn-cgi/trace"
        ]
    ]

    public static var defaultPresets: [WatchdogEndpoint] {
        [
            WatchdogEndpoint(
                isEnabled: true,
                name: "661313 204",
                urlString: "https://661313.xyz/test/generate_204",
                weight: 3,
                intervalSec: 15,
                timeoutSec: 3
            ),
            WatchdogEndpoint(
                isEnabled: true,
                name: "YouTube 204",
                urlString: "https://www.youtube.com/generate_204",
                weight: 1,
                intervalSec: 33,
                timeoutSec: 4
            ),
            WatchdogEndpoint(
                isEnabled: true,
                name: "Cloudflare DoH",
                urlString: "https://cloudflare-dns.com/cdn-cgi/trace",
                weight: 1,
                intervalSec: 33,
                timeoutSec: 4
            )
        ]
    }
}

public struct WatchdogConfig: Codable, Equatable, Sendable {
    public var autoStart: Bool
    public var recheckBeforeAct: Int
    public var recheckIntervalSec: Int
    public var maxConsecutiveReconnects: Int
    public var cooldownSec: Int
    public var triggerPolicy: WatchdogTriggerPolicy
    public var onlyWhenWiFiMatched: Bool
    public var endpoints: [WatchdogEndpoint]

    public static let defaultRecheckBeforeAct = 1
    public static let defaultRecheckIntervalSec = 3
    public static let defaultMaxConsecutiveReconnects = 3
    public static let defaultCooldownSec = 60

    enum CodingKeys: String, CodingKey {
        case autoStart, recheckBeforeAct, recheckIntervalSec, maxConsecutiveReconnects, cooldownSec, triggerPolicy, onlyWhenWiFiMatched, endpoints
        // Legacy keys decoded only when upgrading older persisted configs that lack per-endpoint timing.
        case checkTimeoutMs, pollIntervalSec
    }

    public init(
        autoStart: Bool = true,
        recheckBeforeAct: Int = WatchdogConfig.defaultRecheckBeforeAct,
        recheckIntervalSec: Int = WatchdogConfig.defaultRecheckIntervalSec,
        maxConsecutiveReconnects: Int = WatchdogConfig.defaultMaxConsecutiveReconnects,
        cooldownSec: Int = WatchdogConfig.defaultCooldownSec,
        triggerPolicy: WatchdogTriggerPolicy = .weighted,
        onlyWhenWiFiMatched: Bool = false,
        endpoints: [WatchdogEndpoint] = WatchdogEndpoint.defaultPresets
    ) {
        self.autoStart = autoStart
        self.recheckBeforeAct = recheckBeforeAct
        self.recheckIntervalSec = recheckIntervalSec
        self.maxConsecutiveReconnects = maxConsecutiveReconnects
        self.cooldownSec = cooldownSec
        self.triggerPolicy = triggerPolicy
        self.onlyWhenWiFiMatched = onlyWhenWiFiMatched
        self.endpoints = endpoints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? true
        recheckBeforeAct = try container.decodeIfPresent(Int.self, forKey: .recheckBeforeAct) ?? Self.defaultRecheckBeforeAct
        recheckIntervalSec = try container.decodeIfPresent(Int.self, forKey: .recheckIntervalSec) ?? Self.defaultRecheckIntervalSec
        maxConsecutiveReconnects = try container.decodeIfPresent(Int.self, forKey: .maxConsecutiveReconnects) ?? Self.defaultMaxConsecutiveReconnects
        cooldownSec = try container.decodeIfPresent(Int.self, forKey: .cooldownSec) ?? Self.defaultCooldownSec
        triggerPolicy = try container.decodeIfPresent(WatchdogTriggerPolicy.self, forKey: .triggerPolicy) ?? .weighted
        onlyWhenWiFiMatched = try container.decodeIfPresent(Bool.self, forKey: .onlyWhenWiFiMatched) ?? false

        var decodedEndpoints = try container.decodeIfPresent([WatchdogEndpoint].self, forKey: .endpoints) ?? WatchdogEndpoint.defaultPresets
        let legacyPollSec = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSec)
        let legacyTimeoutSec = (try container.decodeIfPresent(Int.self, forKey: .checkTimeoutMs)).map { max(1, Int((Double($0) / 1000.0).rounded())) }
        if legacyPollSec != nil || legacyTimeoutSec != nil {
            for idx in decodedEndpoints.indices {
                if let legacyPollSec { decodedEndpoints[idx].intervalSec = legacyPollSec }
                if let legacyTimeoutSec { decodedEndpoints[idx].timeoutSec = legacyTimeoutSec }
            }
        }
        endpoints = decodedEndpoints.map { $0.clamped() }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(autoStart, forKey: .autoStart)
        try container.encode(recheckBeforeAct, forKey: .recheckBeforeAct)
        try container.encode(recheckIntervalSec, forKey: .recheckIntervalSec)
        try container.encode(maxConsecutiveReconnects, forKey: .maxConsecutiveReconnects)
        try container.encode(cooldownSec, forKey: .cooldownSec)
        try container.encode(triggerPolicy, forKey: .triggerPolicy)
        try container.encode(onlyWhenWiFiMatched, forKey: .onlyWhenWiFiMatched)
        try container.encode(endpoints, forKey: .endpoints)
    }

    public var enabledValidEndpoints: [WatchdogEndpoint] {
        endpoints.filter {
            $0.isEnabled && !$0.urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public func clamped() -> WatchdogConfig {
        var copy = self
        copy.recheckBeforeAct = min(max(recheckBeforeAct, 0), 10)
        copy.recheckIntervalSec = min(max(recheckIntervalSec, 1), 60)
        copy.maxConsecutiveReconnects = min(max(maxConsecutiveReconnects, 1), 10)
        copy.cooldownSec = min(max(cooldownSec, 10), 600)
        copy.endpoints = endpoints.map { $0.clamped() }
        return copy
    }

    /// One-time migration from v1.0.2–v1.0.4 configs to v1.1.0 per-endpoint seconds and `/test/generate_204`.
    public func migratingLegacyDefaults(fromVersion version: Int) -> WatchdogConfig {
        guard version < 4 else { return clamped() }
        var copy = self
        let currentURLs = copy.endpoints.map(\.urlString)
        if WatchdogEndpoint.legacyPresetURLSets.contains(currentURLs) {
            copy.endpoints = WatchdogEndpoint.defaultPresets
        } else {
            copy.endpoints.removeAll {
                $0.urlString.contains("github.githubassets.com") || $0.urlString.contains("dropbox.com/robots.txt")
            }
            if let legacyIdx = copy.endpoints.firstIndex(where: { $0.urlString.contains("661313.xyz/test/success.txt") }) {
                copy.endpoints[legacyIdx].name = "661313 204"
                copy.endpoints[legacyIdx].urlString = "https://661313.xyz/test/generate_204"
                copy.endpoints[legacyIdx].weight = max(copy.endpoints[legacyIdx].weight, 3)
                copy.endpoints[legacyIdx].intervalSec = 15
                copy.endpoints[legacyIdx].timeoutSec = 3
            } else if !copy.endpoints.contains(where: { $0.urlString.contains("661313.xyz/test") }) {
                copy.endpoints.insert(WatchdogEndpoint.defaultPresets[0], at: 0)
            }
        }
        if version < 3 {
            if copy.triggerPolicy == .allUnreachable {
                copy.triggerPolicy = .weighted
            }
            if copy.recheckBeforeAct == 3 {
                copy.recheckBeforeAct = WatchdogConfig.defaultRecheckBeforeAct
            }
        }
        return copy.clamped()
    }

    /// Returns a copy keeping current endpoints while restoring all strategy and debounce parameters to defaults.
    public func withDefaultParameters() -> WatchdogConfig {
        WatchdogConfig(
            autoStart: true,
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

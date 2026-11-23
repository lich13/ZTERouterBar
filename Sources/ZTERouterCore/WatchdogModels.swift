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
    public static let defaultTimeoutSec = 10

    public static let weightRange = 1...10
    public static let intervalRange = 5...3600
    public static let timeoutRange = 1...30

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
        self.weight = weight.clamped(to: Self.weightRange)
        self.intervalSec = intervalSec.clamped(to: Self.intervalRange)
        self.timeoutSec = timeoutSec.clamped(to: Self.timeoutRange)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            urlString: try container.decodeIfPresent(String.self, forKey: .urlString) ?? "",
            weight: try container.decodeIfPresent(Int.self, forKey: .weight) ?? Self.defaultWeight,
            intervalSec: try container.decodeIfPresent(Int.self, forKey: .intervalSec) ?? Self.defaultIntervalSec,
            timeoutSec: try container.decodeIfPresent(Int.self, forKey: .timeoutSec) ?? Self.defaultTimeoutSec
        )
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
                weight: 1,
                intervalSec: 15,
                timeoutSec: WatchdogEndpoint.defaultTimeoutSec
            ),
            WatchdogEndpoint(
                isEnabled: true,
                name: "YouTube 204",
                urlString: "https://www.youtube.com/generate_204",
                weight: 1,
                intervalSec: 33,
                timeoutSec: WatchdogEndpoint.defaultTimeoutSec
            ),
            WatchdogEndpoint(
                isEnabled: true,
                name: "Cloudflare DoH",
                urlString: "https://cloudflare-dns.com/cdn-cgi/trace",
                weight: 1,
                intervalSec: 33,
                timeoutSec: WatchdogEndpoint.defaultTimeoutSec
            ),
            telegramPreset
        ]
    }

    /// Added in defaults version 6; appended to untouched older preset lists on upgrade.
    public static var telegramPreset: WatchdogEndpoint {
        WatchdogEndpoint(
            isEnabled: true,
            name: "Telegram API",
            urlString: "https://api.telegram.org/",
            weight: 1,
            intervalSec: 33,
            timeoutSec: WatchdogEndpoint.defaultTimeoutSec
        )
    }
}

public struct WatchdogConfig: Codable, Equatable, Sendable {
    public var autoStart: Bool
    /// When off, a sustained failure only notifies; the router is never redialed automatically.
    public var autoReconnectEnabled: Bool
    /// Seconds of continuous failure (confirmed by full re-probes) required before a reconnect.
    public var failureWindowSec: Int
    /// Interval between full re-probes while confirming a failure.
    public var recheckIntervalSec: Int
    /// Quiet period after a reconnect: no probing, no verdict, no reconnect.
    public var postReconnectGraceSec: Int
    public var maxConsecutiveReconnects: Int
    public var cooldownSec: Int
    public var triggerPolicy: WatchdogTriggerPolicy
    public var onlyWhenWiFiMatched: Bool
    public var endpoints: [WatchdogEndpoint]

    public static let defaultFailureWindowSec = 15
    public static let defaultRecheckIntervalSec = 5
    public static let defaultPostReconnectGraceSec = 180
    public static let defaultMaxConsecutiveReconnects = 3
    public static let defaultCooldownSec = 300

    public static let failureWindowRange = 10...600
    public static let recheckIntervalRange = 1...60
    public static let postReconnectGraceRange = 0...600
    public static let maxConsecutiveReconnectsRange = 1...10
    public static let cooldownRange = 10...600

    /// Decoded only when upgrading older persisted configs that lack per-endpoint timing; never encoded.
    private enum LegacyCodingKeys: String, CodingKey {
        case checkTimeoutMs, pollIntervalSec
    }

    public init(
        autoStart: Bool = true,
        autoReconnectEnabled: Bool = false,
        failureWindowSec: Int = WatchdogConfig.defaultFailureWindowSec,
        recheckIntervalSec: Int = WatchdogConfig.defaultRecheckIntervalSec,
        postReconnectGraceSec: Int = WatchdogConfig.defaultPostReconnectGraceSec,
        maxConsecutiveReconnects: Int = WatchdogConfig.defaultMaxConsecutiveReconnects,
        cooldownSec: Int = WatchdogConfig.defaultCooldownSec,
        triggerPolicy: WatchdogTriggerPolicy = .weighted,
        onlyWhenWiFiMatched: Bool = false,
        endpoints: [WatchdogEndpoint] = WatchdogEndpoint.defaultPresets
    ) {
        self.autoStart = autoStart
        self.autoReconnectEnabled = autoReconnectEnabled
        self.failureWindowSec = failureWindowSec
        self.recheckIntervalSec = recheckIntervalSec
        self.postReconnectGraceSec = postReconnectGraceSec
        self.maxConsecutiveReconnects = maxConsecutiveReconnects
        self.cooldownSec = cooldownSec
        self.triggerPolicy = triggerPolicy
        self.onlyWhenWiFiMatched = onlyWhenWiFiMatched
        self.endpoints = endpoints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? true
        autoReconnectEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoReconnectEnabled) ?? false
        failureWindowSec = try container.decodeIfPresent(Int.self, forKey: .failureWindowSec) ?? Self.defaultFailureWindowSec
        recheckIntervalSec = try container.decodeIfPresent(Int.self, forKey: .recheckIntervalSec) ?? Self.defaultRecheckIntervalSec
        postReconnectGraceSec = try container.decodeIfPresent(Int.self, forKey: .postReconnectGraceSec) ?? Self.defaultPostReconnectGraceSec
        maxConsecutiveReconnects = try container.decodeIfPresent(Int.self, forKey: .maxConsecutiveReconnects) ?? Self.defaultMaxConsecutiveReconnects
        cooldownSec = try container.decodeIfPresent(Int.self, forKey: .cooldownSec) ?? Self.defaultCooldownSec
        triggerPolicy = try container.decodeIfPresent(WatchdogTriggerPolicy.self, forKey: .triggerPolicy) ?? .weighted
        onlyWhenWiFiMatched = try container.decodeIfPresent(Bool.self, forKey: .onlyWhenWiFiMatched) ?? false

        var decodedEndpoints = try container.decodeIfPresent([WatchdogEndpoint].self, forKey: .endpoints) ?? WatchdogEndpoint.defaultPresets
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyPollSec = try legacy.decodeIfPresent(Int.self, forKey: .pollIntervalSec)
        let legacyTimeoutSec = (try legacy.decodeIfPresent(Int.self, forKey: .checkTimeoutMs)).map { max(1, Int((Double($0) / 1000.0).rounded())) }
        if legacyPollSec != nil || legacyTimeoutSec != nil {
            for idx in decodedEndpoints.indices {
                if let legacyPollSec { decodedEndpoints[idx].intervalSec = legacyPollSec }
                if let legacyTimeoutSec { decodedEndpoints[idx].timeoutSec = legacyTimeoutSec }
            }
        }
        endpoints = decodedEndpoints.map { $0.clamped() }
    }

    public var enabledValidEndpoints: [WatchdogEndpoint] {
        endpoints.filter {
            $0.isEnabled && !$0.urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public func clamped() -> WatchdogConfig {
        var copy = self
        copy.failureWindowSec = failureWindowSec.clamped(to: Self.failureWindowRange)
        copy.recheckIntervalSec = recheckIntervalSec.clamped(to: Self.recheckIntervalRange)
        copy.postReconnectGraceSec = postReconnectGraceSec.clamped(to: Self.postReconnectGraceRange)
        copy.maxConsecutiveReconnects = maxConsecutiveReconnects.clamped(to: Self.maxConsecutiveReconnectsRange)
        copy.cooldownSec = cooldownSec.clamped(to: Self.cooldownRange)
        copy.endpoints = endpoints.map { $0.clamped() }
        return copy
    }

    /// One-time migration of persisted configs. Versions below 4 predate per-endpoint seconds and
    /// `/test/generate_204`; versions below 5 predate the sustained-failure window and still carry
    /// the old hair-trigger defaults (661313 weight 3, 3s recheck, 60s cooldown); versions below 6
    /// predate the Telegram preset; versions below 7 predate the 15s window / 180s grace / 10s timeout defaults.
    public func migratingLegacyDefaults(fromVersion version: Int) -> WatchdogConfig {
        guard version < 7 else { return clamped() }
        var copy = self
        if version < 4 {
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
                    copy.endpoints[legacyIdx].intervalSec = 15
                    copy.endpoints[legacyIdx].timeoutSec = WatchdogEndpoint.defaultTimeoutSec
                } else if !copy.endpoints.contains(where: { $0.urlString.contains("661313.xyz/test") }) {
                    copy.endpoints.insert(WatchdogEndpoint.defaultPresets[0], at: 0)
                }
            }
        }
        if version < 3, copy.triggerPolicy == .allUnreachable {
            copy.triggerPolicy = .weighted
        }
        if version < 5 {
            for idx in copy.endpoints.indices
            where copy.endpoints[idx].urlString.contains("661313.xyz/test/generate_204") && copy.endpoints[idx].weight == 3 {
                copy.endpoints[idx].weight = 1
            }
            if copy.recheckIntervalSec == 3 {
                copy.recheckIntervalSec = WatchdogConfig.defaultRecheckIntervalSec
            }
            if copy.cooldownSec == 60 {
                copy.cooldownSec = WatchdogConfig.defaultCooldownSec
            }
        }
        if version < 6 {
            let presets = WatchdogEndpoint.defaultPresets
            if copy.endpoints.map(\.urlString) == presets.dropLast().map(\.urlString) {
                copy.endpoints.append(WatchdogEndpoint.telegramPreset)
            }
        }
        if copy.failureWindowSec == 30 || copy.failureWindowSec == 60 {
            copy.failureWindowSec = WatchdogConfig.defaultFailureWindowSec
        }
        if copy.postReconnectGraceSec == 45 || copy.postReconnectGraceSec == 300 {
            copy.postReconnectGraceSec = WatchdogConfig.defaultPostReconnectGraceSec
        }
        let presetURLSet = Set(WatchdogEndpoint.defaultPresets.map(\.urlString))
        for idx in copy.endpoints.indices where presetURLSet.contains(copy.endpoints[idx].urlString) {
            if copy.endpoints[idx].timeoutSec == 3 || copy.endpoints[idx].timeoutSec == 4 {
                copy.endpoints[idx].timeoutSec = WatchdogEndpoint.defaultTimeoutSec
            }
        }
        return copy.clamped()
    }

    /// Returns a copy keeping current endpoints while restoring all strategy and timing parameters to defaults.
    public func withDefaultParameters() -> WatchdogConfig {
        WatchdogConfig(endpoints: endpoints)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
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
    case confirming(elapsedSec: Int, windowSec: Int)
    case reconnecting
    case settling(seconds: Int)
    case coolingDown(seconds: Int)
    case paused(reason: String)

    public var displayLabel: String {
        switch self {
        case .idle:
            return "未启动"
        case .monitoring:
            return "守护运行中"
        case let .confirming(elapsedSec, windowSec):
            return "异常确认中 (\(elapsedSec)/\(windowSec)s)"
        case .reconnecting:
            return "正在自动重连外网…"
        case let .settling(seconds):
            return "重连后保护期 (\(seconds)s)"
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
    /// Second consecutive failing round of an outage; emitted once until the link is healthy again.
    case probeFailureDetected(reason: String)
    case autoReconnectTriggered(reason: String)
    case autoReconnectFinished(state: WANConnectionState)
    case autoReconnectFailed(reason: String)
    case log(WatchdogLogEntry)
}

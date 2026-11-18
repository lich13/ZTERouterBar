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
    case allUnreachable
    case anyUnreachable

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .allUnreachable: "全部启用端点均不可达才重连 (推荐)"
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

    public init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        name: String = "",
        urlString: String = "",
        proxyMode: EndpointProxyMode = .system,
        proxyHost: String = "",
        proxyPort: Int = 7890,
        proxyUsername: String = "",
        proxyPassword: String = ""
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

    public static var defaultPresets: [WatchdogEndpoint] {
        [
            WatchdogEndpoint(
                isEnabled: true,
                name: "Cloudflare 204",
                urlString: "https://cp.cloudflare.com/generate_204",
                proxyMode: .system
            ),
            WatchdogEndpoint(
                isEnabled: true,
                name: "Google 204",
                urlString: "https://www.gstatic.com/generate_204",
                proxyMode: .system
            ),
            WatchdogEndpoint(
                isEnabled: true,
                name: "Apple Captive",
                urlString: "https://captive.apple.com/hotspot-detect.html",
                proxyMode: .system
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

    public init(
        autoStart: Bool = true,
        checkTimeoutMs: Int = 4000,
        pollIntervalSec: Int = 15,
        recheckBeforeAct: Int = 3,
        recheckIntervalSec: Int = 3,
        maxConsecutiveReconnects: Int = 3,
        cooldownSec: Int = 60,
        triggerPolicy: WatchdogTriggerPolicy = .allUnreachable,
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
        return copy
    }
}

public struct EndpointProbeOutcome: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let urlString: String
    public let proxyMode: EndpointProxyMode
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
    case log(WatchdogLogEntry)
}

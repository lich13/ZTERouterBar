import Foundation

public struct RouterProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var routerURLString: String
    public var wifiSSIDs: [String]
    public var hashPreference: AuthHashPreference

    public init(
        id: UUID = UUID(),
        name: String,
        routerURLString: String,
        wifiSSIDs: [String] = [],
        hashPreference: AuthHashPreference = .auto
    ) {
        self.id = id
        self.name = name
        self.routerURLString = routerURLString
        self.wifiSSIDs = wifiSSIDs
        self.hashPreference = hashPreference
    }

    public static func normalizeSSIDList(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，\n")
        var seen: Set<String> = []
        var result: [String] = []
        for piece in raw.components(separatedBy: separators) {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    public func matches(ssid: String) -> Bool {
        let target = ssid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return false }
        return wifiSSIDs.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target
        }
    }
}

public enum RouterProfileMatcher {
    public static func match(ssid: String?, in profiles: [RouterProfile]) -> RouterProfile? {
        guard let ssid else { return nil }
        let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return profiles.first { $0.matches(ssid: trimmed) }
    }
}

public enum WiFiLeaveQuitTier: Int, Comparable, Equatable, Sendable {
    /// Wi-Fi radio remains powered on while SSID briefly reads nil (AP roaming / reassociation).
    case roamGrace = 1
    /// Switched to a known unbound SSID or turned off Wi-Fi power.
    case definiteLeave = 2

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var delay: Duration {
        switch self {
        case .roamGrace: .seconds(8)
        case .definiteLeave: .milliseconds(1500)
        }
    }
}

public enum WiFiLeaveQuitAction: Equatable, Sendable {
    case none
    case cancelTimer
    case startTimer(WiFiLeaveQuitTier)
}

public struct WiFiOnlyLifecycleEvaluation: Equatable, Sendable {
    public let isSuspendedOutsideBoundWiFi: Bool
    public let timerAction: WiFiLeaveQuitAction

    public init(isSuspendedOutsideBoundWiFi: Bool, timerAction: WiFiLeaveQuitAction) {
        self.isSuspendedOutsideBoundWiFi = isSuspendedOutsideBoundWiFi
        self.timerAction = timerAction
    }
}

/// Pure state machine governing `wifiOnlyLaunch` suspension, tiered auto-quit delays, and UI deferral.
public struct WiFiOnlyLifecycleStateMachine: Equatable, Sendable {
    public static let launchedByTriggerArgument = "--launched-by-wifi-trigger"

    public private(set) var sawBoundWiFi: Bool
    public private(set) var isSuspendedOutsideBoundWiFi: Bool = false
    public private(set) var activeQuitTier: WiFiLeaveQuitTier?
    public private(set) var quitDeferredByBlockingUI: Bool = false

    public init(launchedByWiFiTrigger: Bool = false) {
        self.sawBoundWiFi = launchedByWiFiTrigger
    }

    /// Background unfocused dashboard windows must not block auto-quit; only an open menu bar popover
    /// or an actively focused dashboard window defers termination until unfocused/closed.
    public static func shouldBlockAutoQuit(
        isPopoverShown: Bool,
        isDashboardVisible: Bool,
        isAppActive: Bool
    ) -> Bool {
        isPopoverShown || (isDashboardVisible && isAppActive)
    }

    public mutating func evaluate(
        wifiOnlyLaunch: Bool,
        currentSSID: String?,
        isWiFiPoweredOn: Bool,
        isBoundWiFiMatched: Bool
    ) -> WiFiOnlyLifecycleEvaluation {
        if isBoundWiFiMatched {
            sawBoundWiFi = true
        }
        guard wifiOnlyLaunch, sawBoundWiFi, !isBoundWiFiMatched else {
            let hadTimer = (activeQuitTier != nil)
            isSuspendedOutsideBoundWiFi = false
            activeQuitTier = nil
            quitDeferredByBlockingUI = false
            return WiFiOnlyLifecycleEvaluation(
                isSuspendedOutsideBoundWiFi: false,
                timerAction: hadTimer ? .cancelTimer : .none
            )
        }

        isSuspendedOutsideBoundWiFi = true
        if quitDeferredByBlockingUI {
            return WiFiOnlyLifecycleEvaluation(isSuspendedOutsideBoundWiFi: true, timerAction: .none)
        }

        let hasUnboundSSID = !(currentSSID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let desiredTier: WiFiLeaveQuitTier = (!isWiFiPoweredOn || hasUnboundSSID) ? .definiteLeave : .roamGrace

        if let current = activeQuitTier {
            guard desiredTier > current else {
                return WiFiOnlyLifecycleEvaluation(isSuspendedOutsideBoundWiFi: true, timerAction: .none)
            }
        }
        activeQuitTier = desiredTier
        return WiFiOnlyLifecycleEvaluation(
            isSuspendedOutsideBoundWiFi: true,
            timerAction: .startTimer(desiredTier)
        )
    }

    public mutating func timerDidFire(
        wifiOnlyLaunch: Bool,
        isBoundWiFiMatched: Bool,
        isBlockingAutoQuit: Bool
    ) -> Bool {
        activeQuitTier = nil
        if isBoundWiFiMatched {
            sawBoundWiFi = true
        }
        guard wifiOnlyLaunch, sawBoundWiFi, !isBoundWiFiMatched else {
            isSuspendedOutsideBoundWiFi = false
            quitDeferredByBlockingUI = false
            return false
        }
        if isBlockingAutoQuit {
            quitDeferredByBlockingUI = true
            return false
        }
        quitDeferredByBlockingUI = false
        return true
    }

    public mutating func noteBlockingUIChanged(
        isBlockingAutoQuit: Bool,
        wifiOnlyLaunch: Bool,
        isBoundWiFiMatched: Bool
    ) -> Bool {
        if isBoundWiFiMatched {
            sawBoundWiFi = true
        }
        guard !isBlockingAutoQuit, quitDeferredByBlockingUI else {
            return false
        }
        quitDeferredByBlockingUI = false
        guard wifiOnlyLaunch, sawBoundWiFi, !isBoundWiFiMatched else {
            isSuspendedOutsideBoundWiFi = false
            return false
        }
        return true
    }
}

public enum WiFiTriggerCheckResult: Equatable, Sendable {
    case terminal(String)
    case retryWhileAssociating(String)
    case retryBriefBurst(String)
}

public enum WiFiTriggerPrecheckOutcome: Equatable, Sendable {
    case result(WiFiTriggerCheckResult)
    case readyToLaunch
}

public enum WiFiTriggerStepDecision: Equatable, Sendable {
    case finish(String)
    case scheduleNextTick
}

/// Pure deadline state machine for `--wifi-trigger` so unbound -> nil -> bound transitions and XPC bursts are deterministic.
public struct WiFiTriggerPollPolicy: Equatable, Sendable {
    public static let tickInterval: Duration = .milliseconds(300)
    public static let associationWindow: Duration = .milliseconds(4500)
    public static let briefBurstWindow: Duration = .milliseconds(1200)
    public static let hardCapWindow: Duration = .seconds(12)

    public let hardCapDeadline: ContinuousClock.Instant
    public private(set) var pollDeadline: ContinuousClock.Instant
    public private(set) var grantedAssociationWindow: Bool = false
    public private(set) var associatingSince: ContinuousClock.Instant?

    public init(startedAt now: ContinuousClock.Instant) {
        self.hardCapDeadline = now + Self.hardCapWindow
        self.pollDeadline = now
    }

    private static func normalizedSSID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func sameSSID(_ lhs: String, _ rhs: String) -> Bool {
        lhs.lowercased() == rhs.lowercased()
    }

    public static func precheck(
        wifiOnlyLaunch: Bool,
        poweredOn: Bool,
        rawSSID: String?,
        profiles: [RouterProfile],
        suppressedSSID: inout String?,
        reassociatedAfterNil: Bool = false
    ) -> WiFiTriggerPrecheckOutcome {
        guard wifiOnlyLaunch else {
            suppressedSSID = nil
            return .result(.terminal("mode disabled"))
        }

        let ssid = poweredOn ? Self.normalizedSSID(rawSSID) : nil
        let currentSuppressed = Self.normalizedSSID(suppressedSSID)
        if suppressedSSID != nil, currentSuppressed == nil {
            suppressedSSID = nil
        }

        if let currentSuppressed {
            if !poweredOn {
                suppressedSSID = nil
            } else if let ssid, !Self.sameSSID(ssid, currentSuppressed) {
                // Switched away from the Wi-Fi the user quit on; transient nil during roam waits.
                suppressedSSID = nil
            }
        }

        guard RouterProfileMatcher.match(ssid: ssid, in: profiles) != nil else {
            if !poweredOn {
                return .result(.terminal("Wi-Fi powered off, not launching"))
            }
            if ssid == nil {
                return .result(.retryWhileAssociating("no Wi-Fi name available"))
            }
            return .result(.retryBriefBurst("Wi-Fi not bound to a profile"))
        }

        if let ssid,
           let activeSuppressed = Self.normalizedSSID(suppressedSSID),
           Self.sameSSID(ssid, activeSuppressed) {
            if reassociatedAfterNil {
                return .result(.terminal("bound Wi-Fi, but user quit on it; not launching"))
            }
            // On the initial network_change event, CoreWLAN may still return the cached SSID for a few
            // hundred milliseconds before disassociation; poll briefly instead of exiting immediately.
            return .result(.retryBriefBurst("bound Wi-Fi, but user quit on it"))
        }

        return .readyToLaunch
    }

    public mutating func evaluateStep(
        wifiOnlyLaunch: Bool,
        poweredOn: Bool,
        rawSSID: String?,
        profiles: [RouterProfile],
        suppressedSSID: inout String?,
        isInitialEvent: Bool?,
        now: ContinuousClock.Instant,
        performLaunch: () -> String
    ) -> WiFiTriggerStepDecision {
        let checkResult: WiFiTriggerCheckResult
        switch Self.precheck(
            wifiOnlyLaunch: wifiOnlyLaunch,
            poweredOn: poweredOn,
            rawSSID: rawSSID,
            profiles: profiles,
            suppressedSSID: &suppressedSSID,
            reassociatedAfterNil: grantedAssociationWindow
        ) {
        case let .result(res):
            checkResult = res
        case .readyToLaunch:
            checkResult = .terminal(performLaunch())
        }

        if case .retryWhileAssociating = checkResult {
            if associatingSince == nil {
                associatingSince = now
            }
        } else {
            associatingSince = nil
        }

        let decision: WiFiTriggerStepDecision
        if let isInitial = isInitialEvent {
            decision = evaluateEvent(result: checkResult, isInitial: isInitial, now: now)
        } else {
            decision = evaluateTick(result: checkResult, now: now)
        }

        if case .retryWhileAssociating = checkResult,
           case .finish = decision,
           let since = associatingSince,
           now >= since + Self.associationWindow {
            // Finished a full association poll window still with `ssid == nil` while `poweredOn == true`:
            // confirmed disconnect rather than a transient BSSID roam (or hard-cap truncation), so lift suppression.
            suppressedSSID = nil
        }

        return decision
    }

    public mutating func evaluateEvent(
        result: WiFiTriggerCheckResult,
        isInitial: Bool,
        now: ContinuousClock.Instant
    ) -> WiFiTriggerStepDecision {
        switch result {
        case let .terminal(action):
            return .finish(action)
        case let .retryWhileAssociating(reason):
            grantedAssociationWindow = true
            let extended = now + Self.associationWindow
            pollDeadline = min(hardCapDeadline, max(pollDeadline, extended))
            return now >= pollDeadline ? .finish("\(reason), not launching") : .scheduleNextTick
        case let .retryBriefBurst(reason):
            let candidate = now + Self.briefBurstWindow
            if isInitial || candidate > pollDeadline {
                pollDeadline = min(hardCapDeadline, max(pollDeadline, candidate))
            }
            return now >= pollDeadline ? .finish("\(reason), not launching") : .scheduleNextTick
        }
    }

    public mutating func evaluateTick(
        result: WiFiTriggerCheckResult,
        now: ContinuousClock.Instant
    ) -> WiFiTriggerStepDecision {
        switch result {
        case let .terminal(action):
            return .finish(action)
        case let .retryWhileAssociating(reason):
            if !grantedAssociationWindow {
                grantedAssociationWindow = true
                let extended = now + Self.associationWindow
                pollDeadline = min(hardCapDeadline, max(pollDeadline, extended))
            }
            return now >= pollDeadline ? .finish("\(reason), not launching") : .scheduleNextTick
        case let .retryBriefBurst(reason):
            return now >= pollDeadline ? .finish("\(reason), not launching") : .scheduleNextTick
        }
    }
}

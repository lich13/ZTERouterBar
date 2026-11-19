import Foundation

public enum KeychainLoadResult: Equatable, Sendable {
    case found(String)
    case notFound
    case deferredBySystem(Int32)
    case deniedOrFailed(Int32)

    /// `CSSMERR_CSP_IN_DARK_WAKE` (`0x800108E6` as signed `OSStatus`), returned by `securityd`
    /// when an ACL authorization dialog cannot be displayed during macOS DarkWake.
    public static let cssmErrCSPInDarkWake: Int32 = -2_147_415_834
    public static let errSecInteractionNotAllowedCode: Int32 = -25_308
    public static let errSecInteractionRequiredCode: Int32 = -25_315
    public static let errSecItemNotFoundCode: Int32 = -25_300
    public static let errSecUserCanceledCode: Int32 = -128
    public static let errSecAuthFailedCode: Int32 = -25_293

    public static func classify(status: Int32, password: String?) -> KeychainLoadResult {
        if status == 0 {
            guard let password, !password.isEmpty else {
                return .notFound
            }
            return .found(password)
        }
        if status == errSecItemNotFoundCode {
            return .notFound
        }
        switch status {
        case cssmErrCSPInDarkWake, errSecInteractionNotAllowedCode, errSecInteractionRequiredCode:
            return .deferredBySystem(status)
        default:
            return .deniedOrFailed(status)
        }
    }

    public var password: String? {
        if case let .found(value) = self {
            return value
        }
        return nil
    }

    public var statusCode: Int32? {
        switch self {
        case .found, .notFound:
            return nil
        case let .deferredBySystem(code), let .deniedOrFailed(code):
            return code
        }
    }
}

public enum ProfileCredentialIssue: Equatable, Sendable {
    case deferredBySystem(status: Int32)
    case deniedOrFailed(status: Int32)

    public var statusCode: Int32 {
        switch self {
        case let .deferredBySystem(code), let .deniedOrFailed(code):
            return code
        }
    }

    public var isSystemDeferred: Bool {
        if case .deferredBySystem = self { return true }
        return false
    }
}

public struct ProfileCredentialEvaluation: Equatable, Sendable {
    public let password: String
    public let hasStoredPassword: Bool
    public let issue: ProfileCredentialIssue?

    public init(password: String, hasStoredPassword: Bool, issue: ProfileCredentialIssue?) {
        self.password = password
        self.hasStoredPassword = hasStoredPassword
        self.issue = issue
    }

    public var isCredentialReady: Bool {
        !password.isEmpty
    }
}

public struct WiFiTransitionDecision: Equatable, Sendable {
    public let shouldSelectProfileID: UUID?
    public let shouldRefreshSameProfile: Bool

    public init(shouldSelectProfileID: UUID?, shouldRefreshSameProfile: Bool) {
        self.shouldSelectProfileID = shouldSelectProfileID
        self.shouldRefreshSameProfile = shouldRefreshSameProfile
    }
}

/// Pure state machine governing Keychain access classification, GUI-only preload, retry debouncing,
/// cross-sleep watchdog suspension, and narrowly-scoped duplicate-session reclaim.
public struct ProfileCredentialStateMachine: Sendable {
    public static let guiEventDebounceDuration: Duration = .milliseconds(500)
    public static let perProfileRetryCooldownSec: TimeInterval = 3.0
    public static let wakeSSIDRejoinGraceSec: TimeInterval = 15.0

    public private(set) var unlockedCache: [UUID: String] = [:]
    public private(set) var deferredProfiles: Set<UUID> = []
    public private(set) var deniedStatus: [UUID: Int32] = [:]
    private var deferredStatus: [UUID: Int32] = [:]
    private var knownMissingProfiles: Set<UUID> = []
    public private(set) var lastKeychainAttemptAt: [UUID: Date] = [:]
    private var cooldownSuppressedUntil: [UUID: Date] = [:]

    public private(set) var hasPreloadedAllProfilesInGUI: Bool = false
    public private(set) var watchdogPausedBySystem: Bool = false
    public private(set) var needsSessionReclaim: Bool = true

    public private(set) var isSystemSleeping: Bool = false
    public private(set) var ssidBeforeSleep: String?
    public private(set) var lastObservedSSID: String?
    private var lastWakeAt: Date?

    public init(initialSSID: String? = nil) {
        self.lastObservedSSID = Self.normalizeSSID(initialSSID)
    }

    public func peekEvaluation(for id: UUID) -> ProfileCredentialEvaluation? {
        if let pw = unlockedCache[id], !pw.isEmpty {
            return ProfileCredentialEvaluation(password: pw, hasStoredPassword: true, issue: nil)
        }
        if let denied = deniedStatus[id] {
            return ProfileCredentialEvaluation(password: "", hasStoredPassword: true, issue: .deniedOrFailed(status: denied))
        }
        if let deferred = deferredStatus[id] {
            return ProfileCredentialEvaluation(password: "", hasStoredPassword: true, issue: .deferredBySystem(status: deferred))
        }
        if knownMissingProfiles.contains(id) {
            return ProfileCredentialEvaluation(password: "", hasStoredPassword: false, issue: nil)
        }
        return nil
    }

    public mutating func loadActiveProfile(
        id: UUID,
        isInteractiveGUI: Bool,
        userInitiatedRetry: Bool = false,
        now: Date = Date(),
        loader: (UUID) -> KeychainLoadResult
    ) -> (evaluation: ProfileCredentialEvaluation, diagnosticLog: String?) {
        if userInitiatedRetry {
            deniedStatus.removeValue(forKey: id)
            deferredProfiles.remove(id)
            deferredStatus.removeValue(forKey: id)
            knownMissingProfiles.remove(id)
            lastKeychainAttemptAt.removeValue(forKey: id)
        } else {
            if let cached = unlockedCache[id], !cached.isEmpty {
                return (ProfileCredentialEvaluation(password: cached, hasStoredPassword: true, issue: nil), nil)
            }
            if let denied = deniedStatus[id] {
                return (
                    ProfileCredentialEvaluation(
                        password: "",
                        hasStoredPassword: true,
                        issue: .deniedOrFailed(status: denied)
                    ),
                    nil
                )
            }
            if deferredProfiles.contains(id) {
                let savedCode = deferredStatus[id] ?? KeychainLoadResult.cssmErrCSPInDarkWake
                guard isInteractiveGUI else {
                    return (
                        ProfileCredentialEvaluation(
                            password: "",
                            hasStoredPassword: true,
                            issue: .deferredBySystem(status: savedCode)
                        ),
                        nil
                    )
                }
                if let lastAttempt = lastKeychainAttemptAt[id],
                   now.timeIntervalSince(lastAttempt) < Self.perProfileRetryCooldownSec {
                    cooldownSuppressedUntil[id] = lastAttempt.addingTimeInterval(Self.perProfileRetryCooldownSec)
                    return (
                        ProfileCredentialEvaluation(
                            password: "",
                            hasStoredPassword: true,
                            issue: .deferredBySystem(status: savedCode)
                        ),
                        nil
                    )
                }
            }
        }

        cooldownSuppressedUntil.removeValue(forKey: id)
        lastKeychainAttemptAt[id] = now
        let result = loader(id)
        switch result {
        case let .found(password):
            unlockedCache[id] = password
            deferredProfiles.remove(id)
            deferredStatus.removeValue(forKey: id)
            deniedStatus.removeValue(forKey: id)
            knownMissingProfiles.remove(id)
            return (ProfileCredentialEvaluation(password: password, hasStoredPassword: true, issue: nil), nil)

        case .notFound:
            unlockedCache.removeValue(forKey: id)
            deferredProfiles.remove(id)
            deferredStatus.removeValue(forKey: id)
            deniedStatus.removeValue(forKey: id)
            knownMissingProfiles.insert(id)
            return (ProfileCredentialEvaluation(password: "", hasStoredPassword: false, issue: nil), nil)

        case let .deferredBySystem(code):
            unlockedCache.removeValue(forKey: id)
            deferredProfiles.insert(id)
            deferredStatus[id] = code
            deniedStatus.removeValue(forKey: id)
            knownMissingProfiles.remove(id)
            return (
                ProfileCredentialEvaluation(
                    password: "",
                    hasStoredPassword: true,
                    issue: .deferredBySystem(status: code)
                ),
                "钥匙串读取受限 (status=\(code))"
            )

        case let .deniedOrFailed(code):
            unlockedCache.removeValue(forKey: id)
            deferredProfiles.remove(id)
            deferredStatus.removeValue(forKey: id)
            deniedStatus[id] = code
            knownMissingProfiles.remove(id)
            return (
                ProfileCredentialEvaluation(
                    password: "",
                    hasStoredPassword: true,
                    issue: .deniedOrFailed(status: code)
                ),
                "钥匙串读取未获授权或失败 (status=\(code))"
            )
        }
    }

    /// Preloads all saved profiles into `unlockedCache` once an interactive GUI session is active.
    /// Never auto-retries profiles in `deniedStatus`.
    public mutating func preloadAllProfilesIfNeeded(
        profileIDs: [UUID],
        isInteractiveGUI: Bool,
        forceDeferredRetry: Bool = false,
        now: Date = Date(),
        loader: (UUID) -> KeychainLoadResult
    ) -> [(profileID: UUID, diagnosticLog: String)] {
        guard isInteractiveGUI else { return [] }
        if hasPreloadedAllProfilesInGUI && deferredProfiles.isEmpty {
            return []
        }

        var diagnostics: [(UUID, String)] = []
        for id in profileIDs {
            if let cached = unlockedCache[id], !cached.isEmpty {
                continue
            }
            if deniedStatus[id] != nil {
                continue
            }
            if knownMissingProfiles.contains(id) {
                continue
            }
            if deferredProfiles.contains(id) && forceDeferredRetry {
                lastKeychainAttemptAt.removeValue(forKey: id)
            }
            let (_, diag) = loadActiveProfile(
                id: id,
                isInteractiveGUI: true,
                userInitiatedRetry: false,
                now: now,
                loader: loader
            )
            if let diag {
                diagnostics.append((id, diag))
            }
        }

        hasPreloadedAllProfilesInGUI = deferredProfiles.isEmpty
        return diagnostics
    }

    public mutating func storeUnlockedPassword(_ password: String, for id: UUID) {
        unlockedCache[id] = password
        deferredProfiles.remove(id)
        deferredStatus.removeValue(forKey: id)
        deniedStatus.removeValue(forKey: id)
        knownMissingProfiles.remove(id)
        cooldownSuppressedUntil.removeValue(forKey: id)
    }

    public mutating func removePassword(for id: UUID) {
        unlockedCache.removeValue(forKey: id)
        deferredProfiles.remove(id)
        deferredStatus.removeValue(forKey: id)
        deniedStatus.removeValue(forKey: id)
        knownMissingProfiles.insert(id)
        cooldownSuppressedUntil.removeValue(forKey: id)
    }

    public mutating func purgeProfile(id: UUID) {
        unlockedCache.removeValue(forKey: id)
        deferredProfiles.remove(id)
        deferredStatus.removeValue(forKey: id)
        deniedStatus.removeValue(forKey: id)
        knownMissingProfiles.remove(id)
        lastKeychainAttemptAt.removeValue(forKey: id)
        cooldownSuppressedUntil.removeValue(forKey: id)
    }

    /// Returns the shortest remaining delay when an interactive GUI retry was skipped solely due to
    /// `perProfileRetryCooldownSec` from an earlier (e.g. DarkWake) attempt. Returns `nil` once `loader`
    /// has actually executed so failed GUI reads never loop.
    public func nextCooldownRetryDelaySec(now: Date = Date()) -> TimeInterval? {
        let pending = deferredProfiles.compactMap { id -> TimeInterval? in
            guard deniedStatus[id] == nil, unlockedCache[id] == nil, let until = cooldownSuppressedUntil[id] else {
                return nil
            }
            return max(0.05, until.timeIntervalSince(now))
        }
        return pending.min()
    }

    // MARK: - Watchdog Pause / Resume

    public mutating func noteWatchdogPausedForDeferredCredential(
        wasRunning: Bool,
        autoStart: Bool,
        userStoppedWatchdog: Bool
    ) {
        if wasRunning || watchdogPausedBySystem || (autoStart && !userStoppedWatchdog) {
            watchdogPausedBySystem = true
        }
    }

    public mutating func noteWatchdogStarted() {
        watchdogPausedBySystem = false
    }

    public mutating func noteUserStoppedWatchdog() {
        watchdogPausedBySystem = false
    }

    public func shouldResumeWatchdog(
        isCredentialReady: Bool,
        isWatchdogRunning: Bool,
        autoStart: Bool,
        userStoppedWatchdog: Bool
    ) -> Bool {
        guard isCredentialReady, !isWatchdogRunning, !isSystemSleeping else {
            return false
        }
        return watchdogPausedBySystem || (autoStart && !userStoppedWatchdog)
    }

    // MARK: - Sleep / Wake & Session Reclaim

    public mutating func noteSystemWillSleep(currentSSID: String?, isWatchdogRunning: Bool) {
        isSystemSleeping = true
        ssidBeforeSleep = Self.normalizeSSID(currentSSID) ?? lastObservedSSID
        if isWatchdogRunning {
            watchdogPausedBySystem = true
        }
    }

    public mutating func noteSystemDidWake(currentSSID: String?, now: Date = Date()) {
        isSystemSleeping = false
        lastWakeAt = now
        if let normalized = Self.normalizeSSID(currentSSID), normalized == ssidBeforeSleep {
            ssidBeforeSleep = nil
            lastObservedSSID = normalized
        }
    }

    public mutating func noteProfileSelected() {
        needsSessionReclaim = true
    }

    public mutating func noteSSIDChanged(
        _ newSSID: String?,
        matchedProfileID: UUID?,
        activeProfileID: UUID,
        autoMatchEnabled: Bool,
        now: Date = Date()
    ) -> WiFiTransitionDecision {
        let normalizedNew = Self.normalizeSSID(newSSID)
        let previousSSID = lastObservedSSID
        lastObservedSSID = normalizedNew

        guard let normalizedNew else {
            return WiFiTransitionDecision(shouldSelectProfileID: nil, shouldRefreshSameProfile: false)
        }

        let isWakeSameSSIDRejoin: Bool = {
            guard let preSleep = ssidBeforeSleep else { return false }
            let withinWakeGrace = isSystemSleeping
                || (lastWakeAt.map { now.timeIntervalSince($0) <= Self.wakeSSIDRejoinGraceSec } ?? false)
            return withinWakeGrace && normalizedNew == preSleep
        }()
        ssidBeforeSleep = nil

        guard autoMatchEnabled, let matchedProfileID else {
            return WiFiTransitionDecision(shouldSelectProfileID: nil, shouldRefreshSameProfile: false)
        }

        if matchedProfileID != activeProfileID {
            needsSessionReclaim = true
            return WiFiTransitionDecision(shouldSelectProfileID: matchedProfileID, shouldRefreshSameProfile: false)
        }

        let ssidActuallyChanged = (normalizedNew != previousSSID)
        if ssidActuallyChanged && !isWakeSameSSIDRejoin {
            needsSessionReclaim = true
        }
        return WiFiTransitionDecision(
            shouldSelectProfileID: nil,
            shouldRefreshSameProfile: ssidActuallyChanged
        )
    }

    public func effectiveReclaimFlag(silentPoll: Bool) -> Bool {
        silentPoll ? needsSessionReclaim : true
    }

    /// Clears `needsSessionReclaim` once an HTTP round-trip reaches the router (success or router-level error).
    /// Preserves `needsSessionReclaim` on `.transportError` when DHCP/routing is not ready yet.
    public mutating func noteRouterInteractionResult(error: ZTERouterError?) {
        if let error, case .transportError = error {
            return
        }
        needsSessionReclaim = false
    }

    private static func normalizeSSID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }
}

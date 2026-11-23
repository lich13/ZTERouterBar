import AppKit
import CoreWLAN
import Foundation
import os
import XPC
import ZTERouterCore

/// "Launch only on a bound Wi-Fi": a per-user launchd agent that launchd starts on demand whenever the
/// network configuration changes. It runs this same executable with `--wifi-trigger`, which checks the
/// current Wi-Fi against the saved profiles, opens the app on a match, and exits. Nothing stays resident.
enum WiFiLaunchAgent {
    static let label = "com.zte.routerbar.wifi-trigger"
    static let triggerArgument = "--wifi-trigger"
    static let launchedByTriggerArgument = WiFiOnlyLifecycleStateMachine.launchedByTriggerArgument

    private static let eventStream = "com.apple.notifyd.matching"
    private static let networkChangeNotification = "com.apple.system.config.network_change"
    private static let logger = Logger(subsystem: "com.zte.routerbar", category: "wifi-trigger")

    enum AgentError: LocalizedError {
        case notRunningFromAppBundle
        case bootstrapFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .notRunningFromAppBundle: "需要通过 .app 应用包运行"
            case let .bootstrapFailed(status): "launchctl bootstrap 返回 \(status)"
            }
        }
    }

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var serviceTarget: String { "gui/\(getuid())/\(label)" }

    private static func expectedPlist(executablePath: String, bundleIdentifier: String) -> NSDictionary {
        [
            "Label": label,
            "ProgramArguments": [executablePath, triggerArgument],
            "RunAtLoad": true,
            "ThrottleInterval": 1,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "AssociatedBundleIdentifiers": [bundleIdentifier],
            "LaunchEvents": [
                eventStream: ["network-change": ["Notification": networkChangeNotification]]
            ]
        ]
    }

    // MARK: - Registration (called from the running app)

    static func install() throws {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let executablePath = Bundle.main.executablePath else {
            throw AgentError.notRunningFromAppBundle
        }
        let plist = expectedPlist(
            executablePath: executablePath,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.zte.routerbar"
        )
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)

        var status = launchctl("bootstrap", "gui/\(getuid())", plistURL.path)
        if status != 0 {
            // Already loaded (possibly from an older path): replace it. `bootout` returns before the
            // old instance is fully gone, so give `bootstrap` a few short retries.
            launchctl("bootout", serviceTarget)
            for _ in 0..<5 where status != 0 {
                usleep(300_000)
                status = launchctl("bootstrap", "gui/\(getuid())", plistURL.path)
            }
        }
        guard status == 0 else { throw AgentError.bootstrapFailed(status) }
    }

    static func uninstall() {
        launchctl("bootout", serviceTarget)
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// Re-registers when the plist is missing, outdated, points at another copy of the app, or is not loaded.
    static func syncIfNeeded() {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let executablePath = Bundle.main.executablePath else {
            return
        }
        let expected = expectedPlist(
            executablePath: executablePath,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.zte.routerbar"
        )
        if let existing = NSDictionary(contentsOf: plistURL),
           existing.isEqual(expected),
           launchctl("print", serviceTarget) == 0 {
            return
        }
        do {
            try install()
        } catch {
            logger.error("agent sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    private static func launchctl(_ arguments: String...) -> Int32 {
        run("/bin/launchctl", arguments)
    }

    fileprivate static func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Manual-quit suppression

    /// Remembers the Wi-Fi the user quit on, so the trigger does not bring the app straight back.
    static func suppressLaunch(onSSID ssid: String) {
        let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: SettingsKeys.wifiLaunchSuppressedSSID)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    static func clearSuppression() {
        guard UserDefaults.standard.object(forKey: SettingsKeys.wifiLaunchSuppressedSSID) != nil else { return }
        UserDefaults.standard.removeObject(forKey: SettingsKeys.wifiLaunchSuppressedSSID)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    // MARK: - Trigger process (launchd job; never starts AppKit)

    static func runTrigger() -> Never {
        // A private queue, not `.main`: under `dispatchMain()` the main queue is not drained on the
        // main thread, which trips Swift's main-actor checks for closures sent to it.
        let queue = DispatchQueue(label: label)
        let coordinator = TriggerCoordinator(queue: queue)
        // launchd requires jobs with LaunchEvents to check in, or it keeps relaunching them;
        // any follow-up `network_change` event delivered while alive extends the poll window so it is never lost.
        xpc_set_event_stream_handler(eventStream, queue) { _ in
            coordinator.handleEvent(isInitial: false)
        }
        queue.async {
            coordinator.handleEvent(isInitial: true)
        }
        dispatchMain()
    }

    fileprivate static func evaluateStep(
        policy: inout WiFiTriggerPollPolicy,
        isInitialEvent: Bool?,
        now: ContinuousClock.Instant = ContinuousClock.now
    ) -> WiFiTriggerStepDecision {
        let defaults = UserDefaults.standard
        let iface = CWWiFiClient.shared().interface()
        let poweredOn = iface?.powerOn() ?? false
        let rawSSID = iface?.ssid()
        let profiles = defaults.data(forKey: SettingsKeys.profiles)
            .flatMap { try? JSONDecoder().decode([RouterProfile].self, from: $0) } ?? []

        let previousSuppressed = defaults.string(forKey: SettingsKeys.wifiLaunchSuppressedSSID)
        var updatedSuppressed = previousSuppressed

        let decision = policy.evaluateStep(
            wifiOnlyLaunch: defaults.bool(forKey: SettingsKeys.wifiOnlyLaunch),
            poweredOn: poweredOn,
            rawSSID: rawSSID,
            profiles: profiles,
            suppressedSSID: &updatedSuppressed,
            isInitialEvent: isInitialEvent,
            now: now,
            performLaunch: {
                let bundleID = Bundle.main.bundleIdentifier ?? "com.zte.routerbar"
                if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .contains(where: { $0.processIdentifier != getpid() }) {
                    // `open` on a running app would send a reopen event and pop the dashboard.
                    return "bound Wi-Fi, app already running"
                }
                let status = run("/usr/bin/open", ["-g", Bundle.main.bundleURL.path, "--args", launchedByTriggerArgument])
                return status == 0 ? "bound Wi-Fi, launched app" : "bound Wi-Fi, open failed (\(status))"
            }
        )

        if updatedSuppressed != previousSuppressed {
            if let updatedSuppressed {
                defaults.set(updatedSuppressed, forKey: SettingsKeys.wifiLaunchSuppressedSSID)
            } else {
                defaults.removeObject(forKey: SettingsKeys.wifiLaunchSuppressedSSID)
            }
        }

        return decision
    }
}

private final class TriggerCoordinator: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.zte.routerbar", category: "wifi-trigger")
    private let queue: DispatchQueue
    private var policy: WiFiTriggerPollPolicy
    private var timerScheduled = false

    init(queue: DispatchQueue) {
        self.queue = queue
        self.policy = WiFiTriggerPollPolicy(startedAt: ContinuousClock.now)
    }

    func handleEvent(isInitial: Bool) {
        let decision = WiFiLaunchAgent.evaluateStep(
            policy: &policy,
            isInitialEvent: isInitial
        )
        apply(decision)
    }

    private func scheduleTickIfNeeded() {
        guard !timerScheduled else { return }
        timerScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [self] in
            timerScheduled = false
            let decision = WiFiLaunchAgent.evaluateStep(
                policy: &policy,
                isInitialEvent: nil
            )
            apply(decision)
        }
    }

    private func apply(_ decision: WiFiTriggerStepDecision) {
        switch decision {
        case let .finish(action):
            finish(action)
        case .scheduleNextTick:
            scheduleTickIfNeeded()
        }
    }

    private func finish(_ action: String) -> Never {
        Self.logger.notice("wifi-trigger: \(action, privacy: .public)")
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        exit(0)
    }
}

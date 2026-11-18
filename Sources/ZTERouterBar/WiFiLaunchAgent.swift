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

    // MARK: - Registration (called from the running app)

    static func install() throws {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let executablePath = Bundle.main.executablePath else {
            throw AgentError.notRunningFromAppBundle
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath, triggerArgument],
            "RunAtLoad": true,
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua",
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "com.zte.routerbar"],
            "LaunchEvents": [
                eventStream: ["network-change": ["Notification": networkChangeNotification]]
            ]
        ]
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

    /// Re-registers when the plist is missing, points at another copy of the app, or is not loaded.
    static func syncIfNeeded() {
        let registeredPath = (NSDictionary(contentsOf: plistURL)?["ProgramArguments"] as? [String])?.first
        if registeredPath == Bundle.main.executablePath, launchctl("print", serviceTarget) == 0 {
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

    private static func run(_ executable: String, _ arguments: [String]) -> Int32 {
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
        UserDefaults.standard.set(ssid, forKey: SettingsKeys.wifiLaunchSuppressedSSID)
    }

    static func clearSuppression() {
        UserDefaults.standard.removeObject(forKey: SettingsKeys.wifiLaunchSuppressedSSID)
    }

    // MARK: - Trigger process (launchd job; never starts AppKit)

    static func runTrigger() -> Never {
        // A private queue, not `.main`: under `dispatchMain()` the main queue is not drained on the
        // main thread, which trips Swift's main-actor checks for closures sent to it.
        let queue = DispatchQueue(label: label)
        // launchd requires jobs with LaunchEvents to check in, or it keeps relaunching them.
        xpc_set_event_stream_handler(eventStream, queue) { _ in }
        // Network changes arrive in bursts while Wi-Fi is still associating; let it settle.
        queue.asyncAfter(deadline: .now() + 1.0) {
            let action = decideAndLaunch()
            logger.notice("wifi-trigger: \(action, privacy: .public)")
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            exit(0)
        }
        dispatchMain()
    }

    private static func decideAndLaunch() -> String {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKeys.wifiOnlyLaunch) else { return "mode disabled" }

        let rawSSID = CWWiFiClient.shared().interface()?.ssid()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ssid = (rawSSID?.isEmpty == false) ? rawSSID : nil

        let suppressedSSID = defaults.string(forKey: SettingsKeys.wifiLaunchSuppressedSSID)
        if let suppressedSSID, suppressedSSID != ssid {
            // Left (or switched away from) the Wi-Fi the user quit on: the next join launches again.
            defaults.removeObject(forKey: SettingsKeys.wifiLaunchSuppressedSSID)
        }

        let profiles = defaults.data(forKey: SettingsKeys.profiles)
            .flatMap { try? JSONDecoder().decode([RouterProfile].self, from: $0) } ?? []
        guard RouterProfileMatcher.match(ssid: ssid, in: profiles) != nil else {
            return ssid == nil ? "no Wi-Fi name available, not launching" : "Wi-Fi not bound to a profile, not launching"
        }
        if suppressedSSID == ssid {
            return "bound Wi-Fi, but user quit on it; not launching"
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.zte.routerbar"
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains(where: { $0.processIdentifier != getpid() }) {
            // `open` on a running app would send a reopen event and pop the dashboard.
            return "bound Wi-Fi, app already running"
        }
        let status = run("/usr/bin/open", ["-g", Bundle.main.bundleURL.path])
        return status == 0 ? "bound Wi-Fi, launched app" : "bound Wi-Fi, open failed (\(status))"
    }
}

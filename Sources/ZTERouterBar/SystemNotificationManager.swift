import AppKit
import Foundation
import UserNotifications
import ZTERouterCore

@MainActor
protocol UserNotificationSending: AnyObject {
    var authorizationStatus: UNAuthorizationStatus { get }
    func configureAndRequestAuthorization() async
    func refreshAuthorizationStatus() async
    func notifyProbeFailure(profileName: String, reason: String, willAutoReconnect: Bool)
    func notifyAutoReconnectTriggered(profileName: String, reason: String, currentIP: WANIPSnapshot)
    func notifyReconnectIPChange(
        isAutomatic: Bool,
        profileName: String,
        state: WANConnectionState,
        before: WANIPSnapshot,
        after: WANIPSnapshot
    )
}

@MainActor
@Observable
final class SystemNotificationManager: NSObject, UserNotificationSending, UNUserNotificationCenterDelegate {
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let canUseCenter: Bool
    private var didConfigureDelegate = false

    override init() {
        self.canUseCenter = (
            Bundle.main.bundleURL.pathExtension == "app"
                && Bundle.main.bundleIdentifier != nil
        )
        super.init()
    }

    func configureAndRequestAuthorization() async {
        guard canUseCenter else { return }
        ensureDelegate()
        let center = UNUserNotificationCenter.current()
        let status = await Self.fetchAuthorizationStatus()
        authorizationStatus = status
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            authorizationStatus = await Self.fetchAuthorizationStatus()
        }
    }

    func refreshAuthorizationStatus() async {
        guard canUseCenter else { return }
        authorizationStatus = await Self.fetchAuthorizationStatus()
    }

    /// Reads `authorizationStatus` inside the callback so non-`Sendable` `UNNotificationSettings`
    /// never crosses concurrency domains on Xcode 16 / macOS 15 SDKs.
    private nonisolated static func fetchAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func notifyProbeFailure(profileName: String, reason: String, willAutoReconnect: Bool) {
        let followUp = willAutoReconnect ? "持续异常将自动重连。" : "自动重连未开启，可手动重连。"
        deliver(
            identifierPrefix: "zte.probe.fail",
            title: "ZTERouterBar · 外网探测不通",
            body: "路由器「\(profileName)」\(reason)。\(followUp)"
        )
    }

    func notifyAutoReconnectTriggered(profileName: String, reason: String, currentIP: WANIPSnapshot) {
        let title = "ZTERouterBar · 正在自动重连外网"
        var lines: [String] = ["路由器「\(profileName)」\(reason)，已触发重新拨号。"]
        if !currentIP.ipv4.isEmpty {
            lines.append("当前 IPv4：\(currentIP.ipv4)")
        }
        if !currentIP.ipv6.isEmpty {
            lines.append("当前 IPv6：\(currentIP.ipv6)")
        }
        deliver(identifierPrefix: "zte.auto.trigger", title: title, body: lines.joined(separator: "\n"))
    }

    func notifyReconnectIPChange(
        isAutomatic: Bool,
        profileName: String,
        state: WANConnectionState,
        before: WANIPSnapshot,
        after: WANIPSnapshot
    ) {
        let formatted = WANIPChangeFormatter.formatNotificationMessage(
            isAutomatic: isAutomatic,
            profileName: profileName,
            state: state,
            before: before,
            after: after
        )
        deliver(
            identifierPrefix: isAutomatic ? "zte.auto.ip" : "zte.manual.ip",
            title: formatted.title,
            body: formatted.body
        )
    }

    private func ensureDelegate() {
        guard !didConfigureDelegate else { return }
        UNUserNotificationCenter.current().delegate = self
        didConfigureDelegate = true
    }

    private func deliver(identifierPrefix: String, title: String, body: String) {
        guard canUseCenter else { return }
        ensureDelegate()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(identifierPrefix).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // Ensure banners are presented even when Dashboard/Settings window is active in foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

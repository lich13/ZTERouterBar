import Foundation
import os
import Security
import ZTERouterCore

public enum MenuBarDisplayStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case iconOnly
    case iconAndSignal
    case iconAndBand

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .iconOnly: "仅图标"
        case .iconAndSignal: "图标 + 信号强度"
        case .iconAndBand: "图标 + 制式/频段"
        }
    }
}

/// `UserDefaults` keys. Shared with the Wi-Fi launch trigger, which reads them without building a `SettingsStore`.
enum SettingsKeys {
    static let profiles = "zte.router.profiles.v1"
    static let activeProfileID = "zte.router.activeProfileID"
    static let autoMatchByWiFi = "zte.router.autoMatchByWiFi"
    static let pollingInterval = "zte.router.pollingInterval"
    static let menuBarDisplayStyle = "zte.router.menuBarDisplayStyle"
    static let globalShortcutEnabled = "zte.router.globalShortcutEnabled"
    static let systemNotificationsEnabled = "zte.router.systemNotificationsEnabled"
    static let watchdogConfig = "zte.router.watchdogConfig.v1"
    static let watchdogDefaultsVersion = "zte.router.watchdogDefaultsVersion"
    static let wifiOnlyLaunch = "zte.router.wifiOnlyLaunch"
    static let wifiLaunchSuppressedSSID = "zte.router.wifiLaunchSuppressedSSID"
}

@MainActor
@Observable
final class SettingsStore {
    private typealias Keys = SettingsKeys

    private static let currentWatchdogDefaultsVersion = 6

    var profiles: [RouterProfile] {
        didSet { saveProfiles() }
    }

    var activeProfileID: UUID {
        didSet { defaults.set(activeProfileID.uuidString, forKey: Keys.activeProfileID) }
    }

    var autoMatchByWiFi: Bool {
        didSet { defaults.set(autoMatchByWiFi, forKey: Keys.autoMatchByWiFi) }
    }

    var pollingInterval: Double {
        didSet { defaults.set(pollingInterval, forKey: Keys.pollingInterval) }
    }

    var menuBarDisplayStyleRaw: String {
        didSet { defaults.set(menuBarDisplayStyleRaw, forKey: Keys.menuBarDisplayStyle) }
    }

    var globalShortcutEnabled: Bool {
        didSet { defaults.set(globalShortcutEnabled, forKey: Keys.globalShortcutEnabled) }
    }

    var systemNotificationsEnabled: Bool {
        didSet { defaults.set(systemNotificationsEnabled, forKey: Keys.systemNotificationsEnabled) }
    }

    var watchdogConfig: WatchdogConfig {
        didSet { saveWatchdogConfig() }
    }

    /// Launch only while connected to a Wi-Fi bound to a profile; see `WiFiLaunchAgent`.
    var wifiOnlyLaunch: Bool {
        didSet { defaults.set(wifiOnlyLaunch, forKey: Keys.wifiOnlyLaunch) }
    }

    var menuBarDisplayStyle: MenuBarDisplayStyle {
        get { MenuBarDisplayStyle(rawValue: menuBarDisplayStyleRaw) ?? .iconAndSignal }
        set { menuBarDisplayStyleRaw = newValue.rawValue }
    }

    var activeProfile: RouterProfile {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles[0]
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let loadedProfiles: [RouterProfile]
        var needsProfileSave = false
        if let data = defaults.data(forKey: Keys.profiles),
           let decoded = try? JSONDecoder().decode([RouterProfile].self, from: data),
           !decoded.isEmpty {
            loadedProfiles = decoded
        } else {
            needsProfileSave = true
            loadedProfiles = [
                RouterProfile(
                    id: UUID(),
                    name: "默认路由器",
                    routerURLString: "http://192.168.8.1"
                )
            ]
        }
        self.profiles = loadedProfiles

        if let savedIDString = defaults.string(forKey: Keys.activeProfileID),
           let savedID = UUID(uuidString: savedIDString),
           loadedProfiles.contains(where: { $0.id == savedID }) {
            self.activeProfileID = savedID
        } else {
            self.activeProfileID = loadedProfiles[0].id
        }

        self.autoMatchByWiFi = defaults.object(forKey: Keys.autoMatchByWiFi) as? Bool ?? true
        let savedInterval = defaults.double(forKey: Keys.pollingInterval)
        self.pollingInterval = savedInterval > 0 ? savedInterval : 3.0

        let storedStyleRaw = defaults.string(forKey: Keys.menuBarDisplayStyle) ?? ""
        if let validStyle = MenuBarDisplayStyle(rawValue: storedStyleRaw) {
            self.menuBarDisplayStyleRaw = validStyle.rawValue
        } else {
            // Migrate retired `iconAndSpeed` or missing style to signal strength.
            self.menuBarDisplayStyleRaw = MenuBarDisplayStyle.iconAndSignal.rawValue
        }

        self.globalShortcutEnabled = defaults.object(forKey: Keys.globalShortcutEnabled) as? Bool ?? true
        self.systemNotificationsEnabled = defaults.object(forKey: Keys.systemNotificationsEnabled) as? Bool ?? true
        self.wifiOnlyLaunch = defaults.bool(forKey: Keys.wifiOnlyLaunch)

        let savedVersion = defaults.integer(forKey: Keys.watchdogDefaultsVersion)
        if let wdData = defaults.data(forKey: Keys.watchdogConfig),
           let decodedWD = try? JSONDecoder().decode(WatchdogConfig.self, from: wdData) {
            self.watchdogConfig = savedVersion < Self.currentWatchdogDefaultsVersion
                ? decodedWD.migratingLegacyDefaults(fromVersion: savedVersion)
                : decodedWD.clamped()
        } else {
            self.watchdogConfig = WatchdogConfig()
        }

        if savedVersion < 4 {
            KeychainPasswordStore.purgeRetiredProxyPasswords()
            defaults.removeObject(forKey: "zte.router.url")
            defaults.removeObject(forKey: "zte.router.hashPreference")
        }

        // Write back only what this launch actually changed.
        if savedVersion < Self.currentWatchdogDefaultsVersion {
            saveWatchdogConfig()
            defaults.set(Self.currentWatchdogDefaultsVersion, forKey: Keys.watchdogDefaultsVersion)
        }
        if needsProfileSave {
            saveProfiles()
        }
        if defaults.string(forKey: Keys.activeProfileID) != activeProfileID.uuidString {
            defaults.set(activeProfileID.uuidString, forKey: Keys.activeProfileID)
        }
    }

    func updateProfile(_ profile: RouterProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
    }

    @discardableResult
    func addNewProfile(suggestedSSID: String? = nil) -> RouterProfile {
        let index = profiles.count + 1
        let ssids = suggestedSSID.map { [$0] } ?? []
        let name = suggestedSSID.map { "路由器 (\($0))" } ?? "路由器配置 \(index)"
        let profile = RouterProfile(
            id: UUID(),
            name: name,
            routerURLString: "http://192.168.8.1",
            wifiSSIDs: ssids,
            hashPreference: .auto
        )
        profiles.append(profile)
        activeProfileID = profile.id
        return profile
    }

    func deleteProfile(id: UUID) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        KeychainPasswordStore.deletePassword(forProfileID: id)
        if activeProfileID == id, let first = profiles.first {
            activeProfileID = first.id
        }
    }

    private func saveProfiles() {
        if let encoded = try? JSONEncoder().encode(profiles) {
            defaults.set(encoded, forKey: Keys.profiles)
        }
    }

    private func saveWatchdogConfig() {
        if let encoded = try? JSONEncoder().encode(watchdogConfig.clamped()) {
            defaults.set(encoded, forKey: Keys.watchdogConfig)
        }
    }
}

enum KeychainPasswordStore {
    private static let profileService = "com.zte.routerbar.profile"
    private static let retiredProxyService = "com.zte.routerbar.watchdogProxy"
    private static let logger = Logger(subsystem: "com.zte.routerbar", category: "keychain")

    static func loadPasswordResult(forProfileID id: UUID) -> KeychainLoadResult {
        loadResult(service: profileService, account: id.uuidString)
    }

    static func loadPassword(forProfileID id: UUID) -> String? {
        loadPasswordResult(forProfileID: id).password
    }

    @discardableResult
    static func savePassword(_ password: String, forProfileID id: UUID) -> OSStatus {
        save(password, service: profileService, account: id.uuidString)
    }

    @discardableResult
    static func deletePassword(forProfileID id: UUID) -> OSStatus {
        delete(service: profileService, account: id.uuidString)
    }

    static func purgeRetiredProxyPasswords() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: retiredProxyService
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func loadResult(service: String, account: String) -> KeychainLoadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.warning("Keychain read returned status=\(status, privacy: .public) for profile=\(account, privacy: .public)")
        }
        let password: String? = (status == errSecSuccess)
            ? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
            : nil
        return KeychainLoadResult.classify(status: status, password: password)
    }

    private static func save(_ password: String, service: String, account: String) -> OSStatus {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            return SecItemAdd(newItem as CFDictionary, nil)
        }
        return updateStatus
    }

    private static func delete(service: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary)
    }
}

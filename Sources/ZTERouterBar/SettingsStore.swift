import Foundation
import Security
import ZTERouterCore

public enum MenuBarDisplayStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case iconOnly
    case iconAndBand
    case iconAndSpeed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .iconOnly: "仅图标"
        case .iconAndBand: "图标 + 制式/频段"
        case .iconAndSpeed: "图标 + 实时网速"
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    private enum Keys {
        static let profiles = "zte.router.profiles.v1"
        static let activeProfileID = "zte.router.activeProfileID"
        static let autoMatchByWiFi = "zte.router.autoMatchByWiFi"
        static let pollingInterval = "zte.router.pollingInterval"
        static let menuBarDisplayStyle = "zte.router.menuBarDisplayStyle"
        static let globalShortcutEnabled = "zte.router.globalShortcutEnabled"
        static let watchdogConfig = "zte.router.watchdogConfig.v1"
        // Legacy single-profile keys for migration
        static let legacyRouterURL = "zte.router.url"
        static let legacyHashPreference = "zte.router.hashPreference"
    }

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

    var watchdogConfig: WatchdogConfig {
        didSet { saveWatchdogConfig() }
    }

    var menuBarDisplayStyle: MenuBarDisplayStyle {
        get { MenuBarDisplayStyle(rawValue: menuBarDisplayStyleRaw) ?? .iconAndBand }
        set { menuBarDisplayStyleRaw = newValue.rawValue }
    }

    var activeProfile: RouterProfile {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles[0]
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        var loadedProfiles: [RouterProfile] = []
        if let data = defaults.data(forKey: Keys.profiles),
           let decoded = try? JSONDecoder().decode([RouterProfile].self, from: data),
           !decoded.isEmpty {
            loadedProfiles = decoded
        } else {
            let legacyURL = defaults.string(forKey: Keys.legacyRouterURL) ?? "http://192.168.8.1"
            let legacyHash = AuthHashPreference(rawValue: defaults.string(forKey: Keys.legacyHashPreference) ?? "") ?? .auto
            let defaultProfile = RouterProfile(
                id: UUID(),
                name: "默认路由器",
                routerURLString: legacyURL,
                wifiSSIDs: [],
                hashPreference: legacyHash
            )
            loadedProfiles = [defaultProfile]
            if let oldPassword = KeychainPasswordStore.loadLegacyPassword(for: legacyURL), !oldPassword.isEmpty {
                KeychainPasswordStore.savePassword(oldPassword, forProfileID: defaultProfile.id)
            }
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
        self.menuBarDisplayStyleRaw = defaults.string(forKey: Keys.menuBarDisplayStyle) ?? MenuBarDisplayStyle.iconAndBand.rawValue
        self.globalShortcutEnabled = defaults.object(forKey: Keys.globalShortcutEnabled) as? Bool ?? true

        if let wdData = defaults.data(forKey: Keys.watchdogConfig),
           var decodedWD = try? JSONDecoder().decode(WatchdogConfig.self, from: wdData) {
            for idx in decodedWD.endpoints.indices {
                let id = decodedWD.endpoints[idx].id
                if let proxyPass = KeychainPasswordStore.loadProxyPassword(forEndpointID: id) {
                    decodedWD.endpoints[idx].proxyPassword = proxyPass
                }
            }
            self.watchdogConfig = decodedWD.clamped()
        } else {
            self.watchdogConfig = WatchdogConfig()
        }

        saveProfiles()
        saveWatchdogConfig()
        defaults.set(activeProfileID.uuidString, forKey: Keys.activeProfileID)
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
        // Store optional proxy passwords in Keychain rather than UserDefaults plist.
        var sanitized = watchdogConfig.clamped()
        for idx in sanitized.endpoints.indices {
            let ep = sanitized.endpoints[idx]
            if ep.proxyPassword.isEmpty {
                KeychainPasswordStore.deleteProxyPassword(forEndpointID: ep.id)
            } else {
                KeychainPasswordStore.saveProxyPassword(ep.proxyPassword, forEndpointID: ep.id)
            }
            sanitized.endpoints[idx].proxyPassword = ""
        }
        if let encoded = try? JSONEncoder().encode(sanitized) {
            defaults.set(encoded, forKey: Keys.watchdogConfig)
        }
    }
}

enum KeychainPasswordStore {
    private static let profileService = "com.zte.routerbar.profile"
    private static let proxyService = "com.zte.routerbar.watchdogProxy"
    private static let legacyService = "com.zte.routerbar.admin"

    static func loadPassword(forProfileID id: UUID) -> String? {
        load(service: profileService, account: id.uuidString)
    }

    @discardableResult
    static func savePassword(_ password: String, forProfileID id: UUID) -> OSStatus {
        save(password, service: profileService, account: id.uuidString)
    }

    @discardableResult
    static func deletePassword(forProfileID id: UUID) -> OSStatus {
        delete(service: profileService, account: id.uuidString)
    }

    static func loadProxyPassword(forEndpointID id: UUID) -> String? {
        load(service: proxyService, account: id.uuidString)
    }

    @discardableResult
    static func saveProxyPassword(_ password: String, forEndpointID id: UUID) -> OSStatus {
        save(password, service: proxyService, account: id.uuidString)
    }

    @discardableResult
    static func deleteProxyPassword(forEndpointID id: UUID) -> OSStatus {
        delete(service: proxyService, account: id.uuidString)
    }

    static func loadLegacyPassword(for hostKey: String) -> String? {
        let account = hostKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return load(service: legacyService, account: account.isEmpty ? "default" : account)
    }

    private static func load(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
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

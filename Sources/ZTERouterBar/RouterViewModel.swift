import AppKit
import Foundation
import ServiceManagement
import ZTERouterCore

@MainActor
@Observable
final class RouterViewModel {
    let settings: SettingsStore
    let wifiMonitor: WiFiNetworkMonitor
    private(set) var client: ZTERouterClient?

    var snapshot: RouterStatusSnapshot?
    var passwordInput: String = ""
    var hasStoredPassword: Bool = false

    var isRefreshing: Bool = false
    var isReconnectingWAN: Bool = false
    var isUIActive: Bool = false
    var selectedDashboardTab: DashboardTab = .overview

    var lastError: String?
    var actionStatusMessage: String?
    var launchAtLoginEnabled: Bool = false

    private var pollingTask: Task<Void, Never>?
    private var clearMessageTask: Task<Void, Never>?

    init(
        settings: SettingsStore = SettingsStore(),
        wifiMonitor: WiFiNetworkMonitor = WiFiNetworkMonitor()
    ) {
        self.settings = settings
        self.wifiMonitor = wifiMonitor

        wifiMonitor.onSSIDChanged = { [weak self] ssid in
            self?.handleWiFiSSIDChanged(ssid)
        }

        // Initial auto-match if Wi-Fi SSID is already readable
        if settings.autoMatchByWiFi,
           let matched = RouterProfileMatcher.match(ssid: wifiMonitor.currentSSID, in: settings.profiles) {
            settings.activeProfileID = matched.id
        }

        reloadPasswordFromKeychain()
        rebuildClient()
        refreshLaunchAtLoginStatus()
    }

    var activeProfile: RouterProfile {
        settings.activeProfile
    }

    var matchedProfileForCurrentWiFi: RouterProfile? {
        RouterProfileMatcher.match(ssid: wifiMonitor.currentSSID, in: settings.profiles)
    }

    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.hasStoredPassword {
                    await self.refreshNow(silent: true)
                }
                let interval = self.isUIActive ? min(2.0, self.settings.pollingInterval) : max(3.0, self.settings.pollingInterval * 2.0)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func setUIActive(_ active: Bool) {
        isUIActive = active
        if active {
            wifiMonitor.refreshSSID()
            if hasStoredPassword {
                Task { await refreshNow(silent: true) }
            }
        }
    }

    // MARK: - Profile & Wi-Fi Auto-Matching

    private func handleWiFiSSIDChanged(_ ssid: String?) {
        guard settings.autoMatchByWiFi else { return }
        guard let matched = RouterProfileMatcher.match(ssid: ssid, in: settings.profiles) else { return }
        guard matched.id != settings.activeProfileID else { return }

        selectProfile(matched.id, announce: "已按 Wi-Fi「\(ssid ?? "")」自动切换配置：\(matched.name)")
    }

    func triggerWiFiAutoMatch() {
        wifiMonitor.refreshSSID()
        guard settings.autoMatchByWiFi,
              let ssid = wifiMonitor.currentSSID,
              let matched = RouterProfileMatcher.match(ssid: ssid, in: settings.profiles) else {
            return
        }
        if matched.id != settings.activeProfileID {
            selectProfile(matched.id, announce: "已匹配 Wi-Fi「\(ssid)」配置：\(matched.name)")
        }
    }

    func selectProfile(_ profileID: UUID, announce: String? = nil) {
        guard settings.profiles.contains(where: { $0.id == profileID }) else { return }
        settings.activeProfileID = profileID
        snapshot = nil
        lastError = nil
        reloadPasswordFromKeychain()
        rebuildClient()
        if let announce {
            showToast(announce)
        }
        if hasStoredPassword {
            Task { await refreshNow(silent: false) }
        }
    }

    func reloadPasswordFromKeychain() {
        if let saved = KeychainPasswordStore.loadPassword(forProfileID: activeProfile.id), !saved.isEmpty {
            passwordInput = saved
            hasStoredPassword = true
        } else {
            passwordInput = ""
            hasStoredPassword = false
        }
    }

    func saveProfile(
        _ profile: RouterProfile,
        password: String?,
        activateAndTest: Bool
    ) async {
        settings.updateProfile(profile)

        if let password {
            let trimmedPass = password.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPass.isEmpty {
                let status = KeychainPasswordStore.savePassword(trimmedPass, forProfileID: profile.id)
                if profile.id == settings.activeProfileID || activateAndTest {
                    passwordInput = trimmedPass
                    hasStoredPassword = true
                }
                if status != errSecSuccess {
                    showToast("配置已保存（钥匙串状态码：\(status)）")
                }
            }
        }

        if activateAndTest {
            settings.activeProfileID = profile.id
            snapshot = nil
            reloadPasswordFromKeychain()
            rebuildClient()
            await refreshNow(silent: false)
            if lastError == nil {
                showToast("已保存并成功连接「\(profile.name)」")
            }
        } else if profile.id == settings.activeProfileID {
            reloadPasswordFromKeychain()
            rebuildClient()
        }
    }

    func saveQuickSetup(name: String, urlString: String, password: String, bindCurrentWiFi: Bool) async {
        var profile = activeProfile
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanName.isEmpty {
            profile.name = cleanName
        }
        profile.routerURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if bindCurrentWiFi, let ssid = wifiMonitor.currentSSID, !profile.matches(ssid: ssid) {
            profile.wifiSSIDs.append(ssid)
        }
        await saveProfile(profile, password: password, activateAndTest: true)
    }

    func clearPassword(forProfileID profileID: UUID) {
        KeychainPasswordStore.deletePassword(forProfileID: profileID)
        if profileID == settings.activeProfileID {
            passwordInput = ""
            hasStoredPassword = false
            snapshot = nil
            rebuildClient()
        }
    }

    func bindCurrentWiFi(toProfileID profileID: UUID) {
        wifiMonitor.refreshSSID()
        guard let ssid = wifiMonitor.currentSSID else {
            lastError = wifiMonitor.isLocationAuthorized
                ? "当前未检测到已连接的 Wi-Fi 名称。"
                : "尚未授权定位权限，无法读取当前 Wi-Fi 名称。"
            return
        }
        guard var target = settings.profiles.first(where: { $0.id == profileID }) else { return }
        if !target.matches(ssid: ssid) {
            target.wifiSSIDs.append(ssid)
            settings.updateProfile(target)
        }
        showToast("已将 Wi-Fi「\(ssid)」绑定到「\(target.name)」")
    }

    func rebuildClient() {
        let profile = activeProfile
        do {
            let config = try RouterEndpointConfig(
                baseURLString: profile.routerURLString,
                hashPreference: profile.hashPreference
            )
            let pass = KeychainPasswordStore.loadPassword(forProfileID: profile.id) ?? passwordInput
            client = ZTERouterClient(config: config, password: pass)
            lastError = nil
        } catch {
            client = nil
            lastError = error.localizedDescription
        }
    }

    // MARK: - Refresh

    func refreshNow(silent: Bool = false) async {
        guard !isRefreshing else { return }
        guard let client else {
            if !silent { lastError = "当前配置的路由器地址无效。" }
            return
        }
        guard hasStoredPassword || !passwordInput.isEmpty else {
            if !silent { lastError = ZTERouterError.missingPassword.localizedDescription }
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let fresh = try await client.fetchStatus()
            self.snapshot = fresh
            self.lastError = nil
        } catch {
            if !silent || self.snapshot == nil {
                self.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - One-Click WAN Reconnect (Zero Confirmation Popup)

    func reconnectWAN() async {
        guard !isReconnectingWAN else { return }
        guard let client else {
            lastError = "请先配置路由器地址与密码。"
            return
        }

        isReconnectingWAN = true
        defer { isReconnectingWAN = false }
        lastError = nil

        do {
            let newState = try await client.reconnectInternet()
            await refreshNow(silent: true)
            showToast(newState.isConnected ? "外网重连成功" : "已触发重连，状态：\(newState.localizedLabel)")
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Launch at Login

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
            lastError = nil
        } catch {
            refreshLaunchAtLoginStatus()
            lastError = "设置开机自启失败（请确保通过 .app 应用包运行）：\(error.localizedDescription)"
        }
    }

    func showToast(_ message: String) {
        actionStatusMessage = message
        clearMessageTask?.cancel()
        clearMessageTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self.actionStatusMessage = nil
        }
    }
}

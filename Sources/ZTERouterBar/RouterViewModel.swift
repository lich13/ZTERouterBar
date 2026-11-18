import AppKit
import Foundation
import ServiceManagement
import ZTERouterCore

@MainActor
@Observable
final class RouterViewModel {
    let settings: SettingsStore
    let wifiMonitor: WiFiNetworkMonitor
    let notifier: SystemNotificationManager
    private(set) var client: ZTERouterClient?

    var snapshot: RouterStatusSnapshot?
    var signalHistory: [SignalSample] = []
    var passwordInput: String = ""
    var hasStoredPassword: Bool = false

    var isRefreshing: Bool = false
    var isReconnectingWAN: Bool = false
    var isSessionOccupied: Bool = false
    var isUIActive: Bool = false
    var selectedDashboardTab: DashboardTab = .overview

    // Watchdog state
    var isWatchdogRunning: Bool = false
    var watchdogPhase: WatchdogPhase = .idle
    var lastProbeOutcomes: [EndpointProbeOutcome] = []
    var lastWatchdogHealthy: Bool?
    var watchdogLogs: [WatchdogLogEntry] = []
    var isProbingOnce: Bool = false

    var lastError: String?
    var actionStatusMessage: String?
    var launchAtLoginEnabled: Bool = false

    private var pollingTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var clearMessageTask: Task<Void, Never>?
    private var userStoppedWatchdog = false
    private var pendingAutoBeforeIP: WANIPSnapshot = WANIPSnapshot()
    private var handledAutoReconnectFinish = false

    private let prober: any EndpointProbing = URLEndpointProber()
    private let watchdogRunner = WatchdogRunner()

    init(
        settings: SettingsStore = SettingsStore(),
        wifiMonitor: WiFiNetworkMonitor = WiFiNetworkMonitor(),
        notifier: SystemNotificationManager = SystemNotificationManager()
    ) {
        self.settings = settings
        self.wifiMonitor = wifiMonitor
        self.notifier = notifier

        wifiMonitor.onSSIDChanged = { [weak self] ssid in
            self?.handleWiFiSSIDChanged(ssid)
        }

        if settings.autoMatchByWiFi,
           let matched = RouterProfileMatcher.match(ssid: wifiMonitor.currentSSID, in: settings.profiles) {
            settings.activeProfileID = matched.id
        }

        reloadPasswordFromKeychain()
        rebuildClient()
        refreshLaunchAtLoginStatus()

        Task { [weak self] in
            await self?.notifier.configureAndRequestAuthorization()
        }

        if settings.watchdogConfig.autoStart && hasStoredPassword {
            startWatchdog()
        }
    }

    var currentSignalAssessment: SignalRatingAssessment? {
        snapshot.map(SignalEvaluator.assess(snapshot:))
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
                let baseInterval = self.isUIActive ? min(2.0, self.settings.pollingInterval) : max(3.0, self.settings.pollingInterval * 2.0)
                let interval = self.isSessionOccupied ? max(15.0, baseInterval * 4.0) : baseInterval
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
            if hasStoredPassword && !isSessionOccupied {
                Task { await refreshNow(silent: true) }
            }
        }
    }

    // MARK: - Watchdog Controls

    func startWatchdog() {
        guard let client else {
            appendWatchdogLog(WatchdogLogEntry(level: .error, message: "尚未配置有效的路由器地址，无法启动守护"))
            return
        }
        guard hasStoredPassword || !passwordInput.isEmpty else {
            appendWatchdogLog(WatchdogLogEntry(level: .warning, message: "尚未保存路由器管理密码，请在配置中设置后再启动守护"))
            return
        }
        let validEndpoints = settings.watchdogConfig.enabledValidEndpoints
        guard !validEndpoints.isEmpty else {
            appendWatchdogLog(WatchdogLogEntry(level: .warning, message: "请至少启用一个有效的 HTTP/HTTPS 检测端点"))
            return
        }

        userStoppedWatchdog = false
        watchdogTask?.cancel()
        isWatchdogRunning = true
        let config = settings.watchdogConfig.clamped()

        watchdogTask = Task { [weak self] in
            guard let self else { return }
            await self.watchdogRunner.run(
                config: config,
                prober: self.prober,
                router: client,
                canReconnect: { [weak self] in
                    await MainActor.run {
                        guard let self else { return "已退出" }
                        if self.isReconnectingWAN {
                            return "正在执行手动重连，跳过本次自动重连"
                        }
                        if self.settings.watchdogConfig.onlyWhenWiFiMatched {
                            guard let ssid = self.wifiMonitor.currentSSID else {
                                return "未检测到当前 Wi-Fi 名称（已开启仅匹配 Wi-Fi 时自动重连）"
                            }
                            guard self.activeProfile.matches(ssid: ssid) else {
                                return "当前 Wi-Fi「\(ssid)」未绑定至当前配置「\(self.activeProfile.name)」"
                            }
                        }
                        return nil
                    }
                },
                onEvent: { [weak self] event in
                    await MainActor.run {
                        self?.handleWatchdogEvent(event)
                    }
                }
            )
            await MainActor.run {
                self.isWatchdogRunning = false
                self.watchdogPhase = .idle
                self.watchdogTask = nil
            }
        }
    }

    func stopWatchdog(userInitiated: Bool = true) {
        if userInitiated {
            userStoppedWatchdog = true
        }
        watchdogTask?.cancel()
        watchdogTask = nil
        isWatchdogRunning = false
        watchdogPhase = .idle
    }

    func toggleWatchdog() {
        if isWatchdogRunning {
            stopWatchdog(userInitiated: true)
            showToast("外网保活守护已停止")
        } else {
            startWatchdog()
            if isWatchdogRunning {
                showToast("外网保活守护已启动")
            }
        }
    }

    func updateWatchdogConfig(_ newConfig: WatchdogConfig) {
        settings.watchdogConfig = newConfig.clamped()
        if isWatchdogRunning {
            startWatchdog()
            showToast("守护配置已更新并生效")
        } else {
            showToast("守护配置已保存")
        }
    }

    func restoreDefaultWatchdogEndpoints() {
        var copy = settings.watchdogConfig
        copy.endpoints = WatchdogEndpoint.defaultPresets
        updateWatchdogConfig(copy)
    }

    func runSingleWatchdogProbe() async {
        guard !isProbingOnce else { return }
        let endpoints = settings.watchdogConfig.enabledValidEndpoints
        guard !endpoints.isEmpty else {
            appendWatchdogLog(WatchdogLogEntry(level: .warning, message: "没有启用的有效探测端点"))
            return
        }
        isProbingOnce = true
        defer { isProbingOnce = false }

        appendWatchdogLog(WatchdogLogEntry(level: .info, message: "手动执行单轮连通性探测（\(endpoints.count) 个端点）…"))
        let results = await watchdogRunner.probeAll(
            endpoints: endpoints,
            timeoutMs: settings.watchdogConfig.checkTimeoutMs,
            prober: prober
        )
        let policy = settings.watchdogConfig.triggerPolicy
        let healthy = WatchdogEvaluator.isHealthy(outcomes: results, policy: policy)
        lastProbeOutcomes = results
        lastWatchdogHealthy = healthy
        for item in results {
            appendWatchdogLog(WatchdogLogEntry(
                level: item.reachable ? .info : .warning,
                message: "  \(WatchdogEvaluator.formatProbeSummary(item))"
            ))
        }
        let verdict: String
        if policy == .weighted {
            let tally = WatchdogEvaluator.weightTally(outcomes: results)
            verdict = healthy
                ? "==> 单轮探测结果：网络正常（可达权重 \(tally.reachable)/\(tally.total)）"
                : "==> 单轮探测结果：未达到权重阈值（可达权重 \(tally.reachable)/\(tally.total)）"
        } else {
            verdict = healthy ? "==> 单轮探测结果：网络正常" : "==> 单轮探测结果：未达到可达条件"
        }
        appendWatchdogLog(WatchdogLogEntry(
            level: healthy ? .success : .warning,
            message: verdict
        ))
    }

    func clearWatchdogLogs() {
        watchdogLogs.removeAll()
    }

    private func handleWatchdogEvent(_ event: WatchdogEvent) {
        switch event {
        case let .phaseChanged(phase):
            let previous = watchdogPhase
            watchdogPhase = phase
            if previous == .reconnecting && phase != .reconnecting && !handledAutoReconnectFinish {
                Task { await refreshNow(silent: true) }
            }
        case let .probeRoundCompleted(outcomes, overallHealthy):
            lastProbeOutcomes = outcomes
            lastWatchdogHealthy = overallHealthy
        case let .autoReconnectTriggered(reason):
            handledAutoReconnectFinish = false
            pendingAutoBeforeIP = WANIPSnapshot(snapshot: snapshot)
            if settings.systemNotificationsEnabled {
                notifier.notifyAutoReconnectTriggered(
                    profileName: activeProfile.name,
                    reason: reason,
                    currentIP: pendingAutoBeforeIP
                )
            }
        case let .autoReconnectFinished(state):
            handledAutoReconnectFinish = true
            let beforeIP = pendingAutoBeforeIP
            Task { [weak self] in
                await self?.finalizeReconnectIPTracking(isAutomatic: true, state: state, beforeIP: beforeIP)
            }
        case let .log(entry):
            appendWatchdogLog(entry)
        }
    }

    private func appendWatchdogLog(_ entry: WatchdogLogEntry) {
        watchdogLogs.append(entry)
        if watchdogLogs.count > 300 {
            watchdogLogs.removeFirst(watchdogLogs.count - 300)
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
        signalHistory.removeAll()
        lastError = nil
        isSessionOccupied = false
        reloadPasswordFromKeychain()
        rebuildClient()
        if let announce {
            showToast(announce)
        }
        if hasStoredPassword {
            Task { await refreshNow(silent: false) }
            if isWatchdogRunning {
                startWatchdog()
            } else if settings.watchdogConfig.autoStart && !userStoppedWatchdog {
                startWatchdog()
            }
        } else if isWatchdogRunning {
            stopWatchdog(userInitiated: false)
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
            signalHistory.removeAll()
            isSessionOccupied = false
            reloadPasswordFromKeychain()
            rebuildClient()
            await refreshNow(silent: false)
            if lastError == nil {
                showToast("已保存并成功连接「\(profile.name)」")
            }
            if hasStoredPassword && settings.watchdogConfig.autoStart && !userStoppedWatchdog && !isWatchdogRunning {
                startWatchdog()
            } else if isWatchdogRunning {
                startWatchdog()
            }
        } else if profile.id == settings.activeProfileID {
            reloadPasswordFromKeychain()
            rebuildClient()
            if isWatchdogRunning {
                startWatchdog()
            }
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
            isSessionOccupied = false
            stopWatchdog(userInitiated: false)
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
            let fresh = try await client.fetchStatus(reclaimIfDuplicate: !silent)
            self.snapshot = fresh
            self.recordSignalSample(from: fresh)
            self.lastError = nil
            self.isSessionOccupied = false
        } catch let routerError as ZTERouterError {
            switch routerError {
            case .duplicateUser:
                self.isSessionOccupied = true
                self.lastError = routerError.localizedDescription
            case .wrongPassword, .loginRateLimited, .sessionExpired:
                self.isSessionOccupied = false
                self.lastError = routerError.localizedDescription
            default:
                if !silent || self.snapshot == nil {
                    self.lastError = routerError.localizedDescription
                }
            }
        } catch {
            if !silent || self.snapshot == nil {
                self.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - One-Click WAN Reconnect

    func reconnectWAN() async {
        guard !isReconnectingWAN else { return }
        guard let client else {
            lastError = "请先配置路由器地址与密码。"
            return
        }

        isReconnectingWAN = true
        defer { isReconnectingWAN = false }
        lastError = nil

        var beforeIP = WANIPSnapshot(snapshot: snapshot)
        if beforeIP.isEmpty {
            await waitForIdleRefreshAndFetch(silent: true)
            beforeIP = WANIPSnapshot(snapshot: snapshot)
        }

        do {
            let newState = try await client.reconnectInternet()
            isSessionOccupied = false
            let afterIP = await finalizeReconnectIPTracking(isAutomatic: false, state: newState, beforeIP: beforeIP)
            if newState.isConnected {
                let ipSuffix = afterIP.hasChanged(from: beforeIP) ? "（外网 IP 已更新）" : ""
                showToast("外网重连成功\(ipSuffix)")
            } else {
                showToast("已触发重连，状态：\(newState.localizedLabel)")
            }
        } catch let routerError as ZTERouterError {
            if routerError == .duplicateUser {
                isSessionOccupied = true
            }
            lastError = routerError.localizedDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func recordSignalSample(from fresh: RouterStatusSnapshot) {
        guard let sample = SignalEvaluator.sample(from: fresh) else { return }
        if let last = signalHistory.last, last.timestamp == sample.timestamp {
            signalHistory[signalHistory.count - 1] = sample
        } else {
            signalHistory.append(sample)
        }
        if signalHistory.count > 120 {
            signalHistory.removeFirst(signalHistory.count - 120)
        }
    }

    @discardableResult
    private func finalizeReconnectIPTracking(
        isAutomatic: Bool,
        state: WANConnectionState,
        beforeIP: WANIPSnapshot
    ) async -> WANIPSnapshot {
        await waitForIdleRefreshAndFetch(silent: true)
        var afterIP = WANIPSnapshot(snapshot: snapshot)

        // ZTE firmware may take ~1s after `CONNECT_NETWORK` settles to populate `wan_ipaddr`.
        if state.isConnected && (afterIP.isEmpty || (!beforeIP.isEmpty && !afterIP.hasChanged(from: beforeIP))) {
            try? await Task.sleep(for: .milliseconds(1200))
            await waitForIdleRefreshAndFetch(silent: true)
            afterIP = WANIPSnapshot(snapshot: snapshot)
        }

        let summary = WANIPChangeFormatter.formatLogSummary(before: beforeIP, after: afterIP)
        if isAutomatic {
            appendWatchdogLog(WatchdogLogEntry(level: .info, message: "重连 IP 对比：\(summary)"))
        }

        if settings.systemNotificationsEnabled {
            notifier.notifyReconnectIPChange(
                isAutomatic: isAutomatic,
                profileName: activeProfile.name,
                state: state,
                before: beforeIP,
                after: afterIP
            )
        }
        return afterIP
    }

    private func waitForIdleRefreshAndFetch(silent: Bool) async {
        for _ in 0..<10 {
            if !isRefreshing { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        await refreshNow(silent: silent)
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

import AppKit
import Foundation
import ServiceManagement
import ZTERouterCore

enum LaunchMode: String, CaseIterable, Identifiable {
    case manual
    case atLogin
    case wifiOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual: "手动启动"
        case .atLogin: "登录 macOS 时启动"
        case .wifiOnly: "仅连接已绑定 Wi-Fi 时启动（离开后自动退出）"
        }
    }
}

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
    var watchdogLogs: [WatchdogLogEntry] = []
    /// Reconnect history (automatic and manual), persisted separately from the rolling watchdog log.
    var reconnectLogs: [WatchdogLogEntry] = []
    var isProbingOnce: Bool = false

    var lastError: String?
    var actionStatusMessage: String?
    var launchMode: LaunchMode = .manual

    private var pollingTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var clearMessageTask: Task<Void, Never>?
    private var userStoppedWatchdog = false
    /// Bumped on every start/stop so a superseded watchdog task cannot touch current state.
    private var watchdogGeneration = 0
    private var manualReconnectGraceUntil: Date?
    private var lastStationFetchAt: Date?

    // "Launch only on bound Wi-Fi": quit after leaving a bound Wi-Fi this run was started on.
    private var sawBoundWiFi = false
    private var leaveQuitTask: Task<Void, Never>?
    private var leaveQuitDeferredByUI = false
    private var pendingAutoBeforeIP: WANIPSnapshot = WANIPSnapshot()
    private var handledAutoReconnectFinish = false

    private let prober: any EndpointProbing = URLEndpointProber()
    private let watchdogRunner = WatchdogRunner()

    static let logDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ZTERouterBar", isDirectory: true)
    private static let reconnectLogLimit = 200
    private let watchdogLogFile = LogFileStore(directory: RouterViewModel.logDirectory, name: "watchdog", retentionDays: 3)
    private let reconnectLogFile = LogFileStore(directory: RouterViewModel.logDirectory, name: "reconnect")

    init(
        settings: SettingsStore = SettingsStore(),
        wifiMonitor: WiFiNetworkMonitor = WiFiNetworkMonitor(),
        notifier: SystemNotificationManager = SystemNotificationManager()
    ) {
        self.settings = settings
        self.wifiMonitor = wifiMonitor
        self.notifier = notifier
        self.reconnectLogs = reconnectLogFile.recentEntries(limit: Self.reconnectLogLimit)

        wifiMonitor.onSSIDChanged = { [weak self] ssid in
            self?.handleWiFiSSIDChanged(ssid)
        }

        if settings.autoMatchByWiFi,
           let matched = RouterProfileMatcher.match(ssid: wifiMonitor.currentSSID, in: settings.profiles) {
            settings.activeProfileID = matched.id
        }

        reloadPasswordFromKeychain()
        rebuildClient()

        // Any launch that reaches the UI lifts a previous "user quit on this Wi-Fi" hold.
        WiFiLaunchAgent.clearSuppression()
        if settings.wifiOnlyLaunch {
            WiFiLaunchAgent.syncIfNeeded()
            if SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
            }
        }
        refreshLaunchMode()
        evaluateLeaveQuit()

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
                let baseInterval = self.isUIActive ? min(2.0, self.settings.pollingInterval) : max(10.0, self.settings.pollingInterval * 2.0)
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
        } else if leaveQuitDeferredByUI {
            leaveQuitDeferredByUI = false
            if settings.wifiOnlyLaunch && matchedProfileForCurrentWiFi == nil {
                NSApp.terminate(nil)
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
        watchdogGeneration += 1
        let generation = watchdogGeneration
        isWatchdogRunning = true
        watchdogPhase = .idle
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
                        if let until = self.manualReconnectGraceUntil, Date() < until {
                            return "手动重连后的保护期内，暂不自动重连"
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
                        guard let self, self.watchdogGeneration == generation else { return }
                        self.handleWatchdogEvent(event)
                    }
                }
            )
            // The runner returned on its own (e.g. no valid endpoint); a restart or stop has already
            // moved the generation on and owns the state.
            guard self.watchdogGeneration == generation else { return }
            self.isWatchdogRunning = false
            self.watchdogPhase = .idle
            self.watchdogTask = nil
        }
    }

    func stopWatchdog(userInitiated: Bool = true) {
        if userInitiated {
            userStoppedWatchdog = true
        }
        let wasRunning = isWatchdogRunning
        watchdogGeneration += 1
        watchdogTask?.cancel()
        watchdogTask = nil
        isWatchdogRunning = false
        watchdogPhase = .idle
        if wasRunning {
            appendWatchdogLog(WatchdogLogEntry(level: .info, message: "保活守护已停止"))
        }
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
        let results = await watchdogRunner.probeAll(endpoints: endpoints, prober: prober)
        let policy = settings.watchdogConfig.triggerPolicy
        let healthy = WatchdogEvaluator.isHealthy(outcomes: results, policy: policy)
        lastProbeOutcomes = results
        WatchdogEvaluator.roundLogEntries(
            probed: results, snapshot: results, policy: policy, healthy: healthy, verdictLabel: "单轮探测结果"
        ).forEach(appendWatchdogLog)
    }

    func clearWatchdogLogs() {
        watchdogLogs.removeAll()
    }

    private func handleWatchdogEvent(_ event: WatchdogEvent) {
        switch event {
        case let .phaseChanged(phase):
            let previous = watchdogPhase
            guard previous != phase else { return }
            watchdogPhase = phase
            if previous == .reconnecting && phase != .reconnecting && !handledAutoReconnectFinish {
                Task { await refreshNow(silent: true) }
            }
        case let .probeRoundCompleted(outcomes, _):
            lastProbeOutcomes = outcomes
        case let .probeFailureDetected(reason):
            if settings.systemNotificationsEnabled {
                notifier.notifyProbeFailure(
                    profileName: activeProfile.name,
                    reason: reason,
                    willAutoReconnect: settings.watchdogConfig.autoReconnectEnabled
                )
            }
        case let .autoReconnectFailed(reason):
            appendReconnectLog(.error, "自动重连失败：\(reason)")
        case let .autoReconnectTriggered(reason):
            handledAutoReconnectFinish = false
            pendingAutoBeforeIP = WANIPSnapshot(snapshot: snapshot)
            appendReconnectLog(.warning, "自动重连触发：\(reason)")
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

    private func appendReconnectLog(_ level: WatchdogLogLevel, _ message: String) {
        let entry = WatchdogLogEntry(level: level, message: "「\(activeProfile.name)」\(message)")
        reconnectLogFile.append(entry)
        reconnectLogs.append(entry)
        if reconnectLogs.count > Self.reconnectLogLimit {
            reconnectLogs.removeFirst(reconnectLogs.count - Self.reconnectLogLimit)
        }
    }

    private func appendWatchdogLog(_ entry: WatchdogLogEntry) {
        watchdogLogFile.append(entry)
        watchdogLogs.append(entry)
        if watchdogLogs.count > 300 {
            watchdogLogs.removeFirst(watchdogLogs.count - 300)
        }
    }

    // MARK: - Profile & Wi-Fi Auto-Matching

    private func handleWiFiSSIDChanged(_ ssid: String?) {
        evaluateLeaveQuit()
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
            if isWatchdogRunning || (settings.watchdogConfig.autoStart && !userStoppedWatchdog) {
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
            // Every caller has just synced `passwordInput` with the keychain.
            client = ZTERouterClient(config: config, password: passwordInput)
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
            // Station lists cost two extra requests: only while the UI is visible, and every ~10s.
            let previous = self.snapshot
            let stationsStale = lastStationFetchAt.map { Date().timeIntervalSince($0) >= 10 } ?? true
            let needStations = previous == nil || (isUIActive && stationsStale)
            var fresh = try await client.fetchStatus(
                reclaimIfDuplicate: !silent,
                includeStationLists: needStations
            )
            if needStations {
                lastStationFetchAt = Date()
            } else if isUIActive, let previous {
                fresh.wifiStations = previous.wifiStations
                fresh.lanStations = previous.lanStations
            }
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
        guard watchdogPhase != .reconnecting else {
            showToast("保活守护正在自动重连，请稍候")
            return
        }
        guard let client else {
            lastError = "请先配置路由器地址与密码。"
            return
        }

        isReconnectingWAN = true
        defer {
            isReconnectingWAN = false
            // Give the fresh link the same quiet period an automatic reconnect gets.
            manualReconnectGraceUntil = Date().addingTimeInterval(TimeInterval(settings.watchdogConfig.postReconnectGraceSec))
        }
        lastError = nil
        appendReconnectLog(.info, "手动重连触发")

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
            appendReconnectLog(.error, "手动重连失败：\(routerError.localizedDescription)")
        } catch {
            lastError = error.localizedDescription
            appendReconnectLog(.error, "手动重连失败：\(error.localizedDescription)")
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
        appendReconnectLog(
            state.isConnected ? .success : .warning,
            "\(isAutomatic ? "自动" : "手动")重连完成：\(state.localizedLabel)；IP 对比：\(summary)"
        )

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

    // MARK: - Launch Mode

    var canUseWiFiOnlyLaunch: Bool {
        wifiMonitor.isLocationAuthorized && settings.profiles.contains { !$0.wifiSSIDs.isEmpty }
    }

    func refreshLaunchMode() {
        if settings.wifiOnlyLaunch {
            launchMode = .wifiOnly
        } else {
            launchMode = SMAppService.mainApp.status == .enabled ? .atLogin : .manual
        }
    }

    func setLaunchMode(_ mode: LaunchMode) {
        do {
            if mode == .wifiOnly {
                guard canUseWiFiOnlyLaunch else {
                    lastError = "请先为路由器配置绑定 Wi-Fi 名称，并授权定位权限以识别当前 Wi-Fi。"
                    return
                }
                try WiFiLaunchAgent.install()
                settings.wifiOnlyLaunch = true
            } else {
                WiFiLaunchAgent.uninstall()
                settings.wifiOnlyLaunch = false
            }
            let loginItemEnabled = SMAppService.mainApp.status == .enabled
            if mode == .atLogin, !loginItemEnabled {
                try SMAppService.mainApp.register()
            } else if mode != .atLogin, loginItemEnabled {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = "设置启动方式失败（请确保通过 .app 应用包运行）：\(error.localizedDescription)"
        }
        refreshLaunchMode()
        evaluateLeaveQuit()
    }

    /// Called by the explicit Quit actions: on a bound Wi-Fi the launch trigger must not bring the app back.
    func noteUserQuit() {
        guard settings.wifiOnlyLaunch, let ssid = wifiMonitor.currentSSID, matchedProfileForCurrentWiFi != nil else { return }
        WiFiLaunchAgent.suppressLaunch(onSSID: ssid)
    }

    /// In Wi-Fi-only mode, quits 60s after leaving a bound Wi-Fi. A run that never saw a bound Wi-Fi
    /// (the user opened the app elsewhere on purpose) is left alone.
    private func evaluateLeaveQuit() {
        guard settings.wifiOnlyLaunch, matchedProfileForCurrentWiFi == nil else {
            if matchedProfileForCurrentWiFi != nil {
                sawBoundWiFi = true
            }
            leaveQuitTask?.cancel()
            leaveQuitTask = nil
            leaveQuitDeferredByUI = false
            return
        }
        guard sawBoundWiFi, leaveQuitTask == nil else { return }
        leaveQuitTask = Task { [weak self] in
            // Suspending clock: time asleep does not count, so waking up does not quit before Wi-Fi rejoins.
            try? await Task.sleep(for: .seconds(60), clock: .suspending)
            guard !Task.isCancelled, let self else { return }
            self.leaveQuitTask = nil
            self.wifiMonitor.refreshSSID()
            guard self.settings.wifiOnlyLaunch, self.matchedProfileForCurrentWiFi == nil else { return }
            if self.isUIActive {
                self.leaveQuitDeferredByUI = true
            } else {
                NSApp.terminate(nil)
            }
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

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
    var activeCredentialIssue: ProfileCredentialIssue?

    var isCredentialReady: Bool {
        !passwordInput.isEmpty
    }

    var isRefreshing: Bool = false
    var isReconnectingWAN: Bool = false
    var isSessionOccupied: Bool = false
    var isUIActive: Bool = false
    var isBlockingAutoQuit: Bool = false
    var selectedDashboardTab: DashboardTab = .overview
    var terminateHandler: @MainActor () -> Void = { NSApp.terminate(nil) }

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

    private var credentialState: ProfileCredentialStateMachine
    private var pollingTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var deferredCooldownRetryTask: Task<Void, Never>?
    private var clearMessageTask: Task<Void, Never>?
    private var stalledInitialPollRetryTask: Task<Void, Never>?
    private var userStoppedWatchdog = false
    /// Bumped on every client rebuild so an in-flight poll from a previous profile cannot clobber current state.
    private var clientGeneration = 0
    /// Bumped on every start/stop so a superseded watchdog task cannot touch current state.
    private var watchdogGeneration = 0
    private var manualReconnectGraceUntil: Date?
    private var lastStationFetchAt: Date?
    private var currentRefreshStartedAt: ContinuousClock.Instant?
    private var consecutiveInitialPollFailures = 0

    // "Launch only on bound Wi-Fi": pause outside bound Wi-Fi and quit promptly once confirmed.
    private var wifiLifecycle: WiFiOnlyLifecycleStateMachine
    private var leaveQuitTask: Task<Void, Never>?
    private var leaveQuitGeneration = 0
    private var isActivitySuspendedForUnboundWiFi = false
    private var watchdogPausedForUnboundWiFi = false
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
        notifier: SystemNotificationManager = SystemNotificationManager(),
        launchedByWiFiTrigger: Bool = CommandLine.arguments.contains(WiFiLaunchAgent.launchedByTriggerArgument)
    ) {
        self.settings = settings
        self.wifiMonitor = wifiMonitor
        self.notifier = notifier
        self.credentialState = ProfileCredentialStateMachine(initialSSID: wifiMonitor.currentSSID)
        self.wifiLifecycle = WiFiOnlyLifecycleStateMachine(launchedByWiFiTrigger: launchedByWiFiTrigger)
        self.reconnectLogs = reconnectLogFile.recentEntries(limit: Self.reconnectLogLimit)

        wifiMonitor.onSSIDChanged = { [weak self] ssid in
            self?.handleWiFiSSIDChanged(ssid)
        }
        wifiMonitor.onWiFiPathReady = { [weak self] in
            self?.handleWiFiPathReady()
        }
        wifiMonitor.onSystemWillSleep = { [weak self] in
            self?.handleSystemWillSleep()
        }
        wifiMonitor.onSystemDidWake = { [weak self] in
            self?.handleSystemDidWake()
        }
        wifiMonitor.onInteractiveGUIEvent = { [weak self] in
            self?.handleInteractiveGUIEvent()
        }

        if settings.autoMatchByWiFi,
           let matched = RouterProfileMatcher.match(ssid: wifiMonitor.currentSSID, in: settings.profiles) {
            settings.activeProfileID = matched.id
        }

        let isGUI = wifiMonitor.isInteractiveGUISession
        if isGUI {
            preloadAllProfilePasswordsIfNeeded(isInteractiveGUI: true)
        }
        reloadPasswordFromKeychain(isInteractiveGUI: isGUI)
        if isGUI {
            scheduleDeferredCooldownRetryIfNeeded()
        }
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

        if settings.watchdogConfig.autoStart {
            if isCredentialReady {
                startWatchdog()
            } else if activeCredentialIssue?.isSystemDeferred == true {
                credentialState.noteWatchdogPausedForDeferredCredential(
                    wasRunning: false,
                    autoStart: true,
                    userStoppedWatchdog: userStoppedWatchdog
                )
            }
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
        guard pollingTask == nil, !wifiLifecycle.isSuspendedOutsideBoundWiFi else { return }
        pollingTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.isCredentialReady && !self.credentialState.isSystemSleeping && !self.wifiLifecycle.isSuspendedOutsideBoundWiFi {
                    await self.refreshNow(silent: true)
                }
                let baseInterval = self.isUIActive ? min(2.0, self.settings.pollingInterval) : max(10.0, self.settings.pollingInterval * 2.0)
                let interval: Double
                if self.isSessionOccupied {
                    interval = max(15.0, baseInterval * 4.0)
                } else if self.snapshot == nil && self.isCredentialReady && self.consecutiveInitialPollFailures < 3 {
                    interval = 1.0
                } else {
                    interval = baseInterval
                }
                try? await Task.sleep(for: .seconds(interval), clock: .suspending)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func setUIActive(_ active: Bool) {
        setUIState(isVisible: active, isBlockingAutoQuit: active)
    }

    func setUIState(isVisible: Bool, isBlockingAutoQuit: Bool) {
        isUIActive = isVisible
        self.isBlockingAutoQuit = isBlockingAutoQuit
        if wifiLifecycle.noteBlockingUIChanged(
            isBlockingAutoQuit: isBlockingAutoQuit,
            wifiOnlyLaunch: settings.wifiOnlyLaunch,
            isBoundWiFiMatched: matchedProfileForCurrentWiFi != nil
        ) {
            terminateHandler()
            return
        }
        syncUnboundSuspensionState()
        if isVisible {
            wifiMonitor.refreshSSID(scheduleFollowUpIfNil: true)
            if !wifiLifecycle.isSuspendedOutsideBoundWiFi {
                if wifiMonitor.isInteractiveGUISession {
                    recoverSessionAndWatchdogAfterWakeOrPathReady(isInteractiveGUI: true, triggerRefresh: false)
                }
                if isCredentialReady && !isSessionOccupied {
                    Task { await refreshNow(silent: true) }
                }
            }
        }
    }

    // MARK: - Watchdog Controls

    func startWatchdog() {
        guard !wifiLifecycle.isSuspendedOutsideBoundWiFi else {
            if !userStoppedWatchdog {
                watchdogPausedForUnboundWiFi = true
                watchdogPhase = .paused(reason: "当前未连接已绑定 Wi-Fi")
            }
            return
        }
        guard let client else {
            appendWatchdogLog(WatchdogLogEntry(level: .error, message: "尚未配置有效的路由器地址，无法启动守护"))
            return
        }
        guard isCredentialReady else {
            if activeCredentialIssue?.isSystemDeferred == true {
                credentialState.noteWatchdogPausedForDeferredCredential(
                    wasRunning: false,
                    autoStart: settings.watchdogConfig.autoStart,
                    userStoppedWatchdog: userStoppedWatchdog
                )
                appendWatchdogLog(WatchdogLogEntry(level: .warning, message: "钥匙串凭据受限延后，待前台解锁后自动恢复守护"))
            } else {
                appendWatchdogLog(WatchdogLogEntry(level: .warning, message: "尚未读取到可用的路由器管理密码，请在配置中设置或授权后再启动守护"))
            }
            return
        }
        let validEndpoints = settings.watchdogConfig.enabledValidEndpoints
        guard !validEndpoints.isEmpty else {
            appendWatchdogLog(WatchdogLogEntry(level: .warning, message: "请至少启用一个有效的 HTTP/HTTPS 检测端点"))
            return
        }

        userStoppedWatchdog = false
        credentialState.noteWatchdogStarted()
        watchdogTask?.cancel()
        watchdogGeneration += 1
        let generation = watchdogGeneration
        let targetProfileID = activeProfile.id
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
                        guard self.watchdogGeneration == generation else {
                            return "守护任务已更新，取消旧实例重连"
                        }
                        if self.credentialState.isSystemSleeping {
                            return "系统正在休眠，跳过本次自动重连"
                        }
                        self.wifiMonitor.refreshSSID(scheduleFollowUpIfNil: false)
                        if self.settings.autoMatchByWiFi,
                           let matched = RouterProfileMatcher.match(ssid: self.wifiMonitor.currentSSID, in: self.settings.profiles),
                           matched.id != targetProfileID {
                            self.selectProfile(matched.id, announce: "已按 Wi-Fi「\(self.wifiMonitor.currentSSID ?? "")」自动切换配置：\(matched.name)")
                            return "Wi-Fi 已切换至「\(matched.name)」，取消向旧配置发重连"
                        }
                        guard self.settings.activeProfileID == targetProfileID else {
                            return "当前生效配置已变更，跳过旧配置自动重连"
                        }
                        guard self.isCredentialReady else {
                            return "当前配置钥匙串凭据尚未就绪，暂不自动重连"
                        }
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
            watchdogPausedForUnboundWiFi = false
            credentialState.noteUserStoppedWatchdog()
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

    // MARK: - Profile, Sleep/Wake & Keychain Credential Recovery

    private func handleSystemWillSleep() {
        deferredCooldownRetryTask?.cancel()
        deferredCooldownRetryTask = nil
        let wasRunning = isWatchdogRunning
        credentialState.noteSystemWillSleep(
            currentSSID: wifiMonitor.currentSSID,
            isWatchdogRunning: wasRunning
        )
        if wasRunning {
            watchdogGeneration += 1
            watchdogTask?.cancel()
            watchdogTask = nil
            isWatchdogRunning = false
            watchdogPhase = .idle
            appendWatchdogLog(WatchdogLogEntry(level: .info, message: "系统进入休眠，保活守护已暂停"))
        }
    }

    private func handleSystemDidWake() {
        credentialState.noteSystemDidWake(currentSSID: wifiMonitor.currentSSID)
        wifiMonitor.refreshSSID(scheduleFollowUpIfNil: true)
        recoverSessionAndWatchdogAfterWakeOrPathReady(
            isInteractiveGUI: wifiMonitor.isInteractiveGUISession,
            triggerRefresh: true
        )
    }

    private func handleInteractiveGUIEvent() {
        credentialState.noteSystemDidWake(currentSSID: wifiMonitor.currentSSID)
        wifiMonitor.refreshSSID(scheduleFollowUpIfNil: true)
        recoverSessionAndWatchdogAfterWakeOrPathReady(
            isInteractiveGUI: true,
            triggerRefresh: true
        )
    }

    private func handleWiFiPathReady() {
        recoverSessionAndWatchdogAfterWakeOrPathReady(
            isInteractiveGUI: wifiMonitor.isInteractiveGUISession,
            triggerRefresh: true
        )
    }

    private func recoverSessionAndWatchdogAfterWakeOrPathReady(
        isInteractiveGUI: Bool,
        triggerRefresh: Bool
    ) {
        wifiMonitor.refreshSSID(scheduleFollowUpIfNil: true)
        if settings.autoMatchByWiFi,
           let ssid = wifiMonitor.currentSSID,
           let matched = RouterProfileMatcher.match(ssid: ssid, in: settings.profiles),
           matched.id != settings.activeProfileID {
            selectProfile(matched.id, announce: "已按 Wi-Fi「\(ssid)」自动切换配置：\(matched.name)")
            return
        }

        if isInteractiveGUI {
            preloadAllProfilePasswordsIfNeeded(isInteractiveGUI: true, forceDeferredRetry: false)
        }

        let wasReady = isCredentialReady
        reloadPasswordFromKeychain(isInteractiveGUI: isInteractiveGUI, userInitiatedRetry: false)
        if isInteractiveGUI {
            scheduleDeferredCooldownRetryIfNeeded()
        }
        if !wasReady && isCredentialReady {
            rebuildClient()
        }

        guard isCredentialReady, !wifiLifecycle.isSuspendedOutsideBoundWiFi else { return }
        if triggerRefresh && !isSessionOccupied {
            abortStalledInitialPollOrRefresh(silent: true)
        }
        if credentialState.shouldResumeWatchdog(
            isCredentialReady: isCredentialReady,
            isWatchdogRunning: isWatchdogRunning,
            autoStart: settings.watchdogConfig.autoStart,
            userStoppedWatchdog: userStoppedWatchdog
        ) {
            startWatchdog()
        }
    }

    private func scheduleDeferredCooldownRetryIfNeeded() {
        guard let delaySec = credentialState.nextCooldownRetryDelaySec() else {
            deferredCooldownRetryTask?.cancel()
            deferredCooldownRetryTask = nil
            return
        }
        deferredCooldownRetryTask?.cancel()
        deferredCooldownRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int((delaySec + 0.05) * 1000)), clock: .suspending)
            guard !Task.isCancelled, let self else { return }
            self.deferredCooldownRetryTask = nil
            guard self.wifiMonitor.isInteractiveGUISession else { return }
            self.recoverSessionAndWatchdogAfterWakeOrPathReady(isInteractiveGUI: true, triggerRefresh: true)
        }
    }

    private func handleWiFiSSIDChanged(_ ssid: String?) {
        let wasSuspendedForUnbound = isActivitySuspendedForUnboundWiFi
        evaluateLeaveQuit(syncResumeNow: false)
        guard !wifiLifecycle.isSuspendedOutsideBoundWiFi else {
            _ = credentialState.noteSSIDChanged(
                ssid,
                matchedProfileID: nil,
                activeProfileID: settings.activeProfileID,
                autoMatchEnabled: settings.autoMatchByWiFi
            )
            return
        }
        let matched = RouterProfileMatcher.match(ssid: ssid, in: settings.profiles)
        let decision = credentialState.noteSSIDChanged(
            ssid,
            matchedProfileID: matched?.id,
            activeProfileID: settings.activeProfileID,
            autoMatchEnabled: settings.autoMatchByWiFi
        )

        if let targetID = decision.shouldSelectProfileID, let matched {
            selectProfile(targetID, announce: "已按 Wi-Fi「\(ssid ?? "")」自动切换配置：\(matched.name)")
            syncUnboundSuspensionState(skipClientRebuild: true)
        } else {
            syncUnboundSuspensionState()
            if decision.shouldRefreshSameProfile && !wasSuspendedForUnbound {
                let isGUI = wifiMonitor.isInteractiveGUISession
                if isGUI {
                    preloadAllProfilePasswordsIfNeeded(isInteractiveGUI: true)
                }
                let wasReady = isCredentialReady
                reloadPasswordFromKeychain(isInteractiveGUI: isGUI)
                if isGUI {
                    scheduleDeferredCooldownRetryIfNeeded()
                }
                if !wasReady && isCredentialReady {
                    rebuildClient()
                }
                if isCredentialReady {
                    abortStalledInitialPollOrRefresh(silent: true)
                    if credentialState.shouldResumeWatchdog(
                        isCredentialReady: isCredentialReady,
                        isWatchdogRunning: isWatchdogRunning,
                        autoStart: settings.watchdogConfig.autoStart,
                        userStoppedWatchdog: userStoppedWatchdog
                    ) {
                        startWatchdog()
                    }
                }
            }
        }
    }

    private func abortStalledInitialPollOrRefresh(silent: Bool) {
        guard !wifiLifecycle.isSuspendedOutsideBoundWiFi else { return }
        if snapshot == nil && isRefreshing && !isReconnectingWAN {
            let age = currentRefreshStartedAt.map { $0.duration(to: ContinuousClock.now) } ?? .seconds(1)
            if age >= .milliseconds(250) {
                stalledInitialPollRetryTask?.cancel()
                stalledInitialPollRetryTask = nil
                stopPolling()
                rebuildClient()
                startPolling()
                return
            }
            if stalledInitialPollRetryTask == nil {
                stalledInitialPollRetryTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(300), clock: .suspending)
                    guard !Task.isCancelled, let self else { return }
                    self.stalledInitialPollRetryTask = nil
                    guard !self.wifiLifecycle.isSuspendedOutsideBoundWiFi,
                          self.snapshot == nil,
                          self.isRefreshing,
                          !self.isReconnectingWAN else { return }
                    self.stopPolling()
                    self.rebuildClient()
                    self.startPolling()
                }
            }
            return
        }
        if pollingTask == nil {
            startPolling()
        } else {
            Task { await refreshNow(silent: silent) }
        }
    }

    func triggerWiFiAutoMatch() {
        wifiMonitor.refreshSSID(scheduleFollowUpIfNil: true)
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
        let wasWatchdogRunning = isWatchdogRunning || watchdogPausedForUnboundWiFi
        watchdogPausedForUnboundWiFi = false
        credentialState.noteProfileSelected()
        settings.activeProfileID = profileID
        snapshot = nil
        signalHistory.removeAll()
        lastError = nil
        isSessionOccupied = false

        let isGUI = wifiMonitor.isInteractiveGUISession
        if isGUI {
            preloadAllProfilePasswordsIfNeeded(isInteractiveGUI: true)
        }
        reloadPasswordFromKeychain(isInteractiveGUI: isGUI)
        if isGUI {
            scheduleDeferredCooldownRetryIfNeeded()
        }
        rebuildClient()
        if let announce {
            showToast(announce)
        }
        if isCredentialReady {
            Task { await refreshNow(silent: false) }
            if wasWatchdogRunning || credentialState.shouldResumeWatchdog(
                isCredentialReady: true,
                isWatchdogRunning: false,
                autoStart: settings.watchdogConfig.autoStart,
                userStoppedWatchdog: userStoppedWatchdog
            ) {
                startWatchdog()
            }
        } else {
            if activeCredentialIssue?.isSystemDeferred == true {
                credentialState.noteWatchdogPausedForDeferredCredential(
                    wasRunning: wasWatchdogRunning,
                    autoStart: settings.watchdogConfig.autoStart,
                    userStoppedWatchdog: userStoppedWatchdog
                )
            }
            if wasWatchdogRunning {
                stopWatchdog(userInitiated: false)
            }
        }
    }

    func preloadAllProfilePasswordsIfNeeded(
        isInteractiveGUI: Bool,
        forceDeferredRetry: Bool = false
    ) {
        let ids = settings.profiles.map(\.id)
        let diagnostics = credentialState.preloadAllProfilesIfNeeded(
            profileIDs: ids,
            isInteractiveGUI: isInteractiveGUI,
            forceDeferredRetry: forceDeferredRetry,
            loader: { KeychainPasswordStore.loadPasswordResult(forProfileID: $0) }
        )
        for (profileID, diag) in diagnostics {
            let name = settings.profiles.first(where: { $0.id == profileID })?.name ?? profileID.uuidString
            appendWatchdogLog(WatchdogLogEntry(level: .warning, message: "\(diag), 配置=\(name)"))
        }
    }

    func reloadPasswordFromKeychain(
        isInteractiveGUI: Bool = false,
        userInitiatedRetry: Bool = false
    ) {
        let profile = activeProfile
        let (evaluation, diag) = credentialState.loadActiveProfile(
            id: profile.id,
            isInteractiveGUI: isInteractiveGUI,
            userInitiatedRetry: userInitiatedRetry,
            loader: { KeychainPasswordStore.loadPasswordResult(forProfileID: $0) }
        )
        passwordInput = evaluation.password
        hasStoredPassword = evaluation.hasStoredPassword
        activeCredentialIssue = evaluation.issue
        if let diag {
            appendWatchdogLog(WatchdogLogEntry(level: .warning, message: "\(diag), 配置=\(profile.name)"))
        }
    }

    /// Invoked synchronously right before opening the popover or context menu in an active GUI session.
    /// Retries `.deferredBySystem` items (and runs GUI preload if needed), without re-prompting `.deniedOrFailed`.
    func prepareCredentialsForInteractiveMenuOrPopover() {
        let needsKeychainAccess = !credentialState.hasPreloadedAllProfilesInGUI
            || !credentialState.deferredProfiles.isEmpty
            || credentialState.peekEvaluation(for: activeProfile.id) == nil
        if needsKeychainAccess {
            NSApp.activate(ignoringOtherApps: true)
        }
        preloadAllProfilePasswordsIfNeeded(isInteractiveGUI: true, forceDeferredRetry: true)
        let wasReady = isCredentialReady
        reloadPasswordFromKeychain(isInteractiveGUI: true, userInitiatedRetry: false)
        if !wasReady && isCredentialReady {
            rebuildClient()
            Task { await refreshNow(silent: false) }
            if credentialState.shouldResumeWatchdog(
                isCredentialReady: true,
                isWatchdogRunning: isWatchdogRunning,
                autoStart: settings.watchdogConfig.autoStart,
                userStoppedWatchdog: userStoppedWatchdog
            ) {
                startWatchdog()
            }
        }
    }

    /// Explicit user button click ("立即读取密码"): clears `.deniedOrFailed` / `.deferredBySystem` hold for active profile.
    func retryUnlockKeychainFromUserAction() {
        NSApp.activate(ignoringOtherApps: true)
        reloadPasswordFromKeychain(isInteractiveGUI: true, userInitiatedRetry: true)
        preloadAllProfilePasswordsIfNeeded(isInteractiveGUI: true, forceDeferredRetry: true)
        rebuildClient()
        if isCredentialReady {
            lastError = nil
            Task { await refreshNow(silent: false) }
            if credentialState.shouldResumeWatchdog(
                isCredentialReady: true,
                isWatchdogRunning: isWatchdogRunning,
                autoStart: settings.watchdogConfig.autoStart,
                userStoppedWatchdog: userStoppedWatchdog
            ) {
                startWatchdog()
            }
        }
    }

    func editorCredentialSnapshot(forProfileID id: UUID) -> (
        password: String,
        hasStoredPassword: Bool,
        issue: ProfileCredentialIssue?
    ) {
        if let peeked = credentialState.peekEvaluation(for: id) {
            return (peeked.password, peeked.hasStoredPassword, peeked.issue)
        }
        if wifiMonitor.isInteractiveGUISession {
            let (eval, diag) = credentialState.loadActiveProfile(
                id: id,
                isInteractiveGUI: true,
                userInitiatedRetry: false,
                loader: { KeychainPasswordStore.loadPasswordResult(forProfileID: $0) }
            )
            if let diag {
                let name = settings.profiles.first(where: { $0.id == id })?.name ?? id.uuidString
                appendWatchdogLog(WatchdogLogEntry(level: .warning, message: "\(diag), 配置=\(name)"))
            }
            return (eval.password, eval.hasStoredPassword, eval.issue)
        }
        return ("", false, nil)
    }

    func retryUnlockProfileFromEditor(id: UUID) -> (
        password: String,
        hasStoredPassword: Bool,
        issue: ProfileCredentialIssue?
    ) {
        if id == settings.activeProfileID {
            retryUnlockKeychainFromUserAction()
            return (passwordInput, hasStoredPassword, activeCredentialIssue)
        }
        NSApp.activate(ignoringOtherApps: true)
        let (eval, diag) = credentialState.loadActiveProfile(
            id: id,
            isInteractiveGUI: true,
            userInitiatedRetry: true,
            loader: { KeychainPasswordStore.loadPasswordResult(forProfileID: $0) }
        )
        if let diag {
            let name = settings.profiles.first(where: { $0.id == id })?.name ?? id.uuidString
            appendWatchdogLog(WatchdogLogEntry(level: .warning, message: "\(diag), 配置=\(name)"))
        }
        return (eval.password, eval.hasStoredPassword, eval.issue)
    }

    func deleteProfile(id: UUID) {
        let wasActive = (settings.activeProfileID == id)
        credentialState.purgeProfile(id: id)
        settings.deleteProfile(id: id)
        evaluateLeaveQuit()
        if wasActive {
            selectProfile(settings.activeProfileID)
        }
    }

    func saveProfile(
        _ profile: RouterProfile,
        password: String?,
        activateAndTest: Bool
    ) async {
        settings.updateProfile(profile)
        evaluateLeaveQuit()

        if let password {
            let trimmedPass = password.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPass.isEmpty {
                let status = KeychainPasswordStore.savePassword(trimmedPass, forProfileID: profile.id)
                if status == errSecSuccess {
                    credentialState.storeUnlockedPassword(trimmedPass, for: profile.id)
                    if profile.id == settings.activeProfileID || activateAndTest {
                        passwordInput = trimmedPass
                        hasStoredPassword = true
                        activeCredentialIssue = nil
                    }
                } else {
                    lastError = "保存钥匙串管理密码未成功（状态码 \(status)），请重试授权或检查钥匙串状态。"
                    return
                }
            }
        }

        if activateAndTest {
            credentialState.noteProfileSelected()
            settings.activeProfileID = profile.id
            snapshot = nil
            signalHistory.removeAll()
            isSessionOccupied = false
            reloadPasswordFromKeychain(isInteractiveGUI: wifiMonitor.isInteractiveGUISession)
            rebuildClient()
            await refreshNow(silent: false)
            if lastError == nil {
                showToast("已保存并成功连接「\(profile.name)」")
            }
            if isCredentialReady && (isWatchdogRunning || credentialState.shouldResumeWatchdog(
                isCredentialReady: true,
                isWatchdogRunning: false,
                autoStart: settings.watchdogConfig.autoStart,
                userStoppedWatchdog: userStoppedWatchdog
            )) {
                startWatchdog()
            }
        } else if profile.id == settings.activeProfileID {
            reloadPasswordFromKeychain(isInteractiveGUI: wifiMonitor.isInteractiveGUISession)
            rebuildClient()
            if isWatchdogRunning && isCredentialReady {
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
        credentialState.removePassword(for: profileID)
        if profileID == settings.activeProfileID {
            passwordInput = ""
            hasStoredPassword = false
            activeCredentialIssue = nil
            snapshot = nil
            isSessionOccupied = false
            credentialState.noteUserStoppedWatchdog()
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
        evaluateLeaveQuit()
        showToast("已将 Wi-Fi「\(ssid)」绑定到「\(target.name)」")
    }

    func rebuildClient() {
        clientGeneration += 1
        isRefreshing = false
        currentRefreshStartedAt = nil
        consecutiveInitialPollFailures = 0
        lastStationFetchAt = nil
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
        let entryGen = clientGeneration
        if isRefreshing {
            guard !silent else { return }
            for _ in 0..<20 {
                if !isRefreshing || clientGeneration != entryGen { break }
                try? await Task.sleep(for: .milliseconds(100), clock: .suspending)
            }
            guard !isRefreshing else { return }
        }
        let gen = clientGeneration
        guard let client else {
            if !silent { lastError = "当前配置的路由器地址无效。" }
            return
        }
        guard isCredentialReady else {
            if !silent {
                if let issue = activeCredentialIssue {
                    lastError = issue.isSystemDeferred
                        ? "钥匙串凭据暂受限（状态码 \(issue.statusCode)），请点击「立即读取密码」重试。"
                        : "读取钥匙串管理密码未获授权（状态码 \(issue.statusCode)），请点击「立即读取密码」授权。"
                } else {
                    lastError = ZTERouterError.missingPassword.localizedDescription
                }
            }
            return
        }

        isRefreshing = true
        currentRefreshStartedAt = ContinuousClock.now
        defer {
            if clientGeneration == gen {
                isRefreshing = false
                currentRefreshStartedAt = nil
            }
        }

        let allowReclaim = credentialState.effectiveReclaimFlag(silentPoll: silent)

        do {
            // Station lists cost two extra requests: only while the UI is visible, and every ~10s.
            let previous = self.snapshot
            let stationsStale = lastStationFetchAt.map { Date().timeIntervalSince($0) >= 10 } ?? true
            let needStations = previous == nil || (isUIActive && stationsStale)
            var fresh = try await client.fetchStatus(
                reclaimIfDuplicate: allowReclaim,
                includeStationLists: needStations
            )
            guard clientGeneration == gen else { return }
            credentialState.noteRouterInteractionResult(error: nil)
            if needStations {
                lastStationFetchAt = Date()
            } else if isUIActive, let previous {
                fresh.wifiStations = previous.wifiStations
                fresh.lanStations = previous.lanStations
            }
            self.snapshot = fresh
            self.consecutiveInitialPollFailures = 0
            self.recordSignalSample(from: fresh)
            self.lastError = nil
            self.isSessionOccupied = false
        } catch let routerError as ZTERouterError {
            guard clientGeneration == gen else { return }
            if self.snapshot == nil {
                self.consecutiveInitialPollFailures += 1
            }
            credentialState.noteRouterInteractionResult(error: routerError)
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
            guard clientGeneration == gen else { return }
            if self.snapshot == nil {
                self.consecutiveInitialPollFailures += 1
            }
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
        if !isCredentialReady, activeCredentialIssue?.isSystemDeferred == true, wifiMonitor.isInteractiveGUISession {
            prepareCredentialsForInteractiveMenuOrPopover()
        }
        guard let client, isCredentialReady else {
            if let issue = activeCredentialIssue {
                lastError = "需先读取钥匙串中的管理密码（状态码 \(issue.statusCode)）。"
            } else {
                lastError = "请先配置路由器地址与密码。"
            }
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
        guard settings.wifiOnlyLaunch else { return }
        let priorSSID = wifiMonitor.currentSSID
        wifiMonitor.refreshSSID()
        let effectiveSSID = wifiMonitor.currentSSID ?? (wifiMonitor.isWiFiPoweredOn ? priorSSID : nil)
        guard let ssid = effectiveSSID,
              RouterProfileMatcher.match(ssid: ssid, in: settings.profiles) != nil else {
            return
        }
        WiFiLaunchAgent.suppressLaunch(onSSID: ssid)
    }

    /// In Wi-Fi-only mode, immediately suspends polling and watchdog upon leaving a bound Wi-Fi, then
    /// quits after 1.5s on a definite unbound network / Wi-Fi off (or 8s grace while roaming with nil SSID).
    private func evaluateLeaveQuit(syncResumeNow: Bool = true) {
        let evaluation = wifiLifecycle.evaluate(
            wifiOnlyLaunch: settings.wifiOnlyLaunch,
            currentSSID: wifiMonitor.currentSSID,
            isWiFiPoweredOn: wifiMonitor.isWiFiPoweredOn,
            isBoundWiFiMatched: matchedProfileForCurrentWiFi != nil
        )

        if evaluation.isSuspendedOutsideBoundWiFi || syncResumeNow {
            syncUnboundSuspensionState()
        }

        switch evaluation.timerAction {
        case .none:
            break
        case .cancelTimer:
            leaveQuitGeneration += 1
            leaveQuitTask?.cancel()
            leaveQuitTask = nil
        case let .startTimer(tier):
            leaveQuitGeneration += 1
            let gen = leaveQuitGeneration
            leaveQuitTask?.cancel()
            leaveQuitTask = Task { [weak self] in
                // Suspending clock: time asleep does not count, so waking up does not quit before Wi-Fi rejoins.
                try? await Task.sleep(for: tier.delay, clock: .suspending)
                guard !Task.isCancelled, let self, self.leaveQuitGeneration == gen else { return }
                self.leaveQuitTask = nil
                self.wifiMonitor.refreshSSID()
                guard self.leaveQuitGeneration == gen else { return }
                if self.wifiLifecycle.timerDidFire(
                    wifiOnlyLaunch: self.settings.wifiOnlyLaunch,
                    isBoundWiFiMatched: self.matchedProfileForCurrentWiFi != nil,
                    isBlockingAutoQuit: self.isBlockingAutoQuit
                ) {
                    self.terminateHandler()
                } else {
                    self.syncUnboundSuspensionState()
                }
            }
        }
    }

    private func syncUnboundSuspensionState(skipClientRebuild: Bool = false) {
        if wifiLifecycle.isSuspendedOutsideBoundWiFi {
            guard !isActivitySuspendedForUnboundWiFi else { return }
            isActivitySuspendedForUnboundWiFi = true
            suspendActivityForUnboundWiFi()
        } else if isActivitySuspendedForUnboundWiFi {
            isActivitySuspendedForUnboundWiFi = false
            resumeActivityAfterBoundWiFiRestored(skipClientRebuild: skipClientRebuild)
        }
    }

    private func suspendActivityForUnboundWiFi() {
        stalledInitialPollRetryTask?.cancel()
        stalledInitialPollRetryTask = nil
        stopPolling()
        rebuildClient()
        let shouldRememberWatchdog = isWatchdogRunning || credentialState.shouldResumeWatchdog(
            isCredentialReady: isCredentialReady,
            isWatchdogRunning: isWatchdogRunning,
            autoStart: settings.watchdogConfig.autoStart,
            userStoppedWatchdog: userStoppedWatchdog
        )
        if shouldRememberWatchdog && !userStoppedWatchdog {
            watchdogPausedForUnboundWiFi = true
        }
        if isWatchdogRunning {
            stopWatchdog(userInitiated: false)
        }
        if watchdogPausedForUnboundWiFi {
            watchdogPhase = .paused(reason: "当前未连接已绑定 Wi-Fi")
        }
    }

    private func resumeActivityAfterBoundWiFiRestored(skipClientRebuild: Bool = false) {
        let isGUI = wifiMonitor.isInteractiveGUISession
        if !isCredentialReady {
            if isGUI {
                preloadAllProfilePasswordsIfNeeded(isInteractiveGUI: true)
            }
            reloadPasswordFromKeychain(isInteractiveGUI: isGUI)
            if isGUI {
                scheduleDeferredCooldownRetryIfNeeded()
            }
        }
        if !skipClientRebuild {
            rebuildClient()
        }
        startPolling()
        let shouldStartWatchdog = watchdogPausedForUnboundWiFi || credentialState.shouldResumeWatchdog(
            isCredentialReady: isCredentialReady,
            isWatchdogRunning: isWatchdogRunning,
            autoStart: settings.watchdogConfig.autoStart,
            userStoppedWatchdog: userStoppedWatchdog
        )
        watchdogPausedForUnboundWiFi = false
        if shouldStartWatchdog && isCredentialReady && !userStoppedWatchdog {
            if !isWatchdogRunning {
                startWatchdog()
            }
        } else {
            if activeCredentialIssue?.isSystemDeferred == true && shouldStartWatchdog {
                credentialState.noteWatchdogPausedForDeferredCredential(
                    wasRunning: true,
                    autoStart: settings.watchdogConfig.autoStart,
                    userStoppedWatchdog: userStoppedWatchdog
                )
            }
            if !isWatchdogRunning {
                watchdogPhase = .idle
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

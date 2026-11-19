import AppKit
import SwiftUI
import ZTERouterCore

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private let viewModel: RouterViewModel
    private let hotkeyManager = GlobalHotkeyManager()
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    private var dashboardWindow: NSWindow?
    private var isPopoverShown = false
    private var registeredHotkeyState: Bool?
    private var lastRenderedSignature: String = ""

    init(viewModel: RouterViewModel) {
        self.viewModel = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        configureStatusButton()
        configurePopover()
        observeState()
        syncHotkeyRegistration()
        viewModel.startPolling()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusButtonClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusButtonAppearance()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    /// Built on open and dropped on close, so no SwiftUI graph re-evaluates on every poll while hidden.
    private func makePopoverContent() -> NSViewController {
        let rootView = PopoverView(
            viewModel: viewModel,
            onOpenDashboard: { [weak self] tab in
                self?.closePopover()
                self?.openDashboard(tab: tab)
            },
            onOpenSettings: { [weak self] in
                self?.closePopover()
                self?.openDashboard(tab: .settings)
            },
            onQuit: { [weak self] in
                self?.quitByUser()
            }
        )
        let hosting = NSHostingController(rootView: rootView)
        hosting.view.layoutSubtreeIfNeeded()
        return hosting
    }

    private func quitByUser() {
        viewModel.noteUserQuit()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Observation

    private func observeState() {
        withObservationTracking {
            _ = viewModel.snapshot
            _ = viewModel.isReconnectingWAN
            _ = viewModel.isSessionOccupied
            _ = viewModel.isWatchdogRunning
            _ = viewModel.watchdogPhase
            _ = viewModel.lastError
            _ = viewModel.hasStoredPassword
            _ = viewModel.activeCredentialIssue
            _ = viewModel.passwordInput
            _ = viewModel.settings.activeProfileID
            _ = viewModel.settings.menuBarDisplayStyleRaw
            _ = viewModel.settings.globalShortcutEnabled
            _ = viewModel.wifiMonitor.currentSSID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateStatusButtonAppearance()
                self.syncHotkeyRegistration()
                self.observeState()
            }
        }
    }

    private func syncHotkeyRegistration() {
        let enabled = viewModel.settings.globalShortcutEnabled
        guard registeredHotkeyState != enabled else { return }
        registeredHotkeyState = enabled
        hotkeyManager.register(enabled: enabled) { [weak self] in
            guard let self else { return }
            Task { await self.viewModel.reconnectWAN() }
        }
    }

    private func updateStatusButtonAppearance() {
        guard let button = statusItem.button else { return }

        let symbolName: String
        let tintColor: NSColor
        let tintKey: String

        let isAutoReconnecting = (viewModel.watchdogPhase == .reconnecting)
        if viewModel.isReconnectingWAN || isAutoReconnecting {
            symbolName = "arrow.triangle.2.circlepath"
            tintColor = .systemOrange
            tintKey = "orange"
        } else if viewModel.isSessionOccupied {
            symbolName = "exclamationmark.triangle"
            tintColor = .systemOrange
            tintKey = "orange"
        } else if viewModel.activeCredentialIssue != nil {
            symbolName = "lock.fill"
            tintColor = .systemOrange
            tintKey = "orange"
        } else if !viewModel.hasStoredPassword {
            symbolName = "antenna.radiowaves.left.and.right.slash"
            tintColor = .secondaryLabelColor
            tintKey = "secondary"
        } else if let snap = viewModel.snapshot {
            if snap.connectionState.isConnected {
                symbolName = "globe"
                tintColor = .systemGreen
                tintKey = "green"
            } else if snap.connectionState.isTransitioning {
                symbolName = "arrow.triangle.2.circlepath"
                tintColor = .systemOrange
                tintKey = "orange"
            } else {
                symbolName = "network.slash"
                tintColor = .systemRed
                tintKey = "red"
            }
        } else if viewModel.lastError != nil {
            symbolName = "exclamationmark.triangle"
            tintColor = .systemOrange
            tintKey = "orange"
        } else {
            symbolName = "antenna.radiowaves.left.and.right"
            tintColor = .labelColor
            tintKey = "label"
        }

        let titleText: String
        if viewModel.isReconnectingWAN || viewModel.watchdogPhase == .reconnecting {
            titleText = " 重连中"
        } else if viewModel.isSessionOccupied {
            titleText = viewModel.settings.menuBarDisplayStyle == .iconOnly ? "" : " 占用"
        } else if viewModel.activeCredentialIssue != nil {
            titleText = viewModel.settings.menuBarDisplayStyle == .iconOnly ? "" : " 待授权"
        } else if let snap = viewModel.snapshot {
            switch viewModel.settings.menuBarDisplayStyle {
            case .iconOnly:
                titleText = ""
            case .iconAndSignal:
                titleText = " " + SignalEvaluator.menuBarSignalText(for: snap)
            case .iconAndBand:
                if snap.connectionState.isConnected {
                    let net = snap.is5G ? "5G" : (snap.isLTE ? "4G" : snap.networkType)
                    let band = snap.nrCells.first?.band ?? snap.lteCells.first?.band ?? ""
                    titleText = band.isEmpty ? " \(net)" : " \(net) \(band)"
                } else {
                    titleText = " 断网"
                }
            }
        } else {
            titleText = ""
        }

        let tipText = buildTooltip()
        let signature = "\(symbolName)|\(tintKey)|\(titleText)|\(tipText)"
        guard signature != lastRenderedSignature else { return }
        lastRenderedSignature = signature

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tintColor]))
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ZTE Router")?.withSymbolConfiguration(config)
        image?.isTemplate = false
        button.image = image
        button.imagePosition = .imageLeading
        button.title = titleText
        button.toolTip = tipText
    }

    private func buildTooltip() -> String {
        let profileName = viewModel.activeProfile.name
        let watchdogStatus = viewModel.isWatchdogRunning ? "保活守护：\(viewModel.watchdogPhase.displayLabel)" : "保活守护：已关闭"
        guard let snap = viewModel.snapshot else {
            return "ZTE 移动路由助手 (\(profileName))\n\(watchdogStatus)\n左键打开面板 · ⌥+左键一键重连外网"
        }
        let assessment = SignalEvaluator.assess(snapshot: snap)
        let rsrpText = assessment.rsrp.map { " · RSRP \(Int($0.rounded())) dBm" } ?? ""
        let sinrText = assessment.sinr.map { " · SINR \(String(format: "%.1f", $0)) dB" } ?? ""
        return """
        [\(profileName)] \(snap.connectionState.localizedLabel) · \(snap.networkType) \(snap.bandSummary)
        信号：\(assessment.grade.rawValue) (\(assessment.score)分)\(rsrpText)\(sinrText) · 终端 \(snap.totalConnectedDevices) 台
        \(watchdogStatus)
        左键打开面板 · ⌥+左键一键重连外网 · 右键菜单
        """
    }

    // MARK: - Click Handling

    @objc private func handleStatusButtonClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            closePopover()
            showContextMenu()
            return
        }

        if event?.modifierFlags.contains(.option) == true {
            Task { await viewModel.reconnectWAN() }
            return
        }

        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        viewModel.prepareCredentialsForInteractiveMenuOrPopover()
        let content = makePopoverContent()
        popover.contentViewController = content
        popover.contentSize = content.view.fittingSize
        isPopoverShown = true
        updateActiveState()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        isPopoverShown = false
        updateActiveState()
    }

    // MARK: - Context Menu

    private func showContextMenu() {
        viewModel.prepareCredentialsForInteractiveMenuOrPopover()
        let menu = NSMenu()

        let statusText: String
        if let snap = viewModel.snapshot {
            statusText = "[\(viewModel.activeProfile.name)] \(snap.connectionState.localizedLabel) · \(snap.networkType) \(snap.bandSummary)"
        } else {
            statusText = "ZTE 移动路由助手 · \(viewModel.activeProfile.name)"
        }
        let headerItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())

        if viewModel.activeCredentialIssue != nil {
            let unlockItem = NSMenuItem(title: "立即读取钥匙串密码…", action: #selector(menuRetryUnlockKeychain), keyEquivalent: "")
            unlockItem.target = self
            menu.addItem(unlockItem)
            menu.addItem(.separator())
        }

        let isConnected = viewModel.snapshot?.connectionState.isConnected ?? true
        let reconnectTitle = isConnected ? "一键重连外网 (⌃⌥W)" : "立即连接外网 (⌃⌥W)"
        let reconnectItem = NSMenuItem(title: reconnectTitle, action: #selector(menuReconnectWAN), keyEquivalent: "")
        reconnectItem.target = self
        reconnectItem.isEnabled = viewModel.isCredentialReady && !viewModel.isReconnectingWAN
        menu.addItem(reconnectItem)

        let watchdogTitle = viewModel.isWatchdogRunning ? "停止外网保活守护" : "开启外网保活守护"
        let watchdogItem = NSMenuItem(title: watchdogTitle, action: #selector(menuToggleWatchdog), keyEquivalent: "")
        watchdogItem.target = self
        watchdogItem.isEnabled = viewModel.isCredentialReady
        menu.addItem(watchdogItem)

        if viewModel.settings.profiles.count > 1 {
            let profileMenuItem = NSMenuItem(title: "切换路由器配置", action: nil, keyEquivalent: "")
            let profileSubmenu = NSMenu()
            for profile in viewModel.settings.profiles {
                let ssids = profile.wifiSSIDs.isEmpty ? "" : " (\(profile.wifiSSIDs.joined(separator: ", ")))"
                let item = NSMenuItem(
                    title: "\(profile.name)\(ssids)",
                    action: #selector(menuSelectProfile(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = profile.id.uuidString
                if profile.id == viewModel.settings.activeProfileID {
                    item.state = .on
                }
                profileSubmenu.addItem(item)
            }
            profileMenuItem.submenu = profileSubmenu
            menu.addItem(profileMenuItem)
        }

        menu.addItem(.separator())

        let dashItem = NSMenuItem(title: "打开控制台…", action: #selector(menuOpenDashboard), keyEquivalent: "")
        dashItem.target = self
        menu.addItem(dashItem)

        let watchdogSettingsItem = NSMenuItem(title: "保活守护设置与日志…", action: #selector(menuOpenWatchdog), keyEquivalent: "")
        watchdogSettingsItem.target = self
        menu.addItem(watchdogSettingsItem)

        let webItem = NSMenuItem(title: "在浏览器打开管理界面", action: #selector(menuOpenBrowser), keyEquivalent: "")
        webItem.target = self
        menu.addItem(webItem)

        let settingsItem = NSMenuItem(title: "配置与设置…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 ZTERouterBar", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuRetryUnlockKeychain() {
        viewModel.retryUnlockKeychainFromUserAction()
    }

    @objc private func menuReconnectWAN() {
        Task { await viewModel.reconnectWAN() }
    }

    @objc private func menuToggleWatchdog() {
        viewModel.toggleWatchdog()
    }

    @objc private func menuSelectProfile(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw) else { return }
        viewModel.selectProfile(id)
    }

    @objc private func menuOpenDashboard() {
        openDashboard(tab: .overview)
    }

    @objc private func menuOpenWatchdog() {
        openDashboard(tab: .watchdog)
    }

    @objc private func menuOpenSettings() {
        openDashboard(tab: .settings)
    }

    @objc private func menuOpenBrowser() {
        if let url = URL(string: "\(viewModel.activeProfile.routerURLString)/index.html") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func menuQuit() {
        quitByUser()
    }

    // MARK: - Window Management

    func openDashboard(tab: DashboardTab) {
        viewModel.selectedDashboardTab = tab
        if let window = dashboardWindow {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            updateActiveState()
            return
        }

        let hosting = NSHostingController(rootView: DashboardView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hosting)
        window.title = "ZTE 移动路由控制台"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 860, height: 600))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.dashboardWindow = window

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateActiveState()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === dashboardWindow {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                // Release the window and its SwiftUI graph unless it was reopened in the meantime.
                if let window = self.dashboardWindow, !window.isVisible {
                    window.delegate = nil
                    window.contentViewController = nil
                    self.dashboardWindow = nil
                }
                self.updateActiveState()
            }
        }
    }

    private func updateActiveState() {
        let windowVisible = dashboardWindow?.isVisible ?? false
        viewModel.setUIActive(isPopoverShown || windowVisible)
    }
}

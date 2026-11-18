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
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )
        popover.contentViewController = NSHostingController(rootView: rootView)
    }

    // MARK: - Observation

    private func observeState() {
        withObservationTracking {
            _ = viewModel.snapshot
            _ = viewModel.isReconnectingWAN
            _ = viewModel.isSessionOccupied
            _ = viewModel.lastError
            _ = viewModel.hasStoredPassword
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

        if viewModel.isReconnectingWAN {
            symbolName = "arrow.triangle.2.circlepath"
            tintColor = .systemOrange
        } else if viewModel.isSessionOccupied {
            symbolName = "exclamationmark.triangle"
            tintColor = .systemOrange
        } else if !viewModel.hasStoredPassword {
            symbolName = "antenna.radiowaves.left.and.right.slash"
            tintColor = .secondaryLabelColor
        } else if let snap = viewModel.snapshot {
            if snap.connectionState.isConnected {
                symbolName = "globe"
                tintColor = .systemGreen
            } else if snap.connectionState.isTransitioning {
                symbolName = "arrow.triangle.2.circlepath"
                tintColor = .systemOrange
            } else {
                symbolName = "network.slash"
                tintColor = .systemRed
            }
        } else if viewModel.lastError != nil {
            symbolName = "exclamationmark.triangle"
            tintColor = .systemOrange
        } else {
            symbolName = "antenna.radiowaves.left.and.right"
            tintColor = .labelColor
        }

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tintColor]))
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ZTE Router")?.withSymbolConfiguration(config)
        image?.isTemplate = false
        button.image = image
        button.imagePosition = .imageLeading

        let titleText: String
        if viewModel.isReconnectingWAN {
            titleText = " 重连中"
        } else if viewModel.isSessionOccupied {
            titleText = viewModel.settings.menuBarDisplayStyle == .iconOnly ? "" : " 占用"
        } else if let snap = viewModel.snapshot {
            switch viewModel.settings.menuBarDisplayStyle {
            case .iconOnly:
                titleText = ""
            case .iconAndBand:
                if snap.connectionState.isConnected {
                    let net = snap.is5G ? "5G" : (snap.isLTE ? "4G" : snap.networkType)
                    let band = snap.nrCells.first?.band ?? snap.lteCells.first?.band ?? ""
                    titleText = band.isEmpty ? " \(net)" : " \(net) \(band)"
                } else {
                    titleText = " 断网"
                }
            case .iconAndSpeed:
                if snap.connectionState.isConnected {
                    titleText = " ↓\(Formatters.compactSpeed(snap.rxBytesPerSec)) ↑\(Formatters.compactSpeed(snap.txBytesPerSec))"
                } else {
                    titleText = " 断网"
                }
            }
        } else {
            titleText = ""
        }

        button.title = titleText
        button.toolTip = buildTooltip()
    }

    private func buildTooltip() -> String {
        let profileName = viewModel.activeProfile.name
        guard let snap = viewModel.snapshot else {
            return "ZTE 移动路由助手 (\(profileName))\n左键打开面板 · ⌥+左键一键重连外网"
        }
        return """
        [\(profileName)] \(snap.connectionState.localizedLabel) · \(snap.networkType) \(snap.bandSummary)
        ↓ \(Formatters.speedBits(snap.rxBytesPerSec))  ↑ \(Formatters.speedBits(snap.txBytesPerSec)) · 终端 \(snap.totalConnectedDevices) 台
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
        isPopoverShown = true
        updateActiveState()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        isPopoverShown = false
        updateActiveState()
    }

    // MARK: - Context Menu

    private func showContextMenu() {
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

        let isConnected = viewModel.snapshot?.connectionState.isConnected ?? true
        let reconnectTitle = isConnected ? "一键重连外网 (⌃⌥W)" : "立即连接外网 (⌃⌥W)"
        let reconnectItem = NSMenuItem(title: reconnectTitle, action: #selector(menuReconnectWAN), keyEquivalent: "")
        reconnectItem.target = self
        reconnectItem.isEnabled = viewModel.hasStoredPassword && !viewModel.isReconnectingWAN
        menu.addItem(reconnectItem)

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

    @objc private func menuReconnectWAN() {
        Task { await viewModel.reconnectWAN() }
    }

    @objc private func menuSelectProfile(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw) else { return }
        viewModel.selectProfile(id)
    }

    @objc private func menuOpenDashboard() {
        openDashboard(tab: .overview)
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
        NSApplication.shared.terminate(nil)
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
                self.updateActiveState()
            }
        }
    }

    private func updateActiveState() {
        let windowVisible = dashboardWindow?.isVisible ?? false
        viewModel.setUIActive(isPopoverShown || windowVisible)
    }
}

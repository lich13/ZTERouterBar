import AppKit
import CoreGraphics
import CoreLocation
import CoreWLAN
import Foundation
import Network
import ZTERouterCore

@MainActor
@Observable
final class WiFiNetworkMonitor: NSObject, CLLocationManagerDelegate, CWEventDelegate {
    var currentSSID: String?
    var isWiFiPoweredOn: Bool
    var authorizationStatus: CLAuthorizationStatus
    var isWiFiPathSatisfied: Bool = false

    private let locationManager = CLLocationManager()
    private let wifiClient = CWWiFiClient.shared()
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let monitorQueue = DispatchQueue(label: "com.zte.routerbar.wifiMonitor")
    @ObservationIgnored private var networkChangeToken: DarwinNotificationToken?

    private var screensKnownAsleep = false
    private var ssidRetryTask: Task<Void, Never>?
    private var guiEventDebounceTask: Task<Void, Never>?

    var isLocationAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .authorizedAlways
    }

    var isInteractiveGUISession: Bool {
        Self.queryInteractiveGUISession(screensKnownAsleep: screensKnownAsleep)
    }

    var onSSIDChanged: (@MainActor (String?) -> Void)?
    var onWiFiPathReady: (@MainActor () -> Void)?
    var onSystemWillSleep: (@MainActor () -> Void)?
    var onSystemDidWake: (@MainActor () -> Void)?
    var onInteractiveGUIEvent: (@MainActor () -> Void)?

    override init() {
        self.authorizationStatus = locationManager.authorizationStatus
        self.isWiFiPoweredOn = wifiClient.interface()?.powerOn() ?? false
        super.init()
        locationManager.delegate = self
        wifiClient.delegate = self

        try? wifiClient.startMonitoringEvent(with: .ssidDidChange)
        try? wifiClient.startMonitoringEvent(with: .linkDidChange)
        try? wifiClient.startMonitoringEvent(with: .bssidDidChange)
        try? wifiClient.startMonitoringEvent(with: .powerDidChange)

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = (path.status == .satisfied)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let becameSatisfied = !self.isWiFiPathSatisfied && satisfied
                self.isWiFiPathSatisfied = satisfied
                self.refreshSSID(scheduleFollowUpIfNil: satisfied)
                if becameSatisfied {
                    self.onWiFiPathReady?()
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)

        self.networkChangeToken = DarwinNotificationToken.register(
            name: "com.apple.system.config.network_change",
            queue: monitorQueue
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshSSID(scheduleFollowUpIfNil: true)
                if self.isWiFiPathSatisfied || self.isWiFiPoweredOn {
                    self.onWiFiPathReady?()
                }
            }
        }

        registerSessionAndPowerObservers()
        refreshSSID(scheduleFollowUpIfNil: true)
    }

    deinit {
        pathMonitor.cancel()
    }

    func requestLocationPermission() {
        NSApp.activate(ignoringOtherApps: true)
        locationManager.requestWhenInUseAuthorization()
        refreshSSID(scheduleFollowUpIfNil: true)
    }

    func openSystemLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshSSID(scheduleFollowUpIfNil: Bool = false) {
        authorizationStatus = locationManager.authorizationStatus
        let iface = wifiClient.interface()
        let poweredOn = iface?.powerOn() ?? false
        let detected = poweredOn ? iface?.ssid()?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let normalized = (detected?.isEmpty == false) ? detected : nil

        if normalized != nil || !poweredOn {
            ssidRetryTask?.cancel()
            ssidRetryTask = nil
        } else if scheduleFollowUpIfNil && isLocationAuthorized && ssidRetryTask == nil {
            ssidRetryTask = Task { [weak self] in
                for _ in 0..<12 {
                    try? await Task.sleep(for: .milliseconds(400), clock: .suspending)
                    guard !Task.isCancelled, let self else { return }
                    self.refreshSSID(scheduleFollowUpIfNil: false)
                    if self.currentSSID != nil || !self.isWiFiPoweredOn {
                        break
                    }
                }
                self?.ssidRetryTask = nil
            }
        }

        let ssidChanged = (currentSSID != normalized)
        let powerChanged = (isWiFiPoweredOn != poweredOn)
        isWiFiPoweredOn = poweredOn
        currentSSID = normalized
        if ssidChanged || powerChanged {
            onSSIDChanged?(normalized)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.authorizationStatus = status
            self?.refreshSSID(scheduleFollowUpIfNil: true)
        }
    }

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in
            self?.refreshSSID(scheduleFollowUpIfNil: true)
        }
    }

    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in
            self?.refreshSSID(scheduleFollowUpIfNil: true)
        }
    }

    nonisolated func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in
            self?.refreshSSID(scheduleFollowUpIfNil: true)
        }
    }

    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in
            self?.refreshSSID(scheduleFollowUpIfNil: true)
        }
    }

    nonisolated func clientConnectionInterrupted() {
        Task { @MainActor [weak self] in
            self?.refreshSSID(scheduleFollowUpIfNil: true)
        }
    }

    // MARK: - Session & Power Monitoring

    private func registerSessionAndPowerObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.guiEventDebounceTask?.cancel()
                self.guiEventDebounceTask = nil
                self.onSystemWillSleep?()
            }
        }

        wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onSystemDidWake?()
                self.scheduleInteractiveGUICheck()
            }
        }

        wsCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.screensKnownAsleep = true
            }
        }

        wsCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.screensKnownAsleep = false
                self.scheduleInteractiveGUICheck()
            }
        }

        wsCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleInteractiveGUICheck()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.screensKnownAsleep = false
                self.scheduleInteractiveGUICheck()
            }
        }
    }

    private func scheduleInteractiveGUICheck() {
        guiEventDebounceTask?.cancel()
        guiEventDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: ProfileCredentialStateMachine.guiEventDebounceDuration, clock: .suspending)
            guard !Task.isCancelled, let self else { return }
            self.guiEventDebounceTask = nil
            guard self.isInteractiveGUISession else { return }
            self.onInteractiveGUIEvent?()
        }
    }

    /// Returns true only when this session is on console, the screen is unlocked, and at least one display is awake
    /// (preventing `securityd` prompts from firing during DarkWake or behind the lock screen).
    static func queryInteractiveGUISession(screensKnownAsleep: Bool) -> Bool {
        if screensKnownAsleep {
            return false
        }
        guard let rawDict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        if let onConsole = rawDict["kCGSSessionOnConsoleKey"] as? Bool, !onConsole {
            return false
        }
        if let isLocked = rawDict["CGSSessionScreenIsLocked"] as? Bool, isLocked {
            return false
        }

        var displayCount: UInt32 = 0
        if CGGetOnlineDisplayList(0, nil, &displayCount) == .success, displayCount > 0 {
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
            if CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success {
                let list = displays.prefix(Int(displayCount))
                if !list.isEmpty && list.allSatisfy({ CGDisplayIsAsleep($0) != 0 }) {
                    return false
                }
            }
        } else if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            return false
        }
        return true
    }
}

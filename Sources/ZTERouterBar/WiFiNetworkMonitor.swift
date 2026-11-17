import AppKit
import CoreLocation
import CoreWLAN
import Foundation
import Network

@MainActor
@Observable
final class WiFiNetworkMonitor: NSObject, CLLocationManagerDelegate, CWEventDelegate {
    var currentSSID: String?
    var authorizationStatus: CLAuthorizationStatus

    private let locationManager = CLLocationManager()
    private let wifiClient = CWWiFiClient.shared()
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let monitorQueue = DispatchQueue(label: "com.zte.routerbar.wifiMonitor")

    var isLocationAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .authorizedAlways
    }

    var onSSIDChanged: (@MainActor (String?) -> Void)?

    override init() {
        self.authorizationStatus = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
        wifiClient.delegate = self

        try? wifiClient.startMonitoringEvent(with: .ssidDidChange)
        try? wifiClient.startMonitoringEvent(with: .linkDidChange)

        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSSID()
            }
        }
        pathMonitor.start(queue: monitorQueue)
        refreshSSID()
    }

    func requestLocationPermission() {
        NSApp.activate(ignoringOtherApps: true)
        locationManager.requestWhenInUseAuthorization()
        refreshSSID()
    }

    func openSystemLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshSSID() {
        authorizationStatus = locationManager.authorizationStatus
        let detected = wifiClient.interface()?.ssid()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (detected?.isEmpty == false) ? detected : nil
        if currentSSID != normalized {
            currentSSID = normalized
            onSSIDChanged?(normalized)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.authorizationStatus = status
            self?.refreshSSID()
        }
    }

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in
            self?.refreshSSID()
        }
    }

    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in
            self?.refreshSSID()
        }
    }
}

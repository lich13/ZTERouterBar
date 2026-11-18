import Foundation
import Testing
@testable import ZTERouterCore

@Suite("ZTERouterCore Tests")
struct ZTERouterCoreTests {
    @Test("SHA-256 uppercase and login challenge match ZTE util.js")
    func testCrypto() {
        #expect(
            RouterCrypto.sha256Upper("abc")
                == "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
        )

        let pwHash = RouterCrypto.sha256Upper("demo-password")
        let challenge = RouterCrypto.computeLoginPassword(plainPassword: "demo-password", ld: "SALT123")
        #expect(challenge == RouterCrypto.sha256Upper(pwHash + "SALT123"))

        let adSha = RouterCrypto.computeAD(
            waInnerVersion: "BD_FLYMODEMMU5120V1.0.1B12",
            crVersion: "",
            rd: "RAND456",
            algorithm: .sha256
        )
        #expect(adSha == RouterCrypto.sha256Upper(RouterCrypto.sha256Upper("BD_FLYMODEMMU5120V1.0.1B12") + "RAND456"))

        let adMd5 = RouterCrypto.computeAD(
            waInnerVersion: "BD_MC801AV1.0.0",
            crVersion: "CR1",
            rd: "RD1",
            algorithm: .md5
        )
        #expect(adMd5.count == 32)
        #expect(adMd5 == adMd5.lowercased())

        #expect(
            ResolvedHashAlgorithm.resolve(waInnerVersion: "BD_FLYMODEMMU5120V1.0.1B12", preference: .auto) == .sha256
        )
        #expect(
            ResolvedHashAlgorithm.resolve(waInnerVersion: "BD_MC801AV1.0.0B01", preference: .auto) == .md5
        )
    }

    @Test("Profile normalization and Wi-Fi SSID auto-matching")
    func testProfileMatcher() {
        let normalized = RouterProfile.normalizeSSIDList(" Office_5G , office_5g, Home_WiFi \n Guest ")
        #expect(normalized == ["Office_5G", "Home_WiFi", "Guest"])

        let p1 = RouterProfile(name: "Pocket", routerURLString: "http://192.168.8.1", wifiSSIDs: ["Travel_5G", "Travel_24G"])
        let p2 = RouterProfile(name: "Home", routerURLString: "http://192.168.1.1", wifiSSIDs: ["HomeCPE"])

        #expect(RouterProfileMatcher.match(ssid: "travel_5g", in: [p1, p2])?.id == p1.id)
        #expect(RouterProfileMatcher.match(ssid: " HomeCPE ", in: [p1, p2])?.id == p2.id)
        #expect(RouterProfileMatcher.match(ssid: "UnknownWiFi", in: [p1, p2]) == nil)
        #expect(RouterProfileMatcher.match(ssid: nil, in: [p1, p2]) == nil)
    }

    @Test("Status parser combines radio counts, station_list, lan_station_list and hides bogus WIFI5 label")
    func testStatusAndStationCountParser() throws {
        let mu5120JSON1 = """
        {
          "wa_inner_version": "BD_FLYMODEMMU5120V1.0.1B12",
          "cr_version": "",
          "hardware_version": "MU5120_HWV2.0",
          "web_version": "WEB_TEST_1.0",
          "ppp_status": "ipv4_ipv6_connected",
          "wan_connect_status": "pdp_connected",
          "network_type": "SA",
          "network_provider": "CMCC",
          "mdm_mcc": "460",
          "mdm_mnc": "02",
          "wan_apn": "CMIOT5G",
          "wan_ipaddr": "10.0.0.2",
          "ipv6_wan_ipaddr": "2001:db8::2",
          "bandwidth": "100MHz",
          "Z5g_rsrp": "-76",
          "Z5g_rsrq": "-11",
          "Z5g_SINR": "22.0",
          "nr5g_cell_id": "151918002",
          "nr5g_pci": "297",
          "nr5g_action_channel": "504990",
          "nr5g_action_band": "n41",
          "pm_sensor_mdm": "41",
          "pm_sensor_pa1": "39",
          "wifi_chip_temp": "47"
        }
        """

        let mu5120JSON2 = """
        {
          "net_select": "Only_5G",
          "realtime_tx_thrpt": "15409",
          "realtime_rx_thrpt": "10007",
          "realtime_time": "20613",
          "battery_value": "100",
          "battery_charging": "2",
          "wifi_access_sta_num": "6",
          "wifi_chip1_ssid1_access_sta_num": "1",
          "wifi_chip2_ssid1_access_sta_num": "5"
        }
        """

        let stationListJSON = """
        {
          "station_list": [
            {"interfacetype": "WIFI5", "ip_addr": "192.168.8.47", "connect_time": "120", "ssid_index": "2", "mac_addr": "00:00:5E:00:53:01", "hostname": "device-1"},
            {"interfacetype": "WIFI5", "ip_addr": "192.168.8.48", "connect_time": "60", "ssid_index": "1", "mac_addr": "00:00:5E:00:53:02", "hostname": "device-2"}
          ]
        }
        """

        let lanStationListJSON = """
        {
          "lan_station_list": [
            {"interfacetype": "", "ip_addr": "192.168.8.50", "connect_time": "300", "ssid_index": "", "mac_addr": "00:00:5E:00:53:03", "hostname": "wired-1"}
          ]
        }
        """

        let snap = try RouterStatusParser.parse(jsonDataList: [
            Data(mu5120JSON1.utf8),
            Data(mu5120JSON2.utf8),
            Data(stationListJSON.utf8),
            Data(lanStationListJSON.utf8)
        ])

        #expect(snap.connectionState.isConnected)
        #expect(snap.is5GSA)
        #expect(snap.bandSummary == "n41(100MHz)")
        #expect(snap.nrCells.count == 1)
        #expect(snap.nrCells[0].pci == "297")
        #expect(snap.nrCells[0].band == "n41")
        #expect(snap.wifiAccessStationCount == 6)
        #expect(snap.wifi24GCount == 1)
        #expect(snap.wifi5GCount == 5)
        #expect(snap.wirelessDeviceCount == 6)
        #expect(snap.wiredDeviceCount == 1)
        #expect(snap.totalConnectedDevices == 7)
        #expect(snap.wifiStations.count == 2)
        #expect(snap.wifiStations[0].deviceKind == .wireless)
        #expect(snap.wifiStations[0].displayConnectionType == "无线 Wi-Fi")
        #expect(snap.lanStations.count == 1)
        #expect(snap.lanStations[0].deviceKind == .wired)
        #expect(snap.lanStations[0].displayConnectionType == "有线 / USB")
    }

    @Test("Status parser parses LTE CA + NSA cells and filters invalid sensors")
    func testLTECAParser() throws {
        let lteJSON = """
        {
          "wa_inner_version": "BD_MC888V1.0",
          "network_type": "ENDC",
          "wan_lte_ca": "ca_activated",
          "lte_pci": "1A",
          "lte_ca_pcell_band": "3",
          "lte_ca_pcell_freq": "1525",
          "lte_ca_pcell_bandwidth": "20MHz",
          "lte_rsrp_1": "-85",
          "lte_snr_1": "15.0",
          "lte_rsrq": "-9",
          "lte_multi_ca_scell_info": "1,2B,2,1,300,15.0;",
          "lte_multi_ca_scell_sig_info": "-90.0,-8.0,12.5,0,2;",
          "nr5g_pci": "64",
          "nr5g_action_channel": "639936",
          "nr5g_action_nsa_band": "78",
          "5g_rx0_rsrp": "-82",
          "Z5g_SINR": "18.5",
          "pm_sensor_ambient": "-273"
        }
        """

        let snap = try RouterStatusParser.parse(jsonDataList: [Data(lteJSON.utf8)])
        #expect(snap.isLTE)
        #expect(snap.is5GNSA)
        #expect(snap.isLTECarrierAggregationActive)
        #expect(snap.lteCells.count == 2)
        #expect(snap.lteCells[0].pci == "26")
        #expect(snap.lteCells[0].band == "B3")
        #expect(snap.lteCells[1].pci == "43")
        #expect(snap.lteCells[1].band == "B1")
        #expect(snap.nrCells.count == 1)
        #expect(snap.nrCells[0].band == "n78")
        #expect(snap.temperatures.isEmpty)
    }

    @Test("Client sends multi_data=1 on loginfo, queries station_list individually, and recovers from kicked session on reconnect")
    func testClientKickedSessionRecoveryAndReconnect() async throws {
        let transport = MockTransport(simulateKickedOutBeforeDisconnect: true, simulateDuplicateUntilLogout: true)
        let config = try RouterEndpointConfig(baseURLString: "http://192.168.8.1", hashPreference: .auto)
        let client = ZTERouterClient(config: config, password: "fixture-password", transport: transport)

        await #expect(throws: ZTERouterError.duplicateUser) {
            _ = try await client.fetchStatus(reclaimIfDuplicate: false)
        }

        let finalState = try await client.reconnectInternet(pauseBetweenDisconnectAndConnect: .milliseconds(10))
        #expect(finalState.isConnected)

        let snap = try await client.fetchStatus()
        #expect(snap.wirelessDeviceCount == 6)
        #expect(snap.wifiStations.count == 2)
        #expect(snap.wiredDeviceCount == 1)
        #expect(snap.totalConnectedDevices == 7)

        let captured = await transport.capturedRequests
        for req in captured {
            #expect(req.value(forHTTPHeaderField: "Referer") == "http://192.168.8.1/index.html")
            #expect(req.value(forHTTPHeaderField: "Origin") == "http://192.168.8.1")
        }

        let loginfoQueries = captured.filter {
            $0.httpMethod == "GET" && ($0.url?.absoluteString.contains("cmd=loginfo") ?? false)
        }
        #expect(!loginfoQueries.isEmpty)
        for q in loginfoQueries {
            #expect(q.url?.absoluteString.contains("multi_data=1") == true)
        }

        let stationQueries = captured.filter {
            $0.httpMethod == "GET" && ($0.url?.absoluteString.contains("cmd=station_list") ?? false)
        }
        #expect(stationQueries.count == 1)
        #expect(!(stationQueries[0].url?.absoluteString.contains("multi_data=1") ?? true))

        let postGoforms = captured.compactMap { req -> String? in
            guard req.httpMethod == "POST", let body = req.httpBody, let text = String(data: body, encoding: .utf8) else { return nil }
            return text.split(separator: "&").first(where: { $0.hasPrefix("goformId=") }).map(String.init)
        }
        #expect(postGoforms.contains("goformId=LOGOUT"))
        #expect(postGoforms.contains("goformId=DISCONNECT_NETWORK"))
        #expect(postGoforms.contains("goformId=CONNECT_NETWORK"))
    }

    @Test("Client surfaces wrongPassword error on code 3")
    func testWrongPasswordError() async throws {
        let transport = MockTransport(rejectLogin: true)
        let config = try RouterEndpointConfig(baseURLString: "http://192.168.8.1")
        let client = ZTERouterClient(config: config, password: "wrong", transport: transport)

        await #expect(throws: ZTERouterError.wrongPassword) {
            _ = try await client.fetchStatus()
        }
    }

    @Test("Watchdog config defaults, presets, and trigger policy evaluation")
    func testWatchdogConfigAndPolicies() {
        let cfg = WatchdogConfig()
        #expect(cfg.autoStart == true)
        #expect(cfg.triggerPolicy == .allUnreachable)
        #expect(cfg.endpoints.count == 3)
        #expect(cfg.endpoints.allSatisfy { $0.isValidHTTPURL && $0.proxyMode == .system })

        let ok = EndpointProbeOutcome(id: UUID(), name: "A", urlString: "https://example.invalid", proxyMode: .system, reachable: true, statusCode: 204, elapsedMs: 50)
        let fail = EndpointProbeOutcome(id: UUID(), name: "B", urlString: "https://example.invalid", proxyMode: .system, reachable: false, errorMessage: "timeout")

        #expect(WatchdogEvaluator.isHealthy(outcomes: [ok, fail], policy: .allUnreachable) == true)
        #expect(WatchdogEvaluator.isHealthy(outcomes: [fail, fail], policy: .allUnreachable) == false)
        #expect(WatchdogEvaluator.isHealthy(outcomes: [ok, fail], policy: .anyUnreachable) == false)
        #expect(WatchdogEvaluator.isHealthy(outcomes: [ok, ok], policy: .anyUnreachable) == true)
    }

    @Test("Watchdog ignores transient jitter when recheck recovers")
    func testWatchdogJitterRecheckPreventsReconnect() async {
        // Round 1 fails, Recheck 1 recovers -> zero reconnects
        let prober = ScriptedProber(roundResults: [false, true, true])
        let router = MockReconnectRouter()
        var cfg = WatchdogConfig(recheckBeforeAct: 3)
        cfg.endpoints = [WatchdogEndpoint(name: "Test", urlString: "https://example.invalid")]

        let runner = WatchdogRunner(sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
        let collector = PhaseCollector()
        let task = Task {
            await runner.run(config: cfg, prober: prober, router: router) { event in
                await collector.record(event)
            }
        }

        // Wait until at least 3 probe rounds execute
        for _ in 0..<50 {
            if await prober.completedRounds >= 3 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await task.value

        let reconnects = await router.reconnectCount
        #expect(reconnects == 0)
    }

    @Test("Watchdog triggers reconnect after confirmed failure and cools down after repeated failures")
    func testWatchdogReconnectAndCooldown() async {
        // 1 initial fail + 2 recheck fails -> reconnect #1 -> post-check fails -> reconnect #2 -> post-check fails -> cooldown -> next round succeeds
        let prober = ScriptedProber(roundResults: [
            false, false, false, // initial + 2 rechecks
            false,               // post reconnect #1 still failing
            false,               // post reconnect #2 still failing -> cooldown
            true                 // after cooldown recovered
        ])
        let router = MockReconnectRouter()
        var cfg = WatchdogConfig(recheckBeforeAct: 2, maxConsecutiveReconnects: 2, cooldownSec: 60)
        cfg.endpoints = [WatchdogEndpoint(name: "Test", urlString: "https://example.invalid")]

        let runner = WatchdogRunner(sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
        let collector = PhaseCollector()
        let task = Task {
            await runner.run(config: cfg, prober: prober, router: router) { event in
                await collector.record(event)
            }
        }

        for _ in 0..<80 {
            if await prober.completedRounds >= 6 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await task.value

        let reconnects = await router.reconnectCount
        let phases = await collector.phases
        #expect(reconnects == 2)
        #expect(phases.contains(.reconnecting))
        #expect(phases.contains(.verifyingAfterReconnect))
        #expect(phases.contains(.coolingDown(seconds: 60)))
    }

    @Test("URLEndpointProber rejects invalid URL and invalid proxy config immediately")
    func testProberValidation() async {
        let prober = URLEndpointProber()
        let badURL = WatchdogEndpoint(name: "Bad", urlString: "not-a-url")
        let out1 = await prober.check(badURL, timeoutMs: 1000)
        #expect(out1.reachable == false)
        #expect(out1.errorMessage?.isEmpty == false)

        let badProxy = WatchdogEndpoint(name: "BadProxy", urlString: "https://example.invalid", proxyMode: .socks5, proxyHost: "", proxyPort: 1080)
        let out2 = await prober.check(badProxy, timeoutMs: 1000)
        #expect(out2.reachable == false)
        #expect(out2.errorMessage?.contains("SOCKS5") == true)
    }
}

private actor ScriptedProber: EndpointProbing {
    private var roundResults: [Bool]
    private(set) var completedRounds = 0

    init(roundResults: [Bool]) {
        self.roundResults = roundResults
    }

    func check(_ endpoint: WatchdogEndpoint, timeoutMs: Int) async -> EndpointProbeOutcome {
        let idx = completedRounds
        completedRounds += 1
        let ok = idx < roundResults.count ? roundResults[idx] : true
        return EndpointProbeOutcome(
            id: endpoint.id,
            name: endpoint.displayTitle,
            urlString: endpoint.urlString,
            proxyMode: endpoint.proxyMode,
            reachable: ok,
            statusCode: ok ? 204 : nil,
            elapsedMs: 12,
            errorMessage: ok ? nil : "simulated failure"
        )
    }
}

private actor MockReconnectRouter: RouterReconnecting {
    private(set) var reconnectCount = 0

    func reconnectInternet() async throws -> WANConnectionState {
        reconnectCount += 1
        return .connected(rawStatus: "ipv4_ipv6_connected")
    }
}

private actor PhaseCollector {
    private(set) var phases: [WatchdogPhase] = []

    func record(_ event: WatchdogEvent) {
        if case let .phaseChanged(phase) = event {
            phases.append(phase)
        }
    }
}

private actor MockTransport: HTTPTransport {
    var capturedRequests: [URLRequest] = []
    private var loggedIn = false
    private var wanConnected = true
    private let rejectLogin: Bool
    private var simulateKickedOutBeforeDisconnect: Bool
    private var occupiedByOtherSession: Bool

    init(
        rejectLogin: Bool = false,
        simulateKickedOutBeforeDisconnect: Bool = false,
        simulateDuplicateUntilLogout: Bool = false
    ) {
        self.rejectLogin = rejectLogin
        self.simulateKickedOutBeforeDisconnect = simulateKickedOutBeforeDisconnect
        self.occupiedByOtherSession = simulateDuplicateUntilLogout
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequests.append(request)
        let url = request.url!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!

        if request.httpMethod == "GET" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let cmd = comps?.queryItems?.first(where: { $0.name == "cmd" })?.value ?? ""

            var payload: [String: Any] = [:]
            if cmd == "loginfo" {
                payload["loginfo"] = loggedIn ? "ok" : ""
            } else if cmd == "ppp_status" {
                payload["ppp_status"] = wanConnected ? "ipv4_ipv6_connected" : "ppp_disconnected"
            } else if cmd == "station_list" {
                payload["station_list"] = [
                    ["interfacetype": "WIFI5", "ip_addr": "192.168.8.47", "connect_time": "100", "ssid_index": "2", "mac_addr": "00:00:5E:00:53:01", "hostname": "dev-1"],
                    ["interfacetype": "WIFI5", "ip_addr": "192.168.8.48", "connect_time": "200", "ssid_index": "1", "mac_addr": "00:00:5E:00:53:02", "hostname": "dev-2"]
                ]
            } else if cmd == "lan_station_list" {
                payload["lan_station_list"] = [
                    ["interfacetype": "", "ip_addr": "192.168.8.50", "connect_time": "300", "ssid_index": "", "mac_addr": "00:00:5E:00:53:03", "hostname": "lan-1"]
                ]
            } else {
                for key in cmd.split(separator: ",").map(String.init) {
                    switch key {
                    case "wa_inner_version": payload[key] = "BD_FLYMODEMMU5120V1.0.1B12"
                    case "cr_version": payload[key] = ""
                    case "RD": payload[key] = "MOCK_RD_123"
                    case "LD": payload[key] = "MOCK_LD_456"
                    case "modem_main_state": payload[key] = "modem_init_complete"
                    case "network_type": payload[key] = "SA"
                    case "wifi_access_sta_num": payload[key] = "6"
                    case "wifi_chip1_ssid1_access_sta_num": payload[key] = "1"
                    case "wifi_chip2_ssid1_access_sta_num": payload[key] = "5"
                    case "ppp_status": payload[key] = wanConnected ? "ipv4_ipv6_connected" : "ppp_disconnected"
                    default: payload[key] = ""
                    }
                }
            }
            let data = try JSONSerialization.data(withJSONObject: payload)
            return (data, response)
        }

        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let params = parseFormBody(body)
        let goformId = params["goformId"] ?? ""

        let result: String
        switch goformId {
        case "LOGIN":
            if rejectLogin {
                result = "3"
            } else if occupiedByOtherSession {
                result = "2"
            } else {
                loggedIn = true
                result = "0"
            }
        case "LOGOUT":
            occupiedByOtherSession = false
            loggedIn = false
            result = "success"
        case "DISCONNECT_NETWORK":
            if simulateKickedOutBeforeDisconnect {
                simulateKickedOutBeforeDisconnect = false
                loggedIn = false
                result = "failure"
            } else {
                wanConnected = false
                result = "success"
            }
        case "CONNECT_NETWORK":
            wanConnected = true
            result = "success"
        default:
            result = "success"
        }

        let json = try JSONSerialization.data(withJSONObject: ["result": result])
        return (json, response)
    }

    private func parseFormBody(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                result[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
            }
        }
        return result
    }
}

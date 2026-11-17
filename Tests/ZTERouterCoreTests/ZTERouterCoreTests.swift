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

    @Test("Status parser combines wifi_access_sta_num, station_list, and lan_station_list")
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
          "wifi_access_sta_num": "6"
        }
        """

        let stationListJSON = """
        {
          "station_list": [
            {"interfacetype": "WIFI5", "ip_addr": "192.168.8.47", "connect_time": "120", "ssid_index": "2", "mac_addr": "00:00:5E:00:53:01", "hostname": "device-1"},
            {"interfacetype": "WIFI5", "ip_addr": "192.168.8.48", "connect_time": "60", "ssid_index": "2", "mac_addr": "00:00:5E:00:53:02", "hostname": "device-2"}
          ]
        }
        """

        let lanStationListJSON = """
        {
          "lan_station_list": [
            {"interfacetype": "LAN", "ip_addr": "192.168.8.50", "connect_time": "300", "ssid_index": "", "mac_addr": "00:00:5E:00:53:03", "hostname": "wired-1"}
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
        #expect(snap.wirelessDeviceCount == 6)
        #expect(snap.wiredDeviceCount == 1)
        #expect(snap.totalConnectedDevices == 7)
        #expect(snap.wifiStations.count == 2)
        #expect(snap.lanStations.count == 1)
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

    @Test("Client queries station_list individually without multi_data and reconnects WAN in one flow")
    func testClientFetchAndReconnectFlow() async throws {
        let transport = MockTransport()
        let config = try RouterEndpointConfig(baseURLString: "http://192.168.8.1", hashPreference: .auto)
        let client = ZTERouterClient(config: config, password: "fixture-password", transport: transport)

        let snap = try await client.fetchStatus()
        #expect(snap.wirelessDeviceCount == 6)
        #expect(snap.wifiStations.count == 2)
        #expect(snap.wiredDeviceCount == 1)
        #expect(snap.totalConnectedDevices == 7)

        let finalState = try await client.reconnectInternet(pauseBetweenDisconnectAndConnect: .milliseconds(10))
        #expect(finalState.isConnected)

        let captured = await transport.capturedRequests
        for req in captured {
            #expect(req.value(forHTTPHeaderField: "Referer") == "http://192.168.8.1/index.html")
            #expect(req.value(forHTTPHeaderField: "Origin") == "http://192.168.8.1")
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
        #expect(postGoforms == [
            "goformId=LOGIN",
            "goformId=DISCONNECT_NETWORK",
            "goformId=CONNECT_NETWORK"
        ])
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
}

private actor MockTransport: HTTPTransport {
    var capturedRequests: [URLRequest] = []
    private var loggedIn = false
    private var wanConnected = true
    private let rejectLogin: Bool

    init(rejectLogin: Bool = false) {
        self.rejectLogin = rejectLogin
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
                    ["interfacetype": "WIFI5", "ip_addr": "192.168.8.48", "connect_time": "200", "ssid_index": "2", "mac_addr": "00:00:5E:00:53:02", "hostname": "dev-2"]
                ]
            } else if cmd == "lan_station_list" {
                payload["lan_station_list"] = [
                    ["interfacetype": "LAN", "ip_addr": "192.168.8.50", "connect_time": "300", "ssid_index": "", "mac_addr": "00:00:5E:00:53:03", "hostname": "lan-1"]
                ]
            } else {
                for key in cmd.split(separator: ",").map(String.init) {
                    switch key {
                    case "wa_inner_version": payload[key] = "BD_FLYMODEMMU5120V1.0.1B12"
                    case "cr_version": payload[key] = ""
                    case "RD": payload[key] = "MOCK_RD_123"
                    case "LD": payload[key] = "MOCK_LD_456"
                    case "wifi_access_sta_num": payload[key] = "6"
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
            } else {
                loggedIn = true
                result = "0"
            }
        case "DISCONNECT_NETWORK":
            wanConnected = false
            result = "success"
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

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

        // Background poll skips `station_list` and `lan_station_list` while keeping `wifi_access_sta_num`,
        // and is a single merged request that carries `loginfo` itself.
        let bgSnap = try await client.fetchStatus(includeStationLists: false)
        #expect(bgSnap.wirelessDeviceCount == 6)
        #expect(bgSnap.wifiStations.isEmpty)
        let capturedAfterBG = await transport.capturedRequests
        let bgRequests = Array(capturedAfterBG.dropFirst(captured.count))
        #expect(bgRequests.count == 1)
        #expect(bgRequests.first?.httpMethod == "GET")
        #expect(bgRequests.first?.url?.absoluteString.contains("loginfo") == true)
        #expect(bgRequests.first?.url?.absoluteString.contains("multi_data=1") == true)
        let stationQueriesAfterBG = capturedAfterBG.filter {
            $0.httpMethod == "GET" && ($0.url?.absoluteString.contains("cmd=station_list") ?? false)
        }
        #expect(stationQueriesAfterBG.count == 1)

        let postGoforms = captured.compactMap { req -> String? in
            guard req.httpMethod == "POST", let body = req.httpBody, let text = String(data: body, encoding: .utf8) else { return nil }
            return text.split(separator: "&").first(where: { $0.hasPrefix("goformId=") }).map(String.init)
        }
        #expect(postGoforms.contains("goformId=LOGOUT"))
        #expect(postGoforms.contains("goformId=DISCONNECT_NETWORK"))
        #expect(postGoforms.contains("goformId=CONNECT_NETWORK"))
    }

    @Test("Status poll re-logs in once after the session is kicked, without a separate loginfo query")
    func testStatusPollRecoversKickedSession() async throws {
        let transport = MockTransport()
        let config = try RouterEndpointConfig(baseURLString: "http://192.168.8.1")
        let client = ZTERouterClient(config: config, password: "fixture-password", transport: transport)

        _ = try await client.fetchStatus(includeStationLists: false)
        await transport.expireSession()
        let snap = try await client.fetchStatus(includeStationLists: false)
        #expect(snap.networkType == "SA")

        let captured = await transport.capturedRequests
        #expect(Self.loginPostCount(captured) == 2)
        #expect(!captured.contains { $0.url?.absoluteString.contains("cmd=loginfo") ?? false })
    }

    @Test("Firmware that omits loginfo from the merged status query falls back instead of logging in every poll")
    func testStatusPollFallsBackWhenLoginfoUnreliable() async throws {
        let transport = MockTransport(omitLoginfoInStatusQuery: true)
        let config = try RouterEndpointConfig(baseURLString: "http://192.168.8.1")
        let client = ZTERouterClient(config: config, password: "fixture-password", transport: transport)

        for _ in 0..<3 {
            let snap = try await client.fetchStatus(includeStationLists: false)
            #expect(snap.networkType == "SA")
        }
        let captured = await transport.capturedRequests
        #expect(Self.loginPostCount(captured) == 1)
        #expect(captured.contains { $0.url?.absoluteString.contains("cmd=loginfo") ?? false })
    }

    private static func loginPostCount(_ requests: [URLRequest]) -> Int {
        requests.filter { req in
            guard req.httpMethod == "POST", let body = req.httpBody, let text = String(data: body, encoding: .utf8) else { return false }
            return text.contains("goformId=LOGIN")
        }.count
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

    @Test("Watchdog config defaults, per-endpoint seconds, legacy migration, and weighted policy evaluation")
    func testWatchdogConfigAndPolicies() throws {
        let cfg = WatchdogConfig()
        #expect(cfg.autoStart == true)
        #expect(cfg.autoReconnectEnabled == false)
        #expect(cfg.triggerPolicy == .weighted)
        #expect(cfg.failureWindowSec == 60)
        #expect(cfg.recheckIntervalSec == 5)
        #expect(cfg.postReconnectGraceSec == 300)
        #expect(cfg.maxConsecutiveReconnects == 3)
        #expect(cfg.cooldownSec == 300)
        #expect(cfg.endpoints.count == 4)
        #expect(cfg.endpoints[3].urlString == "https://api.telegram.org/")
        #expect(cfg.endpoints[3].weight == 1)
        #expect(cfg.endpoints[3].intervalSec == 33)
        #expect(cfg.endpoints[3].timeoutSec == 4)
        #expect(cfg.endpoints[0].urlString == "https://661313.xyz/test/generate_204")
        #expect(cfg.endpoints[0].weight == 1)
        #expect(cfg.endpoints[0].intervalSec == 15)
        #expect(cfg.endpoints[0].timeoutSec == 3)
        #expect(cfg.endpoints[1].weight == 1)
        #expect(cfg.endpoints[1].intervalSec == 33)
        #expect(cfg.endpoints[1].timeoutSec == 4)
        #expect(cfg.endpoints[2].weight == 1)
        #expect(cfg.endpoints[2].intervalSec == 33)
        #expect(cfg.endpoints[2].timeoutSec == 4)
        #expect(cfg.endpoints.allSatisfy { $0.isValidHTTPURL && $0.urlString.hasPrefix("https://") })
        #expect(!cfg.endpoints.contains(where: { $0.urlString.contains("success.txt") || $0.urlString.contains("github") || $0.urlString.contains("dropbox") }))

        // Backwards-compatible decoding of v1.0.4 JSON with global checkTimeoutMs / pollIntervalSec & proxy keys
        let v104JSON = Data("""
        {
          "autoStart": true,
          "checkTimeoutMs": 5000,
          "pollIntervalSec": 25,
          "recheckBeforeAct": 1,
          "recheckIntervalSec": 3,
          "maxConsecutiveReconnects": 3,
          "cooldownSec": 60,
          "triggerPolicy": "weighted",
          "onlyWhenWiFiMatched": false,
          "endpoints": [
            {"id":"00000000-0000-0000-0000-000000000001","isEnabled":true,"name":"661313 节点","urlString":"https://661313.xyz/test/success.txt","proxyMode":"system","weight":3,"expectedResponseText":"success"},
            {"id":"00000000-0000-0000-0000-000000000002","isEnabled":true,"name":"Custom","urlString":"https://custom.invalid/ping","proxyMode":"socks5","weight":1}
          ]
        }
        """.utf8)
        let decoded104 = try JSONDecoder().decode(WatchdogConfig.self, from: v104JSON)
        #expect(decoded104.endpoints[1].intervalSec == 25)
        #expect(decoded104.endpoints[1].timeoutSec == 5)
        let migrated104 = decoded104.migratingLegacyDefaults(fromVersion: 3)
        #expect(migrated104.endpoints[0].urlString == "https://661313.xyz/test/generate_204")
        #expect(migrated104.endpoints[0].intervalSec == 15)
        #expect(migrated104.endpoints[0].timeoutSec == 3)
        #expect(migrated104.endpoints[1].intervalSec == 25)
        #expect(migrated104.endpoints[1].timeoutSec == 5)
        #expect(migrated104.endpoints[0].weight == 1)
        #expect(migrated104.recheckIntervalSec == 5)
        #expect(migrated104.cooldownSec == 300)
        #expect(migrated104.failureWindowSec == 60)
        #expect(migrated104.postReconnectGraceSec == 300)
        #expect(migrated104.autoReconnectEnabled == false)

        // v1.0.5 (defaults version 4) config with user-tuned timeouts: only the hair-trigger defaults change.
        let v105JSON = Data("""
        {
          "autoStart": true,
          "recheckBeforeAct": 1,
          "recheckIntervalSec": 3,
          "maxConsecutiveReconnects": 3,
          "cooldownSec": 60,
          "triggerPolicy": "weighted",
          "onlyWhenWiFiMatched": false,
          "endpoints": [
            {"id":"00000000-0000-0000-0000-000000000001","isEnabled":true,"name":"661313 204","urlString":"https://661313.xyz/test/generate_204","weight":3,"intervalSec":15,"timeoutSec":10},
            {"id":"00000000-0000-0000-0000-000000000002","isEnabled":true,"name":"YouTube 204","urlString":"https://www.youtube.com/generate_204","weight":1,"intervalSec":33,"timeoutSec":10},
            {"id":"00000000-0000-0000-0000-000000000003","isEnabled":true,"name":"Custom","urlString":"https://custom.invalid/ping","weight":3,"intervalSec":20,"timeoutSec":10}
          ]
        }
        """.utf8)
        let migrated105 = try JSONDecoder().decode(WatchdogConfig.self, from: v105JSON).migratingLegacyDefaults(fromVersion: 4)
        #expect(migrated105.endpoints.map(\.weight) == [1, 1, 3])
        #expect(migrated105.endpoints.map(\.timeoutSec) == [10, 10, 10])
        #expect(migrated105.endpoints.map(\.intervalSec) == [15, 33, 20])
        #expect(migrated105.recheckIntervalSec == 5)
        #expect(migrated105.cooldownSec == 300)
        #expect(migrated105.failureWindowSec == 60)
        #expect(migrated105.postReconnectGraceSec == 300)
        #expect(migrated105.endpoints.count == 3)
        // Already-migrated configs keep whatever the user chose afterwards.
        var tuned = migrated105
        tuned.recheckIntervalSec = 3
        tuned.cooldownSec = 60
        #expect(tuned.migratingLegacyDefaults(fromVersion: 6) == tuned)

        // v1.1.0 (defaults version 5): untouched 30s/45s defaults and the 3-preset list move to the
        // new defaults; values the user tuned and custom endpoint lists stay as they are.
        let v110 = WatchdogConfig(
            failureWindowSec: 30,
            postReconnectGraceSec: 45,
            endpoints: Array(WatchdogEndpoint.defaultPresets.dropLast())
        ).migratingLegacyDefaults(fromVersion: 5)
        #expect(v110.failureWindowSec == 60)
        #expect(v110.postReconnectGraceSec == 300)
        #expect(v110.endpoints.map(\.urlString) == WatchdogEndpoint.defaultPresets.map(\.urlString))
        let v110Tuned = WatchdogConfig(
            failureWindowSec: 40,
            postReconnectGraceSec: 90,
            endpoints: [WatchdogEndpoint(name: "Custom", urlString: "https://custom.invalid/ping")]
        )
        #expect(v110Tuned.migratingLegacyDefaults(fromVersion: 5) == v110Tuned)

        // Legacy untouched preset sets migrate cleanly to v1.1.0 defaults
        for oldURLs in WatchdogEndpoint.legacyPresetURLSets {
            let legacy = WatchdogConfig(
                triggerPolicy: .allUnreachable,
                endpoints: oldURLs.map { WatchdogEndpoint(name: "Legacy", urlString: $0) }
            ).migratingLegacyDefaults(fromVersion: 0)
            #expect(legacy.triggerPolicy == .weighted)
            #expect(legacy.endpoints.map(\.urlString) == WatchdogEndpoint.defaultPresets.map(\.urlString))
        }

        // Weighted evaluation: primary (3) dominates two secondaries (1 + 1)
        let primaryOK = EndpointProbeOutcome(id: UUID(), name: "661313", urlString: "https://example.invalid", weight: 3, reachable: true, statusCode: 204, elapsedMs: 30)
        let primaryFail = EndpointProbeOutcome(id: UUID(), name: "661313", urlString: "https://example.invalid", weight: 3, reachable: false, errorMessage: "timeout")
        let sec1OK = EndpointProbeOutcome(id: UUID(), name: "S1", urlString: "https://example.invalid", weight: 1, reachable: true, statusCode: 204, elapsedMs: 50)
        let sec1Fail = EndpointProbeOutcome(id: UUID(), name: "S1", urlString: "https://example.invalid", weight: 1, reachable: false, errorMessage: "timeout")
        let sec2OK = EndpointProbeOutcome(id: UUID(), name: "S2", urlString: "https://example.invalid", weight: 1, reachable: true, statusCode: 200, elapsedMs: 40)
        let sec2Fail = EndpointProbeOutcome(id: UUID(), name: "S2", urlString: "https://example.invalid", weight: 1, reachable: false, errorMessage: "timeout")

        #expect(WatchdogEvaluator.isHealthy(outcomes: [primaryOK, sec1Fail, sec2Fail], policy: .weighted) == true)
        #expect(WatchdogEvaluator.isHealthy(outcomes: [primaryFail, sec1OK, sec2OK], policy: .weighted) == false)
        #expect(WatchdogEvaluator.isHealthy(outcomes: [primaryFail, sec1OK, sec2OK], policy: .allUnreachable) == true)
        #expect(WatchdogEvaluator.isHealthy(outcomes: [primaryFail, sec1Fail, sec2Fail], policy: .allUnreachable) == false)
        #expect(WatchdogEvaluator.isHealthy(outcomes: [primaryOK, sec1Fail], policy: .anyUnreachable) == false)
        #expect(WatchdogEvaluator.isHealthy(outcomes: [primaryOK, sec1OK], policy: .anyUnreachable) == true)

        // Default 1/1/1 weights: one endpoint down is healthy, two down is not.
        let equalOK = EndpointProbeOutcome(id: UUID(), name: "E", urlString: "https://example.invalid", weight: 1, reachable: true, statusCode: 204)
        let equalFail = EndpointProbeOutcome(id: UUID(), name: "E", urlString: "https://example.invalid", weight: 1, reachable: false, errorMessage: "timeout")
        #expect(WatchdogEvaluator.isHealthy(outcomes: [equalFail, equalOK, equalOK], policy: .weighted) == true)
        #expect(WatchdogEvaluator.isHealthy(outcomes: [equalFail, equalFail, equalOK], policy: .weighted) == false)
    }

    @Test("Watchdog schedules per-endpoint independent intervals cleanly")
    func testPerEndpointScheduling() async {
        let fast = WatchdogEndpoint(name: "Fast", urlString: "https://fast.invalid", weight: 3, intervalSec: 15, timeoutSec: 3)
        let slow = WatchdogEndpoint(name: "Slow", urlString: "https://slow.invalid", weight: 1, intervalSec: 33, timeoutSec: 4)
        var cfg = WatchdogConfig(triggerPolicy: .weighted)
        cfg.endpoints = [fast, slow]

        let counter = EndpointCallCounter()
        let prober = CountingProber(counter: counter)
        let router = MockReconnectRouter()
        let runner = WatchdogRunner(sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })

        let task = Task {
            await runner.run(config: cfg, prober: prober, router: router) { _ in }
        }

        // Wait until Fast reaches at least 4 probes (t=0, 15, 30, 45)
        for _ in 0..<100 {
            if await counter.count(for: fast.id) >= 4 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await task.value

        let fastCount = await counter.count(for: fast.id)
        let slowCount = await counter.count(for: slow.id)
        #expect(fastCount >= 4)
        #expect(slowCount >= 2 && slowCount < fastCount)
    }

    @Test("Watchdog ignores a blip: failing rounds that recover inside the window never reconnect")
    func testWatchdogBlipInsideWindowDoesNotReconnect() async {
        // Round 1 fails, first recheck fails too (the old 2-fail trigger), second recheck recovers.
        let prober = ScriptedProber(roundResults: [false, false, true])
        let router = MockReconnectRouter()
        var cfg = WatchdogConfig()
        cfg.endpoints = [WatchdogEndpoint(name: "Test", urlString: "https://example.invalid")]

        let collector = PhaseCollector()
        let task = Task {
            await WatchdogRunner(sleep: Self.fastSleep).run(config: cfg, prober: prober, router: router) { event in
                await collector.record(event)
            }
        }
        await Self.waitUntil { await prober.completedRounds >= 5 }
        task.cancel()
        await task.value

        #expect(await router.reconnectCount == 0)
        let phases = await collector.phases
        #expect(phases.contains(.confirming(elapsedSec: 0, windowSec: 60)))
        #expect(phases.contains(.confirming(elapsedSec: 5, windowSec: 60)))
        #expect(!phases.contains(.reconnecting))
        #expect(await collector.probeFailureCount == 1)
    }

    @Test("With auto reconnect off, a sustained failure notifies once and never redials")
    func testWatchdogAutoReconnectDisabledOnlyNotifies() async {
        // 1 failing round + 12 failing rechecks fill the window, then the outage simply continues.
        let prober = ScriptedProber(roundResults: Array(repeating: false, count: 40))
        let router = MockReconnectRouter()
        var cfg = WatchdogConfig()
        cfg.endpoints = [WatchdogEndpoint(name: "Test", urlString: "https://example.invalid")]

        let collector = PhaseCollector()
        let task = Task {
            await WatchdogRunner(sleep: Self.fastSleep).run(config: cfg, prober: prober, router: router) { event in
                await collector.record(event)
            }
        }
        await Self.waitUntil { await prober.completedRounds >= 20 }
        task.cancel()
        await task.value

        #expect(await router.reconnectCount == 0)
        #expect(await collector.autoTriggerCount == 0)
        #expect(await collector.probeFailureCount == 1)
        let phases = await collector.phases
        #expect(phases.contains(.paused(reason: "外网持续异常，自动重连未开启")))
        #expect(!phases.contains(.reconnecting))
    }

    @Test("Watchdog reconnects once after a full failure window, then stays silent for the grace period")
    func testWatchdogSustainedFailureReconnectsOnceThenSettles() async {
        // 1 failing round + 12 failing rechecks (12 x 5s = 60s window) -> reconnect -> recovered afterwards.
        let prober = ScriptedProber(roundResults: Array(repeating: false, count: 13))
        let router = MockReconnectRouter()
        var cfg = WatchdogConfig(autoReconnectEnabled: true)
        cfg.endpoints = [WatchdogEndpoint(name: "Test", urlString: "https://example.invalid")]

        let collector = PhaseCollector()
        let sleeps = SleepRecorder()
        let runner = WatchdogRunner(sleep: { duration in
            await sleeps.record(duration)
            try await Task.sleep(for: .milliseconds(2))
        })
        let task = Task {
            await runner.run(config: cfg, prober: prober, router: router) { event in
                await collector.record(event)
            }
        }
        await Self.waitUntil { await prober.completedRounds >= 16 }
        task.cancel()
        await task.value

        #expect(await router.reconnectCount == 1)
        #expect(await collector.autoTriggerCount == 1)
        #expect(await collector.probeFailureCount == 1)
        #expect(await collector.autoFinishCount == 1)

        let phases = await collector.phases
        let beforeReconnect = phases.prefix { $0 != .reconnecting }
        #expect(beforeReconnect.filter(Self.isConfirming).count == 12)
        #expect(phases.contains(.settling(seconds: 300)))
        #expect(!phases.contains(.coolingDown(seconds: 300)))

        // The grace period is one uninterrupted sleep: no probe happens inside it.
        let recorded = await sleeps.durations
        #expect(recorded.contains(.seconds(300)))
        let graceIndex = recorded.firstIndex(of: .seconds(300))
        #expect(graceIndex.map { recorded[..<$0].filter { $0 == .seconds(5) }.count } == 12)
    }

    @Test("Slow failing probes count toward the failure window")
    func testWatchdogWindowCountsProbeDuration() async {
        // Each failing recheck takes 10s on top of the 5s pause: 4 rechecks cover the 60s window.
        let prober = ScriptedProber(roundResults: Array(repeating: false, count: 5), elapsedMs: 10_000)
        let router = MockReconnectRouter()
        var cfg = WatchdogConfig(autoReconnectEnabled: true)
        cfg.endpoints = [WatchdogEndpoint(name: "Test", urlString: "https://example.invalid", timeoutSec: 10)]

        let collector = PhaseCollector()
        let task = Task {
            await WatchdogRunner(sleep: Self.fastSleep).run(config: cfg, prober: prober, router: router) { event in
                await collector.record(event)
            }
        }
        await Self.waitUntil { await prober.completedRounds >= 7 }
        task.cancel()
        await task.value

        #expect(await router.reconnectCount == 1)
        let phases = await collector.phases
        #expect(phases.prefix { $0 != .reconnecting }.filter(Self.isConfirming) == [
            .confirming(elapsedSec: 0, windowSec: 60),
            .confirming(elapsedSec: 15, windowSec: 60),
            .confirming(elapsedSec: 30, windowSec: 60),
            .confirming(elapsedSec: 45, windowSec: 60)
        ])
    }

    @Test("A second reconnect needs a new full window, and repeated reconnects end in a cooldown")
    func testWatchdogRepeatedReconnectsCoolDown() async {
        // window 10s / recheck 5s = 2 rechecks. Fail (1+2) -> reconnect #1 -> grace -> fail (1+2) -> reconnect #2 -> cooldown -> recovered.
        let prober = ScriptedProber(roundResults: Array(repeating: false, count: 6))
        let router = MockReconnectRouter()
        var cfg = WatchdogConfig(autoReconnectEnabled: true, failureWindowSec: 10, postReconnectGraceSec: 45, maxConsecutiveReconnects: 2, cooldownSec: 60)
        cfg.endpoints = [WatchdogEndpoint(name: "Test", urlString: "https://example.invalid")]

        let collector = PhaseCollector()
        let task = Task {
            await WatchdogRunner(sleep: Self.fastSleep).run(config: cfg, prober: prober, router: router) { event in
                await collector.record(event)
            }
        }
        await Self.waitUntil { await prober.completedRounds >= 9 }
        task.cancel()
        await task.value

        #expect(await router.reconnectCount == 2)
        #expect(await collector.autoTriggerCount == 2)

        let phases = await collector.phases
        let reconnectIndices = phases.indices.filter { phases[$0] == .reconnecting }
        #expect(reconnectIndices.count == 2)
        if reconnectIndices.count == 2 {
            let between = phases[reconnectIndices[0]..<reconnectIndices[1]]
            #expect(between.contains(.settling(seconds: 45)))
            #expect(between.filter(Self.isConfirming).count == 2)
        }
        #expect(phases.contains(.coolingDown(seconds: 60)))
        #expect(phases.filter { $0 == .settling(seconds: 45) }.count == 1)
    }

    private static let fastSleep: @Sendable (Duration) async throws -> Void = { _ in
        try await Task.sleep(for: .milliseconds(2))
    }

    private static func isConfirming(_ phase: WatchdogPhase) -> Bool {
        if case .confirming = phase { return true }
        return false
    }

    private static func waitUntil(_ condition: @Sendable () async -> Bool) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Signal rating assessment and WAN IP change notification formatting")
    func testSignalRatingAndWANIPFormatting() throws {
        // Strong 5G SA signal -> excellent
        let strong = SignalEvaluator.evaluate(rsrp: -78, sinr: 24, rsrq: -8)
        #expect(strong.grade == .excellent)
        #expect(strong.score >= 85)

        // Poor signal -> poor/veryPoor even with decent SINR
        let weak = SignalEvaluator.evaluate(rsrp: -115, sinr: 12, rsrq: -16)
        #expect(weak.score <= 45)
        #expect(weak.grade == .poor || weak.grade == .veryPoor)

        // Parse 5G SA JSON with WAN IP and extract sample
        let json1 = Data("""
        {"ppp_status":"ipv4_ipv6_connected","network_type":"SA","nr5g_action_band":"n41","5g_rx0_rsrp":"-84","Z5g_SINR":"21.0","Z5g_rsrq":"-9","wan_ipaddr":"10.10.0.1","ipv6_wan_ipaddr":"2001:db8::1"}
        """.utf8)
        let snap1 = try RouterStatusParser.parse(jsonDataList: [json1])
        let sample = try #require(SignalEvaluator.sample(from: snap1))
        #expect(sample.rsrp == -84)
        #expect(sample.sinr == 21.0)

        let mu5120SampleJSON = Data("""
        {"ppp_status":"ipv4_ipv6_connected","network_type":"SA","nr5g_action_band":"n41","5g_rx0_rsrp":"-69","Z5g_SINR":"23.5","Z5g_rsrq":"-12"}
        """.utf8)
        let strongSnap = try RouterStatusParser.parse(jsonDataList: [mu5120SampleJSON])
        #expect(SignalEvaluator.menuBarSignalText(for: strongSnap) == "-69dBm 极佳")

        let disconnectedJSON = Data("""
        {"ppp_status":"ppp_disconnected","network_type":"SA","5g_rx0_rsrp":"-69"}
        """.utf8)
        let offlineSnap = try RouterStatusParser.parse(jsonDataList: [disconnectedJSON])
        #expect(SignalEvaluator.menuBarSignalText(for: offlineSnap) == "断网")

        let beforeIP = WANIPSnapshot(snapshot: snap1)
        let afterIP = WANIPSnapshot(ipv4: "10.10.0.2", ipv6: "2001:db8::2")
        let autoMsg = WANIPChangeFormatter.formatNotificationMessage(
            isAutomatic: true,
            profileName: "CPE",
            state: .connected(rawStatus: "ipv4_ipv6_connected"),
            before: beforeIP,
            after: afterIP
        )
        #expect(autoMsg.title.contains("自动重连完成"))
        #expect(autoMsg.title.contains("IP 已变更"))
        #expect(autoMsg.body.contains("10.10.0.1 → 10.10.0.2"))
        #expect(autoMsg.body.contains("2001:db8::1 → 2001:db8::2"))

        let manualUnchanged = WANIPChangeFormatter.formatNotificationMessage(
            isAutomatic: false,
            profileName: "CPE",
            state: .connected(rawStatus: "ipv4_ipv6_connected"),
            before: beforeIP,
            after: beforeIP
        )
        #expect(manualUnchanged.title.contains("手动重连完成"))
        #expect(manualUnchanged.title.contains("未变化"))
        #expect(manualUnchanged.body.contains("10.10.0.1（未变化）"))
    }

    @Test("URLEndpointProber rejects invalid URL and interprets HTTP gateway failure codes")
    func testProberValidation() async {
        let prober = URLEndpointProber()
        let badURL = WatchdogEndpoint(name: "Bad", urlString: "not-a-url")
        let out1 = await prober.check(badURL)
        #expect(out1.reachable == false)
        #expect(out1.errorMessage?.isEmpty == false)

        #expect(URLEndpointProber.failureMessage(forStatusCode: 200) == nil)
        #expect(URLEndpointProber.failureMessage(forStatusCode: 204) == nil)
        #expect(URLEndpointProber.failureMessage(forStatusCode: 301) == nil)
        #expect(URLEndpointProber.failureMessage(forStatusCode: 407) != nil)
        #expect(URLEndpointProber.failureMessage(forStatusCode: 502) != nil)
        #expect(URLEndpointProber.failureMessage(forStatusCode: 503) != nil)
        #expect(URLEndpointProber.failureMessage(forStatusCode: 504) != nil)
    }
}

private actor EndpointCallCounter {
    private var counts: [UUID: Int] = [:]

    func increment(_ id: UUID) {
        counts[id, default: 0] += 1
    }

    func count(for id: UUID) -> Int {
        counts[id, default: 0]
    }
}

private actor CountingProber: EndpointProbing {
    let counter: EndpointCallCounter

    init(counter: EndpointCallCounter) {
        self.counter = counter
    }

    func check(_ endpoint: WatchdogEndpoint) async -> EndpointProbeOutcome {
        await counter.increment(endpoint.id)
        return EndpointProbeOutcome(
            id: endpoint.id,
            name: endpoint.displayTitle,
            urlString: endpoint.urlString,
            weight: endpoint.weight,
            reachable: true,
            statusCode: 204,
            elapsedMs: 10
        )
    }
}

private actor SleepRecorder {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }
}

private actor ScriptedProber: EndpointProbing {
    private var roundResults: [Bool]
    private let elapsedMs: Int
    private(set) var completedRounds = 0

    init(roundResults: [Bool], elapsedMs: Int = 12) {
        self.roundResults = roundResults
        self.elapsedMs = elapsedMs
    }

    func check(_ endpoint: WatchdogEndpoint) async -> EndpointProbeOutcome {
        let idx = completedRounds
        completedRounds += 1
        let ok = idx < roundResults.count ? roundResults[idx] : true
        return EndpointProbeOutcome(
            id: endpoint.id,
            name: endpoint.displayTitle,
            urlString: endpoint.urlString,
            weight: endpoint.weight,
            reachable: ok,
            statusCode: ok ? 204 : nil,
            elapsedMs: elapsedMs,
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
    private(set) var autoTriggerCount = 0
    private(set) var autoFinishCount = 0
    private(set) var probeFailureCount = 0

    func record(_ event: WatchdogEvent) {
        switch event {
        case .probeFailureDetected:
            probeFailureCount += 1
        case let .phaseChanged(phase):
            phases.append(phase)
        case .autoReconnectTriggered:
            autoTriggerCount += 1
        case .autoReconnectFinished:
            autoFinishCount += 1
        default:
            break
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
    private let omitLoginfoInStatusQuery: Bool

    init(
        rejectLogin: Bool = false,
        simulateKickedOutBeforeDisconnect: Bool = false,
        simulateDuplicateUntilLogout: Bool = false,
        omitLoginfoInStatusQuery: Bool = false
    ) {
        self.rejectLogin = rejectLogin
        self.simulateKickedOutBeforeDisconnect = simulateKickedOutBeforeDisconnect
        self.occupiedByOtherSession = simulateDuplicateUntilLogout
        self.omitLoginfoInStatusQuery = omitLoginfoInStatusQuery
    }

    func expireSession() {
        loggedIn = false
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
                    case "loginfo": payload[key] = (loggedIn && !omitLoginfoInStatusQuery) ? "ok" : ""
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

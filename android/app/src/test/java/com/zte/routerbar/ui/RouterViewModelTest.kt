package com.zte.routerbar.ui

import android.net.Network
import com.zte.routerbar.core.AuthHashPreference
import com.zte.routerbar.core.EndpointProbeOutcome
import com.zte.routerbar.core.ProbeEndpoint
import com.zte.routerbar.core.RouterEndpointConfig
import com.zte.routerbar.core.RouterHttpRequest
import com.zte.routerbar.core.RouterHttpResponse
import com.zte.routerbar.core.RouterProfile
import com.zte.routerbar.core.ZteRouterClient
import com.zte.routerbar.data.CredentialRepository
import com.zte.routerbar.data.ProfileRepository
import com.zte.routerbar.data.StoredAppSettings
import com.zte.routerbar.data.WifiLanMonitor
import com.zte.routerbar.data.WifiLanState
import java.net.URI
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RouterViewModelTest {
    @Test
    fun foregroundLifecyclePollsThrottlesStationsAndAutoSwitchesByGateway() = runTest {
        val p1 = RouterProfile(id = "p1", name = "随身热点", routerUrlString = "http://192.168.8.1")
        val p2 = RouterProfile(id = "p2", name = "客厅 CPE", routerUrlString = "http://192.168.0.1")
        val profileRepo = FakeProfileRepo(
            StoredAppSettings(profiles = listOf(p1, p2), activeProfileId = "p1", autoMatchByGateway = true, pollingIntervalSec = 3)
        )
        val credRepo = FakeCredentialRepo(mutableMapOf("p1" to "pw1", "p2" to "pw2"))
        val wifi = FakeWifiMonitor(WifiLanState(isWifiConnected = true, gatewayIpv4 = "192.168.8.1"))

        val fakeRouter1 = FakeRouterBackend(wanIpv4 = "10.1.0.1")
        val fakeRouter2 = FakeRouterBackend(wanIpv4 = "10.2.0.9")

        val vm = RouterViewModel(
            profileRepo = profileRepo,
            credentialRepo = credRepo,
            wifiMonitor = wifi,
            clientFactory = { cfg, pw ->
                val backend = if (cfg.host == "192.168.0.1") fakeRouter2 else fakeRouter1
                ZteRouterClient(
                    config = cfg,
                    password = pw,
                    transport = { req -> backend.handle(req) },
                    clockMs = { testScheduler.currentTime },
                    delayFn = { delay(it) }
                )
            },
            clockMs = { testScheduler.currentTime },
            delayFn = { delay(it) },
            externalScope = backgroundScope
        )
        runCurrent()

        vm.setForegroundActive(true)
        runCurrent()
        assertEquals("10.1.0.1", vm.uiState.value.snapshot?.wanIPv4)
        assertEquals(1, fakeRouter1.stationListQueryCount)
        assertEquals(1, vm.uiState.value.snapshot?.wifiStations?.size)

        // Next 3s poll skips station_list (< 10s) while keeping cached wifiStations
        advanceTimeBy(3_000L)
        runCurrent()
        assertEquals(1, fakeRouter1.stationListQueryCount)
        assertEquals(1, vm.uiState.value.snapshot?.wifiStations?.size)

        // Switching Wi-Fi gateway to 192.168.0.1 auto-matches p2
        wifi.emit(WifiLanState(isWifiConnected = true, gatewayIpv4 = "192.168.0.1"))
        runCurrent()
        assertEquals("p2", vm.uiState.value.activeProfileId)
        assertEquals("10.2.0.9", vm.uiState.value.snapshot?.wanIPv4)

        // Stopping foreground halts polling
        val callsAtStop = fakeRouter2.statusQueryCount
        vm.setForegroundActive(false)
        advanceTimeBy(30_000L)
        runCurrent()
        assertEquals(callsAtStop, fakeRouter2.statusQueryCount)
    }

    @Test
    fun reconnectWanTracksDelayedIpChangeAndSheetGuardsUnsavedDrafts() = runTest {
        val p1 = RouterProfile(id = "p1", name = "默认路由器", routerUrlString = "http://192.168.8.1")
        val profileRepo = FakeProfileRepo(StoredAppSettings(profiles = listOf(p1), activeProfileId = "p1"))
        val credRepo = FakeCredentialRepo(mutableMapOf("p1" to "pw1"))
        val wifi = FakeWifiMonitor(WifiLanState(isWifiConnected = true, gatewayIpv4 = "192.168.8.1"))
        val backend = FakeRouterBackend(wanIpv4 = "100.64.0.1", nextWanIpv4OnSecondFetchAfterReconnect = "100.64.9.99")

        val vm = RouterViewModel(
            profileRepo = profileRepo,
            credentialRepo = credRepo,
            wifiMonitor = wifi,
            clientFactory = { cfg, pw ->
                ZteRouterClient(
                    config = cfg,
                    password = pw,
                    transport = { req -> backend.handle(req) },
                    clockMs = { testScheduler.currentTime },
                    delayFn = { delay(it) }
                )
            },
            clockMs = { testScheduler.currentTime },
            delayFn = { delay(it) },
            externalScope = backgroundScope
        )
        runCurrent()
        vm.refreshNow(silent = false)
        assertEquals("100.64.0.1", vm.uiState.value.snapshot?.wanIPv4)

        vm.reconnectWanNow()
        val banner = vm.uiState.value.reconnectIpBanner
        assertNotNull(banner)
        assertTrue(banner!!.changed)
        assertTrue(banner.detail.contains("100.64.0.1 → 100.64.9.99"))

        // Profile sheet unsaved-changes guard
        vm.openProfileSheet()
        assertTrue(vm.uiState.value.isProfileSheetOpen)
        assertFalse(vm.uiState.value.hasUnsavedDraftChanges)

        vm.updateDraftName("未保存的新名称")
        assertTrue(vm.uiState.value.hasUnsavedDraftChanges)
        vm.requestCloseProfileSheet()
        assertTrue(vm.uiState.value.isProfileSheetOpen)
        assertTrue(vm.uiState.value.showDiscardDialog)

        vm.confirmDiscardProfileChanges()
        assertFalse(vm.uiState.value.isProfileSheetOpen)
        assertFalse(vm.uiState.value.showDiscardDialog)
        assertEquals("默认路由器", vm.uiState.value.draftName)
    }

    @Test
    fun stagingNewProfileNeverLeaksOrphanOnDiscardAndProfileSwitchCancelsStalePoll() = runTest {
        val p1 = RouterProfile(id = "p1", name = "热点 1", routerUrlString = "http://192.168.8.1")
        val p2 = RouterProfile(id = "p2", name = "热点 2", routerUrlString = "http://192.168.0.1")
        val profileRepo = FakeProfileRepo(
            StoredAppSettings(profiles = listOf(p1, p2), activeProfileId = "p1", autoMatchByGateway = true, pollingIntervalSec = 3)
        )
        val credRepo = FakeCredentialRepo(mutableMapOf("p1" to "pw1", "p2" to "pw2"))
        val wifi = FakeWifiMonitor(WifiLanState(isWifiConnected = true, gatewayIpv4 = "192.168.8.1", networkHandle = 101L))
        val slowBackend1 = FakeRouterBackend(wanIpv4 = "10.8.8.8")
        val fastBackend2 = FakeRouterBackend(wanIpv4 = "10.0.0.2")

        val vm = RouterViewModel(
            profileRepo = profileRepo,
            credentialRepo = credRepo,
            wifiMonitor = wifi,
            clientFactory = { cfg, pw ->
                val isP1 = cfg.host == "192.168.8.1"
                ZteRouterClient(
                    config = cfg,
                    password = pw,
                    transport = { req ->
                        if (isP1) {
                            delay(5_000L)
                            slowBackend1.handle(req)
                        } else {
                            fastBackend2.handle(req)
                        }
                    },
                    clockMs = { testScheduler.currentTime },
                    delayFn = { delay(it) }
                )
            },
            clockMs = { testScheduler.currentTime },
            delayFn = { delay(it) },
            externalScope = backgroundScope
        )
        runCurrent()

        // Start foreground: p1 poll is stalled on slow 5s socket (isRefreshing = true).
        vm.setForegroundActive(true)
        advanceTimeBy(500L)
        runCurrent()
        assertTrue(vm.uiState.value.isRefreshing)

        // Roaming to 192.168.0.1 cancels p1's slow poll immediately and connects p2 without being blocked or clobbered.
        wifi.emit(WifiLanState(isWifiConnected = true, gatewayIpv4 = "192.168.0.1", networkHandle = 202L))
        runCurrent()
        assertEquals("p2", vm.uiState.value.activeProfileId)
        assertEquals("10.0.0.2", vm.uiState.value.snapshot?.wanIPv4)

        advanceTimeBy(6_000L)
        runCurrent()
        assertEquals("10.0.0.2", vm.uiState.value.snapshot?.wanIPv4)

        // + 新增配置 stages a draft without persisting an orphan profile when discarded.
        vm.openProfileSheet()
        vm.addNewProfileDraft()
        assertTrue(vm.uiState.value.isEditingUnsavedNewProfile)
        assertEquals(2, profileRepo.load().profiles.size)

        vm.updateDraftName("临时未保存路由")
        assertTrue(vm.uiState.value.hasUnsavedDraftChanges)
        vm.requestCloseProfileSheet()
        assertTrue(vm.uiState.value.showDiscardDialog)
        vm.confirmDiscardProfileChanges()
        assertFalse(vm.uiState.value.isProfileSheetOpen)
        assertEquals(2, profileRepo.load().profiles.size)

        // Intra-sheet profile selection also guards unsaved draft edits before switching.
        vm.openProfileSheet()
        assertEquals("p2", vm.uiState.value.editingProfileId)
        vm.updateDraftUrl("http://192.168.0.254")
        assertTrue(vm.uiState.value.hasUnsavedDraftChanges)
        vm.selectProfileForEditing("p1")
        assertTrue(vm.uiState.value.showDiscardDialog)
        assertEquals("p2", vm.uiState.value.editingProfileId)
        vm.confirmDiscardProfileChanges()
        assertFalse(vm.uiState.value.showDiscardDialog)
        assertEquals("p1", vm.uiState.value.editingProfileId)
        assertEquals("热点 1", vm.uiState.value.draftName)
    }

    @Test
    fun manualProbeRunsAllFourPresetsConcurrentlyStreamsPartialResultsAndGuardsReentrancy() = runTest {
        val p1 = RouterProfile(id = "p1", name = "默认路由器", routerUrlString = "http://192.168.8.1")
        val profileRepo = FakeProfileRepo(StoredAppSettings(profiles = listOf(p1), activeProfileId = "p1"))
        val credRepo = FakeCredentialRepo(mutableMapOf()) // Works even without router password configured!
        val wifi = FakeWifiMonitor(WifiLanState(isWifiConnected = true, gatewayIpv4 = "192.168.8.1"))

        var totalProbeCalls = 0
        var expectedRefreshCount = 1
        val vm = RouterViewModel(
            profileRepo = profileRepo,
            credentialRepo = credRepo,
            wifiMonitor = wifi,
            endpointProber = { endpoint ->
                assertEquals(expectedRefreshCount, wifi.refreshCount)
                totalProbeCalls += 1
                when (endpoint.id) {
                    "661313-204" -> {
                        delay(80L)
                        EndpointProbeOutcome(endpoint.id, endpoint.name, endpoint.urlString, reachable = true, statusCode = 204, elapsedMs = 80)
                    }
                    "youtube-204" -> {
                        delay(120L)
                        EndpointProbeOutcome(endpoint.id, endpoint.name, endpoint.urlString, reachable = true, statusCode = 204, elapsedMs = 120)
                    }
                    "cloudflare-doh" -> {
                        delay(150L)
                        EndpointProbeOutcome(endpoint.id, endpoint.name, endpoint.urlString, reachable = true, statusCode = 200, elapsedMs = 150)
                    }
                    else -> {
                        delay(2_000L)
                        EndpointProbeOutcome(endpoint.id, endpoint.name, endpoint.urlString, reachable = false, elapsedMs = 2_000, errorMessage = "请求超时 (10s)")
                    }
                }
            },
            clockMs = { testScheduler.currentTime },
            delayFn = { delay(it) },
            externalScope = backgroundScope
        )
        runCurrent()
        assertEquals(4, vm.uiState.value.probeEndpoints.size)
        assertFalse(vm.uiState.value.hasStoredPassword)

        vm.triggerManualProbe()
        // Duplicate click while probing must be ignored
        vm.triggerManualProbe()
        runCurrent()
        assertTrue(vm.uiState.value.isProbingNodes)

        // At 200ms, the 3 fast nodes have already streamed into probeOutcomes while the 4th is still running
        advanceTimeBy(200L)
        runCurrent()
        assertTrue(vm.uiState.value.isProbingNodes)
        assertEquals(3, vm.uiState.value.probeOutcomes.size)
        assertEquals(true, vm.uiState.value.probeOutcomes["661313-204"]?.reachable)
        assertEquals(200, vm.uiState.value.probeOutcomes["cloudflare-doh"]?.statusCode)

        // At 2_000ms total (not 80+120+150+2000 serial!), the entire concurrent round finishes
        advanceTimeBy(1_850L)
        runCurrent()
        assertFalse(vm.uiState.value.isProbingNodes)
        assertEquals(4, totalProbeCalls)
        assertEquals(4, vm.uiState.value.probeOutcomes.size)
        assertEquals(false, vm.uiState.value.probeOutcomes["telegram-api"]?.reachable)
        assertEquals(2_050L, testScheduler.currentTime)
        assertEquals(2_000L, vm.uiState.value.lastProbeCompletedAtMs)

        // Subsequent manual trigger refreshes wifiMonitor again and clears stale outcomes cleanly
        expectedRefreshCount = 2
        vm.triggerManualProbe()
        runCurrent()
        assertTrue(vm.uiState.value.isProbingNodes)
        assertTrue(vm.uiState.value.probeOutcomes.isEmpty())
        advanceTimeBy(2_050L)
        runCurrent()
        assertFalse(vm.uiState.value.isProbingNodes)
        assertEquals(8, totalProbeCalls)
        assertEquals(2, wifi.refreshCount)
    }
}

private class FakeProfileRepo(initial: StoredAppSettings) : ProfileRepository {
    private var current = initial
    override fun load(): StoredAppSettings = current
    override fun save(settings: StoredAppSettings) {
        current = settings
    }
}

private class FakeCredentialRepo(private val map: MutableMap<String, String>) : CredentialRepository {
    override fun readPassword(profileId: String): String? = map[profileId]
    override fun writePassword(profileId: String, password: String) {
        map[profileId] = password
    }
    override fun deletePassword(profileId: String) {
        map.remove(profileId)
    }
    override fun hasPassword(profileId: String): Boolean = !map[profileId].isNullOrEmpty()
}

private class FakeWifiMonitor(initial: WifiLanState) : WifiLanMonitor {
    private val _state = MutableStateFlow(initial)
    override val state: StateFlow<WifiLanState> = _state
    var refreshCount: Int = 0
    override fun currentWifiNetwork(): Network? = null
    override fun refresh() {
        refreshCount += 1
    }
    override fun close() = Unit
    fun emit(next: WifiLanState) {
        _state.value = next
    }
}

private class FakeRouterBackend(
    private var wanIpv4: String,
    private val nextWanIpv4OnSecondFetchAfterReconnect: String? = null
) {
    var statusQueryCount = 0
    var stationListQueryCount = 0
    private var loggedIn = false
    private var wanConnected = true
    private var postReconnectStatusFetches = 0
    private var reconnected = false

    fun handle(request: RouterHttpRequest): RouterHttpResponse {
        if (request.method == "GET") {
            if (request.url.contains("/tmpl/network/apn_setting.html")) {
                return RouterHttpResponse(200, "<html></html>".toByteArray(Charsets.UTF_8))
            }
            val query = URI(request.url).rawQuery.orEmpty()
            val cmd = query.split("&")
                .firstOrNull { it.startsWith("cmd=") }
                ?.removePrefix("cmd=")
                .orEmpty()
            val obj = JSONObject()
            when (cmd) {
                "loginfo" -> obj.put("loginfo", if (loggedIn) "ok" else "")
                "ppp_status" -> obj.put("ppp_status", if (wanConnected) "ipv4_ipv6_connected" else "ppp_disconnected")
                "station_list" -> {
                    stationListQueryCount += 1
                    obj.put(
                        "station_list",
                        JSONArray().put(
                            JSONObject()
                                .put("hostname", "phone-1")
                                .put("ip_addr", "192.168.8.20")
                                .put("mac_addr", "00:00:5E:00:53:99")
                                .put("interfacetype", "WIFI5")
                                .put("connect_time", 60)
                                .put("ssid_index", "1")
                        )
                    )
                }
                "lan_station_list" -> obj.put("lan_station_list", JSONArray())
                else -> {
                    if (cmd.contains("network_type")) {
                        statusQueryCount += 1
                        if (reconnected && loggedIn && nextWanIpv4OnSecondFetchAfterReconnect != null) {
                            postReconnectStatusFetches += 1
                            if (postReconnectStatusFetches >= 2) {
                                wanIpv4 = nextWanIpv4OnSecondFetchAfterReconnect
                            }
                        }
                    }
                    for (key in cmd.split(",")) {
                        val v = when (key) {
                            "wa_inner_version" -> "BD_FLYMODEMMU5120V1.0.1B12"
                            "RD" -> "RD_1"
                            "LD" -> "LD_1"
                            "loginfo" -> if (loggedIn) "ok" else ""
                            "ppp_status" -> if (!loggedIn) "" else if (wanConnected) "ipv4_ipv6_connected" else "ppp_disconnected"
                            "network_type" -> if (loggedIn) "SA" else ""
                            "nr5g_action_band" -> if (loggedIn) "n41" else ""
                            "5g_rx0_rsrp" -> if (loggedIn) "-78" else ""
                            "Z5g_SINR" -> if (loggedIn) "21.0" else ""
                            "Z5g_rsrq" -> if (loggedIn) "-9" else ""
                            "wan_ipaddr" -> if (loggedIn) wanIpv4 else ""
                            "wifi_access_sta_num" -> if (loggedIn) "1" else ""
                            else -> ""
                        }
                        obj.put(key, v)
                    }
                }
            }
            return RouterHttpResponse(200, obj.toString().toByteArray(Charsets.UTF_8))
        }

        val body = request.body?.toString(Charsets.UTF_8).orEmpty()
        when {
            body.contains("goformId=LOGIN") -> loggedIn = true
            body.contains("goformId=DISCONNECT_NETWORK") -> wanConnected = false
            body.contains("goformId=CONNECT_NETWORK") -> {
                wanConnected = true
                reconnected = true
                postReconnectStatusFetches = 0
            }
        }
        return RouterHttpResponse(200, """{"result":"0"}""".toByteArray(Charsets.UTF_8))
    }
}

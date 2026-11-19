package com.zte.routerbar.ui

import android.net.Network
import com.zte.routerbar.core.AuthHashPreference
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
    override fun currentWifiNetwork(): Network? = null
    override fun refresh() = Unit
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

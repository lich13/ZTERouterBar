package com.zte.routerbar.core

import java.net.URI
import java.net.URLDecoder
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ZteRouterClientTest {
    @Test
    fun clientSendsMultiDataQueriesStationsIndividuallyAndRecoversKickedSessionOnReconnect() = runTest {
        val transport = MockRouterTransport(
            simulateKickedOutBeforeDisconnect = true,
            simulateDuplicateUntilLogout = true
        )
        val config = RouterEndpointConfig.parse("http://192.168.8.1", AuthHashPreference.AUTO)
        var fakeClock = 1_700_000_000_000L
        val client = ZteRouterClient(
            config = config,
            password = "fixture-password",
            transport = transport,
            clockMs = { fakeClock },
            delayFn = { ms -> fakeClock += ms }
        )

        try {
            client.fetchStatus(reclaimIfDuplicate = false)
            fail("Expected DuplicateUser")
        } catch (_: ZteRouterException.DuplicateUser) {
            // expected
        }

        val finalState = client.reconnectInternet(pauseBetweenDisconnectAndConnectMs = 10L)
        assertTrue(finalState.isConnected)

        val snap = client.fetchStatus()
        assertEquals(6, snap.wirelessDeviceCount)
        assertEquals(2, snap.wifiStations.size)
        assertEquals(1, snap.wiredDeviceCount)
        assertEquals(7, snap.totalConnectedDevices)

        val captured = transport.capturedRequests
        for (req in captured) {
            assertEquals("http://192.168.8.1/index.html", req.headers["Referer"])
            assertEquals("http://192.168.8.1", req.headers["Origin"])
            assertEquals("XMLHttpRequest", req.headers["X-Requested-With"])
        }

        // Literal commas preserved in multi-cmd query
        assertTrue(captured.any { it.url.contains("cmd=wa_inner_version,cr_version,RD,LD") })

        val loginfoQueries = captured.filter { it.method == "GET" && it.url.contains("cmd=loginfo&") }
        assertTrue(loginfoQueries.isNotEmpty())
        assertTrue(loginfoQueries.all { it.url.contains("multi_data=1") })

        val stationQueries = captured.filter { it.method == "GET" && it.url.contains("cmd=station_list&") }
        assertEquals(1, stationQueries.size)
        assertFalse(stationQueries[0].url.contains("multi_data=1"))

        val bgBefore = captured.size
        val bgSnap = client.fetchStatus(includeStationLists = false)
        assertEquals(6, bgSnap.wirelessDeviceCount)
        assertTrue(bgSnap.wifiStations.isEmpty())
        val bgRequests = transport.capturedRequests.drop(bgBefore)
        assertEquals(1, bgRequests.size)
        assertTrue(bgRequests[0].url.contains("loginfo"))
        assertTrue(bgRequests[0].url.contains("multi_data=1"))

        val postGoforms = transport.capturedRequests.mapNotNull { req ->
            if (req.method != "POST" || req.body == null) return@mapNotNull null
            req.body.toString(Charsets.UTF_8)
                .split("&")
                .firstOrNull { it.startsWith("goformId=") }
        }
        assertTrue("goformId=LOGOUT" in postGoforms)
        assertTrue("goformId=DISCONNECT_NETWORK" in postGoforms)
        assertTrue("goformId=CONNECT_NETWORK" in postGoforms)

        // After 60s, fetchStatus triggers keep-alive GET to apn_setting.html
        fakeClock += 60_000L
        client.fetchStatus(includeStationLists = false)
        assertTrue(transport.capturedRequests.any { it.url.contains("/tmpl/network/apn_setting.html?v=") })
    }

    @Test
    fun statusPollRecoversKickedSessionAndFallsBackWhenLoginfoOmitted() = runTest {
        val transport1 = MockRouterTransport()
        val config = RouterEndpointConfig.parse("http://192.168.8.1")
        val client1 = ZteRouterClient(
            config = config,
            password = "fixture-password",
            transport = transport1,
            delayFn = {}
        )

        client1.fetchStatus(includeStationLists = false)
        transport1.expireSession()
        val snap = client1.fetchStatus(includeStationLists = false)
        assertEquals("SA", snap.networkType)
        assertEquals(2, loginPostCount(transport1.capturedRequests))
        assertFalse(transport1.capturedRequests.any { it.url.contains("cmd=loginfo&") })

        // Firmware omitting loginfo in merged status query falls back to explicit cmd=loginfo check
        val transport2 = MockRouterTransport(omitLoginfoInStatusQuery = true)
        val client2 = ZteRouterClient(
            config = config,
            password = "fixture-password",
            transport = transport2,
            delayFn = {}
        )
        repeat(3) {
            assertEquals("SA", client2.fetchStatus(includeStationLists = false).networkType)
        }
        assertEquals(1, loginPostCount(transport2.capturedRequests))
        assertTrue(transport2.capturedRequests.any { it.url.contains("cmd=loginfo&") })
    }

    @Test
    fun surfacesWrongPasswordAndSerializesConcurrentOperationsWithoutDeadlock() = runTest {
        val badTransport = MockRouterTransport(rejectLogin = true)
        val config = RouterEndpointConfig.parse("http://192.168.8.1")
        val badClient = ZteRouterClient(config = config, password = "wrong", transport = badTransport, delayFn = {})
        try {
            badClient.fetchStatus()
            fail("Expected WrongPassword")
        } catch (_: ZteRouterException.WrongPassword) {
            // expected
        }

        // Concurrent poll + reconnect serialized by non-reentrant opMutex
        val okTransport = MockRouterTransport()
        val okClient = ZteRouterClient(config = config, password = "ok", transport = okTransport, delayFn = {})
        val job1 = async { okClient.fetchStatus(includeStationLists = false) }
        val job2 = async { okClient.reconnectInternet(pauseBetweenDisconnectAndConnectMs = 5L) }
        assertEquals("SA", job1.await().networkType)
        assertTrue(job2.await().isConnected)
    }

    @Test
    fun isolatedCookieJarStoresPerInstanceCookiesAndIgnoresNullStatusLineHeader() {
        val jarA = IsolatedCookieJar()
        val jarB = IsolatedCookieJar()
        val uri = URI("http://192.168.8.1/goform/goform_set_cmd_process")

        jarA.storeFromResponse(
            uri,
            mapOf(
                null to listOf("HTTP/1.1 200 OK"),
                "Set-Cookie" to listOf("stok=TOKEN_A; Path=/")
            )
        )
        assertEquals("stok=TOKEN_A", jarA.cookieHeaderFor(URI("http://192.168.8.1/goform/goform_get_cmd_process")))
        assertNull(jarB.cookieHeaderFor(URI("http://192.168.8.1/goform/goform_get_cmd_process")))
    }

    @Test
    fun reloginUsesActualPreLoginVersionFieldsForAdWhileKeepingCachedModelAlgorithm() = runTest {
        var loggedIn = false
        val loginAds = mutableListOf<String>()
        val transport = RouterHttpTransport { req ->
            if (req.method == "GET") {
                val query = URI(req.url).rawQuery.orEmpty()
                val cmd = query.split("&").firstOrNull { it.startsWith("cmd=") }?.removePrefix("cmd=").orEmpty()
                val obj = JSONObject()
                for (k in cmd.split(",")) {
                    val v = when (k) {
                        // Firmware masks wa_inner_version before login, exposes legacy MD5 model after login.
                        "wa_inner_version" -> if (loggedIn) "BD_MC801AV1.0.0B01" else ""
                        "cr_version" -> ""
                        "RD" -> "RD_TOKEN"
                        "LD" -> "LD_TOKEN"
                        "loginfo" -> if (loggedIn) "ok" else ""
                        "ppp_status" -> if (loggedIn) "ppp_connected" else ""
                        "network_type" -> if (loggedIn) "LTE" else ""
                        else -> ""
                    }
                    obj.put(k, v)
                }
                RouterHttpResponse(200, obj.toString().toByteArray(Charsets.UTF_8))
            } else {
                val body = req.body?.toString(Charsets.UTF_8).orEmpty()
                val ad = body.split("&")
                    .firstOrNull { it.startsWith("AD=") }
                    ?.removePrefix("AD=")
                    ?.let { URLDecoder.decode(it, Charsets.UTF_8.name()) }
                    .orEmpty()
                loginAds.add(ad)
                loggedIn = true
                RouterHttpResponse(200, """{"result":"0"}""".toByteArray(Charsets.UTF_8))
            }
        }

        val client = ZteRouterClient(
            config = RouterEndpointConfig.parse("http://192.168.8.1", AuthHashPreference.AUTO),
            password = "pw",
            transport = transport,
            delayFn = {}
        )

        // First poll:wa_inner_version="" -> defaults to SHA256("") + RD_TOKEN, then caches BD_MC801AV1.0.0B01.
        assertEquals("LTE", client.fetchStatus(includeStationLists = false).networkType)
        assertEquals(
            RouterCrypto.computeAD("", "", "RD_TOKEN", ResolvedHashAlgorithm.SHA256),
            loginAds[0]
        )

        // Expire session: second LOGIN resolves MD5 from cached BD_MC801A, while hashing actual pre-login wa="" + cr="".
        loggedIn = false
        assertEquals("LTE", client.fetchStatus(includeStationLists = false).networkType)
        assertEquals(
            RouterCrypto.computeAD("", "", "RD_TOKEN", ResolvedHashAlgorithm.MD5),
            loginAds[1]
        )
    }

    private fun loginPostCount(requests: List<RouterHttpRequest>): Int =
        requests.count { req ->
            req.method == "POST" && req.body?.toString(Charsets.UTF_8)?.contains("goformId=LOGIN") == true
        }
}

internal class MockRouterTransport(
    private val rejectLogin: Boolean = false,
    private var simulateKickedOutBeforeDisconnect: Boolean = false,
    simulateDuplicateUntilLogout: Boolean = false,
    private val omitLoginfoInStatusQuery: Boolean = false
) : RouterHttpTransport {
    val capturedRequests = mutableListOf<RouterHttpRequest>()
    private var loggedIn = false
    private var wanConnected = true
    private var occupiedByOtherSession = simulateDuplicateUntilLogout

    @Synchronized
    fun expireSession() {
        loggedIn = false
    }

    override suspend fun send(request: RouterHttpRequest): RouterHttpResponse = handleSync(request)

    @Synchronized
    private fun handleSync(request: RouterHttpRequest): RouterHttpResponse {
        capturedRequests.add(request)
        if (request.method == "GET") {
            if (request.url.contains("/tmpl/network/apn_setting.html")) {
                return RouterHttpResponse(200, "<html></html>".toByteArray(Charsets.UTF_8))
            }
            val query = URI(request.url).rawQuery.orEmpty()
            val cmd = parseForm(query)["cmd"].orEmpty()
            val payload = JSONObject()

            when (cmd) {
                "loginfo" -> payload.put("loginfo", if (loggedIn) "ok" else "")
                "ppp_status" -> payload.put("ppp_status", if (wanConnected) "ipv4_ipv6_connected" else "ppp_disconnected")
                "station_list" -> payload.put(
                    "station_list",
                    JSONArray()
                        .put(
                            JSONObject()
                                .put("interfacetype", "WIFI5")
                                .put("ip_addr", "192.168.8.47")
                                .put("connect_time", "100")
                                .put("ssid_index", "2")
                                .put("mac_addr", "00:00:5E:00:53:01")
                                .put("hostname", "dev-1")
                        )
                        .put(
                            JSONObject()
                                .put("interfacetype", "WIFI5")
                                .put("ip_addr", "192.168.8.48")
                                .put("connect_time", "200")
                                .put("ssid_index", "1")
                                .put("mac_addr", "00:00:5E:00:53:02")
                                .put("hostname", "dev-2")
                        )
                )
                "lan_station_list" -> payload.put(
                    "lan_station_list",
                    JSONArray().put(
                        JSONObject()
                            .put("interfacetype", "")
                            .put("ip_addr", "192.168.8.50")
                            .put("connect_time", "300")
                            .put("ssid_index", "")
                            .put("mac_addr", "00:00:5E:00:53:03")
                            .put("hostname", "lan-1")
                    )
                )
                else -> {
                    for (key in cmd.split(",")) {
                        val value = when (key) {
                            "wa_inner_version" -> "BD_FLYMODEMMU5120V1.0.1B12"
                            "cr_version" -> ""
                            "RD" -> "MOCK_RD_123"
                            "LD" -> "MOCK_LD_456"
                            "modem_main_state" -> if (loggedIn) "modem_init_complete" else ""
                            "network_type" -> if (loggedIn) "SA" else ""
                            "wifi_access_sta_num" -> if (loggedIn) "6" else ""
                            "wifi_chip1_ssid1_access_sta_num" -> if (loggedIn) "1" else ""
                            "wifi_chip2_ssid1_access_sta_num" -> if (loggedIn) "5" else ""
                            "ppp_status" -> if (!loggedIn) "" else if (wanConnected) "ipv4_ipv6_connected" else "ppp_disconnected"
                            "loginfo" -> if (loggedIn && !omitLoginfoInStatusQuery) "ok" else ""
                            else -> ""
                        }
                        payload.put(key, value)
                    }
                }
            }
            return RouterHttpResponse(200, payload.toString().toByteArray(Charsets.UTF_8))
        }

        val bodyText = request.body?.toString(Charsets.UTF_8).orEmpty()
        val params = parseForm(bodyText)
        val result = when (params["goformId"].orEmpty()) {
            "LOGIN" -> when {
                rejectLogin -> "3"
                occupiedByOtherSession -> "2"
                else -> {
                    loggedIn = true
                    "0"
                }
            }
            "LOGOUT" -> {
                occupiedByOtherSession = false
                loggedIn = false
                "success"
            }
            "DISCONNECT_NETWORK" -> {
                if (simulateKickedOutBeforeDisconnect) {
                    simulateKickedOutBeforeDisconnect = false
                    loggedIn = false
                    "failure"
                } else {
                    wanConnected = false
                    "success"
                }
            }
            "CONNECT_NETWORK" -> {
                wanConnected = true
                "success"
            }
            else -> "success"
        }
        return RouterHttpResponse(200, JSONObject().put("result", result).toString().toByteArray(Charsets.UTF_8))
    }

    private fun parseForm(encoded: String): Map<String, String> {
        if (encoded.isEmpty()) return emptyMap()
        val map = LinkedHashMap<String, String>()
        for (pair in encoded.split("&")) {
            val idx = pair.indexOf('=')
            if (idx > 0) {
                val k = URLDecoder.decode(pair.substring(0, idx), Charsets.UTF_8.name())
                val v = URLDecoder.decode(pair.substring(idx + 1), Charsets.UTF_8.name())
                map[k] = v
            }
        }
        return map
    }
}

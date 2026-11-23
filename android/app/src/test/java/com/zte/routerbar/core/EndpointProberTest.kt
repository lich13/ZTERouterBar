package com.zte.routerbar.core

import com.zte.routerbar.data.ProbeNetworkRoute
import com.zte.routerbar.data.resolveProbeNetworkRoute
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class EndpointProberTest {
    @Test
    fun defaultPresetsMatchMacOsWatchdogNodesAndTimeout() {
        val presets = ProbeEndpoint.defaultPresets()
        assertEquals(4, presets.size)
        assertEquals(
            listOf(
                "https://661313.xyz/test/generate_204",
                "https://www.youtube.com/generate_204",
                "https://cloudflare-dns.com/cdn-cgi/trace",
                "https://api.telegram.org/"
            ),
            presets.map { it.urlString }
        )
        assertTrue(presets.all { it.timeoutSec == 10 && it.isValidHttpUrl })
    }

    @Test
    fun rejectsMalformedUrlsAndClassifiesGatewayFailureCodes() = runTest {
        val prober = HttpEndpointProber(transport = { _, _, _ -> 204 })

        val invalid = prober.check(ProbeEndpoint(id = "bad", name = "Invalid", urlString = "ftp://example.invalid"))
        assertFalse(invalid.reachable)
        assertNotNull(invalid.errorMessage)

        assertNull(HttpEndpointProber.failureMessageForStatusCode(200))
        assertNull(HttpEndpointProber.failureMessageForStatusCode(204))
        assertNull(HttpEndpointProber.failureMessageForStatusCode(302))
        assertNotNull(HttpEndpointProber.failureMessageForStatusCode(407))
        assertNotNull(HttpEndpointProber.failureMessageForStatusCode(502))
        assertNotNull(HttpEndpointProber.failureMessageForStatusCode(503))
        assertNotNull(HttpEndpointProber.failureMessageForStatusCode(504))
    }

    @Test
    fun hardTimeoutCancelsStalledTransportAndReportsMonotonicElapsedMs() = runTest {
        var fakeNano = 1_000_000_000L
        val prober = HttpEndpointProber(
            transport = { _, _, _ ->
                try {
                    awaitCancellation()
                } finally {
                    fakeNano += 10_000_000_000L
                }
            },
            nanoTime = { fakeNano },
            wallClockMs = { 1_700_000_000_000L }
        )

        val ep = ProbeEndpoint(id = "stall", name = "Stalled", urlString = "https://example.invalid/generate_204", timeoutSec = 10)
        val outcome = prober.check(ep)

        assertFalse(outcome.reachable)
        assertEquals(10_000, outcome.elapsedMs)
        assertEquals("请求超时 (10s)", outcome.errorMessage)
    }

    @Test
    fun realHttpUrlConnectionSendsWatchdogHeadersStopsAtRedirectAndFlags502() = runBlocking {
        val capturedHeaders = AtomicReference<Map<String, String>>(emptyMap())
        val stallEntered = CountDownLatch(1)
        val releaseStall = CountDownLatch(1)
        val serverExecutor = Executors.newCachedThreadPool()
        val serverSocket = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))

        serverExecutor.execute {
            while (!serverSocket.isClosed) {
                val client = runCatching { serverSocket.accept() }.getOrNull() ?: break
                serverExecutor.execute {
                    client.use { sock ->
                        val reader = BufferedReader(InputStreamReader(sock.getInputStream(), Charsets.UTF_8))
                        val requestLine = reader.readLine().orEmpty()
                        val headers = LinkedHashMap<String, String>()
                        while (true) {
                            val line = reader.readLine() ?: break
                            if (line.isEmpty()) break
                            val colon = line.indexOf(':')
                            if (colon > 0) {
                                headers[line.substring(0, colon).trim().lowercase(Locale.ROOT)] =
                                    line.substring(colon + 1).trim()
                            }
                        }
                        val path = requestLine.split(" ").getOrNull(1).orEmpty()
                        val out = sock.getOutputStream()
                        when (path) {
                            "/generate_204" -> {
                                capturedHeaders.set(headers)
                                out.write("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                                out.flush()
                            }
                            "/redirect" -> {
                                out.write(
                                    (
                                        "HTTP/1.1 302 Found\r\n" +
                                            "Location: http://127.0.0.1:1/unreachable\r\n" +
                                            "Content-Length: 0\r\n" +
                                            "Connection: close\r\n\r\n"
                                        ).toByteArray()
                                )
                                out.flush()
                            }
                            "/bad_gateway" -> {
                                out.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                                out.flush()
                            }
                            "/slow_body" -> {
                                out.write("HTTP/1.1 200 OK\r\nContent-Length: 4096\r\nConnection: close\r\n\r\nfl=1\n".toByteArray())
                                out.flush()
                                releaseStall.await(30, TimeUnit.SECONDS)
                            }
                            "/hang" -> {
                                stallEntered.countDown()
                                releaseStall.await(30, TimeUnit.SECONDS)
                            }
                            else -> Unit
                        }
                        Unit
                    }
                }
            }
        }

        try {
            val port = serverSocket.localPort
            val prober = HttpEndpointProber()

            val ok204 = prober.check(ProbeEndpoint("p1", "204 Node", "http://127.0.0.1:$port/generate_204", timeoutSec = 3))
            assertTrue(ok204.reachable)
            assertEquals(204, ok204.statusCode)
            assertEquals("ZTERouterBar-Watchdog/1.0", capturedHeaders.get()["user-agent"])
            assertEquals("identity", capturedHeaders.get()["accept-encoding"])

            // 302 must NOT follow redirect to closed port 1; treated immediately as reachable 302.
            val ok302 = prober.check(ProbeEndpoint("p2", "Telegram 302", "http://127.0.0.1:$port/redirect", timeoutSec = 3))
            assertTrue(ok302.reachable)
            assertEquals(302, ok302.statusCode)

            // 200 with unread/stalled body must return as soon as status headers arrive without draining body.
            val okSlowBody = prober.check(ProbeEndpoint("p2b", "Trace 200", "http://127.0.0.1:$port/slow_body", timeoutSec = 1))
            assertTrue(okSlowBody.reachable)
            assertEquals(200, okSlowBody.statusCode)

            val fail502 = prober.check(ProbeEndpoint("p3", "Proxy 502", "http://127.0.0.1:$port/bad_gateway", timeoutSec = 3))
            assertFalse(fail502.reachable)
            assertEquals(502, fail502.statusCode)
            assertEquals("网关/代理不可达 (HTTP 502)", fail502.errorMessage)

            val timedOut = prober.check(ProbeEndpoint("p4", "Hung Socket", "http://127.0.0.1:$port/hang", timeoutSec = 1))
            assertTrue(stallEntered.await(2, TimeUnit.SECONDS))
            assertFalse(timedOut.reachable)
            assertEquals("请求超时 (1s)", timedOut.errorMessage)
        } finally {
            releaseStall.countDown()
            runCatching { serverSocket.close() }
            serverExecutor.shutdownNow()
        }
    }

    @Test
    fun probeNetworkRoutePrioritizesVpnThenStrictWifiOrWiredLanThenSystemDefault() {
        // Active Clash/Sing-box VPN (over Wi-Fi, USB/Ethernet, or mobile data where activeNetwork only reports TRANSPORT_VPN):
        // always routes through system default so VPN tunnel traffic is probed accurately.
        assertEquals(
            ProbeNetworkRoute.SYSTEM_DEFAULT,
            resolveProbeNetworkRoute(hasWifiNetwork = true, activeHasVpn = true, activeHasWiredLan = false)
        )
        assertEquals(
            ProbeNetworkRoute.SYSTEM_DEFAULT,
            resolveProbeNetworkRoute(hasWifiNetwork = true, activeHasVpn = true, activeHasWiredLan = true)
        )
        assertEquals(
            ProbeNetworkRoute.SYSTEM_DEFAULT,
            resolveProbeNetworkRoute(hasWifiNetwork = false, activeHasVpn = true, activeHasWiredLan = false)
        )
        assertEquals(
            ProbeNetworkRoute.SYSTEM_DEFAULT,
            resolveProbeNetworkRoute(hasWifiNetwork = false, activeHasVpn = true, activeHasWiredLan = true)
        )

        // Wi-Fi connected (including dead-WAN Wi-Fi where system activeNetwork fell back to SIM cellular):
        // strictly binds to Wi-Fi so dead-WAN Wi-Fi never leaks onto cellular.
        assertEquals(
            ProbeNetworkRoute.BOUND_WIFI,
            resolveProbeNetworkRoute(hasWifiNetwork = true, activeHasVpn = false, activeHasWiredLan = false)
        )
        assertEquals(
            ProbeNetworkRoute.BOUND_WIFI,
            resolveProbeNetworkRoute(hasWifiNetwork = true, activeHasVpn = false, activeHasWiredLan = true)
        )

        // USB-C / Ethernet LAN to CPE without Wi-Fi or VPN: binds to active wired LAN.
        assertEquals(
            ProbeNetworkRoute.BOUND_ACTIVE_LAN,
            resolveProbeNetworkRoute(hasWifiNetwork = false, activeHasVpn = false, activeHasWiredLan = true)
        )

        // Wi-Fi disconnected and no wired LAN (e.g. user manually triggers node speed test on mobile data):
        // uses system default instead of rejecting.
        assertEquals(
            ProbeNetworkRoute.SYSTEM_DEFAULT,
            resolveProbeNetworkRoute(hasWifiNetwork = false, activeHasVpn = false, activeHasWiredLan = false)
        )
    }
}

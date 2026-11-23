package com.zte.routerbar.core

import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URI
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout

fun interface EndpointProbing {
    suspend fun check(endpoint: ProbeEndpoint): EndpointProbeOutcome
}

fun interface HttpProbeTransport {
    suspend fun fetchStatusCode(
        url: URL,
        timeoutMs: Int,
        headers: Map<String, String>
    ): Int
}

class HttpEndpointProber(
    private val transport: HttpProbeTransport,
    private val nanoTime: () -> Long = { System.nanoTime() },
    private val wallClockMs: () -> Long = { System.currentTimeMillis() }
) : EndpointProbing {

    constructor(
        connectionOpener: (URL) -> HttpURLConnection = { url -> url.openConnection() as HttpURLConnection },
        nanoTime: () -> Long = { System.nanoTime() },
        wallClockMs: () -> Long = { System.currentTimeMillis() }
    ) : this(
        transport = BlockingHttpUrlProbeTransport(connectionOpener),
        nanoTime = nanoTime,
        wallClockMs = wallClockMs
    )

    override suspend fun check(endpoint: ProbeEndpoint): EndpointProbeOutcome {
        val trimmedUrl = endpoint.urlString.trim()
        val parsedUrl = if (endpoint.isValidHttpUrl) {
            runCatching { URI(trimmedUrl).toURL() }.getOrNull()
        } else {
            null
        }
        if (parsedUrl == null) {
            return makeOutcome(
                endpoint = endpoint,
                urlString = endpoint.urlString,
                reachable = false,
                errorMessage = "URL 格式无效（需 http/https）"
            )
        }

        val timeoutSec = endpoint.timeoutSec.coerceIn(1, 30)
        val timeoutMs = timeoutSec * 1_000
        val startNs = nanoTime()
        fun elapsedMs(): Int = ((nanoTime() - startNs) / 1_000_000L).coerceAtLeast(0L).toInt()

        return try {
            val statusCode = withTimeout(timeoutMs.toLong()) {
                transport.fetchStatusCode(
                    url = parsedUrl,
                    timeoutMs = timeoutMs,
                    headers = PROBE_HEADERS
                )
            }
            if (statusCode <= 0) {
                makeOutcome(
                    endpoint = endpoint,
                    urlString = trimmedUrl,
                    reachable = false,
                    elapsedMs = elapsedMs(),
                    errorMessage = "非 HTTP 响应"
                )
            } else {
                val gatewayErr = failureMessageForStatusCode(statusCode)
                if (gatewayErr != null) {
                    makeOutcome(
                        endpoint = endpoint,
                        urlString = trimmedUrl,
                        reachable = false,
                        statusCode = statusCode,
                        elapsedMs = elapsedMs(),
                        errorMessage = gatewayErr
                    )
                } else {
                    makeOutcome(
                        endpoint = endpoint,
                        urlString = trimmedUrl,
                        reachable = true,
                        statusCode = statusCode,
                        elapsedMs = elapsedMs()
                    )
                }
            }
        } catch (timeout: TimeoutCancellationException) {
            currentCoroutineContext().ensureActive()
            makeOutcome(
                endpoint = endpoint,
                urlString = trimmedUrl,
                reachable = false,
                elapsedMs = elapsedMs(),
                errorMessage = "请求超时 (${timeoutSec}s)"
            )
        } catch (_: SocketTimeoutException) {
            currentCoroutineContext().ensureActive()
            makeOutcome(
                endpoint = endpoint,
                urlString = trimmedUrl,
                reachable = false,
                elapsedMs = elapsedMs(),
                errorMessage = "请求超时 (${timeoutSec}s)"
            )
        } catch (ce: CancellationException) {
            throw ce
        } catch (err: Throwable) {
            currentCoroutineContext().ensureActive()
            val message = err.message?.trim()?.takeIf { it.isNotEmpty() }
                ?: err.javaClass.simpleName
            makeOutcome(
                endpoint = endpoint,
                urlString = trimmedUrl,
                reachable = false,
                elapsedMs = elapsedMs(),
                errorMessage = message
            )
        }
    }

    private fun makeOutcome(
        endpoint: ProbeEndpoint,
        urlString: String,
        reachable: Boolean,
        statusCode: Int? = null,
        elapsedMs: Int = 0,
        errorMessage: String? = null
    ): EndpointProbeOutcome = EndpointProbeOutcome(
        id = endpoint.id,
        name = endpoint.displayTitle,
        urlString = urlString,
        reachable = reachable,
        statusCode = statusCode,
        elapsedMs = elapsedMs,
        errorMessage = errorMessage,
        checkedAtMs = wallClockMs()
    )

    companion object {
        val PROBE_HEADERS: Map<String, String> = mapOf(
            "User-Agent" to "ZTERouterBar-Watchdog/1.0",
            "Accept" to "*/*",
            "Accept-Encoding" to "identity",
            "Connection" to "close"
        )

        fun failureMessageForStatusCode(statusCode: Int): String? = when (statusCode) {
            407 -> "代理需要认证 (407)"
            502, 503, 504 -> "网关/代理不可达 (HTTP $statusCode)"
            else -> null
        }
    }
}

private class BlockingHttpUrlProbeTransport(
    private val connectionOpener: (URL) -> HttpURLConnection
) : HttpProbeTransport {
    override suspend fun fetchStatusCode(
        url: URL,
        timeoutMs: Int,
        headers: Map<String, String>
    ): Int = suspendCancellableCoroutine { cont ->
        val connRef = AtomicReference<HttpURLConnection?>(null)
        val future = probeIoExecutor.submit(
            Runnable {
                var connection: HttpURLConnection? = null
                try {
                    if (!cont.isActive) return@Runnable
                    connection = connectionOpener(url)
                    connRef.set(connection)
                    if (!cont.isActive) {
                        runCatching { connection.disconnect() }
                        return@Runnable
                    }
                    connection.requestMethod = "GET"
                    connection.connectTimeout = timeoutMs
                    connection.readTimeout = timeoutMs
                    connection.useCaches = false
                    connection.instanceFollowRedirects = false
                    for ((k, v) in headers) {
                        connection.setRequestProperty(k, v)
                    }

                    val code = connection.responseCode
                    if (cont.isActive) {
                        cont.resume(code)
                    }
                } catch (t: Throwable) {
                    if (cont.isActive) {
                        cont.resumeWithException(t)
                    }
                } finally {
                    runCatching { connection?.disconnect() }
                }
            }
        )
        cont.invokeOnCancellation {
            runCatching { connRef.get()?.disconnect() }
            future.cancel(true)
        }
    }

    companion object {
        private val probeIoExecutor = Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "ZTERouterBar-Probe").apply { isDaemon = true }
        }
    }
}

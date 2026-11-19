package com.zte.routerbar.core

import android.net.Network
import java.net.CookieManager
import java.net.CookiePolicy
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.withContext

data class RouterHttpRequest(
    val url: String,
    val method: String = "GET",
    val headers: Map<String, String> = emptyMap(),
    val body: ByteArray? = null
)

data class RouterHttpResponse(
    val statusCode: Int,
    val body: ByteArray,
    val headers: Map<String, List<String>> = emptyMap()
)

fun interface RouterHttpTransport {
    suspend fun send(request: RouterHttpRequest): RouterHttpResponse
}

internal class IsolatedCookieJar {
    private val manager = CookieManager(null, CookiePolicy.ACCEPT_ALL)

    @Synchronized
    fun cookieHeaderFor(uri: URI): String? {
        val stored = manager.get(uri, emptyMap())
        val values = stored["Cookie"].orEmpty() + stored["Cookie2"].orEmpty()
        return values.filter { it.isNotBlank() }.takeIf { it.isNotEmpty() }?.joinToString("; ")
    }

    @Synchronized
    fun storeFromResponse(uri: URI, rawHeaders: Map<String?, List<String>?>?) {
        if (rawHeaders.isNullOrEmpty()) return
        val sanitized = LinkedHashMap<String, List<String>>()
        for ((key, values) in rawHeaders) {
            if (key != null && values != null) {
                sanitized[key] = values
            }
        }
        if (sanitized.isNotEmpty()) {
            manager.put(uri, sanitized)
        }
    }
}

class HttpUrlConnectionTransport(
    private val networkProvider: () -> Network? = { null },
    private val connectTimeoutMs: Int = 8_000,
    private val readTimeoutMs: Int = 16_000
) : RouterHttpTransport {
    private val cookieJar = IsolatedCookieJar()

    override suspend fun send(request: RouterHttpRequest): RouterHttpResponse = withContext(Dispatchers.IO) {
        val parsedUrl = URL(request.url)
        val uri = parsedUrl.toURI()
        val boundNetwork = networkProvider()
        val connection = ((boundNetwork?.openConnection(parsedUrl) ?: parsedUrl.openConnection()) as HttpURLConnection)
        val cancelHandle = coroutineContext[Job]?.invokeOnCancellation {
            runCatching { connection.disconnect() }
        }

        try {
            connection.requestMethod = request.method
            connection.connectTimeout = connectTimeoutMs
            connection.readTimeout = readTimeoutMs
            connection.useCaches = false
            connection.instanceFollowRedirects = false

            for ((headerName, headerValue) in request.headers) {
                connection.setRequestProperty(headerName, headerValue)
            }
            cookieJar.cookieHeaderFor(uri)?.let { cookieLine ->
                connection.setRequestProperty("Cookie", cookieLine)
            }

            val payload = request.body
            if (payload != null) {
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(payload.size)
                connection.outputStream.use { out ->
                    out.write(payload)
                    out.flush()
                }
            }

            val statusCode = connection.responseCode
            cookieJar.storeFromResponse(uri, connection.headerFields)

            val stream = if (statusCode in 200..399) {
                connection.inputStream
            } else {
                connection.errorStream
            }
            val bytes = stream?.use { it.readBytes() } ?: ByteArray(0)
            val cleanHeaders = connection.headerFields.orEmpty()
                .entries
                .mapNotNull { (k, v) -> if (k != null && v != null) k to v else null }
                .toMap()

            RouterHttpResponse(
                statusCode = statusCode,
                body = bytes,
                headers = cleanHeaders
            )
        } finally {
            cancelHandle?.dispose()
            connection.disconnect()
        }
    }
}

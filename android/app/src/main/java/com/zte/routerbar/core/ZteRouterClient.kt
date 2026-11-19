package com.zte.routerbar.core

import java.net.URLEncoder
import java.util.Locale
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject

sealed class ZteRouterException(override val message: String) : Exception(message) {
    data class InvalidBaseUrl(val url: String) : ZteRouterException("无效的路由器地址：$url")
    data object MissingPassword : ZteRouterException("尚未设置路由器管理密码，请在配置中输入密码。")
    data object WrongPassword : ZteRouterException("路由器管理密码错误，请检查配置中的密码。")
    data object LoginRateLimited : ZteRouterException("路由器登录尝试过于频繁，请稍后再试。")
    data object DuplicateUser : ZteRouterException(
        "路由器后台仅允许单端登录，当前已被其他网页或设备占用；退出另一端登录或等待超时后将自动恢复。"
    )
    data object SessionExpired : ZteRouterException("路由器登录会话已失效（可能被其他终端踢出），请稍后重试。")
    data class LoginFailed(val code: String) : ZteRouterException("登录失败（返回码：$code）。")
    data class CommandFailed(val goformId: String, val result: String) :
        ZteRouterException("指令 $goformId 执行失败（返回：$result）。")
    data class InvalidResponse(val detail: String) : ZteRouterException("路由器返回数据无法解析：$detail")
    data class HttpError(val statusCode: Int) : ZteRouterException("路由器 HTTP 错误：$statusCode")
    data class TransportError(val detail: String) : ZteRouterException("无法连接路由器：$detail")
}

class ZteRouterClient(
    private val config: RouterEndpointConfig,
    private val password: String = "",
    private val transport: RouterHttpTransport,
    private val clockMs: () -> Long = { System.currentTimeMillis() },
    private val delayFn: suspend (Long) -> Unit = { delay(it) }
) {
    private val opMutex = Mutex()

    private var cachedWaInnerVersion: String = ""
    private var cachedCrVersion: String = ""
    private var lastKeepAliveAtMs: Long? = null
    private var statusQueryReportsLogin: Boolean = true

    suspend fun checkLoggedIn(): Boolean = opMutex.withLock {
        checkLoggedInLocked()
    }

    suspend fun login(reclaimIfDuplicate: Boolean = false) = opMutex.withLock {
        loginLocked(reclaimIfDuplicate)
    }

    suspend fun ensureAuthenticated(reclaimIfDuplicate: Boolean = false) = opMutex.withLock {
        ensureAuthenticatedLocked(reclaimIfDuplicate)
    }

    suspend fun keepAliveIfNeeded(intervalMs: Long = 55_000L) = opMutex.withLock {
        keepAliveIfNeededLocked(intervalMs)
    }

    suspend fun fetchStatus(
        reclaimIfDuplicate: Boolean = false,
        includeStationLists: Boolean = true
    ): RouterStatusSnapshot = opMutex.withLock {
        fetchStatusLocked(reclaimIfDuplicate, includeStationLists)
    }

    suspend fun reconnectInternet(
        pauseBetweenDisconnectAndConnectMs: Long = 300L
    ): WANConnectionState = opMutex.withLock {
        reconnectInternetLocked(pauseBetweenDisconnectAndConnectMs)
    }

    suspend fun setInternetConnected(
        connect: Boolean,
        waitUntilSettled: Boolean = true
    ): WANConnectionState = opMutex.withLock {
        setInternetConnectedLocked(connect, waitUntilSettled)
    }

    // MARK: - Serialized Protocol Implementation

    private suspend fun checkLoggedInLocked(): Boolean {
        val dict = getRawFieldsLocked(listOf("loginfo"), forceMultiData = true)
        return dict["loginfo"].orEmpty().lowercase(Locale.ROOT) == "ok"
    }

    private suspend fun ensureAuthenticatedLocked(reclaimIfDuplicate: Boolean) {
        if (checkLoggedInLocked()) return
        loginLocked(reclaimIfDuplicate)
    }

    private suspend fun loginLocked(reclaimIfDuplicate: Boolean) {
        if (password.isEmpty()) {
            throw ZteRouterException.MissingPassword
        }

        when (val result = performLoginPostLocked()) {
            "0", "4", "success" -> {
                lastKeepAliveAtMs = clockMs()
            }
            "2" -> {
                if (!reclaimIfDuplicate) {
                    throw ZteRouterException.DuplicateUser
                }
                runCatching { attemptLogoutLocked() }
                delayFn(250L)
                when (val retryResult = performLoginPostLocked()) {
                    "0", "4", "success" -> lastKeepAliveAtMs = clockMs()
                    "1" -> throw ZteRouterException.LoginRateLimited
                    "2" -> throw ZteRouterException.DuplicateUser
                    "3" -> throw ZteRouterException.WrongPassword
                    else -> throw ZteRouterException.LoginFailed(retryResult)
                }
            }
            "1" -> throw ZteRouterException.LoginRateLimited
            "3" -> throw ZteRouterException.WrongPassword
            else -> throw ZteRouterException.LoginFailed(result)
        }
    }

    private suspend fun performLoginPostLocked(): String {
        val meta = getRawFieldsLocked(listOf("wa_inner_version", "cr_version", "RD", "LD"))
        val wa = meta["wa_inner_version"].orEmpty()
        val cr = meta["cr_version"].orEmpty()
        val ld = meta["LD"].orEmpty()
        val rd = meta["RD"].orEmpty()

        if (wa.isNotEmpty()) {
            cachedWaInnerVersion = wa
            cachedCrVersion = cr
        }

        val algo = ResolvedHashAlgorithm.resolve(
            waInnerVersion = wa.ifEmpty { cachedWaInnerVersion },
            preference = config.hashPreference
        )
        val challengePassword = RouterCrypto.computeLoginPassword(plainPassword = password, ld = ld)

        val params = mutableListOf(
            "isTest" to "false",
            "goformId" to "LOGIN",
            "password" to challengePassword
        )
        if (rd.isNotEmpty()) {
            val ad = RouterCrypto.computeAD(
                waInnerVersion = wa.ifEmpty { cachedWaInnerVersion },
                crVersion = if (wa.isEmpty()) cachedCrVersion else cr,
                rd = rd,
                algorithm = algo
            )
            params.add("AD" to ad)
        }
        return postGoformRawLocked(params)
    }

    private suspend fun attemptLogoutLocked(): String {
        val ad = fetchFreshAdTokenLocked()
        return postGoformRawLocked(
            listOf(
                "isTest" to "false",
                "goformId" to "LOGOUT",
                "AD" to ad
            )
        )
    }

    private suspend fun keepAliveIfNeededLocked(intervalMs: Long = 55_000L) {
        val now = clockMs()
        val last = lastKeepAliveAtMs
        if (last != null && (now - last) < intervalMs) {
            return
        }
        val url = "${config.baseUrl}/tmpl/network/apn_setting.html?v=${now / 1000L}"
        val request = makeBaseRequest(
            url = url,
            method = "GET",
            extraHeaders = mapOf("Accept" to "text/html, */*; q=0.01")
        )
        runCatching { transport.send(request) }
        lastKeepAliveAtMs = now
    }

    private suspend fun fetchStatusLocked(
        reclaimIfDuplicate: Boolean,
        includeStationLists: Boolean
    ): RouterStatusSnapshot {
        if (!statusQueryReportsLogin) {
            ensureAuthenticatedLocked(reclaimIfDuplicate)
        }

        val fetchedAt = clockMs()
        var status = fetchStatusObjectLocked()
        var snapshot = RouterStatusParser.parse(listOf(status), fetchedAtMs = fetchedAt)

        if ((statusQueryReportsLogin && !reportsLoggedIn(status)) || snapshot.isUnauthenticatedEmptySnapshot) {
            loginLocked(reclaimIfDuplicate)
            status = fetchStatusObjectLocked()
            snapshot = RouterStatusParser.parse(listOf(status), fetchedAtMs = clockMs())
            if (snapshot.isUnauthenticatedEmptySnapshot) {
                throw ZteRouterException.SessionExpired
            }
            if (!reportsLoggedIn(status)) {
                statusQueryReportsLogin = false
            }
        }
        keepAliveIfNeededLocked()

        if (includeStationLists) {
            val objects = mutableListOf(status)
            for (cmd in listOf("station_list", "lan_station_list")) {
                val extra = runCatching {
                    val bytes = getRawDataLocked(listOf(cmd), forceMultiData = false)
                    JSONObject(bytes.toString(Charsets.UTF_8))
                }.getOrNull()
                if (extra != null) {
                    objects.add(extra)
                }
            }
            snapshot = RouterStatusParser.parse(objects, fetchedAtMs = snapshot.fetchedAtMs)
        }

        if (snapshot.versionInfo.waInnerVersion.isNotEmpty()) {
            cachedWaInnerVersion = snapshot.versionInfo.waInnerVersion
            cachedCrVersion = snapshot.versionInfo.crVersion
        }
        return snapshot
    }

    private suspend fun fetchStatusObjectLocked(): JSONObject {
        val bytes = getRawDataLocked(RouterStatusParser.statusCmds, forceMultiData = true)
        return try {
            JSONObject(bytes.toString(Charsets.UTF_8))
        } catch (_: Exception) {
            throw ZteRouterException.InvalidResponse("非 JSON 对象")
        }
    }

    private fun reportsLoggedIn(status: JSONObject): Boolean {
        return RouterStatusParser.cleanField(status, "loginfo").trim().lowercase(Locale.ROOT) == "ok"
    }

    private suspend fun reconnectInternetLocked(
        pauseBetweenDisconnectAndConnectMs: Long
    ): WANConnectionState {
        ensureAuthenticatedLocked(reclaimIfDuplicate = true)
        val currentDict = getRawFieldsLocked(listOf("ppp_status"), forceMultiData = true)
        val currentState = WANConnectionState.fromPppStatus(currentDict["ppp_status"].orEmpty())

        if (currentState is WANConnectionState.Disconnecting) {
            waitForWanStateLocked(targetConnected = false, timeoutMs = 12_000L)
            delayFn(pauseBetweenDisconnectAndConnectMs)
        } else if (!currentState.isDisconnected) {
            setInternetConnectedLocked(connect = false, waitUntilSettled = true)
            delayFn(pauseBetweenDisconnectAndConnectMs)
        }

        val connectedState = setInternetConnectedLocked(connect = true, waitUntilSettled = true)
        if (connectedState.isDisconnected) {
            delayFn(pauseBetweenDisconnectAndConnectMs)
            return setInternetConnectedLocked(connect = true, waitUntilSettled = true)
        }
        return connectedState
    }

    private suspend fun waitForWanStateLocked(
        targetConnected: Boolean,
        timeoutMs: Long
    ): WANConnectionState {
        val startMs = clockMs()
        var simulatedElapsedMs = 0L
        while ((clockMs() - startMs) < timeoutMs && simulatedElapsedMs < timeoutMs) {
            coroutineContext.ensureActive()
            val dict = getRawFieldsLocked(listOf("ppp_status"), forceMultiData = true)
            val state = WANConnectionState.fromPppStatus(dict["ppp_status"].orEmpty())
            if (targetConnected && state.isConnected) return state
            if (!targetConnected && state.isDisconnected) return state
            delayFn(300L)
            simulatedElapsedMs += 300L
        }
        val finalDict = getRawFieldsLocked(listOf("ppp_status"), forceMultiData = true)
        return WANConnectionState.fromPppStatus(finalDict["ppp_status"].orEmpty())
    }

    private suspend fun setInternetConnectedLocked(
        connect: Boolean,
        waitUntilSettled: Boolean
    ): WANConnectionState {
        ensureAuthenticatedLocked(reclaimIfDuplicate = true)
        val goformId = if (connect) "CONNECT_NETWORK" else "DISCONNECT_NETWORK"

        try {
            sendAuthenticatedSetCommandLocked(goformId, listOf("notCallback" to "true"))
        } catch (_: ZteRouterException.CommandFailed) {
            loginLocked(reclaimIfDuplicate = true)
            sendAuthenticatedSetCommandLocked(goformId, listOf("notCallback" to "true"))
        }

        if (!waitUntilSettled) {
            val dict = getRawFieldsLocked(listOf("ppp_status"), forceMultiData = true)
            return WANConnectionState.fromPppStatus(dict["ppp_status"].orEmpty())
        }

        val timeoutMs = if (connect) 18_000L else 10_000L
        val startMs = clockMs()
        var simulatedElapsedMs = 0L
        while ((clockMs() - startMs) < timeoutMs && simulatedElapsedMs < timeoutMs) {
            coroutineContext.ensureActive()
            delayFn(300L)
            simulatedElapsedMs += 300L
            val dict = getRawFieldsLocked(listOf("ppp_status"), forceMultiData = true)
            val state = WANConnectionState.fromPppStatus(dict["ppp_status"].orEmpty())
            if (connect && state.isConnected) return state
            if (!connect && state.isDisconnected) return state
        }
        val finalDict = getRawFieldsLocked(listOf("ppp_status"), forceMultiData = true)
        return WANConnectionState.fromPppStatus(finalDict["ppp_status"].orEmpty())
    }

    private suspend fun sendAuthenticatedSetCommandLocked(
        goformId: String,
        extraParams: List<Pair<String, String>>
    ) {
        val ad = fetchFreshAdTokenLocked()
        val params = ArrayList<Pair<String, String>>(extraParams.size + 3)
        params.add("isTest" to "false")
        params.add("goformId" to goformId)
        params.addAll(extraParams)
        params.add("AD" to ad)

        val result = postGoformRawLocked(params)
        if (result == "success" || result == "0") return
        throw ZteRouterException.CommandFailed(goformId = goformId, result = result)
    }

    private suspend fun fetchFreshAdTokenLocked(): String {
        val cmds = if (cachedWaInnerVersion.isEmpty()) {
            listOf("wa_inner_version", "cr_version", "RD")
        } else {
            listOf("RD")
        }
        val dict = getRawFieldsLocked(cmds)
        val wa = dict["wa_inner_version"].orEmpty()
        if (wa.isNotEmpty()) {
            cachedWaInnerVersion = wa
            cachedCrVersion = dict["cr_version"].orEmpty()
        }
        val rd = dict["RD"].orEmpty()
        val algo = ResolvedHashAlgorithm.resolve(
            waInnerVersion = cachedWaInnerVersion,
            preference = config.hashPreference
        )
        return RouterCrypto.computeAD(
            waInnerVersion = cachedWaInnerVersion,
            crVersion = cachedCrVersion,
            rd = rd,
            algorithm = algo
        )
    }

    private suspend fun getRawFieldsLocked(
        cmds: List<String>,
        forceMultiData: Boolean = false
    ): Map<String, String> {
        val bytes = getRawDataLocked(cmds, forceMultiData)
        val obj = try {
            JSONObject(bytes.toString(Charsets.UTF_8))
        } catch (_: Exception) {
            throw ZteRouterException.InvalidResponse("非 JSON 对象")
        }
        val result = LinkedHashMap<String, String>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            if (!obj.has(k) || obj.isNull(k)) continue
            val v = obj.opt(k)
            if (v is String || v is Number || v is Boolean) {
                result[k] = RouterStatusParser.cleanField(obj, k)
            }
        }
        return result
    }

    private suspend fun getRawDataLocked(
        cmds: List<String>,
        forceMultiData: Boolean = false
    ): ByteArray {
        val joinedCmds = cmds.joinToString(",") { formEncode(it) }
        val multiPart = if (forceMultiData || cmds.size > 1) "&multi_data=1" else ""
        val url = "${config.baseUrl}/goform/goform_get_cmd_process?isTest=false&cmd=$joinedCmds$multiPart&_=${clockMs()}"
        val request = makeBaseRequest(
            url = url,
            method = "GET",
            extraHeaders = mapOf("Accept" to "application/json, text/javascript, */*; q=0.01")
        )
        return executeLocked(request)
    }

    private suspend fun postGoformRawLocked(params: List<Pair<String, String>>): String {
        val url = "${config.baseUrl}/goform/goform_set_cmd_process"
        val encodedBody = params.joinToString("&") { (key, value) ->
            "${formEncode(key)}=${formEncode(value)}"
        }
        val request = makeBaseRequest(
            url = url,
            method = "POST",
            extraHeaders = mapOf(
                "Content-Type" to "application/x-www-form-urlencoded; charset=UTF-8",
                "Accept" to "application/json, text/javascript, */*; q=0.01"
            ),
            body = encodedBody.toByteArray(Charsets.UTF_8)
        )
        val bytes = executeLocked(request)
        val text = bytes.toString(Charsets.UTF_8)
        val obj = try {
            JSONObject(text)
        } catch (_: Exception) {
            throw ZteRouterException.InvalidResponse(text)
        }
        if (!obj.has("result") || obj.isNull("result")) {
            throw ZteRouterException.InvalidResponse(text)
        }
        return RouterStatusParser.cleanField(obj, "result")
    }

    private suspend fun executeLocked(request: RouterHttpRequest): ByteArray {
        val response = try {
            transport.send(request)
        } catch (ce: CancellationException) {
            throw ce
        } catch (err: Exception) {
            throw ZteRouterException.TransportError(err.message ?: err.javaClass.simpleName)
        }
        if (response.statusCode !in 200..299) {
            throw ZteRouterException.HttpError(response.statusCode)
        }
        return response.body
    }

    private fun makeBaseRequest(
        url: String,
        method: String,
        extraHeaders: Map<String, String> = emptyMap(),
        body: ByteArray? = null
    ): RouterHttpRequest {
        val headers = LinkedHashMap<String, String>(extraHeaders.size + 3)
        headers["Referer"] = "${config.baseUrl}/index.html"
        headers["Origin"] = config.baseUrl
        headers["X-Requested-With"] = "XMLHttpRequest"
        headers.putAll(extraHeaders)
        return RouterHttpRequest(url = url, method = method, headers = headers, body = body)
    }

    private fun formEncode(value: String): String {
        return URLEncoder.encode(value, Charsets.UTF_8.name())
    }
}

package com.zte.routerbar.data

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import java.net.Inet4Address
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class WifiLanState(
    val isWifiConnected: Boolean = false,
    val gatewayIpv4: String? = null,
    val networkHandle: Long? = null
)

interface WifiLanMonitor {
    val state: StateFlow<WifiLanState>
    fun currentWifiNetwork(): Network?
    fun refresh()
    fun close()
}

class AndroidWifiLanMonitor(context: Context) : WifiLanMonitor {
    private val connectivityManager: ConnectivityManager? =
        context.applicationContext.getSystemService(ConnectivityManager::class.java)

    private val lock = Any()
    private val trackedNetworks = LinkedHashMap<Network, LinkProperties?>()

    @Volatile
    private var primaryWifiNetwork: Network? = null

    private val _state = MutableStateFlow(WifiLanState())
    override val state: StateFlow<WifiLanState> = _state.asStateFlow()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            val lp = runCatching { connectivityManager?.getLinkProperties(network) }.getOrNull()
            synchronized(lock) {
                trackedNetworks[network] = lp
                syncLocked()
            }
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            synchronized(lock) {
                trackedNetworks[network] = linkProperties
                syncLocked()
            }
        }

        override fun onLost(network: Network) {
            synchronized(lock) {
                trackedNetworks.remove(network)
                syncLocked()
            }
        }

        override fun onUnavailable() {
            synchronized(lock) {
                if (trackedNetworks.isEmpty()) {
                    syncLocked()
                }
            }
        }
    }

    private var registered = false

    init {
        val cm = connectivityManager
        if (cm != null) {
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            runCatching {
                cm.registerNetworkCallback(request, callback)
                registered = true
            }
            refresh()
        }
    }

    override fun currentWifiNetwork(): Network? = primaryWifiNetwork

    override fun refresh() {
        val cm = connectivityManager ?: return
        synchronized(lock) {
            val refreshed = LinkedHashMap<Network, LinkProperties?>()
            for ((net, _) in trackedNetworks) {
                val caps = runCatching { cm.getNetworkCapabilities(net) }.getOrNull()
                if (caps != null &&
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                ) {
                    refreshed[net] = runCatching { cm.getLinkProperties(net) }.getOrNull()
                }
            }
            if (refreshed.isEmpty()) {
                val active = runCatching { cm.activeNetwork }.getOrNull()
                val caps = active?.let { runCatching { cm.getNetworkCapabilities(it) }.getOrNull() }
                if (active != null &&
                    caps != null &&
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                ) {
                    refreshed[active] = runCatching { cm.getLinkProperties(active) }.getOrNull()
                }
            }
            trackedNetworks.clear()
            trackedNetworks.putAll(refreshed)
            syncLocked()
        }
    }

    override fun close() {
        if (registered) {
            registered = false
            runCatching { connectivityManager?.unregisterNetworkCallback(callback) }
        }
    }

    private fun syncLocked() {
        val entry = trackedNetworks.entries.lastOrNull()
        if (entry == null) {
            primaryWifiNetwork = null
            _state.value = WifiLanState(isWifiConnected = false, gatewayIpv4 = null, networkHandle = null)
            return
        }
        val net = entry.key
        val lp = entry.value ?: runCatching { connectivityManager?.getLinkProperties(net) }.getOrNull()
        primaryWifiNetwork = net
        _state.value = WifiLanState(
            isWifiConnected = true,
            gatewayIpv4 = extractIpv4Gateway(lp),
            networkHandle = net.networkHandle
        )
    }

    companion object {
        fun extractIpv4Gateway(linkProperties: LinkProperties?): String? {
            val routes = linkProperties?.routes ?: return null
            val defaultGateway = routes.firstOrNull { route ->
                val gw = route.gateway
                route.isDefaultRoute && gw is Inet4Address && !gw.isAnyLocalAddress && !gw.isLoopbackAddress
            }?.gateway?.hostAddress
            if (!defaultGateway.isNullOrBlank()) {
                return defaultGateway
            }
            return routes.firstOrNull { route ->
                val gw = route.gateway
                gw is Inet4Address && !gw.isAnyLocalAddress && !gw.isLoopbackAddress
            }?.gateway?.hostAddress
        }
    }
}

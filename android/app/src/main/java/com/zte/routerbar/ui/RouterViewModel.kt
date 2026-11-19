package com.zte.routerbar.ui

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.zte.routerbar.core.AuthHashPreference
import com.zte.routerbar.core.HttpUrlConnectionTransport
import com.zte.routerbar.core.RouterEndpointConfig
import com.zte.routerbar.core.RouterProfile
import com.zte.routerbar.core.RouterProfileMatcher
import com.zte.routerbar.core.RouterStatusSnapshot
import com.zte.routerbar.core.SignalEvaluator
import com.zte.routerbar.core.SignalRatingAssessment
import com.zte.routerbar.core.SignalSample
import com.zte.routerbar.core.WANConnectionState
import com.zte.routerbar.core.WANIPChangeFormatter
import com.zte.routerbar.core.WANIPSnapshot
import com.zte.routerbar.core.ZteRouterClient
import com.zte.routerbar.core.ZteRouterException
import com.zte.routerbar.data.AndroidCredentialStore
import com.zte.routerbar.data.AndroidProfileStore
import com.zte.routerbar.data.AndroidWifiLanMonitor
import com.zte.routerbar.data.CredentialRepository
import com.zte.routerbar.data.ProfileRepository
import com.zte.routerbar.data.StoredAppSettings
import com.zte.routerbar.data.WifiLanMonitor
import com.zte.routerbar.data.WifiLanState
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

data class ReconnectIpBanner(
    val title: String,
    val detail: String,
    val changed: Boolean
)

data class RouterUiState(
    val profiles: List<RouterProfile> = emptyList(),
    val activeProfileId: String = "",
    val autoMatchByGateway: Boolean = true,
    val pollingIntervalSec: Int = 3,
    val isWifiConnected: Boolean = false,
    val wifiGatewayIp: String? = null,
    val hasStoredPassword: Boolean = false,
    val snapshot: RouterStatusSnapshot? = null,
    val signalAssessment: SignalRatingAssessment? = null,
    val signalHistory: List<SignalSample> = emptyList(),
    val selectedChartMetric: SignalChartMetric = SignalChartMetric.RSRP,
    val isRefreshing: Boolean = false,
    val isReconnectingWan: Boolean = false,
    val isSavingProfile: Boolean = false,
    val isSessionOccupied: Boolean = false,
    val lastError: String? = null,
    val statusToast: String? = null,
    val reconnectIpBanner: ReconnectIpBanner? = null,
    val isProfileSheetOpen: Boolean = false,
    val showDiscardDialog: Boolean = false,
    val editingProfileId: String = "",
    val draftName: String = "",
    val draftInitialName: String = "",
    val draftUrl: String = "",
    val draftInitialUrl: String = "",
    val draftPassword: String = "",
    val draftInitialPassword: String = "",
    val draftHasStoredPassword: Boolean = false,
    val draftHashPreference: AuthHashPreference = AuthHashPreference.AUTO,
    val draftInitialHashPreference: AuthHashPreference = AuthHashPreference.AUTO
) {
    val activeProfile: RouterProfile
        get() = profiles.firstOrNull { it.id == activeProfileId }
            ?: RouterProfile(name = "默认路由器", routerUrlString = "http://192.168.8.1")

    val matchedProfileForGateway: RouterProfile?
        get() = RouterProfileMatcher.matchByGateway(wifiGatewayIp, profiles, activeProfileId)

    val isEditingUnsavedNewProfile: Boolean
        get() = editingProfileId.isNotEmpty() && profiles.none { it.id == editingProfileId }

    val hasUnsavedDraftChanges: Boolean
        get() = draftName != draftInitialName ||
            draftUrl != draftInitialUrl ||
            draftHashPreference != draftInitialHashPreference ||
            draftPassword != draftInitialPassword
}

class RouterViewModel(
    private val profileRepo: ProfileRepository,
    private val credentialRepo: CredentialRepository,
    private val wifiMonitor: WifiLanMonitor,
    private val clientFactory: (RouterEndpointConfig, String) -> ZteRouterClient = { cfg, pw ->
        ZteRouterClient(
            config = cfg,
            password = pw,
            transport = HttpUrlConnectionTransport(networkProvider = wifiMonitor::currentWifiNetwork)
        )
    },
    private val clockMs: () -> Long = { System.currentTimeMillis() },
    private val delayFn: suspend (Long) -> Unit = { delay(it) },
    private val externalScope: CoroutineScope? = null
) : ViewModel() {

    private val scope: CoroutineScope
        get() = externalScope ?: viewModelScope

    private val _uiState = MutableStateFlow(RouterUiState())
    val uiState: StateFlow<RouterUiState> = _uiState.asStateFlow()

    private var activeClient: ZteRouterClient? = null
    private var activePassword: String = ""
    private var clientGeneration: Int = 0
    private var pollingJob: Job? = null
    private var toastClearJob: Job? = null
    private var isForegroundActive: Boolean = false
    private var needsInitialSessionReclaim: Boolean = true
    private var lastStationFetchAtMs: Long? = null
    private var lastObservedGateway: String? = null
    private var lastObservedNetworkHandle: Long? = null
    private var pendingAfterDiscard: (() -> Unit)? = null

    init {
        val loaded = profileRepo.load()
        val active = loaded.activeProfile
        val initialPassword = credentialRepo.readPassword(active.id).orEmpty()
        activePassword = initialPassword

        _uiState.value = RouterUiState(
            profiles = loaded.profiles,
            activeProfileId = active.id,
            autoMatchByGateway = loaded.autoMatchByGateway,
            pollingIntervalSec = loaded.pollingIntervalSec,
            hasStoredPassword = initialPassword.isNotEmpty(),
            editingProfileId = active.id,
            draftName = active.name,
            draftInitialName = active.name,
            draftUrl = active.routerUrlString,
            draftInitialUrl = active.routerUrlString,
            draftPassword = initialPassword,
            draftInitialPassword = initialPassword,
            draftHasStoredPassword = initialPassword.isNotEmpty(),
            draftHashPreference = active.hashPreference,
            draftInitialHashPreference = active.hashPreference
        )
        rebuildClient()

        scope.launch {
            wifiMonitor.state.collect { wifi ->
                handleWifiStateChanged(wifi)
            }
        }
    }

    fun setForegroundActive(active: Boolean) {
        if (isForegroundActive == active) return
        isForegroundActive = active
        if (active) {
            wifiMonitor.refresh()
            startPollingLoop()
        } else {
            stopPollingLoop()
        }
    }

    fun selectChartMetric(metric: SignalChartMetric) {
        _uiState.update { it.copy(selectedChartMetric = metric) }
    }

    fun dismissReconnectBanner() {
        _uiState.update { it.copy(reconnectIpBanner = null) }
    }

    fun setPollingIntervalSec(seconds: Int) {
        val normalized = StoredAppSettings.normalizePollingSec(seconds)
        _uiState.update { it.copy(pollingIntervalSec = normalized) }
        persistSettings()
        if (isForegroundActive) {
            startPollingLoop()
        }
    }

    fun setAutoMatchByGateway(enabled: Boolean) {
        _uiState.update { it.copy(autoMatchByGateway = enabled) }
        persistSettings()
        if (enabled) {
            applyGatewayAutoMatchIfNeeded(_uiState.value.wifiGatewayIp)
        }
    }

    fun selectProfile(profileId: String, announce: String? = null) {
        val state = _uiState.value
        val target = state.profiles.firstOrNull { it.id == profileId } ?: return
        val password = credentialRepo.readPassword(target.id).orEmpty()
        activePassword = password
        needsInitialSessionReclaim = true
        lastStationFetchAtMs = null

        _uiState.update {
            it.copy(
                activeProfileId = target.id,
                hasStoredPassword = password.isNotEmpty(),
                snapshot = null,
                signalAssessment = null,
                signalHistory = emptyList(),
                isSessionOccupied = false,
                lastError = null,
                reconnectIpBanner = null
            )
        }
        persistSettings()
        rebuildClient()
        if (announce != null) {
            showToast(announce)
        }
        if (isForegroundActive) {
            startPollingLoop()
        }
    }

    // MARK: - Profile Sheet & Draft Lifecycle

    fun openProfileSheet() {
        pendingAfterDiscard = null
        val active = _uiState.value.activeProfile
        loadProfileIntoDraft(active)
        _uiState.update { it.copy(isProfileSheetOpen = true, showDiscardDialog = false) }
    }

    fun requestCloseProfileSheet() {
        val state = _uiState.value
        if (state.isSavingProfile) return
        if (state.hasUnsavedDraftChanges) {
            pendingAfterDiscard = {
                val active = _uiState.value.activeProfile
                loadProfileIntoDraft(active)
                _uiState.update { it.copy(isProfileSheetOpen = false, showDiscardDialog = false) }
            }
            _uiState.update { it.copy(showDiscardDialog = true) }
        } else {
            val active = _uiState.value.activeProfile
            loadProfileIntoDraft(active)
            _uiState.update { it.copy(isProfileSheetOpen = false, showDiscardDialog = false) }
        }
    }

    fun dismissDiscardDialog() {
        pendingAfterDiscard = null
        _uiState.update { it.copy(showDiscardDialog = false) }
    }

    fun confirmDiscardProfileChanges() {
        val action = pendingAfterDiscard
        pendingAfterDiscard = null
        if (action != null) {
            action()
        } else {
            val active = _uiState.value.activeProfile
            loadProfileIntoDraft(active)
            _uiState.update { it.copy(isProfileSheetOpen = false, showDiscardDialog = false) }
        }
    }

    fun selectProfileForEditing(profileId: String) {
        val state = _uiState.value
        if (state.isSavingProfile || state.editingProfileId == profileId) return
        val profile = state.profiles.firstOrNull { it.id == profileId } ?: return
        if (state.hasUnsavedDraftChanges) {
            pendingAfterDiscard = {
                loadProfileIntoDraft(profile)
                _uiState.update { it.copy(showDiscardDialog = false, lastError = null) }
            }
            _uiState.update { it.copy(showDiscardDialog = true) }
        } else {
            loadProfileIntoDraft(profile)
        }
    }

    fun selectProfileFromSheet(profileId: String) {
        val state = _uiState.value
        if (state.isSavingProfile) return
        val target = state.profiles.firstOrNull { it.id == profileId } ?: return
        if (state.hasUnsavedDraftChanges) {
            pendingAfterDiscard = {
                selectProfile(target.id)
                loadProfileIntoDraft(target)
                _uiState.update { it.copy(showDiscardDialog = false) }
            }
            _uiState.update { it.copy(showDiscardDialog = true) }
        } else {
            selectProfile(target.id)
            loadProfileIntoDraft(target)
        }
    }

    fun addNewProfileDraft() {
        val current = _uiState.value
        if (current.isSavingProfile) return
        if (current.hasUnsavedDraftChanges) {
            pendingAfterDiscard = {
                stageUnsavedNewProfileDraft()
            }
            _uiState.update { it.copy(showDiscardDialog = true) }
            return
        }
        stageUnsavedNewProfileDraft()
    }

    private fun stageUnsavedNewProfileDraft() {
        val current = _uiState.value
        val index = current.profiles.size + 1
        val suggestedGateway = current.wifiGatewayIp?.takeIf { it.isNotBlank() } ?: "192.168.8.1"
        val suggestedName = "路由器配置 $index"
        val suggestedUrl = "http://$suggestedGateway"
        val draftId = UUID.randomUUID().toString()
        _uiState.update {
            it.copy(
                editingProfileId = draftId,
                draftName = suggestedName,
                draftInitialName = suggestedName,
                draftUrl = suggestedUrl,
                draftInitialUrl = suggestedUrl,
                draftPassword = "",
                draftInitialPassword = "",
                draftHasStoredPassword = false,
                draftHashPreference = AuthHashPreference.AUTO,
                draftInitialHashPreference = AuthHashPreference.AUTO,
                showDiscardDialog = false,
                lastError = null
            )
        }
    }

    fun deleteProfile(profileId: String) {
        val current = _uiState.value
        if (current.profiles.size <= 1) return
        val remaining = current.profiles.filterNot { it.id == profileId }
        if (remaining.isEmpty()) return
        credentialRepo.deletePassword(profileId)

        val nextActive = if (current.activeProfileId == profileId) remaining.first() else current.activeProfile
        val keepStagedNew = current.isEditingUnsavedNewProfile && current.editingProfileId != profileId
        if (keepStagedNew) {
            _uiState.update { it.copy(profiles = remaining) }
        } else {
            val nextEditing = if (current.editingProfileId == profileId) nextActive else {
                remaining.firstOrNull { it.id == current.editingProfileId } ?: nextActive
            }
            val editPw = credentialRepo.readPassword(nextEditing.id).orEmpty()
            _uiState.update {
                it.copy(
                    profiles = remaining,
                    editingProfileId = nextEditing.id,
                    draftName = nextEditing.name,
                    draftInitialName = nextEditing.name,
                    draftUrl = nextEditing.routerUrlString,
                    draftInitialUrl = nextEditing.routerUrlString,
                    draftPassword = editPw,
                    draftInitialPassword = editPw,
                    draftHasStoredPassword = editPw.isNotEmpty(),
                    draftHashPreference = nextEditing.hashPreference,
                    draftInitialHashPreference = nextEditing.hashPreference
                )
            }
        }
        if (current.activeProfileId == profileId) {
            selectProfile(nextActive.id)
        } else {
            persistSettings()
        }
    }

    fun updateDraftName(value: String) {
        _uiState.update { it.copy(draftName = value) }
    }

    fun updateDraftUrl(value: String) {
        _uiState.update { it.copy(draftUrl = value, lastError = null) }
    }

    fun updateDraftPassword(value: String) {
        _uiState.update { it.copy(draftPassword = value, lastError = null) }
    }

    fun updateDraftHashPreference(pref: AuthHashPreference) {
        _uiState.update { it.copy(draftHashPreference = pref, lastError = null) }
    }

    fun fillCurrentGatewayIntoDraft() {
        val gw = _uiState.value.wifiGatewayIp?.trim().orEmpty()
        if (gw.isNotEmpty()) {
            _uiState.update { it.copy(draftUrl = "http://$gw", lastError = null) }
        }
    }

    fun clearDraftProfilePassword() {
        val targetId = _uiState.value.editingProfileId
        if (targetId.isEmpty()) return
        credentialRepo.deletePassword(targetId)
        _uiState.update {
            it.copy(
                draftPassword = "",
                draftInitialPassword = "",
                draftHasStoredPassword = false
            )
        }
        if (targetId == _uiState.value.activeProfileId) {
            activePassword = ""
            _uiState.update {
                it.copy(
                    hasStoredPassword = false,
                    snapshot = null,
                    signalAssessment = null,
                    isSessionOccupied = false
                )
            }
            rebuildClient()
        }
        showToast("已清除该配置的管理密码")
    }

    fun saveQuickSetup(name: String, urlString: String, password: String) {
        if (_uiState.value.isSavingProfile) return
        val active = _uiState.value.activeProfile
        val updated = active.copy(
            name = name.trim().ifEmpty { active.name },
            routerUrlString = urlString.trim().ifEmpty { "http://192.168.8.1" }
        )
        scope.launch {
            saveAndActivateProfileInternal(updated, password, closeSheetOnSuccess = false)
        }
    }

    fun saveDraftAndActivate() {
        val state = _uiState.value
        if (state.isSavingProfile) return
        val targetId = state.editingProfileId.ifEmpty { state.activeProfileId }
        val updated = RouterProfile(
            id = targetId,
            name = state.draftName.trim().ifEmpty { "路由器配置" },
            routerUrlString = state.draftUrl.trim().ifEmpty { "http://192.168.8.1" },
            hashPreference = state.draftHashPreference
        )
        scope.launch {
            saveAndActivateProfileInternal(updated, state.draftPassword, closeSheetOnSuccess = true)
        }
    }

    private suspend fun saveAndActivateProfileInternal(
        profile: RouterProfile,
        rawPassword: String,
        closeSheetOnSuccess: Boolean
    ) {
        try {
            RouterEndpointConfig.parse(profile.routerUrlString, profile.hashPreference)
        } catch (invalid: ZteRouterException.InvalidBaseUrl) {
            _uiState.update { it.copy(lastError = invalid.message) }
            return
        }

        _uiState.update { it.copy(isSavingProfile = true, lastError = null) }
        try {
            val trimmedPass = rawPassword.trim()
            if (trimmedPass.isNotEmpty()) {
                runCatching { credentialRepo.writePassword(profile.id, trimmedPass) }
                    .onFailure { err ->
                        _uiState.update { it.copy(lastError = "密码加密保存失败：${err.message ?: "KeyStore 异常"}") }
                        return
                    }
            }
            val effectivePassword = if (trimmedPass.isNotEmpty()) {
                trimmedPass
            } else {
                credentialRepo.readPassword(profile.id).orEmpty()
            }
            activePassword = effectivePassword
            needsInitialSessionReclaim = true
            lastStationFetchAtMs = null

            _uiState.update { current ->
                val list = if (current.profiles.any { it.id == profile.id }) {
                    current.profiles.map { if (it.id == profile.id) profile else it }
                } else {
                    current.profiles + profile
                }
                current.copy(
                    profiles = list,
                    activeProfileId = profile.id,
                    hasStoredPassword = effectivePassword.isNotEmpty(),
                    snapshot = null,
                    signalAssessment = null,
                    signalHistory = emptyList(),
                    isSessionOccupied = false,
                    editingProfileId = profile.id,
                    draftName = profile.name,
                    draftInitialName = profile.name,
                    draftUrl = profile.routerUrlString,
                    draftInitialUrl = profile.routerUrlString,
                    draftPassword = effectivePassword,
                    draftInitialPassword = effectivePassword,
                    draftHasStoredPassword = effectivePassword.isNotEmpty(),
                    draftHashPreference = profile.hashPreference,
                    draftInitialHashPreference = profile.hashPreference
                )
            }
            persistSettings()
            rebuildClient()

            if (effectivePassword.isNotEmpty()) {
                refreshNow(silent = false)
                if (_uiState.value.lastError == null) {
                    showToast("已保存并连接「${profile.name}」")
                    if (closeSheetOnSuccess) {
                        _uiState.update { it.copy(isProfileSheetOpen = false, showDiscardDialog = false) }
                    }
                }
            } else if (closeSheetOnSuccess) {
                _uiState.update { it.copy(isProfileSheetOpen = false, showDiscardDialog = false) }
            }
        } finally {
            _uiState.update { it.copy(isSavingProfile = false) }
            if (isForegroundActive && pollingJob == null) {
                startPollingLoop(delayFirstPoll = true)
            }
        }
    }

    // MARK: - Refresh & One-Click WAN Reconnect

    suspend fun refreshNow(silent: Boolean = false) {
        val entryGen = clientGeneration
        if (_uiState.value.isRefreshing) {
            if (silent) return
            for (i in 0 until 20) {
                if (!_uiState.value.isRefreshing || clientGeneration != entryGen) break
                delayFn(100L)
            }
            if (_uiState.value.isRefreshing) return
        }
        val gen = clientGeneration
        val client = activeClient
        if (client == null) {
            if (!silent) {
                _uiState.update { it.copy(lastError = "当前配置的路由器地址无效。") }
            }
            return
        }
        if (activePassword.isEmpty()) {
            if (!silent) {
                _uiState.update { it.copy(lastError = ZteRouterException.MissingPassword.message) }
            }
            return
        }

        _uiState.update { it.copy(isRefreshing = true) }
        try {
            val previous = _uiState.value.snapshot
            val now = clockMs()
            val stationsStale = lastStationFetchAtMs?.let { (now - it) >= LayoutSpec.STATION_FETCH_INTERVAL_MS } ?: true
            val needStations = previous == null || stationsStale
            val allowReclaim = if (silent) needsInitialSessionReclaim else true

            var fresh = client.fetchStatus(
                reclaimIfDuplicate = allowReclaim,
                includeStationLists = needStations
            )
            if (clientGeneration != gen) return
            needsInitialSessionReclaim = false

            if (needStations) {
                lastStationFetchAtMs = now
            } else if (previous != null) {
                fresh = fresh.copy(
                    wifiStations = previous.wifiStations,
                    lanStations = previous.lanStations
                )
            }

            val assessment = SignalEvaluator.assess(fresh)
            val nextHistory = appendSignalSample(_uiState.value.signalHistory, fresh)
            _uiState.update {
                it.copy(
                    snapshot = fresh,
                    signalAssessment = assessment,
                    signalHistory = nextHistory,
                    isSessionOccupied = false,
                    lastError = null
                )
            }
        } catch (ce: CancellationException) {
            throw ce
        } catch (routerErr: ZteRouterException) {
            if (clientGeneration != gen) return
            if (routerErr !is ZteRouterException.TransportError) {
                needsInitialSessionReclaim = false
            }
            when (routerErr) {
                is ZteRouterException.DuplicateUser -> {
                    _uiState.update { it.copy(isSessionOccupied = true, lastError = routerErr.message) }
                }
                is ZteRouterException.WrongPassword,
                is ZteRouterException.LoginRateLimited,
                is ZteRouterException.SessionExpired -> {
                    _uiState.update { it.copy(isSessionOccupied = false, lastError = routerErr.message) }
                }
                else -> {
                    if (!silent || _uiState.value.snapshot == null) {
                        _uiState.update { it.copy(lastError = routerErr.message) }
                    }
                }
            }
        } catch (err: Exception) {
            if (clientGeneration != gen) return
            if (!silent || _uiState.value.snapshot == null) {
                _uiState.update { it.copy(lastError = err.message ?: "状态刷新异常") }
            }
        } finally {
            if (clientGeneration == gen) {
                _uiState.update { it.copy(isRefreshing = false) }
            }
        }
    }

    fun triggerManualRefresh() {
        scope.launch { refreshNow(silent = false) }
    }

    fun triggerReconnectWan() {
        scope.launch { reconnectWanNow() }
    }

    suspend fun reconnectWanNow() {
        if (_uiState.value.isReconnectingWan) return
        val client = activeClient
        if (client == null || activePassword.isEmpty()) {
            _uiState.update { it.copy(lastError = "请先配置路由器地址与管理密码。") }
            return
        }

        _uiState.update {
            it.copy(
                isReconnectingWan = true,
                lastError = null,
                reconnectIpBanner = null
            )
        }

        try {
            var beforeIp = WANIPSnapshot.fromSnapshot(_uiState.value.snapshot)
            if (beforeIp.isEmpty) {
                waitForIdleAndRefresh(silent = true)
                beforeIp = WANIPSnapshot.fromSnapshot(_uiState.value.snapshot)
            }

            val newState: WANConnectionState = client.reconnectInternet()
            _uiState.update { it.copy(isSessionOccupied = false) }

            waitForIdleAndRefresh(silent = true)
            var afterIp = WANIPSnapshot.fromSnapshot(_uiState.value.snapshot)

            if (newState.isConnected && (afterIp.isEmpty || (!beforeIp.isEmpty && !afterIp.hasChanged(beforeIp)))) {
                delayFn(1_200L)
                waitForIdleAndRefresh(silent = true)
                afterIp = WANIPSnapshot.fromSnapshot(_uiState.value.snapshot)
            }

            val (title, detail) = WANIPChangeFormatter.formatBannerSummary(
                state = newState,
                before = beforeIp,
                after = afterIp
            )
            _uiState.update {
                it.copy(
                    reconnectIpBanner = ReconnectIpBanner(
                        title = title,
                        detail = detail,
                        changed = afterIp.hasChanged(beforeIp)
                    )
                )
            }
            if (newState.isConnected) {
                val ipSuffix = if (afterIp.hasChanged(beforeIp)) "（外网 IP 已更新）" else ""
                showToast("外网重连成功$ipSuffix")
            } else {
                showToast("已触发重连，状态：${newState.localizedLabel}")
            }
        } catch (ce: CancellationException) {
            throw ce
        } catch (routerErr: ZteRouterException) {
            if (routerErr is ZteRouterException.DuplicateUser) {
                _uiState.update { it.copy(isSessionOccupied = true) }
            }
            _uiState.update { it.copy(lastError = routerErr.message) }
        } catch (err: Exception) {
            _uiState.update { it.copy(lastError = err.message ?: "重连外网失败") }
        } finally {
            _uiState.update { it.copy(isReconnectingWan = false) }
        }
    }

    override fun onCleared() {
        stopPollingLoop()
        wifiMonitor.close()
        super.onCleared()
    }

    // MARK: - Internal Helpers

    private fun startPollingLoop(delayFirstPoll: Boolean = false) {
        pollingJob?.cancel()
        pollingJob = scope.launch {
            if (delayFirstPoll) {
                val initialState = _uiState.value
                val baseMs = initialState.pollingIntervalSec * 1_000L
                delayFn(if (initialState.isSessionOccupied) maxOf(15_000L, baseMs * 4L) else baseMs)
            }
            while (isActive && isForegroundActive) {
                if (activePassword.isNotEmpty()) {
                    refreshNow(silent = true)
                }
                val state = _uiState.value
                val baseMs = state.pollingIntervalSec * 1_000L
                val sleepMs = if (state.isSessionOccupied) maxOf(15_000L, baseMs * 4L) else baseMs
                delayFn(sleepMs)
            }
        }
    }

    private fun stopPollingLoop() {
        pollingJob?.cancel()
        pollingJob = null
    }

    private fun handleWifiStateChanged(wifi: WifiLanState) {
        val connected = wifi.isWifiConnected
        val normalizedGw = wifi.gatewayIpv4?.trim()?.takeIf { it.isNotEmpty() }
        val gatewayChanged = normalizedGw != null && normalizedGw != lastObservedGateway
        val networkChanged = wifi.networkHandle != null && wifi.networkHandle != lastObservedNetworkHandle
        lastObservedGateway = normalizedGw
        lastObservedNetworkHandle = wifi.networkHandle

        _uiState.update {
            it.copy(
                isWifiConnected = connected,
                wifiGatewayIp = normalizedGw
            )
        }

        if (connected) {
            val switched = if (normalizedGw != null) applyGatewayAutoMatchIfNeeded(normalizedGw) else false
            if (!switched && activePassword.isNotEmpty()) {
                if (gatewayChanged) {
                    needsInitialSessionReclaim = true
                }
                if (networkChanged && _uiState.value.isRefreshing && _uiState.value.snapshot == null) {
                    // Abort an initial unbound (cellular/VPN) or stale-network socket stall immediately.
                    rebuildClient()
                    if (isForegroundActive) {
                        startPollingLoop()
                    }
                } else if (gatewayChanged && isForegroundActive) {
                    startPollingLoop()
                }
            }
        }
    }

    private fun applyGatewayAutoMatchIfNeeded(gatewayIp: String?): Boolean {
        val state = _uiState.value
        if (!state.autoMatchByGateway || gatewayIp.isNullOrBlank()) return false
        val matched = RouterProfileMatcher.matchByGateway(gatewayIp, state.profiles, state.activeProfileId)
            ?: return false
        if (matched.id == state.activeProfileId) return false
        selectProfile(matched.id, announce = "已按网关 $gatewayIp 自动切换至「${matched.name}」")
        return true
    }

    private fun loadProfileIntoDraft(profile: RouterProfile) {
        val pw = credentialRepo.readPassword(profile.id).orEmpty()
        _uiState.update {
            it.copy(
                editingProfileId = profile.id,
                draftName = profile.name,
                draftInitialName = profile.name,
                draftUrl = profile.routerUrlString,
                draftInitialUrl = profile.routerUrlString,
                draftPassword = pw,
                draftInitialPassword = pw,
                draftHasStoredPassword = pw.isNotEmpty(),
                draftHashPreference = profile.hashPreference,
                draftInitialHashPreference = profile.hashPreference
            )
        }
    }

    private fun rebuildClient() {
        stopPollingLoop()
        clientGeneration += 1
        lastStationFetchAtMs = null
        _uiState.update { it.copy(isRefreshing = false) }
        val profile = _uiState.value.activeProfile
        try {
            val config = RouterEndpointConfig.parse(profile.routerUrlString, profile.hashPreference)
            activeClient = clientFactory(config, activePassword)
        } catch (err: ZteRouterException.InvalidBaseUrl) {
            activeClient = null
            _uiState.update { it.copy(lastError = err.message) }
        }
    }

    private fun persistSettings() {
        val state = _uiState.value
        if (state.profiles.isEmpty()) return
        profileRepo.save(
            StoredAppSettings(
                profiles = state.profiles,
                activeProfileId = state.activeProfileId,
                autoMatchByGateway = state.autoMatchByGateway,
                pollingIntervalSec = state.pollingIntervalSec
            )
        )
    }

    private fun appendSignalSample(
        existing: List<SignalSample>,
        fresh: RouterStatusSnapshot
    ): List<SignalSample> {
        val sample = SignalEvaluator.sample(fresh) ?: return existing
        val updated = if (existing.lastOrNull()?.timestampMs == sample.timestampMs) {
            existing.dropLast(1) + sample
        } else {
            existing + sample
        }
        return if (updated.size > LayoutSpec.SIGNAL_HISTORY_LIMIT) {
            updated.takeLast(LayoutSpec.SIGNAL_HISTORY_LIMIT)
        } else {
            updated
        }
    }

    private suspend fun waitForIdleAndRefresh(silent: Boolean) {
        repeat(10) {
            if (!_uiState.value.isRefreshing) return@repeat
            delayFn(150L)
        }
        refreshNow(silent = silent)
    }

    private fun showToast(message: String) {
        _uiState.update { it.copy(statusToast = message) }
        toastClearJob?.cancel()
        toastClearJob = scope.launch {
            delayFn(3_500L)
            _uiState.update { if (it.statusToast == message) it.copy(statusToast = null) else it }
        }
    }

    companion object {
        fun factory(context: Context): ViewModelProvider.Factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T {
                val appContext = context.applicationContext
                return RouterViewModel(
                    profileRepo = AndroidProfileStore(appContext),
                    credentialRepo = AndroidCredentialStore(appContext),
                    wifiMonitor = AndroidWifiLanMonitor(appContext)
                ) as T
            }
        }
    }
}

package com.zte.routerbar.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.zte.routerbar.core.EndpointProbeOutcome
import com.zte.routerbar.core.ProbeEndpoint
import com.zte.routerbar.core.SignalEvaluator
import com.zte.routerbar.core.WANConnectionState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SignalOverviewScreen(viewModel: RouterViewModel) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val lifecycleOwner = LocalLifecycleOwner.current
    val screenWidthDp = LocalConfiguration.current.screenWidthDp

    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> viewModel.setForegroundActive(true)
                Lifecycle.Event.ON_STOP -> viewModel.setForegroundActive(false)
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        if (lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) {
            viewModel.setForegroundActive(true)
        }
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            viewModel.setForegroundActive(false)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            text = "ZTERouterBar",
                            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            text = uiState.activeProfile.routerUrlString,
                            style = MaterialTheme.typography.labelSmall.tabularNums(),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                },
                actions = {
                    IconButton(
                        onClick = { viewModel.triggerManualRefresh() },
                        enabled = !uiState.isRefreshing && uiState.hasStoredPassword
                    ) {
                        if (uiState.isRefreshing) {
                            CircularProgressIndicator(
                                strokeWidth = 2.dp,
                                modifier = Modifier.size(18.dp)
                            )
                        } else {
                            Icon(
                                imageVector = AppIcons.Refresh,
                                contentDescription = "立即刷新"
                            )
                        }
                    }
                    IconButton(onClick = { viewModel.openProfileSheet() }) {
                        Icon(
                            imageVector = AppIcons.Settings,
                            contentDescription = "配置与设置"
                        )
                    }
                }
            )
        }
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 14.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            ProfileAndGatewayBar(uiState = uiState, viewModel = viewModel)

            uiState.statusToast?.let { toast ->
                Surface(
                    shape = RoundedCornerShape(10.dp),
                    color = toneColor(MetricTone.EXCELLENT).copy(alpha = 0.14f),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = toast,
                        style = MaterialTheme.typography.bodySmall,
                        color = toneColor(MetricTone.EXCELLENT),
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)
                    )
                }
            }

            if (!uiState.hasStoredPassword) {
                InlineQuickSetupCard(uiState = uiState, viewModel = viewModel)

                uiState.lastError?.let { errorMsg ->
                    ErrorAndTakeoverCard(
                        error = errorMsg,
                        isSessionOccupied = false,
                        onTakeover = {}
                    )
                }

                NodeLatencyProbeCard(
                    uiState = uiState,
                    screenWidthDp = screenWidthDp,
                    onTriggerProbe = viewModel::triggerManualProbe
                )
            } else {
                WanReconnectHeroCard(uiState = uiState, viewModel = viewModel)

                uiState.reconnectIpBanner?.let { banner ->
                    ReconnectIpBannerCard(
                        banner = banner,
                        onDismiss = viewModel::dismissReconnectBanner
                    )
                }

                uiState.lastError?.let { errorMsg ->
                    ErrorAndTakeoverCard(
                        error = errorMsg,
                        isSessionOccupied = uiState.isSessionOccupied,
                        onTakeover = viewModel::triggerManualRefresh
                    )
                }

                NodeLatencyProbeCard(
                    uiState = uiState,
                    screenWidthDp = screenWidthDp,
                    onTriggerProbe = viewModel::triggerManualProbe
                )

                val snap = uiState.snapshot
                if (snap != null) {
                    OverviewSummaryGrid(snap = snap, screenWidthDp = screenWidthDp)

                    uiState.signalAssessment?.let { assessment ->
                        SignalQualityChartCard(
                            assessment = assessment,
                            samples = uiState.signalHistory,
                            signalBars = snap.signalBars,
                            selectedMetric = uiState.selectedChartMetric,
                            onSelectMetric = viewModel::selectChartMetric
                        )
                    }

                    NrCellsSection(cells = snap.nrCells, screenWidthDp = screenWidthDp)
                    LteCellsSection(cells = snap.lteCells, screenWidthDp = screenWidthDp)
                    UmtsSection(umts = snap.umtsInfo)
                    NetworkDetailsCard(snap = snap, screenWidthDp = screenWidthDp)
                    NeighborCellsCard(cells = snap.neighborCells)
                    ConnectedStationsCard(snap = snap)
                } else if (uiState.isRefreshing) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 32.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            CircularProgressIndicator(
                                strokeWidth = 2.2.dp,
                                modifier = Modifier.size(20.dp)
                            )
                            Text(
                                text = "正在读取路由器状态…",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
            }
        }
    }

    ProfileConfigSheet(uiState = uiState, viewModel = viewModel)
}

@Composable
private fun ProfileAndGatewayBar(
    uiState: RouterUiState,
    viewModel: RouterViewModel
) {
    var menuExpanded by remember { mutableStateOf(false) }

    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Box(modifier = Modifier.weight(1f, fill = false).padding(end = 8.dp)) {
            Surface(
                shape = RoundedCornerShape(8.dp),
                color = MaterialTheme.colorScheme.surfaceVariant,
                modifier = Modifier
                    .heightIn(min = LayoutSpec.TOOLBAR_CONTROL_HEIGHT_DP.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .clickable { menuExpanded = true }
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Icon(
                        imageVector = AppIcons.Router,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp)
                    )
                    Text(
                        text = uiState.activeProfile.name,
                        style = MaterialTheme.typography.labelLarge,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    Icon(
                        imageVector = AppIcons.ChevronDown,
                        contentDescription = null,
                        modifier = Modifier.size(14.dp)
                    )
                }
            }

            DropdownMenu(
                expanded = menuExpanded,
                onDismissRequest = { menuExpanded = false }
            ) {
                uiState.profiles.forEach { profile ->
                    DropdownMenuItem(
                        text = {
                            Text(
                                text = if (profile.id == uiState.activeProfileId) "${profile.name} ✓" else profile.name
                            )
                        },
                        onClick = {
                            menuExpanded = false
                            viewModel.selectProfile(profile.id)
                        }
                    )
                }
                HorizontalDivider()
                DropdownMenuItem(
                    text = { Text("管理多个路由器配置…") },
                    onClick = {
                        menuExpanded = false
                        viewModel.openProfileSheet()
                    }
                )
            }
        }

        val gw = uiState.wifiGatewayIp
        val gwMatched = uiState.matchedProfileForGateway != null
        Surface(
            shape = CircleShape,
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f),
            modifier = Modifier.heightIn(min = LayoutSpec.TOOLBAR_CONTROL_HEIGHT_DP.dp)
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(7.dp)
                        .clip(CircleShape)
                        .background(
                            when {
                                !uiState.isWifiConnected -> MaterialTheme.colorScheme.outline
                                gwMatched -> toneColor(MetricTone.EXCELLENT)
                                else -> toneColor(MetricTone.FAIR)
                            }
                        )
                )
                Text(
                    text = when {
                        !uiState.isWifiConnected -> "Wi-Fi 未连接"
                        !gw.isNullOrBlank() -> "网关 $gw"
                        else -> "Wi-Fi 局域网"
                    },
                    style = MaterialTheme.typography.labelSmall.tabularNums(),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1
                )
            }
        }
    }
}

@Composable
private fun InlineQuickSetupCard(
    uiState: RouterUiState,
    viewModel: RouterViewModel
) {
    var quickName by rememberSaveable(uiState.activeProfileId) {
        mutableStateOf(uiState.activeProfile.name)
    }
    var quickUrl by rememberSaveable(uiState.activeProfileId) {
        mutableStateOf(uiState.activeProfile.routerUrlString)
    }
    var quickPassword by rememberSaveable(uiState.activeProfileId) {
        mutableStateOf("")
    }

    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Text(
                text = "配置路由器凭据",
                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold)
            )
            OutlinedTextField(
                value = quickName,
                onValueChange = { quickName = it },
                label = { Text("配置名称") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedTextField(
                    value = quickUrl,
                    onValueChange = { quickUrl = it },
                    label = { Text("路由器地址") },
                    placeholder = { Text("http://192.168.8.1") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    modifier = Modifier.weight(1f)
                )
                if (!uiState.wifiGatewayIp.isNullOrBlank()) {
                    OutlinedButton(
                        onClick = { quickUrl = "http://${uiState.wifiGatewayIp}" },
                        modifier = Modifier
                            .padding(top = 6.dp)
                            .heightIn(min = LayoutSpec.MIN_TOUCH_TARGET_DP.dp)
                    ) {
                        Text("用当前网关")
                    }
                }
            }
            OutlinedTextField(
                value = quickPassword,
                onValueChange = { quickPassword = it },
                label = { Text("管理密码 (Android Keystore 加密存储)") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                modifier = Modifier.fillMaxWidth()
            )
            Row(modifier = Modifier.fillMaxWidth()) {
                Spacer(modifier = Modifier.weight(1f))
                Button(
                    onClick = { viewModel.saveQuickSetup(quickName, quickUrl, quickPassword) },
                    enabled = quickPassword.trim().isNotEmpty() && !uiState.isSavingProfile
                ) {
                    Text(if (uiState.isSavingProfile) "连接保存中…" else "连接并保存")
                }
            }
        }
    }
}

@Composable
private fun WanReconnectHeroCard(
    uiState: RouterUiState,
    viewModel: RouterViewModel
) {
    val state = uiState.snapshot?.connectionState ?: WANConnectionState.Unknown("")
    val isConnected = state.isConnected
    val accentColor = when {
        uiState.isReconnectingWan -> toneColor(MetricTone.FAIR)
        isConnected -> toneColor(MetricTone.EXCELLENT)
        else -> MaterialTheme.colorScheme.outline
    }

    OutlinedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        border = BorderStroke(1.dp, accentColor.copy(alpha = 0.35f)),
        colors = CardDefaults.outlinedCardColors(
            containerColor = accentColor.copy(alpha = 0.08f)
        )
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(3.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(7.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(9.dp)
                                .clip(CircleShape)
                                .background(accentColor)
                        )
                        Text(
                            text = if (uiState.isReconnectingWan) "正在重连外网…" else state.localizedLabel,
                            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }

                    val snap = uiState.snapshot
                    if (snap != null) {
                        val ipLine = when {
                            snap.wanIPv4.isNotEmpty() -> "IPv4: ${snap.wanIPv4}"
                            snap.wanConnectStatus.isNotEmpty() -> snap.wanConnectStatus
                            else -> ""
                        }
                        if (ipLine.isNotEmpty()) {
                            Text(
                                text = ipLine,
                                style = MaterialTheme.typography.labelMedium.tabularNums(),
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                }

                Button(
                    onClick = { viewModel.triggerReconnectWan() },
                    enabled = !uiState.isReconnectingWan,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = if (isConnected) {
                            MaterialTheme.colorScheme.primary
                        } else {
                            toneColor(MetricTone.EXCELLENT)
                        }
                    ),
                    modifier = Modifier.heightIn(min = 44.dp)
                ) {
                    if (uiState.isReconnectingWan) {
                        CircularProgressIndicator(
                            strokeWidth = 2.dp,
                            color = MaterialTheme.colorScheme.onPrimary,
                            modifier = Modifier.size(16.dp)
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                        Text("重连中…")
                    } else {
                        Icon(
                            imageVector = AppIcons.Refresh,
                            contentDescription = null,
                            modifier = Modifier.size(17.dp)
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                        Text(
                            text = if (isConnected) "重连外网" else "连接外网",
                            fontWeight = FontWeight.SemiBold
                        )
                    }
                }
            }

            val snap = uiState.snapshot
            if (snap != null) {
                val gradeTone = Formatters.gradeTone(SignalEvaluator.assess(snap).grade)
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.45f))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text(
                        text = SignalEvaluator.headerSignalText(snap),
                        style = MaterialTheme.typography.labelMedium.tabularNums().copy(fontWeight = FontWeight.SemiBold),
                        color = toneColor(gradeTone),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Spacer(modifier = Modifier.weight(1f))
                    Text(
                        text = "终端 ${snap.totalConnectedDevices} 台",
                        style = MaterialTheme.typography.labelMedium.tabularNums(),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1
                    )
                    Text(
                        text = Formatters.duration(snap.sessionDurationSeconds),
                        style = MaterialTheme.typography.labelMedium.tabularNums(),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1
                    )
                }
            }
        }
    }
}

@Composable
private fun ReconnectIpBannerCard(
    banner: ReconnectIpBanner,
    onDismiss: () -> Unit
) {
    val color = if (banner.changed) toneColor(MetricTone.EXCELLENT) else MaterialTheme.colorScheme.primary
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = color.copy(alpha = 0.12f),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(3.dp)
            ) {
                Text(
                    text = banner.title,
                    style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.SemiBold),
                    color = color
                )
                Text(
                    text = banner.detail,
                    style = MaterialTheme.typography.labelSmall.tabularNums(),
                    color = MaterialTheme.colorScheme.onSurface
                )
            }
            TextButton(onClick = onDismiss) {
                Text("知道了")
            }
        }
    }
}

@Composable
private fun ErrorAndTakeoverCard(
    error: String,
    isSessionOccupied: Boolean,
    onTakeover: () -> Unit
) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = toneColor(MetricTone.FAIR).copy(alpha = 0.15f),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text(
                text = error,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurface
            )
            if (isSessionOccupied) {
                Row(modifier = Modifier.fillMaxWidth()) {
                    Spacer(modifier = Modifier.weight(1f))
                    OutlinedButton(onClick = onTakeover) {
                        Text("尝试接管并重连")
                    }
                }
            }
        }
    }
}

@Composable
private fun NodeLatencyProbeCard(
    uiState: RouterUiState,
    screenWidthDp: Int,
    onTriggerProbe: () -> Unit
) {
    val endpoints = uiState.probeEndpoints
    if (endpoints.isEmpty()) return

    val total = endpoints.size
    val completedCount = endpoints.count { uiState.probeOutcomes.containsKey(it.id) }
    val reachableCount = endpoints.count { uiState.probeOutcomes[it.id]?.reachable == true }
    val summaryTone = when {
        reachableCount == total && completedCount == total -> MetricTone.EXCELLENT
        reachableCount * 2 > total -> MetricTone.GOOD
        reachableCount > 0 -> MetricTone.FAIR
        else -> MetricTone.POOR
    }

    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(2.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Text(
                            text = "外网节点测速",
                            style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false)
                        )
                        if (uiState.isProbingNodes || completedCount > 0) {
                            val badgeColor = if (uiState.isProbingNodes) {
                                MaterialTheme.colorScheme.primary
                            } else {
                                toneColor(summaryTone)
                            }
                            val summaryText = if (uiState.isProbingNodes) {
                                "检测 $completedCount/$total"
                            } else {
                                "可达 $reachableCount/$total"
                            }
                            Surface(
                                shape = CircleShape,
                                color = badgeColor.copy(alpha = 0.14f)
                            ) {
                                Text(
                                    text = summaryText,
                                    style = MaterialTheme.typography.labelSmall.tabularNums().copy(fontWeight = FontWeight.SemiBold),
                                    color = badgeColor,
                                    maxLines = 1,
                                    modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp)
                                )
                            }
                        }
                    }

                    val subtitle = when {
                        uiState.isProbingNodes -> "并发检测 $total 个默认节点（超时 ${ProbeEndpoint.DEFAULT_TIMEOUT_SEC}s）…"
                        uiState.lastProbeCompletedAtMs != null -> "上次测速 ${Formatters.timeOfDay(uiState.lastProbeCompletedAtMs)}"
                        else -> "并发检测连通性与 HTTP 响应延迟"
                    }
                    Text(
                        text = subtitle,
                        style = MaterialTheme.typography.labelSmall.tabularNums(),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }

                FilledTonalButton(
                    onClick = onTriggerProbe,
                    enabled = !uiState.isProbingNodes,
                    modifier = Modifier.heightIn(min = 44.dp)
                ) {
                    if (uiState.isProbingNodes) {
                        CircularProgressIndicator(
                            strokeWidth = 2.dp,
                            modifier = Modifier.size(15.dp)
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                        Text("测速中…")
                    } else {
                        Icon(
                            imageVector = AppIcons.SpeedProbe,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp)
                        )
                        Spacer(modifier = Modifier.width(5.dp))
                        Text(
                            text = if (completedCount == 0) "立即测速" else "重新测速",
                            fontWeight = FontWeight.SemiBold
                        )
                    }
                }
            }

            val cols = LayoutSpec.probeGridColumns(screenWidthDp)
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                endpoints.chunked(cols).forEach { rowItems ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        rowItems.forEach { endpoint ->
                            ProbeEndpointItem(
                                endpoint = endpoint,
                                outcome = uiState.probeOutcomes[endpoint.id],
                                isProbingNodes = uiState.isProbingNodes,
                                modifier = Modifier.weight(1f)
                            )
                        }
                        repeat(cols - rowItems.size) {
                            Spacer(modifier = Modifier.weight(1f))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ProbeEndpointItem(
    endpoint: ProbeEndpoint,
    outcome: EndpointProbeOutcome?,
    isProbingNodes: Boolean,
    modifier: Modifier = Modifier
) {
    val dotColor: Color = when {
        outcome != null && outcome.reachable -> toneColor(MetricTone.EXCELLENT)
        outcome != null -> toneColor(MetricTone.POOR)
        isProbingNodes -> MaterialTheme.colorScheme.primary
        else -> MaterialTheme.colorScheme.outline
    }

    val badgeText: String
    val badgeTextColor: Color
    val badgeContainerColor: Color
    when {
        outcome == null && isProbingNodes -> {
            badgeText = "测速中…"
            badgeTextColor = MaterialTheme.colorScheme.primary
            badgeContainerColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)
        }
        outcome == null -> {
            badgeText = "待测速"
            badgeTextColor = MaterialTheme.colorScheme.onSurfaceVariant
            badgeContainerColor = MaterialTheme.colorScheme.surfaceVariant
        }
        outcome.reachable -> {
            val codeText = outcome.statusCode?.toString() ?: "OK"
            badgeText = "$codeText · ${outcome.elapsedMs}ms"
            val okColor = toneColor(MetricTone.EXCELLENT)
            badgeTextColor = okColor
            badgeContainerColor = okColor.copy(alpha = 0.14f)
        }
        else -> {
            badgeText = when {
                outcome.errorMessage?.contains("超时") == true -> "超时 (${endpoint.timeoutSec}s)"
                outcome.statusCode != null -> "HTTP ${outcome.statusCode}"
                else -> "不可达"
            }
            val failColor = toneColor(MetricTone.POOR)
            badgeTextColor = failColor
            badgeContainerColor = failColor.copy(alpha = 0.14f)
        }
    }

    val errorDetail = outcome?.takeIf { !it.reachable }?.errorMessage
        ?.takeIf { it.isNotBlank() && !it.startsWith("请求超时") }

    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(7.dp)
                    .clip(CircleShape)
                    .background(dotColor)
            )
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(1.dp)
            ) {
                Text(
                    text = endpoint.displayTitle,
                    style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Medium),
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                if (errorDetail != null) {
                    Text(
                        text = errorDetail,
                        style = MaterialTheme.typography.labelSmall.tabularNums(),
                        color = toneColor(MetricTone.POOR),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
            Surface(
                shape = CircleShape,
                color = badgeContainerColor
            ) {
                Text(
                    text = badgeText,
                    style = MaterialTheme.typography.labelSmall.tabularNums().copy(fontWeight = FontWeight.SemiBold),
                    color = badgeTextColor,
                    maxLines = 1,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                )
            }
        }
    }
}

package com.zte.routerbar.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.zte.routerbar.core.ConnectedDeviceKind
import com.zte.routerbar.core.LTECellInfo
import com.zte.routerbar.core.NRCellInfo
import com.zte.routerbar.core.NeighborCellInfo
import com.zte.routerbar.core.RouterStatusSnapshot
import com.zte.routerbar.core.SignalEvaluator
import com.zte.routerbar.core.UMTSCellInfo
import java.util.Locale
import kotlin.math.roundToInt

@Composable
fun OverviewSummaryGrid(
    snap: RouterStatusSnapshot,
    screenWidthDp: Int
) {
    val assessment = SignalEvaluator.assess(snap)
    val rsrpText = assessment.rsrp?.let { "RSRP ${it.roundToInt()} dBm" } ?: assessment.primaryTechLabel
    val sinrText = assessment.sinr?.let { " · SINR ${String.format(Locale.US, "%.1f", it)} dB" }.orEmpty()

    val boxes = listOf(
        SummaryBoxData(
            title = "信号强度评级",
            primary = "${assessment.grade.label} (${assessment.score}分)",
            secondary = "$rsrpText$sinrText",
            tone = Formatters.gradeTone(assessment.grade)
        ),
        SummaryBoxData(
            title = "本次连接流量",
            primary = Formatters.byteCount(snap.sessionRxBytes + snap.sessionTxBytes),
            secondary = "时长 ${Formatters.duration(snap.sessionDurationSeconds)}"
        ),
        SummaryBoxData(
            title = "本月累计流量",
            primary = Formatters.byteCount(snap.monthlyRxBytes + snap.monthlyTxBytes),
            secondary = "↓${Formatters.byteCount(snap.monthlyRxBytes)} ↑${Formatters.byteCount(snap.monthlyTxBytes)}"
        ),
        SummaryBoxData(
            title = "电池与终端",
            primary = snap.batteryPercent?.let {
                "$it%${if (snap.batteryCharging == "2") " 充电中" else ""}"
            } ?: "终端 ${snap.totalConnectedDevices} 台",
            secondary = "无线 ${snap.wirelessDeviceCount} 台 · 有线 ${snap.wiredDeviceCount} 台"
        )
    )

    val cols = LayoutSpec.summaryGridColumns(screenWidthDp)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        boxes.chunked(cols).forEach { rowItems ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                rowItems.forEach { box ->
                    SummaryInfoCard(data = box, modifier = Modifier.weight(1f))
                }
            }
        }
    }
}

private data class SummaryBoxData(
    val title: String,
    val primary: String,
    val secondary: String,
    val tone: MetricTone = MetricTone.NEUTRAL
)

@Composable
private fun SummaryInfoCard(data: SummaryBoxData, modifier: Modifier = Modifier) {
    val primaryColor = if (data.tone == MetricTone.NEUTRAL) {
        MaterialTheme.colorScheme.onSurface
    } else {
        toneColor(data.tone)
    }
    ElevatedCard(
        modifier = modifier,
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Text(
                text = data.title,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                text = data.primary,
                style = MaterialTheme.typography.titleMedium.tabularNums().copy(fontWeight = FontWeight.SemiBold),
                color = primaryColor,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                text = data.secondary,
                style = MaterialTheme.typography.labelSmall.tabularNums(),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

@Composable
fun NrCellsSection(cells: List<NRCellInfo>, screenWidthDp: Int) {
    if (cells.isEmpty()) return
    SectionTitle("5G NR 小区信号")
    val cols = LayoutSpec.cellGridColumns(screenWidthDp)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        cells.chunked(cols).forEach { row ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                row.forEach { cell ->
                    NrCellCard(cell = cell, modifier = Modifier.weight(1f))
                }
                repeat(cols - row.size) {
                    Spacer(modifier = Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun NrCellCard(cell: NRCellInfo, modifier: Modifier = Modifier) {
    ElevatedCard(
        modifier = modifier,
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = if (cell.isPrimary) "5G 主小区 (${cell.band})" else "5G 辅小区 (${cell.band})",
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                    modifier = Modifier.weight(1f)
                )
                if (cell.bandwidthMHz.isNotEmpty()) {
                    BandwidthPill("${cell.bandwidthMHz} MHz")
                }
            }
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FixedKvSlot(
                    label = "RSRP1",
                    value = "${cell.rsrp1} dBm",
                    tone = Formatters.rsrpTone(cell.rsrp1),
                    labelWidth = LayoutSpec.CELL_METRIC_LABEL_WIDTH_DP.dp,
                    modifier = Modifier.weight(1f)
                )
                if (cell.rsrp2.isNotEmpty()) {
                    FixedKvSlot(
                        label = "RSRP2",
                        value = "${cell.rsrp2} dBm",
                        tone = Formatters.rsrpTone(cell.rsrp2),
                        labelWidth = LayoutSpec.CELL_METRIC_LABEL_WIDTH_DP.dp,
                        modifier = Modifier.weight(1f)
                    )
                }
            }
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FixedKvSlot(
                    label = "SINR",
                    value = "${cell.sinr} dB",
                    tone = Formatters.sinrTone(cell.sinr),
                    labelWidth = LayoutSpec.CELL_METRIC_LABEL_WIDTH_DP.dp,
                    modifier = Modifier.weight(1f)
                )
                if (cell.rsrq.isNotEmpty()) {
                    FixedKvSlot(
                        label = "RSRQ",
                        value = "${cell.rsrq} dB",
                        labelWidth = LayoutSpec.CELL_METRIC_LABEL_WIDTH_DP.dp,
                        modifier = Modifier.weight(1f)
                    )
                }
            }
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FixedKvSlot("ARFCN", cell.arfcn.ifEmpty { "-" }, labelWidth = LayoutSpec.CELL_METRIC_LABEL_WIDTH_DP.dp, modifier = Modifier.weight(1f))
                FixedKvSlot("PCI", cell.pci.ifEmpty { "-" }, labelWidth = LayoutSpec.CELL_METRIC_LABEL_WIDTH_DP.dp, modifier = Modifier.weight(1f))
            }
        }
    }
}

@Composable
fun LteCellsSection(cells: List<LTECellInfo>, screenWidthDp: Int) {
    if (cells.isEmpty()) return
    SectionTitle("4G LTE 小区信号")
    val cols = LayoutSpec.cellGridColumns(screenWidthDp)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        cells.chunked(cols).forEach { row ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                row.forEach { cell ->
                    LteCellCard(cell = cell, modifier = Modifier.weight(1f))
                }
                repeat(cols - row.size) {
                    Spacer(modifier = Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun LteCellCard(cell: LTECellInfo, modifier: Modifier = Modifier) {
    ElevatedCard(
        modifier = modifier,
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = if (cell.isPrimary) "LTE 主小区 (${cell.band})" else "LTE 辅载波 (${cell.band})",
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                    modifier = Modifier.weight(1f)
                )
                if (cell.bandwidthMHz.isNotEmpty()) {
                    BandwidthPill("${cell.bandwidthMHz} MHz")
                }
            }
            if (cell.rsrpList.isNotEmpty()) {
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    FixedKvSlot(
                        label = "RSRP",
                        value = cell.rsrpList.joinToString(" / ") + " dBm",
                        tone = Formatters.rsrpTone(cell.rsrpList.first()),
                        labelWidth = LayoutSpec.CELL_METRIC_LABEL_WIDTH_DP.dp,
                        modifier = Modifier.weight(1f)
                    )
                    if (cell.sinrList.isNotEmpty()) {
                        FixedKvSlot(
                            label = "SINR",
                            value = cell.sinrList.joinToString(" / ") + " dB",
                            tone = Formatters.sinrTone(cell.sinrList.first()),
                            labelWidth = LayoutSpec.CELL_METRIC_LABEL_WIDTH_DP.dp,
                            modifier = Modifier.weight(1f)
                        )
                    }
                }
            }
            if (cell.rsrq.isNotEmpty() || cell.rssi.isNotEmpty()) {
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (cell.rsrq.isNotEmpty()) {
                        FixedKvSlot("RSRQ", "${cell.rsrq} dB", labelWidth = LayoutSpec.CELL_METRIC_LABEL_WIDTH_DP.dp, modifier = Modifier.weight(1f))
                    }
                    if (cell.rssi.isNotEmpty()) {
                        FixedKvSlot("RSSI", "${cell.rssi} dBm", labelWidth = LayoutSpec.CELL_METRIC_LABEL_WIDTH_DP.dp, modifier = Modifier.weight(1f))
                    }
                }
            }
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FixedKvSlot("EARFCN", cell.earfcn.ifEmpty { "-" }, labelWidth = LayoutSpec.CELL_METRIC_LABEL_WIDTH_DP.dp, modifier = Modifier.weight(1f))
                FixedKvSlot("PCI", cell.pci.ifEmpty { "-" }, labelWidth = LayoutSpec.CELL_METRIC_LABEL_WIDTH_DP.dp, modifier = Modifier.weight(1f))
            }
        }
    }
}

@Composable
fun UmtsSection(umts: UMTSCellInfo?) {
    if (umts == null) return
    SectionTitle("3G UMTS 信号" + if (umts.band.isEmpty()) "" else " (${umts.band})")
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            FixedKvSlot(
                label = "RSCP",
                value = umts.rscp.joinToString(", ") { "$it dBm" }.ifEmpty { "-" },
                labelWidth = LayoutSpec.CELL_METRIC_LABEL_WIDTH_DP.dp,
                modifier = Modifier.weight(1f)
            )
            FixedKvSlot(
                label = "ECIO",
                value = umts.ecio.joinToString(", ") { "-$it dB" }.ifEmpty { "-" },
                labelWidth = LayoutSpec.CELL_METRIC_LABEL_WIDTH_DP.dp,
                modifier = Modifier.weight(1f)
            )
        }
    }
}

@Composable
fun NetworkDetailsCard(snap: RouterStatusSnapshot, screenWidthDp: Int) {
    val rows = buildList {
        add("运营商" to "${snap.displayProvider.ifEmpty { "-" }} (${snap.mcc.ifEmpty { "-" }}-${snap.mnc.ifEmpty { "-" }})")
        add("接入制式" to "${snap.networkType.ifEmpty { "-" }} (${snap.currentNetworkMode.ifEmpty { "-" }})")
        add("组合频段" to snap.bandSummary.ifEmpty { "-" })
        add("LTE CA 状态" to if (snap.isLTECarrierAggregationActive) "已激活 ✓" else "未激活")
        add("4G Cell ID" to snap.cellID.ifEmpty { "-" })
        add("5G Cell ID" to snap.nr5gCellID.ifEmpty { "-" })
        add("WAN IPv4" to snap.wanIPv4.ifEmpty { "-" })
        add("WAN IPv6" to snap.wanIPv6.ifEmpty { "-" })
        add("APN" to snap.wanAPN.ifEmpty { "-" })
        add("DNS" to Formatters.dnsSummary(snap))
        add("工作模式" to snap.opmsWanMode.ifEmpty { "-" })
        add("固件版本" to snap.versionInfo.waInnerVersion.ifEmpty { "-" })
        if (snap.temperatures.isNotEmpty()) {
            add("设备温度" to snap.temperatures.joinToString(" · ") { "${it.label} ${it.celsius.toInt()}°C" })
        }
    }
    val pairsPerRow = LayoutSpec.detailPairsPerRow(screenWidthDp)

    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text(
                text = "小区与网络详情",
                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold)
            )
            rows.chunked(pairsPerRow).forEach { chunk ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    chunk.forEach { (k, v) ->
                        FixedKvSlot(
                            label = k,
                            value = v,
                            labelWidth = LayoutSpec.DETAIL_LABEL_WIDTH_DP.dp,
                            allowWrap = true,
                            modifier = Modifier.weight(1f)
                        )
                    }
                    repeat(pairsPerRow - chunk.size) {
                        Spacer(modifier = Modifier.weight(1f))
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun NeighborCellsCard(cells: List<NeighborCellInfo>) {
    if (cells.isEmpty()) return
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Text(
                text = "邻区信息",
                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold)
            )
            cells.forEach { cell ->
                if (cell.pci.isNotEmpty()) {
                    FlowRow(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        verticalArrangement = Arrangement.spacedBy(2.dp)
                    ) {
                        Text("PCI: ${cell.pci}", style = MaterialTheme.typography.bodySmall.tabularNums().copy(fontWeight = FontWeight.SemiBold), maxLines = 1)
                        Text("Freq: ${cell.frequency}", style = MaterialTheme.typography.bodySmall.tabularNums(), maxLines = 1)
                        Text("RSRP: ${cell.rsrp} dBm", style = MaterialTheme.typography.bodySmall.tabularNums(), maxLines = 1)
                        Text("RSRQ: ${cell.rsrq} dB", style = MaterialTheme.typography.bodySmall.tabularNums(), maxLines = 1)
                    }
                } else {
                    Text(
                        text = cell.rawLine,
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

@Composable
fun ConnectedStationsCard(snap: RouterStatusSnapshot) {
    val radioDetail = if (snap.wifi24GCount != null && snap.wifi5GCount != null) {
        "无线 ${snap.wirelessDeviceCount} 台（2.4G ${snap.wifi24GCount} / 5G ${snap.wifi5GCount}）· 有线 ${snap.wiredDeviceCount} 台"
    } else {
        "无线 ${snap.wirelessDeviceCount} 台 · 有线 ${snap.wiredDeviceCount} 台"
    }
    val stations = snap.wifiStations + snap.lanStations

    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text(
                text = "已连接终端：共 ${snap.totalConnectedDevices} 台",
                style = MaterialTheme.typography.titleSmall.tabularNums().copy(fontWeight = FontWeight.SemiBold)
            )
            Text(
                text = radioDetail,
                style = MaterialTheme.typography.labelSmall.tabularNums(),
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            if (stations.isEmpty()) {
                Text(
                    text = if (snap.wirelessDeviceCount > 0) {
                        "路由器报告无线接入 ${snap.wirelessDeviceCount} 台（明细列表暂为空）"
                    } else {
                        "暂无已连接终端"
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            } else {
                stations.forEachIndexed { idx, st ->
                    if (idx > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = st.hostname.ifEmpty { "未知设备" },
                                style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            Text(
                                text = "${st.ipAddress.ifEmpty { "-" }} · ${st.displayConnectionType}",
                                style = MaterialTheme.typography.labelSmall.tabularNums(),
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                        Text(
                            text = Formatters.duration(st.connectTimeSeconds),
                            style = MaterialTheme.typography.labelSmall.tabularNums(),
                            color = if (st.deviceKind == ConnectedDeviceKind.WIRED) {
                                MaterialTheme.colorScheme.primary
                            } else {
                                MaterialTheme.colorScheme.onSurfaceVariant
                            }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionTitle(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
        modifier = Modifier.padding(top = 4.dp)
    )
}

@Composable
private fun BandwidthPill(text: String) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(horizontal = 8.dp, vertical = 2.dp)
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.labelSmall.tabularNums(),
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun FixedKvSlot(
    label: String,
    value: String,
    labelWidth: Dp,
    tone: MetricTone = MetricTone.NEUTRAL,
    allowWrap: Boolean = false,
    modifier: Modifier = Modifier
) {
    val valueColor = if (tone == MetricTone.NEUTRAL) {
        MaterialTheme.colorScheme.onSurface
    } else {
        toneColor(tone)
    }
    Row(
        modifier = modifier,
        verticalAlignment = if (allowWrap) Alignment.Top else Alignment.CenterVertically
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.width(labelWidth)
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodySmall.tabularNums().copy(
                fontWeight = if (tone == MetricTone.NEUTRAL) FontWeight.Normal else FontWeight.SemiBold
            ),
            color = valueColor,
            maxLines = if (allowWrap) 2 else 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f)
        )
    }
}

import SwiftUI
import ZTERouterCore

enum DashboardTab: String, CaseIterable, Identifiable {
    case overview
    case watchdog
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "信号与概览"
        case .watchdog: "保活守护"
        case .settings: "配置与设置"
        }
    }

    var icon: String {
        switch self {
        case .overview: "waveform.path.ecg"
        case .watchdog: "shield.checkered"
        case .settings: "gearshape"
        }
    }
}

struct DashboardView: View {
    @Bindable var viewModel: RouterViewModel

    var body: some View {
        NavigationSplitView {
            List(DashboardTab.allCases, selection: $viewModel.selectedDashboardTab) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 165, ideal: 185, max: 210)
        } detail: {
            VStack(spacing: 0) {
                topStatusStrip
                Divider()
                Group {
                    switch viewModel.selectedDashboardTab {
                    case .overview:
                        SignalOverviewTab(viewModel: viewModel)
                    case .watchdog:
                        WatchdogView(viewModel: viewModel)
                    case .settings:
                        SettingsView(viewModel: viewModel)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 780, minHeight: 540)
    }

    private var topStatusStrip: some View {
        let isConnected = viewModel.snapshot?.connectionState.isConnected ?? false
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isReconnectingWAN ? Color.orange : (isConnected ? Color.green : Color.secondary))
                    .frame(width: 10, height: 10)
                Text(viewModel.activeProfile.name)
                    .font(.subheadline.weight(.semibold))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(viewModel.snapshot?.connectionState.localizedLabel ?? "等待连接")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let snap = viewModel.snapshot {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(snap.networkType) \(snap.bandSummary)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !snap.wanIPv4.isEmpty {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(snap.wanIPv4)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let toast = viewModel.actionStatusMessage {
                Text(toast)
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if let error = viewModel.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Button {
                Task { await viewModel.reconnectWAN() }
            } label: {
                if viewModel.isReconnectingWAN {
                    ProgressView().controlSize(.small)
                } else {
                    Label(isConnected ? "一键重连外网" : "连接外网", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(isConnected ? .blue : .green)
            .disabled(viewModel.isReconnectingWAN || !viewModel.hasStoredPassword)

            Button {
                Task { await viewModel.refreshNow(silent: false) }
            } label: {
                if viewModel.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(viewModel.isRefreshing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Signal & Overview Tab

private struct SignalOverviewTab: View {
    let viewModel: RouterViewModel

    var body: some View {
        ScrollView {
            if let snap = viewModel.snapshot {
                VStack(alignment: .leading, spacing: 16) {
                    trafficAndSummaryRow(snap)

                    if let assessment = viewModel.currentSignalAssessment {
                        SignalQualityDashboardCard(
                            assessment: assessment,
                            samples: viewModel.signalHistory,
                            signalBars: snap.signalBars
                        )
                    }

                    if !snap.nrCells.isEmpty {
                        sectionHeader("5G NR 小区信号")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                            ForEach(snap.nrCells) { cell in
                                nrCellCard(cell)
                            }
                        }
                    }

                    if !snap.lteCells.isEmpty {
                        sectionHeader("4G LTE 小区信号")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                            ForEach(snap.lteCells) { cell in
                                lteCellCard(cell)
                            }
                        }
                    }

                    if let umts = snap.umtsInfo {
                        sectionHeader("3G UMTS 信号 \(umts.band.isEmpty ? "" : "(\(umts.band))")")
                        umtsCard(umts)
                    }

                    cellAndNetworkInfoCard(snap)

                    if !snap.neighborCells.isEmpty {
                        neighborCellsCard(snap.neighborCells)
                    }

                    stationsCard(snap: snap)
                }
                .padding(16)
            } else {
                ContentUnavailableView(
                    "暂无路由器状态数据",
                    systemImage: "wifi.exclamationmark",
                    description: Text(viewModel.lastError ?? "请确保 Mac 已连接到目标路由器的 Wi-Fi/局域网，并在「配置与设置」中填写管理密码。")
                )
                .padding(40)
            }
        }
    }

    private func trafficAndSummaryRow(_ snap: RouterStatusSnapshot) -> some View {
        HStack(spacing: 12) {
            infoBox(title: "实时速率", primary: "↓ \(Formatters.speedBits(snap.rxBytesPerSec))", secondary: "↑ \(Formatters.speedBits(snap.txBytesPerSec))")
            infoBox(title: "本次连接流量", primary: Formatters.byteCount(snap.sessionRxBytes + snap.sessionTxBytes), secondary: "时长 \(Formatters.duration(snap.sessionDurationSeconds))")
            infoBox(title: "本月累计流量", primary: Formatters.byteCount(snap.monthlyRxBytes + snap.monthlyTxBytes), secondary: "↓\(Formatters.byteCount(snap.monthlyRxBytes)) ↑\(Formatters.byteCount(snap.monthlyTxBytes))")
            infoBox(
                title: "电池与终端",
                primary: snap.batteryPercent.map { "\($0)% \(snap.batteryCharging == "2" ? "充电中" : "")" } ?? "终端 \(snap.totalConnectedDevices) 台",
                secondary: "无线 \(snap.wirelessDeviceCount) 台 · 有线 \(snap.wiredDeviceCount) 台"
            )
        }
    }

    private func infoBox(title: String, primary: String, secondary: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(primary).font(.headline.monospacedDigit())
            Text(secondary).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func nrCellCard(_ cell: NRCellInfo) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(cell.isPrimary ? "5G 主小区 (\(cell.band))" : "5G 辅小区 (\(cell.band))")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !cell.bandwidthMHz.isEmpty {
                        Text("\(cell.bandwidthMHz) MHz")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        kv("RSRP1", "\(cell.rsrp1) dBm", color: Formatters.rsrpColor(cell.rsrp1))
                        if !cell.rsrp2.isEmpty {
                            kv("RSRP2", "\(cell.rsrp2) dBm", color: Formatters.rsrpColor(cell.rsrp2))
                        }
                    }
                    GridRow {
                        kv("SINR", "\(cell.sinr) dB", color: Formatters.sinrColor(cell.sinr))
                        if !cell.rsrq.isEmpty {
                            kv("RSRQ", "\(cell.rsrq) dB")
                        }
                    }
                    GridRow {
                        kv("ARFCN", cell.arfcn)
                        kv("PCI", cell.pci)
                    }
                }
            }
            .padding(4)
        }
    }

    private func lteCellCard(_ cell: LTECellInfo) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(cell.isPrimary ? "LTE 主小区 (\(cell.band))" : "LTE 辅载波 (\(cell.band))")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !cell.bandwidthMHz.isEmpty {
                        Text("\(cell.bandwidthMHz) MHz")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    if !cell.rsrpList.isEmpty {
                        GridRow {
                            kv("RSRP", cell.rsrpList.joined(separator: " / ") + " dBm", color: Formatters.rsrpColor(cell.rsrpList[0]))
                            if !cell.sinrList.isEmpty {
                                kv("SINR", cell.sinrList.joined(separator: " / ") + " dB", color: Formatters.sinrColor(cell.sinrList[0]))
                            }
                        }
                    }
                    GridRow {
                        if !cell.rsrq.isEmpty { kv("RSRQ", "\(cell.rsrq) dB") }
                        if !cell.rssi.isEmpty { kv("RSSI", "\(cell.rssi) dBm") }
                    }
                    GridRow {
                        kv("EARFCN", cell.earfcn)
                        kv("PCI", cell.pci)
                    }
                }
            }
            .padding(4)
        }
    }

    private func umtsCard(_ umts: UMTSCellInfo) -> some View {
        GroupBox {
            HStack(spacing: 24) {
                kv("RSCP", umts.rscp.map { "\($0) dBm" }.joined(separator: ", "))
                kv("ECIO", umts.ecio.map { "-\($0) dB" }.joined(separator: ", "))
            }
            .padding(4)
        }
    }

    private func cellAndNetworkInfoCard(_ snap: RouterStatusSnapshot) -> some View {
        GroupBox("小区与网络详情") {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    kv("运营商", "\(snap.displayProvider) (\(snap.mcc)-\(snap.mnc))")
                    kv("接入制式", "\(snap.networkType) (\(snap.currentNetworkMode.isEmpty ? "-" : snap.currentNetworkMode))")
                }
                GridRow {
                    kv("组合频段", snap.bandSummary.isEmpty ? "-" : snap.bandSummary)
                    kv("LTE CA 状态", snap.isLTECarrierAggregationActive ? "已激活 ✓" : "未激活")
                }
                GridRow {
                    kv("4G Cell ID", snap.cellID.isEmpty ? "-" : snap.cellID)
                    kv("5G Cell ID", snap.nr5gCellID.isEmpty ? "-" : snap.nr5gCellID)
                }
                GridRow {
                    kv("WAN IPv4", snap.wanIPv4.isEmpty ? "-" : snap.wanIPv4)
                    kv("WAN IPv6", snap.wanIPv6.isEmpty ? "-" : snap.wanIPv6)
                }
                GridRow {
                    kv("APN", snap.wanAPN.isEmpty ? "-" : snap.wanAPN)
                    kv("DNS", dnsSummary(snap))
                }
                GridRow {
                    kv("工作模式", snap.opmsWanMode.isEmpty ? "-" : snap.opmsWanMode)
                    kv("固件版本", snap.versionInfo.waInnerVersion.isEmpty ? "-" : snap.versionInfo.waInnerVersion)
                }
                if !snap.temperatures.isEmpty {
                    GridRow {
                        kv("设备温度", snap.temperatures.map { "\($0.label): \(Int($0.celsius))°C" }.joined(separator: "   "))
                        Color.clear.frame(height: 1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func neighborCellsCard(_ cells: [NeighborCellInfo]) -> some View {
        GroupBox("邻区信息") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(cells) { cell in
                    if !cell.pci.isEmpty {
                        HStack(spacing: 16) {
                            Text("PCI: \(cell.pci)").font(.caption.monospacedDigit().weight(.semibold))
                            Text("Freq: \(cell.frequency)").font(.caption.monospacedDigit())
                            Text("RSRP: \(cell.rsrp) dBm").font(.caption.monospacedDigit())
                            Text("RSRQ: \(cell.rsrq) dB").font(.caption.monospacedDigit())
                        }
                    } else {
                        Text(cell.rawLine).font(.caption.monospaced())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func stationsCard(snap: RouterStatusSnapshot) -> some View {
        let radioDetail: String = {
            if let c24 = snap.wifi24GCount, let c5 = snap.wifi5GCount {
                return "无线 \(snap.wirelessDeviceCount) 台（2.4G \(c24) / 5G \(c5)）· 有线 \(snap.wiredDeviceCount) 台"
            }
            return "无线 \(snap.wirelessDeviceCount) 台 · 有线 \(snap.wiredDeviceCount) 台"
        }()

        return GroupBox("已连接终端：共 \(snap.totalConnectedDevices) 台（\(radioDetail)）") {
            let all = snap.wifiStations + snap.lanStations
            if all.isEmpty {
                Text(snap.wirelessDeviceCount > 0 ? "路由器报告无线接入 \(snap.wirelessDeviceCount) 台（明细列表暂为空）" : "暂无已连接终端")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(4)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(all) { st in
                        HStack {
                            Image(systemName: st.deviceKind == .wired ? "cable.connector" : "wifi")
                                .foregroundStyle(.secondary)
                            Text(st.hostname.isEmpty ? "未知设备" : st.hostname)
                                .font(.subheadline)
                            Spacer()
                            Text(st.ipAddress)
                                .font(.caption.monospacedDigit())
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(st.displayConnectionType)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(Formatters.duration(st.connectTimeSeconds))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(4)
            }
        }
    }

    private func dnsSummary(_ snap: RouterStatusSnapshot) -> String {
        if snap.dnsMode == "manual" {
            let list = [snap.preferDNSManual, snap.standbyDNSManual].filter { !$0.isEmpty }
            return "手动 (\(list.joined(separator: ", ")))"
        }
        return snap.dnsMode.isEmpty ? "-" : snap.dnsMode
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.headline)
    }

    private func kv(_ key: String, _ value: String, color: Color = .primary) -> some View {
        HStack(spacing: 4) {
            Text(key + ":")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }
}

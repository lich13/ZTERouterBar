import AppKit
import SwiftUI
import ZTERouterCore

struct PopoverView: View {
    @Bindable var viewModel: RouterViewModel
    let onOpenDashboard: (DashboardTab) -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    @State private var quickName: String = ""
    @State private var quickURL: String = ""
    @State private var quickPassword: String = ""
    @State private var bindCurrentWiFiOnSetup: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar
            wifiAndProfileBar

            if !viewModel.hasStoredPassword {
                quickSetupCard
            } else {
                wanHeroCard
                watchdogStatusCard
                if let snapshot = viewModel.snapshot {
                    signalSummaryCard(snapshot)
                } else if viewModel.isRefreshing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取路由器状态…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                }
            }

            if let error = viewModel.lastError {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if viewModel.isSessionOccupied {
                        HStack {
                            Spacer()
                            Button("尝试接管并重连") {
                                Task { await viewModel.refreshNow(silent: false) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if let toast = viewModel.actionStatusMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(toast)
                        .font(.caption)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            footerBar
        }
        .padding(14)
        .frame(width: 376)
        .onAppear {
            syncSetupFields()
        }
        .onChange(of: viewModel.settings.activeProfileID) { _, _ in
            syncSetupFields()
        }
    }

    private func syncSetupFields() {
        quickName = viewModel.activeProfile.name
        quickURL = viewModel.activeProfile.routerURLString
        quickPassword = viewModel.passwordInput
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.headline)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text("ZTE 移动路由助手")
                    .font(.headline)
                Text(viewModel.activeProfile.routerURLString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let battery = viewModel.snapshot?.batteryPercent {
                HStack(spacing: 3) {
                    Image(systemName: viewModel.snapshot?.batteryCharging == "2" ? "battery.100percent.bolt" : "battery.100percent")
                        .foregroundStyle(battery > 20 ? .green : .red)
                    Text("\(battery)%")
                        .font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }

            Button {
                Task { await viewModel.refreshNow(silent: false) }
            } label: {
                if viewModel.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("立即刷新")
        }
    }

    private var wifiAndProfileBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(viewModel.settings.profiles) { profile in
                    Button {
                        viewModel.selectProfile(profile.id)
                    } label: {
                        HStack {
                            Text(profile.name)
                            if profile.id == viewModel.settings.activeProfileID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button("管理多个路由器配置…") {
                    onOpenSettings()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "wifi.router")
                        .font(.caption2)
                    Text(viewModel.activeProfile.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if let ssid = viewModel.wifiMonitor.currentSSID {
                HStack(spacing: 4) {
                    Image(systemName: "wifi")
                        .font(.caption2)
                        .foregroundStyle(viewModel.matchedProfileForCurrentWiFi != nil ? .green : .secondary)
                    Text(ssid)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.45), in: Capsule())
                .help(viewModel.matchedProfileForCurrentWiFi != nil ? "已自动匹配当前 Wi-Fi 配置" : "当前 Wi-Fi 未绑定配置，可在设置中一键绑定")
            } else if !viewModel.wifiMonitor.isLocationAuthorized {
                Button {
                    viewModel.wifiMonitor.requestLocationPermission()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "location.slash")
                            .font(.caption2)
                        Text("授权识别 Wi-Fi")
                            .font(.caption2)
                    }
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("macOS 需要定位权限以读取当前连接的 Wi-Fi 名称")
            }
        }
    }

    private var quickSetupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("配置路由器凭据")
                .font(.subheadline.weight(.semibold))
            TextField("配置名称 (如 随身 5G Wi-Fi)", text: $quickName)
                .textFieldStyle(.roundedBorder)
            TextField("路由器地址 (例如 http://192.168.8.1)", text: $quickURL)
                .textFieldStyle(.roundedBorder)
            SecureField("管理密码（加密存入系统钥匙串）", text: $quickPassword)
                .textFieldStyle(.roundedBorder)

            if let ssid = viewModel.wifiMonitor.currentSSID {
                Toggle("同时绑定当前 Wi-Fi「\(ssid)」自动匹配", isOn: $bindCurrentWiFiOnSetup)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("连接并保存") {
                    Task {
                        await viewModel.saveQuickSetup(
                            name: quickName,
                            urlString: quickURL,
                            password: quickPassword,
                            bindCurrentWiFi: bindCurrentWiFiOnSetup
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(quickPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isRefreshing)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var wanHeroCard: some View {
        let state = viewModel.snapshot?.connectionState ?? .unknown(rawStatus: "")
        let isConnected = state.isConnected

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(viewModel.isReconnectingWAN ? Color.orange : (isConnected ? Color.green : Color.secondary))
                            .frame(width: 9, height: 9)
                        Text(viewModel.isReconnectingWAN ? "正在重连外网…" : state.localizedLabel)
                            .font(.subheadline.weight(.semibold))
                    }

                    if let snap = viewModel.snapshot {
                        if !snap.wanIPv4.isEmpty {
                            Text("IPv4: \(snap.wanIPv4)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else if !snap.wanConnectStatus.isEmpty {
                            Text(snap.wanConnectStatus)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Button {
                    Task { await viewModel.reconnectWAN() }
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isReconnectingWAN {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(viewModel.isReconnectingWAN ? "重连中…" : (isConnected ? "重连外网" : "连接外网"))
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(isConnected ? .blue : .green)
                .disabled(viewModel.isReconnectingWAN)
            }

            if let snap = viewModel.snapshot {
                Divider()
                HStack(spacing: 10) {
                    Label {
                        Text("↓ \(Formatters.speedBits(snap.rxBytesPerSec))")
                            .font(.caption.monospacedDigit())
                    } icon: {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                    }

                    Label {
                        Text("↑ \(Formatters.speedBits(snap.txBytesPerSec))")
                            .font(.caption.monospacedDigit())
                    } icon: {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.teal)
                    }

                    Spacer()

                    Text("终端 \(snap.totalConnectedDevices) 台")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("无线 \(snap.wirelessDeviceCount) 台 · 有线 \(snap.wiredDeviceCount) 台")

                    Text(Formatters.duration(snap.sessionDurationSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isConnected ? Color.green.opacity(0.08) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isConnected ? Color.green.opacity(0.28) : Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private var watchdogStatusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "shield.checkered")
                    .font(.caption)
                    .foregroundStyle(viewModel.isWatchdogRunning ? .green : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("外网保活守护")
                        .font(.caption.weight(.semibold))
                    Text(viewModel.watchdogPhase.displayLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    onOpenDashboard(.watchdog)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("编辑探测端点与守护参数")

                Toggle("", isOn: Binding(
                    get: { viewModel.isWatchdogRunning },
                    set: { on in
                        if on && !viewModel.isWatchdogRunning {
                            viewModel.startWatchdog()
                        } else if !on && viewModel.isWatchdogRunning {
                            viewModel.stopWatchdog(userInitiated: true)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if !viewModel.lastProbeOutcomes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(viewModel.lastProbeOutcomes) { outcome in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(outcome.reachable ? Color.green : Color.red)
                                    .frame(width: 6, height: 6)
                                Text(outcome.name)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                Text(outcome.reachable ? "\(outcome.elapsedMs)ms" : "超时")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.45), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func signalSummaryCard(_ snap: RouterStatusSnapshot) -> some View {
        let assessment = viewModel.currentSignalAssessment
        let gradeColor = Formatters.signalGradeColor(assessment?.grade ?? .unknown)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snap.displayProvider.isEmpty ? "蜂窝网络" : snap.displayProvider)
                    .font(.caption.weight(.semibold))
                if !snap.networkType.isEmpty {
                    Text(snap.networkType)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                if let assessment, assessment.grade != .unknown {
                    Text("\(assessment.grade.rawValue) · \(assessment.score)分")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(gradeColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(gradeColor)
                }
                Spacer()
                if !snap.bandSummary.isEmpty {
                    Text(snap.bandSummary)
                        .font(.caption.monospacedDigit().weight(.medium))
                }
            }

            if let nr = snap.nrCells.first {
                HStack(spacing: 10) {
                    metricChip(title: "5G RSRP", value: "\(nr.rsrp1) dBm", color: Formatters.rsrpColor(nr.rsrp1))
                    metricChip(title: "SINR", value: "\(nr.sinr) dB", color: Formatters.sinrColor(nr.sinr))
                    if !nr.rsrq.isEmpty {
                        metricChip(title: "RSRQ", value: "\(nr.rsrq) dB", color: .secondary)
                    }
                    if !nr.pci.isEmpty {
                        metricChip(title: "PCI", value: nr.pci, color: .secondary)
                    }
                }
            } else if let lte = snap.lteCells.first {
                HStack(spacing: 10) {
                    if let rsrp = lte.rsrpList.first {
                        metricChip(title: "LTE RSRP", value: "\(rsrp) dBm", color: Formatters.rsrpColor(rsrp))
                    }
                    if let sinr = lte.sinrList.first {
                        metricChip(title: "SINR", value: "\(sinr) dB", color: Formatters.sinrColor(sinr))
                    }
                    if !lte.rsrq.isEmpty {
                        metricChip(title: "RSRQ", value: "\(lte.rsrq) dB", color: .secondary)
                    }
                    if !lte.pci.isEmpty {
                        metricChip(title: "PCI", value: lte.pci, color: .secondary)
                    }
                }
            }

            if !viewModel.signalHistory.isEmpty {
                SignalSparklineView(
                    samples: viewModel.signalHistory,
                    lineColor: gradeColor
                )
            }

            HStack(spacing: 8) {
                if !snap.temperatures.isEmpty {
                    Image(systemName: "thermometer.medium")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(snap.temperatures.map { "\($0.label) \(Int($0.celsius))°C" }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("无线 \(snap.wirelessDeviceCount) / 有线 \(snap.wiredDeviceCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func metricChip(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footerBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    onOpenDashboard(.overview)
                } label: {
                    Label("控制台", systemImage: "macwindow")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    onOpenDashboard(.watchdog)
                } label: {
                    Label("保活设置", systemImage: "shield.checkered")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    onOpenSettings()
                } label: {
                    Label("配置", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    onQuit()
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("退出 ZTERouterBar")
            }

            HStack {
                Text("提示：⌥+点击状态栏图标 或 按 ⌃⌥W 一键重连外网")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }
}

import AppKit
import SwiftUI
import UserNotifications
import ZTERouterCore

struct WatchdogView: View {
    @Bindable var viewModel: RouterViewModel

    @State private var draftConfig: WatchdogConfig = WatchdogConfig()
    @State private var hasUnappliedEdits: Bool = false

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controlHeaderCard
                endpointsCard
                policyAndTimingCard
                logCard
            }
            .padding(16)
        }
        .onAppear {
            draftConfig = viewModel.settings.watchdogConfig
            hasUnappliedEdits = false
            Task { await viewModel.notifier.refreshAuthorizationStatus() }
        }
    }

    // MARK: - Control Header

    private var controlHeaderCard: some View {
        GroupBox {
            HStack(spacing: 12) {
                Circle()
                    .fill(phaseColor)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text("外网限流保活守护")
                        .font(.headline)
                    Text(viewModel.watchdogPhase.displayLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if hasUnappliedEdits {
                    Button("保存并应用改动") {
                        applyDraftConfig()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }

                Button {
                    if hasUnappliedEdits {
                        applyDraftConfig()
                    }
                    Task { await viewModel.runSingleWatchdogProbe() }
                } label: {
                    if viewModel.isProbingOnce {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("立即探测一次", systemImage: "stethoscope")
                    }
                }
                .disabled(viewModel.isProbingOnce)

                Button {
                    if hasUnappliedEdits {
                        applyDraftConfig()
                    }
                    viewModel.toggleWatchdog()
                } label: {
                    Label(
                        viewModel.isWatchdogRunning ? "停止守护" : "启动守护",
                        systemImage: viewModel.isWatchdogRunning ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isWatchdogRunning ? .red : .green)
            }
            .padding(6)
        }
    }

    // MARK: - Editable Endpoints

    private var endpointsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("探测端点列表（支持手动编辑域名、权重与独立频率/超时）")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        draftConfig.endpoints.append(WatchdogEndpoint(
                            isEnabled: true,
                            name: "自定义站点",
                            urlString: "https://",
                            weight: 1,
                            intervalSec: 33,
                            timeoutSec: 4
                        ))
                        markDirty()
                    } label: {
                        Label("新增端点", systemImage: "plus")
                    }
                    .controlSize(.small)

                    Button("恢复默认预设") {
                        draftConfig.endpoints = WatchdogEndpoint.defaultPresets
                        applyDraftConfig()
                    }
                    .controlSize(.small)
                }

                if draftConfig.endpoints.isEmpty {
                    Text("暂无探测端点，请点击「新增端点」或「恢复默认预设」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 8) {
                        ForEach($draftConfig.endpoints) { $ep in
                            endpointRow(endpoint: $ep)
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    private func endpointRow(endpoint: Binding<WatchdogEndpoint>) -> some View {
        let epVal = endpoint.wrappedValue
        let outcome = viewModel.lastProbeOutcomes.first(where: { $0.id == epVal.id })

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: endpoint.isEnabled)
                    .labelsHidden()
                    .onChange(of: epVal.isEnabled) { _, _ in applyDraftConfig() }

                TextField("名称", text: endpoint.name, prompt: Text("名称"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 112)
                    .onChange(of: epVal.name) { _, _ in markDirty() }
                    .onSubmit { applyDraftConfig() }

                TextField("检测链接 (http/https)", text: endpoint.urlString, prompt: Text("https://661313.xyz/test/generate_204"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: epVal.urlString) { _, _ in markDirty() }
                    .onSubmit { applyDraftConfig() }

                Picker("", selection: endpoint.weight) {
                    ForEach(1...10, id: \.self) { w in
                        Text("权重 \(w)").tag(w)
                    }
                }
                .labelsHidden()
                .frame(width: 78)
                .help("端点权重（1–10）。按权重判定时，可达权重之和须超过总权重 50%")
                .onChange(of: epVal.weight) { _, _ in applyDraftConfig() }

                outcomeBadge(outcome)

                Button(role: .destructive) {
                    draftConfig.endpoints.removeAll { $0.id == epVal.id }
                    applyDraftConfig()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除此端点")
            }

            HStack(spacing: 18) {
                inlineNumberInput("检测频率 (s)", value: endpoint.intervalSec, range: 5...3600)
                inlineNumberInput("单次超时 (s)", value: endpoint.timeoutSec, range: 1...30)
                Spacer()
            }
            .padding(.leading, 28)
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func inlineNumberInput(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 6) {
            Text(title + ":")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .onChange(of: value.wrappedValue) { _, _ in markDirty() }
                .onSubmit { applyDraftConfig() }
            Stepper("", value: value, in: range)
                .labelsHidden()
                .onChange(of: value.wrappedValue) { _, _ in markDirty() }
        }
    }

    @ViewBuilder
    private func outcomeBadge(_ outcome: EndpointProbeOutcome?) -> some View {
        if let outcome {
            if outcome.reachable {
                let code = outcome.statusCode.map(String.init) ?? "OK"
                Text("\(code) · \(outcome.elapsedMs)ms")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.14), in: Capsule())
                    .frame(minWidth: 82)
            } else {
                Text("不可达")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.14), in: Capsule())
                    .frame(minWidth: 82)
                    .help(outcome.errorMessage ?? "探测失败")
            }
        } else {
            Text("待探测")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(minWidth: 82)
        }
    }

    // MARK: - Policy & Timing

    private var policyAndTimingCard: some View {
        GroupBox("检测策略与防抖参数") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("打开 App 后自动启动外网保活守护", isOn: $draftConfig.autoStart)
                    .onChange(of: draftConfig.autoStart) { _, _ in applyDraftConfig() }

                Toggle("仅在当前连接的 Wi-Fi 已匹配当前路由器配置时自动重连", isOn: $draftConfig.onlyWhenWiFiMatched)
                    .onChange(of: draftConfig.onlyWhenWiFiMatched) { _, _ in applyDraftConfig() }

                Toggle("自动重连与重连前后 IP 变化时推送 macOS 系统通知（含手动重连）", isOn: Bindable(viewModel.settings).systemNotificationsEnabled)

                if viewModel.settings.systemNotificationsEnabled && viewModel.notifier.authorizationStatus == .denied {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.slash.fill")
                            .foregroundStyle(.orange)
                        Text("系统通知权限已被拒绝，请在系统设置中允许 ZTERouterBar 发送通知。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("打开通知设置") {
                            viewModel.notifier.openSystemNotificationSettings()
                        }
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }

                Picker("触发重连条件:", selection: $draftConfig.triggerPolicy) {
                    ForEach(WatchdogTriggerPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .frame(maxWidth: 460)
                .onChange(of: draftConfig.triggerPolicy) { _, _ in applyDraftConfig() }

                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        numberInput("持续异常多久才重连 (s)", value: $draftConfig.failureWindowSec, range: 10...600)
                        numberInput("确认期复检间隔 (s)", value: $draftConfig.recheckIntervalSec, range: 1...60)
                    }
                    GridRow {
                        numberInput("重连后保护期 (s)", value: $draftConfig.postReconnectGraceSec, range: 0...600)
                        numberInput("连续重连上限 (次)", value: $draftConfig.maxConsecutiveReconnects, range: 1...10)
                    }
                    GridRow {
                        numberInput("触发上限后冷却 (s)", value: $draftConfig.cooldownSec, range: 10...600)
                    }
                }

                Text("触发节奏：各端点按自身频率(s)与超时(s)独立检测；判为异常后每 \(draftConfig.recheckIntervalSec)s 对全部端点复检，任一轮恢复即取消，持续异常满 \(draftConfig.failureWindowSec)s 才重连。重连后 \(draftConfig.postReconnectGraceSec)s 保护期内不探测、不重连，之后从头监测。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("恢复默认参数") {
                        draftConfig = draftConfig.withDefaultParameters()
                        applyDraftConfig()
                    }
                    .controlSize(.small)

                    Spacer()
                    Button("保存并应用参数") {
                        applyDraftConfig()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasUnappliedEdits)
                }
            }
            .padding(6)
        }
    }

    private func numberInput(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 8) {
            Text(label + ":")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 168, alignment: .leading)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .onChange(of: value.wrappedValue) { _, _ in markDirty() }
                .onSubmit { applyDraftConfig() }
            Stepper("", value: value, in: range)
                .labelsHidden()
                .onChange(of: value.wrappedValue) { _, _ in markDirty() }
        }
    }

    // MARK: - Live Log

    private var logCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("保活运行日志 (\(viewModel.watchdogLogs.count))")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("复制日志") {
                        let text = viewModel.watchdogLogs.map {
                            "\(Self.logTimeFormatter.string(from: $0.timestamp))  \($0.message)"
                        }.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        viewModel.showToast("已复制日志")
                    }
                    .controlSize(.small)
                    .disabled(viewModel.watchdogLogs.isEmpty)

                    Button("清空") {
                        viewModel.clearWatchdogLogs()
                    }
                    .controlSize(.small)
                    .disabled(viewModel.watchdogLogs.isEmpty)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            if viewModel.watchdogLogs.isEmpty {
                                Text("暂无日志。点击「启动守护」或「立即探测一次」开始监测。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                            } else {
                                ForEach(viewModel.watchdogLogs) { entry in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(Self.logTimeFormatter.string(from: entry.timestamp))
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        Text(entry.message)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(colorForLevel(entry.level))
                                            .textSelection(.enabled)
                                    }
                                    .id(entry.id)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(height: 200)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: viewModel.watchdogLogs.last?.id) { _, lastID in
                        if let lastID {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: - Helpers

    private var phaseColor: Color {
        switch viewModel.watchdogPhase {
        case .idle: .secondary
        case .monitoring: .green
        case .confirming, .settling: .orange
        case .reconnecting: .blue
        case .coolingDown, .paused: .orange
        }
    }

    private func colorForLevel(_ level: WatchdogLogLevel) -> Color {
        switch level {
        case .info: .primary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }

    private func markDirty() {
        hasUnappliedEdits = (draftConfig.clamped() != viewModel.settings.watchdogConfig)
    }

    private func applyDraftConfig() {
        draftConfig = draftConfig.clamped()
        viewModel.updateWatchdogConfig(draftConfig)
        hasUnappliedEdits = false
    }
}

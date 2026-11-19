import SwiftUI
import ZTERouterCore

struct SettingsView: View {
    @Bindable var viewModel: RouterViewModel

    @State private var editingProfileID: UUID?
    @State private var nameDraft: String = ""
    @State private var urlDraft: String = ""
    @State private var passwordDraft: String = ""
    @State private var wifiSSIDsDraft: String = ""
    @State private var hashDraft: AuthHashPreference = .auto
    @State private var savedNote: String?
    @State private var editingHasStoredPassword: Bool = false

    var body: some View {
        Form {
            wifiRecognitionSection
            profilesListSection
            profileEditorSection
            generalPreferencesSection
        }
        .formStyle(.grouped)
        .padding(8)
        .onAppear {
            loadProfileIntoEditor(viewModel.activeProfile)
        }
        .onChange(of: viewModel.settings.activeProfileID) { _, newID in
            if let profile = viewModel.settings.profiles.first(where: { $0.id == newID }) {
                loadProfileIntoEditor(profile)
            }
        }
    }

    // MARK: - Wi-Fi Recognition Section

    private var wifiRecognitionSection: some View {
        Section("Wi-Fi 自动识别") {
            HStack(spacing: 10) {
                Image(systemName: viewModel.wifiMonitor.isLocationAuthorized ? "wifi" : "location.slash")
                    .foregroundStyle(viewModel.wifiMonitor.isLocationAuthorized ? .green : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    if let ssid = viewModel.wifiMonitor.currentSSID {
                        Text("当前 Wi-Fi：\(ssid)")
                            .font(.subheadline.weight(.medium))
                        if let matched = viewModel.matchedProfileForCurrentWiFi {
                            Text("已匹配配置：\(matched.name)")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Text("尚未将此 Wi-Fi 绑定到任何路由器配置")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if viewModel.wifiMonitor.isLocationAuthorized {
                        Text("未检测到已连接的 Wi-Fi 名称")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("需要授权定位权限以读取当前 Wi-Fi 名称")
                            .font(.subheadline)
                        Text("macOS 要求授权定位服务才能获取 SSID 用于自动切换配置")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if !viewModel.wifiMonitor.isLocationAuthorized {
                    if viewModel.wifiMonitor.authorizationStatus == .notDetermined {
                        Button("授权识别 Wi-Fi") {
                            viewModel.wifiMonitor.requestLocationPermission()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("打开系统定位设置") {
                            viewModel.wifiMonitor.openSystemLocationSettings()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Button("刷新") {
                    viewModel.triggerWiFiAutoMatch()
                }
            }

            Toggle("切换 Wi-Fi 时自动匹配并切换路由器配置", isOn: Binding(
                get: { viewModel.settings.autoMatchByWiFi },
                set: {
                    viewModel.settings.autoMatchByWiFi = $0
                    if $0 { viewModel.triggerWiFiAutoMatch() }
                }
            ))
        }
    }

    // MARK: - Multi-Profile List

    private var profilesListSection: some View {
        Section {
            ForEach(viewModel.settings.profiles) { profile in
                let isEditing = editingProfileID == profile.id
                let isActive = viewModel.settings.activeProfileID == profile.id
                HStack(spacing: 10) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "wifi.router")
                        .foregroundStyle(isActive ? .green : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(profile.name)
                                .font(.subheadline.weight(isActive ? .semibold : .regular))
                            if isActive {
                                Text("当前使用")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.green)
                            }
                        }
                        Text(profileSummary(profile))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !isActive {
                        Button("切换使用") {
                            viewModel.selectProfile(profile.id)
                            loadProfileIntoEditor(profile)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button(isEditing ? "正在编辑" : "编辑") {
                        loadProfileIntoEditor(profile)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isEditing)

                    if viewModel.settings.profiles.count > 1 {
                        Button(role: .destructive) {
                            viewModel.deleteProfile(id: profile.id)
                            loadProfileIntoEditor(viewModel.activeProfile)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("删除此配置")
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack {
                Text("已保存的路由器配置 (\(viewModel.settings.profiles.count))")
                Spacer()
                Button {
                    let created = viewModel.settings.addNewProfile(suggestedSSID: viewModel.wifiMonitor.currentSSID)
                    loadProfileIntoEditor(created)
                    viewModel.selectProfile(created.id)
                } label: {
                    Label("新增配置", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Profile Editor

    private var profileEditorSection: some View {
        Section("编辑配置详情") {
            TextField("配置名称", text: $nameDraft, prompt: Text("例如：随身 5G Wi-Fi / 客厅路由器"))
            TextField("管理后台地址", text: $urlDraft, prompt: Text("http://192.168.8.1"))
            SecureField("管理密码 (按配置独立加密存入钥匙串)", text: $passwordDraft, prompt: Text("输入管理密码"))

            HStack {
                TextField("绑定 Wi-Fi 名称 (多个用逗号分隔)", text: $wifiSSIDsDraft, prompt: Text("例如：MyWiFi_5G, MyWiFi_2.4G"))
                Button("填入当前 Wi-Fi") {
                    appendCurrentWiFiToDraft()
                }
                .disabled(viewModel.wifiMonitor.currentSSID == nil)
            }

            Picker("AD 签名算法", selection: $hashDraft) {
                ForEach(AuthHashPreference.allCases) { algo in
                    Text(algo.displayName).tag(algo)
                }
            }

            HStack(spacing: 10) {
                Button("保存并测试连接") {
                    Task {
                        guard let targetID = editingProfileID else { return }
                        let updated = RouterProfile(
                            id: targetID,
                            name: nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "路由器配置" : nameDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                            routerURLString: urlDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                            wifiSSIDs: RouterProfile.normalizeSSIDList(wifiSSIDsDraft),
                            hashPreference: hashDraft
                        )
                        savedNote = nil
                        await viewModel.saveProfile(updated, password: passwordDraft, activateAndTest: true)
                        editingHasStoredPassword = viewModel.editorCredentialSnapshot(forProfileID: targetID).hasStoredPassword
                        if viewModel.lastError == nil {
                            savedNote = "已保存并成功连接「\(updated.name)」。"
                        }
                    }
                }
                .buttonStyle(.borderedProminent)

                if let targetID = editingProfileID, editingHasStoredPassword {
                    Button("清除此配置密码", role: .destructive) {
                        viewModel.clearPassword(forProfileID: targetID)
                        editingHasStoredPassword = false
                        passwordDraft = ""
                        savedNote = "已从钥匙串移除此配置的密码。"
                    }
                }

                if let savedNote {
                    Text(savedNote).font(.caption).foregroundStyle(.green)
                }
            }
        }
    }

    // MARK: - General Preferences

    private var generalPreferencesSection: some View {
        Section("状态栏与快捷操作") {
            Picker("状态栏显示风格", selection: Binding(
                get: { viewModel.settings.menuBarDisplayStyle },
                set: { viewModel.settings.menuBarDisplayStyle = $0 }
            )) {
                ForEach(MenuBarDisplayStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }

            Picker("状态轮询间隔", selection: Binding(
                get: { viewModel.settings.pollingInterval },
                set: { viewModel.settings.pollingInterval = $0 }
            )) {
                Text("2 秒").tag(2.0)
                Text("3 秒").tag(3.0)
                Text("5 秒").tag(5.0)
                Text("10 秒").tag(10.0)
            }

            Toggle("启用全局快捷键 ⌃⌥W 一键重连外网", isOn: Binding(
                get: { viewModel.settings.globalShortcutEnabled },
                set: { viewModel.settings.globalShortcutEnabled = $0 }
            ))

            Picker("启动方式", selection: Binding(
                get: { viewModel.launchMode },
                set: { viewModel.setLaunchMode($0) }
            )) {
                ForEach(LaunchMode.allCases) { mode in
                    Text(mode.displayName)
                        .tag(mode)
                        .selectionDisabled(mode == .wifiOnly && !viewModel.canUseWiFiOnlyLaunch)
                }
            }

            Text(viewModel.canUseWiFiOnlyLaunch
                ? "「仅连接已绑定 Wi-Fi 时启动」：平时不常驻；连上任一配置绑定的 Wi-Fi 时由系统自动拉起，离开约 60 秒后自动退出。在该 Wi-Fi 下手动退出后，需重新连接该 Wi-Fi 或手动打开才会再次启动。"
                : "「仅连接已绑定 Wi-Fi 时启动」需要先为路由器配置绑定 Wi-Fi 名称，并授权定位权限以识别当前 Wi-Fi。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func loadProfileIntoEditor(_ profile: RouterProfile) {
        editingProfileID = profile.id
        nameDraft = profile.name
        urlDraft = profile.routerURLString
        wifiSSIDsDraft = profile.wifiSSIDs.joined(separator: ", ")
        hashDraft = profile.hashPreference
        let snapshot = viewModel.editorCredentialSnapshot(forProfileID: profile.id)
        passwordDraft = snapshot.password
        editingHasStoredPassword = snapshot.hasStoredPassword
        savedNote = nil
    }

    private func appendCurrentWiFiToDraft() {
        viewModel.wifiMonitor.refreshSSID()
        guard let ssid = viewModel.wifiMonitor.currentSSID else { return }
        var existing = RouterProfile.normalizeSSIDList(wifiSSIDsDraft)
        if !existing.contains(where: { $0.caseInsensitiveCompare(ssid) == .orderedSame }) {
            existing.append(ssid)
        }
        wifiSSIDsDraft = existing.joined(separator: ", ")
    }

    private func profileSummary(_ profile: RouterProfile) -> String {
        let wifiText = profile.wifiSSIDs.isEmpty ? "未绑定 Wi-Fi" : "Wi-Fi: \(profile.wifiSSIDs.joined(separator: ", "))"
        return "\(profile.routerURLString) · \(wifiText)"
    }
}

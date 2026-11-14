import SwiftUI

struct HomeView: View {
    @EnvironmentObject var coordinator: HostVoiceCoordinator
    @State private var quickTestMode: VoiceActionMode = .dictate
    @State private var isKeyboardEnabled: Bool = false

    private var totalChars: Int {
        coordinator.history.reduce(0) { $0 + $1.characterCount }
    }

    private var estimatedMinutesSaved: Int {
        // Rough comparison: voice ~140 chars/min vs mobile typing ~35 chars/min
        max(0, (totalChars / 35) - (totalChars / 140))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    pipKeepAliveCard
                    keyboardSetupCard
                    insightsHeatmapCard
                    quickVoiceTestCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("FlowType 语音输入法")
            .onAppear {
                refreshKeyboardEnabledState()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                refreshKeyboardEnabledState()
                coordinator.reloadFromStore()
            }
        }
    }

    // MARK: - 1. PiP Keep-Alive Card

    private var pipKeepAliveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("画中画免切 App 保活", systemImage: "pip.fill")
                        .font(.headline)
                    Text(coordinator.pipManager.isPiPActive
                         ? "PiP 已激活：现在切到任意 App，点键盘即可直接录音"
                         : "开启后切到其他 App 时主程序保持后台待命，无需来回跳转")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(coordinator.pipManager.isPiPActive ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
            }

            // Live PiP sample buffer display view (must stay visible/attached for iOS PiP)
            PiPHostPreviewRepresentable(view: coordinator.pipManager.hostView)
                .frame(height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                )

            HStack(spacing: 12) {
                Button {
                    coordinator.togglePiPStandby()
                } label: {
                    Label(
                        coordinator.pipManager.isPiPActive ? "关闭画中画保活" : "启动画中画待命",
                        systemImage: coordinator.pipManager.isPiPActive ? "stop.circle.fill" : "play.circle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(coordinator.pipManager.isPiPActive ? .red : .blue)
            }

            if let err = coordinator.pipManager.lastErrorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 2. Keyboard Setup & App Group Check

    private var keyboardSetupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("系统键盘启用状态", systemImage: "keyboard.badge.ellipsis")
                    .font(.headline)
                Spacer()
                Text(isKeyboardEnabled ? "已添加" : "未添加")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isKeyboardEnabled ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                    .foregroundStyle(isKeyboardEnabled ? .green : .orange)
                    .clipShape(Capsule())
            }

            Text("1. 前往「系统设置 → 键盘 → 键盘 → 添加新键盘」选择 FlowType 语音键盘。\n2. 点进该键盘开启「允许完全访问」（用于读取 App Group 配置、AI 语音结果同步与词典）。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if SharedStore.shared.isUsingAppGroup {
                Label("App Group 共享容器已就绪（\(AppConfig.appGroupID)）", systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if SharedStore.shared.isUsingKeychainSync {
                VStack(alignment: .leading, spacing: 3) {
                    Label("跨进程共享通道已就绪（钥匙串同步：\(SharedStore.shared.activeKeychainAccessGroup ?? "已连接")）", systemImage: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text("已自动启用证书钥匙串通道同步配置、词典与语音状态。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                let provGroups = AppConfig.provisionedAppGroups
                if provGroups.isEmpty {
                    Label("当前未检测到 App Group 容器（签名 Profile 需包含 \(AppConfig.appGroupID)）", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("证书含 \(provGroups.count) 条 App Group，但当前签名权限尚未生效：", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                        Text(provGroups.joined(separator: "、"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("请在全能签签名设置中开启「保留/注入应用组权限」或选中上述组后重签主 App 与键盘插件。")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("打开系统设置启用键盘", systemImage: "arrow.up.forward.app")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 3. Insights & Heatmap (Typeless v2.6.0 style)

    private var insightsHeatmapCard: some View {
        let daily = SharedStore.shared.dailyCharacterCounts(days: 49)
        let maxCount = max(daily.map(\.count).max() ?? 1, 1)

        return VStack(alignment: .leading, spacing: 12) {
            Label("效率洞察与活跃热力图", systemImage: "chart.bar.xaxis")
                .font(.headline)

            HStack(spacing: 12) {
                statPill(title: "累计听写", value: "\(totalChars) 字")
                statPill(title: "记录次数", value: "\(coordinator.history.count) 次")
                statPill(title: "约省时间", value: "\(estimatedMinutesSaved) 分钟")
            }

            // 7 columns x 7 rows heatmap (last 49 days)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(daily.enumerated()), id: \.offset) { _, item in
                    let intensity = item.count == 0 ? 0.08 : min(1.0, 0.25 + 0.75 * Double(item.count) / Double(maxCount))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(item.count == 0 ? Color(.tertiarySystemFill) : Color.blue.opacity(intensity))
                        .frame(height: 18)
                }
            }
            .padding(.top, 4)

            Text("最近 7 周每日语音输出热度")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 4. Quick Voice Test Playground

    private var quickVoiceTestCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI 语音接口快速测试", systemImage: "waveform")
                    .font(.headline)
                Spacer()
                Picker("模式", selection: $quickTestMode) {
                    ForEach(VoiceActionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            Button {
                Task {
                    await coordinator.toggleQuickTestRecording(mode: quickTestMode)
                }
            } label: {
                HStack {
                    Image(systemName: coordinator.status.state == .recording ? "stop.fill" : "mic.fill")
                    Text(testButtonLabel)
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent)
            .tint(coordinator.status.state == .recording ? .red : .indigo)

            if coordinator.status.state == .recording {
                ProgressView(value: min(1.0, max(0.05, Double(coordinator.status.audioLevel))))
                    .tint(.red)
                if !coordinator.status.partialText.isEmpty {
                    Text(coordinator.status.partialText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let err = coordinator.status.errorMessage, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !coordinator.lastQuickTestResult.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !coordinator.lastQuickTestRaw.isEmpty {
                        Text("原始识别：\(coordinator.lastQuickTestRaw)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(coordinator.lastQuickTestResult)
                        .font(.body)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var testButtonLabel: String {
        switch coordinator.status.state {
        case .recording: return String(format: "点击停止录音 (%.1fs)", coordinator.status.elapsedSeconds)
        case .transcribing: return "正在转写语音..."
        case .polishing: return "AI 整理中..."
        default: return "点击测试「\(quickTestMode.title)」"
        }
    }

    private func refreshKeyboardEnabledState() {
        let keyboards = UserDefaults.standard.object(forKey: "AppleKeyboards") as? [String] ?? []
        var candidateExtIDs = Set<String>()
        if let mainID = Bundle.main.bundleIdentifier {
            candidateExtIDs.insert(mainID + ".keyboard")
        }
        if let pluginsURL = Bundle.main.builtInPlugInsURL,
           let items = try? FileManager.default.contentsOfDirectory(at: pluginsURL, includingPropertiesForKeys: nil) {
            for item in items where item.pathExtension == "appex" {
                if let extID = Bundle(url: item)?.bundleIdentifier {
                    candidateExtIDs.insert(extID)
                }
            }
        }
        isKeyboardEnabled = keyboards.contains { $0.contains("FlowType") || candidateExtIDs.contains($0) }
    }
}

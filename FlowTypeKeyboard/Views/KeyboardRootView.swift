import SwiftUI

public struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardStateModel
    @Environment(\.colorScheme) private var systemColorScheme

    private var effectiveColorScheme: ColorScheme {
        switch model.config.appearance {
        case .system: return systemColorScheme
        case .light: return .light
        case .dark: return .dark
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            topToolbar
                .frame(height: 36)
                .padding(.horizontal, 8)

            Divider()
                .opacity(0.35)

            Group {
                if model.activePanel == .voice {
                    VoiceKeyboardPanel(model: model)
                        .gesture(swipeToSwitchGesture)
                } else {
                    ManualKeyboardPanel(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(backgroundSurface)
        .preferredColorScheme(effectiveColorScheme)
    }

    private var backgroundSurface: Color {
        effectiveColorScheme == .dark
            ? Color(red: 0.11, green: 0.11, blue: 0.13)
            : Color(red: 0.83, green: 0.84, blue: 0.87)
    }

    // MARK: - Top Toolbar

    private var topToolbar: some View {
        HStack(spacing: 6) {
            // Voice / Manual panel toggle button
            Button {
                model.switchToPanel(model.activePanel == .voice ? .manual : .voice)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.activePanel == .voice ? "keyboard" : "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.activePanel == .voice ? "手打" : "语音")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.16))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            if model.activePanel == .voice {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(VoiceActionMode.allCases) { mode in
                            Button {
                                model.triggerHaptic()
                                model.voiceMode = mode
                            } label: {
                                Text(mode.title)
                                    .font(.system(size: 12, weight: model.voiceMode == mode ? .semibold : .regular))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(model.voiceMode == mode ? Color.blue : Color.clear)
                                    .foregroundStyle(model.voiceMode == mode ? .white : .primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                // Quick manual info & inline voice shortcut
                HStack(spacing: 6) {
                    Text(model.manualLanguage == .chinesePinyin ? "全拼输入" : "English")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            // Host PiP / Keep-Alive Status Pill
            hostStatusPill

            // Undo last AI insertion
            if model.canUndoLastAIInsert {
                Button {
                    model.undoLastAIInsert()
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("撤销上一次语音输入")
            }

            // System Globe key
            if model.needsInputModeSwitchKey {
                Button {
                    model.triggerHaptic()
                    model.advanceInputModeHandler?()
                } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var hostStatusPill: some View {
        if model.isHostAlive {
            HStack(spacing: 3) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("免切")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.14))
            .clipShape(Capsule())
        } else if let url = AppConfig.deepLinkURL(action: "start-pip") {
            Link(destination: url) {
                HStack(spacing: 3) {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 10))
                    Text("保活")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.15))
                .clipShape(Capsule())
            }
        }
    }

    private var swipeToSwitchGesture: some Gesture {
        DragGesture(minimumDistance: 36, coordinateSpace: .local)
            .onEnded { value in
                guard model.config.enableSwipeToType else { return }
                if abs(value.translation.width) > abs(value.translation.height) * 1.4,
                   abs(value.translation.width) > 48 {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.switchToPanel(.manual)
                    }
                }
            }
    }
}

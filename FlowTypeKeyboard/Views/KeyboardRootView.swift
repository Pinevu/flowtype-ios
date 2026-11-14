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
        .background(
            KeyboardBackgroundView(
                style: model.config.backgroundStyle,
                opacity: model.config.backgroundOpacity,
                hex: model.config.customBackgroundHex,
                scale: model.config.customBackgroundScale,
                offsetX: model.config.customBackgroundOffsetX,
                offsetY: model.config.customBackgroundOffsetY,
                image: model.customBackgroundImage,
                isDark: effectiveColorScheme == .dark
            )
            .equatable()
        )
        .preferredColorScheme(effectiveColorScheme)
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
                // Quick manual layout switch pill & language indicator
                HStack(spacing: 6) {
                    if model.manualLanguage == .chinesePinyin {
                        Button {
                            model.togglePinyinLayoutMode()
                        } label: {
                            HStack(spacing: 4) {
                                Text(model.pinyinLayoutMode == .t9 ? "九宫格" : "26键全拼")
                                Image(systemName: "arrow.left.arrow.right")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.16))
                            .foregroundStyle(.primary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("English")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
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


// MARK: - Background (isolated + equatable so keystrokes never re-render or re-decode it)

struct KeyboardBackgroundView: View, Equatable {
    let style: KeyboardBackgroundStyle
    let opacity: Double
    let hex: String
    let scale: Double
    let offsetX: Double
    let offsetY: Double
    let image: UIImage?
    let isDark: Bool

    static func == (lhs: KeyboardBackgroundView, rhs: KeyboardBackgroundView) -> Bool {
        lhs.style == rhs.style
            && lhs.opacity == rhs.opacity
            && lhs.hex == rhs.hex
            && lhs.scale == rhs.scale
            && lhs.offsetX == rhs.offsetX
            && lhs.offsetY == rhs.offsetY
            && lhs.image === rhs.image
            && lhs.isDark == rhs.isDark
    }

    private var baseSurface: Color {
        isDark
            ? Color(red: 0.11, green: 0.11, blue: 0.13)
            : Color(red: 0.83, green: 0.84, blue: 0.87)
    }

    private func colorFromHex(_ hex: String) -> Color {
        let rgba = AIConfiguration.parseHexRGBA(hex)
        return Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }

    var body: some View {
        ZStack {
            switch style {
            case .system:
                baseSurface.opacity(opacity)
            case .pureDark:
                Color.black.opacity(opacity)
            case .cleanLight:
                Color.white.opacity(opacity)
            case .oceanBlue:
                LinearGradient(
                    colors: [Color(red: 0.08, green: 0.18, blue: 0.36), Color(red: 0.05, green: 0.10, blue: 0.22)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(opacity)
            case .neonPurple:
                LinearGradient(
                    colors: [Color(red: 0.28, green: 0.08, blue: 0.42), Color(red: 0.12, green: 0.04, blue: 0.28)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(opacity)
            case .morandiGrey:
                Color(red: 0.45, green: 0.48, blue: 0.50).opacity(opacity)
            case .cherryPink:
                LinearGradient(
                    colors: [Color(red: 0.98, green: 0.88, blue: 0.90), Color(red: 0.92, green: 0.76, blue: 0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(opacity)
            case .customColor:
                colorFromHex(hex).opacity(opacity)
            case .customImage:
                if let uiImg = image {
                    GeometryReader { geo in
                        let layout = AIConfiguration.computeBackgroundCropLayout(
                            imageWidth: Double(uiImg.size.width),
                            imageHeight: Double(uiImg.size.height),
                            containerWidth: Double(geo.size.width),
                            containerHeight: Double(geo.size.height),
                            scale: scale,
                            normalizedOffsetX: offsetX,
                            normalizedOffsetY: offsetY
                        )

                        Image(uiImage: uiImg)
                            .resizable()
                            .frame(width: layout.drawWidth, height: layout.drawHeight)
                            .offset(x: layout.offsetX, y: layout.offsetY)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .opacity(opacity)
                    }
                } else {
                    colorFromHex(hex).opacity(opacity)
                }
            }
        }
    }
}

import SwiftUI

public struct VoiceKeyboardPanel: View {
    @ObservedObject var model: KeyboardStateModel
    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        VStack(spacing: 10) {
            if !model.hasFullAccess {
                fullAccessBanner
            } else {
                contextAccessoryBar
            }

            Spacer(minLength: 2)

            centerVoiceArea

            if let banner = model.statusBannerMessage, !banner.isEmpty {
                VStack(spacing: 5) {
                    Text(banner)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                    if model.hostStatus.state == .error || KeyboardKeyGestureMap.isAudioSessionConflictError(message: banner) {
                        Button {
                            model.openHostAppForVoiceRecording()
                        } label: {
                            Label("前往主程序激活录音", systemImage: "arrow.up.forward.app.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Color.blue.opacity(0.16))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 2)

            bottomUtilityRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Full Access Warning

    private var fullAccessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            Text("请前往「系统设置 → 键盘 → Lintype语音输入」开启「允许完全访问」以启用语音联动与个人词典")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Context / Mode Accessory Bar

    @ViewBuilder
    private var contextAccessoryBar: some View {
        HStack(spacing: 8) {
            if model.voiceMode == .translate {
                Menu {
                    ForEach(model.config.targetLanguages, id: \.self) { lang in
                        Button {
                            model.selectedTargetLanguage = lang
                        } label: {
                            HStack {
                                Text(lang)
                                if lang == model.selectedTargetLanguage {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                        Text("目标语言：\(model.selectedTargetLanguage)")
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.14))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
                }
            } else if model.voiceMode == .edit || model.voiceMode == .helpMeWrite {
                let count = model.selectedTextPreview.count
                Label(
                    count > 0 ? "已选中 \(count) 字，请说出指令" : "请直接口述指令或补充需求",
                    systemImage: count > 0 ? "text.cursor" : "sparkles"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(keyBackgroundColor.opacity(0.65))
                .clipShape(Capsule())
            } else {
                Text(model.isHostAlive
                     ? "后台保活中 · 轻点即说，无需切出当前应用"
                     : (model.config.autoKeepAlivePiP
                        ? "首次使用将短暂切到主程序开启麦克风与画中画保活"
                        : "首次或系统回收后点语音将短暂打开主程序录音并维持后台保活"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    // MARK: - Center Microphone Control

    @ViewBuilder
    private var centerVoiceArea: some View {
        switch model.hostStatus.state {
        case .recording:
            VStack(spacing: 10) {
                waveformBars(level: model.hostStatus.audioLevel)

                if !model.hostStatus.partialText.isEmpty {
                    Text(model.hostStatus.partialText)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                }

                HStack(spacing: 14) {
                    Button {
                        model.cancelVoiceRecording()
                    } label: {
                        Label("取消", systemImage: "xmark")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(keyBackgroundColor)
                            .foregroundStyle(.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.toggleVoiceRecording()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "stop.fill")
                            Text(String(format: "完成 (%.1fs)", model.hostStatus.elapsedSeconds))
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .background(Color.red)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

        case .transcribing, .polishing:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text(model.hostStatus.state == .transcribing ? "正在转写语音..." : "AI 正在整理润色...")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 112)

        default:
            VStack(spacing: 8) {
                Button {
                    model.toggleVoiceRecording()
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: model.isHostAlive
                                            ? [Color.blue, Color.indigo]
                                            : [Color.blue.opacity(0.18), Color.indigo.opacity(0.18)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 74, height: 74)
                                .shadow(color: .black.opacity(0.14), radius: 6, y: 3)

                            Image(systemName: model.isHostAlive ? "mic.fill" : "mic")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(model.isHostAlive ? .white : .blue)
                        }

                        Text("点击开始「\(model.voiceMode.title)」")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)

                if model.config.enableSwipeToType {
                    Text("左右滑动切出全拼 / 英文键盘")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func waveformBars(level: Float) -> some View {
        let weights: [Double] = [0.35, 0.55, 0.78, 0.95, 1.0, 0.95, 0.78, 0.55, 0.35]
        return HStack(spacing: 5) {
            ForEach(0..<weights.count, id: \.self) { idx in
                let h = max(8.0, min(42.0, 10.0 + Double(level) * 36.0 * weights[idx]))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.red)
                    .frame(width: 5, height: h)
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
        .frame(height: 44)
    }

    // MARK: - Bottom Utility Bar

    private var bottomUtilityRow: some View {
        let isDark = colorScheme == .dark
        let uiPalette = KeyPaletteUIColors(
            isDark: isDark,
            isTranslucent: model.config.backgroundStyle != .system || model.config.backgroundOpacity < 0.98
        )
        let hapticEnabled = model.config.hapticFeedback

        return GeometryReader { geo in
            let spacing: CGFloat = 6
            let wLeft: CGFloat = 68
            let wDel: CGFloat = 52
            let wReturn: CGFloat = 68
            let wSpace = max(60, geo.size.width - wLeft - wDel - wReturn - spacing * 3)

            HStack(spacing: spacing) {
                NativeTactileKey(
                    presentation: NativeKeyPresentation(
                        title: "",
                        systemImage: "keyboard",
                        subtitle: model.manualLanguage == .chinesePinyin ? "拼音" : "EN",
                        fontSize: 13,
                        fontWeight: .medium,
                        subtitleFontSize: 10.5,
                        cornerRadius: 7,
                        fillColor: uiPalette.special,
                        pressedColor: uiPalette.specialPressed,
                        edgeColor: uiPalette.edge,
                        textColor: uiPalette.primaryText,
                        tintColor: uiPalette.primaryText,
                        isDark: isDark,
                        showsPopover: false,
                        participatesInRollover: false,
                        hapticEnabled: hapticEnabled
                    ),
                    onTap: { model.switchToPanel(.manual) },
                    onTouchDown: { model.triggerTouchDownHaptic() }
                )
                .frame(width: wLeft, height: 38)

                NativeSpacebarKey(
                    title: "空格",
                    fontSize: 14,
                    cornerRadius: 7,
                    fillColor: uiPalette.key,
                    pressedColor: uiPalette.keyPressed,
                    edgeColor: uiPalette.edge,
                    textColor: uiPalette.primaryText,
                    hapticEnabled: hapticEnabled,
                    onTouchDown: { model.triggerTouchDownHaptic() },
                    onTap: { model.handleSpaceTap() },
                    onTrackpadDrag: { dx in model.handleSpaceTrackpadDrag(deltaX: dx) },
                    onTrackpadEnd: { model.resetSpaceTrackpad() }
                )
                .frame(width: wSpace, height: 38)

                NativeHoldRepeatKey(
                    systemImage: "delete.left",
                    fontSize: 16,
                    cornerRadius: 7,
                    fillColor: uiPalette.special,
                    pressedColor: uiPalette.specialPressed,
                    edgeColor: uiPalette.edge,
                    tintColor: uiPalette.primaryText,
                    hapticEnabled: hapticEnabled,
                    onTouchDown: { model.triggerTouchDownHaptic() },
                    onTap: { model.handleBackspaceTap() },
                    onHoldStart: { model.startContinuousBackspace() },
                    onHoldEnd: { model.stopContinuousBackspace() }
                )
                .frame(width: wDel, height: 38)

                NativeTactileKey(
                    presentation: NativeKeyPresentation(
                        title: model.returnKeyLabel,
                        fontSize: 14,
                        fontWeight: .semibold,
                        cornerRadius: 7,
                        fillColor: .systemBlue,
                        pressedColor: UIColor.systemBlue.withAlphaComponent(0.75),
                        edgeColor: uiPalette.edge,
                        textColor: .white,
                        isDark: isDark,
                        showsPopover: false,
                        participatesInRollover: false,
                        hapticEnabled: hapticEnabled
                    ),
                    onTap: { model.handleReturnTap() },
                    onTouchDown: { model.triggerTouchDownHaptic() }
                )
                .frame(width: wReturn, height: 38)
            }
        }
        .frame(height: 38)
    }

    private var keyBackgroundColor: Color {
        colorScheme == .dark
            ? Color(white: 0.27)
            : Color.white
    }
}

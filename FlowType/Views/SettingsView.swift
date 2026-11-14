import SwiftUI
import PhotosUI

struct SettingsView: View {
    @EnvironmentObject var coordinator: HostVoiceCoordinator
    @State private var draft: AIConfiguration = AIConfiguration()
    @State private var newLanguage: String = ""
    @State private var showSavedToast = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil

    var body: some View {
        NavigationStack {
            Form {
                asrSection
                llmSection
                promptSection
                translateLanguagesSection
                keyboardBehaviorSection
                appearanceSection
            }
            .navigationTitle("AI 与输入法设置")
            .onAppear {
                draft = coordinator.config
            }
            .onChange(of: draft) { newValue in
                coordinator.saveConfiguration(newValue)
            }
            .onChange(of: selectedPhotoItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        SharedStore.shared.saveCustomBackgroundImage(data)
                        draft.backgroundStyle = .customImage
                        coordinator.saveConfiguration(draft)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        coordinator.saveConfiguration(draft)
                        showSavedToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showSavedToast = false
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if showSavedToast {
                    Text("设置已同步到键盘扩展")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 16)
                }
            }
        }
    }

    // MARK: - 1. ASR Settings

    private var asrSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ASRPreset.presets) { preset in
                        Button(preset.name) {
                            draft.asrProvider = preset.provider
                            draft.asrBaseURL = preset.baseURL
                            draft.asrModel = preset.model
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }

            Picker("识别引擎", selection: $draft.asrProvider) {
                ForEach(ASRProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            if draft.asrProvider != .appleOnDeviceSpeech {
                TextField("ASR Base URL", text: $draft.asrBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                SecureField("ASR API Key", text: $draft.asrAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("ASR 模型（如 whisper-1）", text: $draft.asrModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Picker("识别语言提示", selection: $draft.asrLanguage) {
                Text("自动检测 (Auto)").tag("auto")
                Text("中文 (zh)").tag("zh")
                Text("English (en)").tag("en")
                Text("日本語 (ja)").tag("ja")
                Text("한국어 (ko)").tag("ko")
            }
        } header: {
            Text("语音识别 (ASR) 自定义")
        } footer: {
            Text("支持 OpenAI Whisper、Groq、硅基流动 SenseVoice、Google Gemini 音频直出，以及免 Key 的 Apple 系统语音识别。")
        }
    }

    // MARK: - 2. LLM Settings

    private var llmSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LLMPreset.presets) { preset in
                        Button(preset.name) {
                            draft.llmProvider = preset.provider
                            draft.llmBaseURL = preset.baseURL
                            draft.llmModel = preset.model
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }

            Picker("LLM 接口协议", selection: $draft.llmProvider) {
                ForEach(LLMProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            if draft.llmProvider != .noneRawTranscript {
                TextField("LLM Base URL", text: $draft.llmBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                SecureField("LLM API Key", text: $draft.llmAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("LLM 模型名", text: $draft.llmModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    Text("Temperature: \(String(format: "%.2f", draft.llmTemperature))")
                    Slider(value: $draft.llmTemperature, in: 0...1, step: 0.05)
                }
            }

            Toggle("听写模式自动去口头禅与自纠整理", isOn: $draft.enableSmartCleanup)
        } header: {
            Text("文本润色 / 改写 / 翻译 (LLM) 自定义")
        } footer: {
            Text("支持所有 OpenAI 兼容接口（OpenAI / DeepSeek / Groq / 硅基流动 / 本地 Ollama 等）、Google Gemini 和 Anthropic Claude。")
        }
    }

    // MARK: - 3. Prompts

    private var promptSection: some View {
        Section("自定义提示词 (Prompts)") {
            NavigationLink("听写润色 Prompt") {
                PromptEditorView(
                    title: "听写润色 Prompt",
                    text: $draft.customDictationPrompt,
                    defaultValue: AIConfiguration.defaultDictationPrompt
                )
            }
            NavigationLink("语音改写 (Speak to Edit) Prompt") {
                PromptEditorView(
                    title: "语音改写 Prompt",
                    text: $draft.customEditPrompt,
                    defaultValue: AIConfiguration.defaultEditPrompt
                )
            }
            NavigationLink("实时翻译 Prompt") {
                PromptEditorView(
                    title: "实时翻译 Prompt",
                    text: $draft.customTranslatePrompt,
                    defaultValue: AIConfiguration.defaultTranslatePrompt
                )
            }
            NavigationLink("Help me write 创作 Prompt") {
                PromptEditorView(
                    title: "Help me write Prompt",
                    text: $draft.customHelpWritePrompt,
                    defaultValue: AIConfiguration.defaultHelpWritePrompt
                )
            }
        }
    }

    // MARK: - 4. Translation Target Languages

    private var translateLanguagesSection: some View {
        Section("翻译目标语言预设") {
            Picker("当前默认目标语言", selection: $draft.selectedTargetLanguage) {
                ForEach(draft.targetLanguages, id: \.self) { lang in
                    Text(lang).tag(lang)
                }
            }

            ForEach(draft.targetLanguages, id: \.self) { lang in
                Text(lang)
            }
            .onDelete { offsets in
                draft.targetLanguages.remove(atOffsets: offsets)
                if !draft.targetLanguages.contains(draft.selectedTargetLanguage),
                   let first = draft.targetLanguages.first {
                    draft.selectedTargetLanguage = first
                }
            }

            HStack {
                TextField("新增语言（如：Deutsch）", text: $newLanguage)
                Button("添加") {
                    let trimmed = newLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !draft.targetLanguages.contains(trimmed) {
                        draft.targetLanguages.append(trimmed)
                        newLanguage = ""
                    }
                }
                .disabled(newLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - 5. Keyboard & Keep-Alive Behavior

    private var keyboardBehaviorSection: some View {
        Section("键盘与保活行为") {
            Picker("默认打开面板", selection: $draft.defaultKeyboardTab) {
                ForEach(KeyboardDefaultTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            Picker("中文拼音默认键盘", selection: $draft.defaultPinyinLayout) {
                ForEach(PinyinLayoutMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Toggle("跳转唤醒时自动启动画中画 (PiP)", isOn: $draft.autoKeepAlivePiP)
            Toggle("静音后台音频辅助保活", isOn: $draft.enableAudioBackgroundKeepAlive)
            Toggle("左右滑动切换手打键盘 (Swipe-to-type)", isOn: $draft.enableSwipeToType)
            Toggle("拼音模糊音 (zh/z, ch/c, sh/s, an/ang...)", isOn: $draft.enablePinyinFuzzy)
            Toggle("按键触感反馈", isOn: $draft.hapticFeedback)
            Toggle("双击空格输入句号", isOn: $draft.doubleSpacePeriod)
        }
    }

    // MARK: - 6. Appearance & Custom Background

    private var appearanceSection: some View {
        Section {
            Picker("界面外观", selection: $draft.appearance) {
                ForEach(AppearancePreference.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("键盘背景风格", selection: $draft.backgroundStyle) {
                ForEach(KeyboardBackgroundStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }

            if draft.backgroundStyle == .customColor {
                HStack {
                    Text("自定义色值 Hex")
                    Spacer()
                    TextField("#1E1E2E", text: $draft.customBackgroundHex)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                }
            }

            if draft.backgroundStyle == .customImage {
                VStack(alignment: .leading, spacing: 8) {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("从相册选择自定义背景图片", systemImage: "photo.badge.plus")
                            .font(.subheadline)
                    }
                    if SharedStore.shared.loadCustomBackgroundImageData() != nil {
                        Text("已设置自定义壁纸（点上方可重新选择）")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        Text("尚未选择壁纸，将默认显示预设纯色")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("背景透明度")
                    Spacer()
                    Text("\(Int(draft.backgroundOpacity * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $draft.backgroundOpacity, in: 0.2...1.0, step: 0.05)
            }

            // Keyboard Preview Card
            VStack(alignment: .leading, spacing: 6) {
                Text("输入法背景实时预览")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ZStack {
                    previewBackground
                        .frame(height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(spacing: 5) {
                        HStack(spacing: 4) {
                            ForEach(["1 ，。/'", "2 ABC", "3 DEF"], id: \.self) { title in
                                Text(title)
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 24)
                                    .background(Color.white.opacity(0.75))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        HStack(spacing: 4) {
                            ForEach(["4 GHI", "5 JKL", "6 MNO"], id: \.self) { title in
                                Text(title)
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 24)
                                    .background(Color.white.opacity(0.75))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        HStack(spacing: 4) {
                            Text("123")
                                .font(.system(size: 10))
                                .frame(width: 44, height: 22)
                                .background(Color.white.opacity(0.55))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text("空格 · 九宫格")
                                .font(.system(size: 10))
                                .frame(maxWidth: .infinity)
                                .frame(height: 22)
                                .background(Color.white.opacity(0.85))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text("换行")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 44, height: 22)
                                .background(Color.blue)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .padding(8)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("输入法外观与背景定制")
        } footer: {
            Text("支持自定义纯色、渐变与相册壁纸，可自由调节透明度，键盘将实时同步呈现。")
        }
    }

    @ViewBuilder
    private var previewBackground: some View {
        ZStack {
            Color.gray.opacity(0.2)
            switch draft.backgroundStyle {
            case .system:
                Color(red: 0.83, green: 0.84, blue: 0.87)
            case .pureDark:
                Color.black.opacity(draft.backgroundOpacity)
            case .cleanLight:
                Color.white.opacity(draft.backgroundOpacity)
            case .oceanBlue:
                LinearGradient(
                    colors: [Color(red: 0.08, green: 0.18, blue: 0.36), Color(red: 0.05, green: 0.10, blue: 0.22)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ).opacity(draft.backgroundOpacity)
            case .neonPurple:
                LinearGradient(
                    colors: [Color(red: 0.28, green: 0.08, blue: 0.42), Color(red: 0.12, green: 0.04, blue: 0.28)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ).opacity(draft.backgroundOpacity)
            case .morandiGrey:
                Color(red: 0.45, green: 0.48, blue: 0.50).opacity(draft.backgroundOpacity)
            case .cherryPink:
                LinearGradient(
                    colors: [Color(red: 0.98, green: 0.88, blue: 0.90), Color(red: 0.92, green: 0.76, blue: 0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                ).opacity(draft.backgroundOpacity)
            case .customColor:
                colorFromHex(draft.customBackgroundHex).opacity(draft.backgroundOpacity)
            case .customImage:
                if let data = SharedStore.shared.loadCustomBackgroundImageData(),
                   let uiImg = UIImage(data: data) {
                    Image(uiImage: uiImg)
                        .resizable()
                        .scaledToFill()
                        .opacity(draft.backgroundOpacity)
                        .clipped()
                } else {
                    colorFromHex(draft.customBackgroundHex).opacity(draft.backgroundOpacity)
                }
            }
        }
    }

    private func colorFromHex(_ hex: String) -> Color {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch clean.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 30, 30, 46)
        }
        return Color(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

struct PromptEditorView: View {
    let title: String
    @Binding var text: String
    let defaultValue: String

    var body: some View {
        VStack(spacing: 12) {
            TextEditor(text: $text)
                .font(.callout)
                .padding(8)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("恢复默认") {
                    text = defaultValue
                }
            }
        }
    }
}

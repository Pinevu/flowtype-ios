import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var coordinator: HostVoiceCoordinator
    @State private var draft: AIConfiguration = AIConfiguration()
    @State private var newLanguage: String = ""
    @State private var showSavedToast = false

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
            Toggle("跳转唤醒时自动启动画中画 (PiP)", isOn: $draft.autoKeepAlivePiP)
            Toggle("静音后台音频辅助保活", isOn: $draft.enableAudioBackgroundKeepAlive)
            Toggle("左右滑动切换手打键盘 (Swipe-to-type)", isOn: $draft.enableSwipeToType)
            Toggle("拼音模糊音 (zh/z, ch/c, sh/s, an/ang...)", isOn: $draft.enablePinyinFuzzy)
            Toggle("按键触感反馈", isOn: $draft.hapticFeedback)
            Toggle("双击空格输入句号", isOn: $draft.doubleSpacePeriod)
        }
    }

    // MARK: - 6. Appearance

    private var appearanceSection: some View {
        Section("外观主题") {
            Picker("界面外观", selection: $draft.appearance) {
                ForEach(AppearancePreference.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
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

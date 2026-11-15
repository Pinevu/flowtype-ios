import SwiftUI
import PhotosUI

struct SettingsView: View {
    @EnvironmentObject var coordinator: HostVoiceCoordinator
    @State private var draft: AIConfiguration = AIConfiguration()
    @State private var newLanguage: String = ""
    @State private var showSavedToast = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var customPreviewUIImage: UIImage? = nil
    @State private var showImageEditorSheet = false

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
                reloadCachedPreviewImage()
            }
            .onChange(of: draft) { newValue in
                coordinator.saveConfiguration(newValue)
            }
            .onChange(of: selectedPhotoItem) { item in
                guard let item else { return }
                Task {
                    defer {
                        Task { @MainActor in
                            selectedPhotoItem = nil
                        }
                    }
                    if let rawData = try? await item.loadTransferable(type: Data.self) {
                        let processed = await Task.detached(priority: .userInitiated) {
                            Self.downsampleBackgroundImage(rawData)
                        }.value
                        if let compressed = processed {
                            await MainActor.run {
                                SharedStore.shared.saveCustomBackgroundImage(compressed)
                                customPreviewUIImage = UIImage(data: compressed)
                                draft.backgroundStyle = .customImage
                                draft.customBackgroundScale = 1.0
                                draft.customBackgroundOffsetX = 0.0
                                draft.customBackgroundOffsetY = 0.0
                                draft.customBackgroundRevision += 1
                                coordinator.saveConfiguration(draft)
                                showImageEditorSheet = true
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showImageEditorSheet) {
                if let img = customPreviewUIImage {
                    CustomBackgroundEditorSheet(
                        image: img,
                        initialScale: draft.customBackgroundScale,
                        initialOffsetX: draft.customBackgroundOffsetX,
                        initialOffsetY: draft.customBackgroundOffsetY,
                        backgroundOpacity: draft.backgroundOpacity
                    ) { newScale, newOffsetX, newOffsetY in
                        draft.customBackgroundScale = newScale
                        draft.customBackgroundOffsetX = newOffsetX
                        draft.customBackgroundOffsetY = newOffsetY
                        draft.customBackgroundRevision += 1
                        coordinator.saveConfiguration(draft)
                        showSavedToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showSavedToast = false
                        }
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
                Text("粤语 (yue)").tag("yue")
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
                VStack(alignment: .leading, spacing: 10) {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("从相册选择自定义背景图片", systemImage: "photo.badge.plus")
                            .font(.subheadline)
                    }

                    if customPreviewUIImage != nil {
                        HStack(spacing: 12) {
                            Button {
                                showImageEditorSheet = true
                            } label: {
                                Label("调整放大与拖动位置", systemImage: "crop")
                                    .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button(role: .destructive) {
                                SharedStore.shared.removeCustomBackgroundImage()
                                customPreviewUIImage = nil
                                draft.customBackgroundScale = 1.0
                                draft.customBackgroundOffsetX = 0.0
                                draft.customBackgroundOffsetY = 0.0
                                draft.customBackgroundRevision += 1
                                coordinator.saveConfiguration(draft)
                            } label: {
                                Label("清除图片", systemImage: "trash")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Text("当前缩放 \(String(format: "%.1fx", draft.customBackgroundScale))，可在编辑器中双指放大与拖动对齐")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("尚未选择壁纸，选择图片后可自由放大与拖动裁切位置")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("背景透明度")
                    Spacer()
                    Text("\(Int((draft.backgroundOpacity * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $draft.backgroundOpacity, in: 0.0...1.0, step: 0.01)
            }

            // Proportional Keyboard Preview Card (matches exact 390:293 keyboard ratio)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("输入法等比例实时预览")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("390:293 等比")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                proportionalKeyboardPreview
            }
            .padding(.vertical, 4)
        } header: {
            Text("输入法外观与背景定制")
        } footer: {
            Text("支持 0%–100% 全范围调节背景透明度；相册壁纸支持自由放大拖动裁切，预览与实际键盘等比例同步。")
        }
    }

    private var proportionalKeyboardPreview: some View {
        let previewWidth: CGFloat = 276
        let previewHeight: CGFloat = previewWidth * (293.0 / 390.0)
        let uniformScale: CGFloat = previewWidth / 390.0

        return HStack {
            Spacer()
            ZStack {
                BackgroundCheckerboardView()

                ZStack {
                    previewBackground(width: 390, height: 293)

                    KeyboardNineKeyMockOverlay(
                        isDark: previewPrefersDarkTextScheme,
                        isTranslucent: draft.backgroundStyle != .system || draft.backgroundOpacity < 0.98
                    )
                }
                .frame(width: 390, height: 293)
                .scaleEffect(uniformScale)
                .frame(width: previewWidth, height: previewHeight)
            }
            .frame(width: previewWidth, height: previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            Spacer()
        }
    }

    private var previewPrefersDarkTextScheme: Bool {
        switch draft.appearance {
        case .dark: return true
        case .light: return false
        case .system: return UITraitCollection.current.userInterfaceStyle == .dark
        }
    }

    @ViewBuilder
    private func previewBackground(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            switch draft.backgroundStyle {
            case .system:
                let baseColor = previewPrefersDarkTextScheme
                    ? Color(red: 0.11, green: 0.11, blue: 0.13)
                    : Color(red: 0.83, green: 0.84, blue: 0.87)
                baseColor.opacity(draft.backgroundOpacity)
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
                if let uiImg = customPreviewUIImage {
                    let layout = AIConfiguration.computeBackgroundCropLayout(
                        imageWidth: Double(uiImg.size.width),
                        imageHeight: Double(uiImg.size.height),
                        containerWidth: Double(width),
                        containerHeight: Double(height),
                        scale: draft.customBackgroundScale,
                        normalizedOffsetX: draft.customBackgroundOffsetX,
                        normalizedOffsetY: draft.customBackgroundOffsetY
                    )
                    Image(uiImage: uiImg)
                        .resizable()
                        .frame(width: layout.drawWidth, height: layout.drawHeight)
                        .offset(x: layout.offsetX, y: layout.offsetY)
                        .frame(width: width, height: height)
                        .clipped()
                        .opacity(draft.backgroundOpacity)
                } else {
                    colorFromHex(draft.customBackgroundHex).opacity(draft.backgroundOpacity)
                }
            }
        }
    }

    private func reloadCachedPreviewImage() {
        if let data = SharedStore.shared.loadCustomBackgroundImageData() {
            customPreviewUIImage = UIImage(data: data)
        } else {
            customPreviewUIImage = nil
        }
    }

    nonisolated private static func downsampleBackgroundImage(
        _ rawData: Data,
        maxDimension: CGFloat = 1080,
        maxBytes: Int = 260_000
    ) -> Data? {
        guard let image = UIImage(data: rawData) else { return nil }
        let width = max(1, image.size.width)
        let height = max(1, image.size.height)
        let maxSide = max(width, height)
        let ratio = maxSide > maxDimension ? (maxDimension / maxSide) : 1.0
        let targetSize = CGSize(
            width: max(1, (width * ratio).rounded()),
            height: max(1, (height * ratio).rounded())
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        for quality in [0.78, 0.64, 0.50, 0.36] as [CGFloat] {
            if let jpeg = rendered.jpegData(compressionQuality: quality), jpeg.count <= maxBytes {
                return jpeg
            }
        }
        return rendered.jpegData(compressionQuality: 0.30)
    }

    private func colorFromHex(_ hex: String) -> Color {
        let rgba = AIConfiguration.parseHexRGBA(hex)
        return Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}

private struct BackgroundCheckerboardView: View {
    var cellSize: CGFloat = 11

    var body: some View {
        Canvas { context, size in
            let light = Color(white: 0.96)
            let dark = Color(white: 0.86)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))
            let cols = Int(ceil(size.width / cellSize))
            let rows = Int(ceil(size.height / cellSize))
            for r in 0..<rows {
                for c in 0..<cols where (r + c).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(c) * cellSize,
                        y: CGFloat(r) * cellSize,
                        width: cellSize,
                        height: cellSize
                    )
                    context.fill(Path(rect), with: .color(dark))
                }
            }
        }
    }
}

/// Renders an exact-scale 390x293 mock of the 5x4 Nine-Key layout for true-to-life settings preview & alignment guide.
private struct KeyboardNineKeyMockOverlay: View {
    let isDark: Bool
    let isTranslucent: Bool
    var wireframeOnly: Bool = false

    private var keyFill: Color {
        if wireframeOnly {
            return Color.white.opacity(0.20)
        }
        let base = isDark ? Color(white: 0.29) : Color.white
        return base.opacity(isTranslucent ? 0.90 : 1.0)
    }

    private var specialFill: Color {
        if wireframeOnly {
            return Color.white.opacity(0.12)
        }
        let base = isDark ? Color(white: 0.19) : Color(red: 0.68, green: 0.70, blue: 0.75)
        return base.opacity(isTranslucent ? 0.86 : 1.0)
    }

    private var labelColor: Color {
        wireframeOnly ? .white : (isDark ? .white : .black)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Mock Top Toolbar (38pt)
            HStack(spacing: 8) {
                Text("语音")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.20))
                    .foregroundStyle(wireframeOnly ? .white : .blue)
                    .clipShape(Capsule())

                Text("九宫格")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.18))
                    .foregroundStyle(labelColor.opacity(0.85))
                    .clipShape(Capsule())

                Spacer()

                Text("免切")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
                Image(systemName: "globe")
                    .font(.system(size: 13))
                    .foregroundStyle(labelColor.opacity(0.7))
            }
            .frame(height: 34)
            .padding(.horizontal, 8)

            Divider().opacity(0.22)

            // Mock Candidate Bar (36pt)
            HStack(spacing: 14) {
                ForEach(["的", "一", "我", "你", "在", "是", "了", "不"], id: \.self) { ch in
                    Text(ch)
                        .font(.system(size: 16))
                        .foregroundStyle(labelColor)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(labelColor.opacity(0.6))
            }
            .frame(height: 36)
            .padding(.horizontal, 12)

            Divider().opacity(0.22)

            // Mock 5x4 T9 Grid
            GeometryReader { geo in
                let rowSpacing: CGFloat = 7
                let colSpacing: CGFloat = 6
                let rowHeight = max(24, (geo.size.height - rowSpacing * 3) / 4)
                let span2Height = rowHeight * 2 + rowSpacing
                let colWidth = max(36, (geo.size.width - colSpacing * 4) / 5)
                let span2Width = colWidth * 2 + colSpacing

                HStack(alignment: .top, spacing: colSpacing) {
                    VStack(spacing: rowSpacing) {
                        mockKey("123", width: colWidth, height: rowHeight, fill: specialFill, fontSize: 14)
                        mockKey("#@¥", width: colWidth, height: rowHeight, fill: specialFill, fontSize: 14)
                        mockKey("ABC", width: colWidth, height: span2Height, fill: specialFill, fontSize: 15)
                    }

                    VStack(spacing: rowSpacing) {
                        HStack(spacing: colSpacing) {
                            mockKey(",。?!", width: colWidth, height: rowHeight, fill: keyFill, fontSize: 15)
                            mockKey("ABC", width: colWidth, height: rowHeight, fill: keyFill, fontSize: 16)
                            mockKey("DEF", width: colWidth, height: rowHeight, fill: keyFill, fontSize: 16)
                        }
                        HStack(spacing: colSpacing) {
                            mockKey("GHI", width: colWidth, height: rowHeight, fill: keyFill, fontSize: 16)
                            mockKey("JKL", width: colWidth, height: rowHeight, fill: keyFill, fontSize: 16)
                            mockKey("MNO", width: colWidth, height: rowHeight, fill: keyFill, fontSize: 16)
                        }
                        HStack(spacing: colSpacing) {
                            mockKey("PQRS", width: colWidth, height: rowHeight, fill: keyFill, fontSize: 16)
                            mockKey("TUV", width: colWidth, height: rowHeight, fill: keyFill, fontSize: 16)
                            mockKey("WXYZ", width: colWidth, height: rowHeight, fill: keyFill, fontSize: 16)
                        }
                        HStack(spacing: colSpacing) {
                            mockKey("选拼音", width: colWidth, height: rowHeight, fill: keyFill, fontSize: 13)
                            mockKey("空格", width: span2Width, height: rowHeight, fill: keyFill, fontSize: 13)
                        }
                    }

                    VStack(spacing: rowSpacing) {
                        Image(systemName: "delete.left")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: colWidth, height: rowHeight)
                            .background(specialFill)
                            .foregroundStyle(labelColor)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        mockKey("^_^", width: colWidth, height: rowHeight, fill: specialFill, fontSize: 14)
                        mockKey("换行", width: colWidth, height: span2Height, fill: specialFill, fontSize: 15)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }

    private func mockKey(_ text: String, width: CGFloat, height: CGFloat, fill: Color, fontSize: CGFloat) -> some View {
        Text(text)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(labelColor)
            .frame(width: width, height: height)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct CustomBackgroundEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let image: UIImage
    let backgroundOpacity: Double
    let onSave: (Double, Double, Double) -> Void

    @State private var committedScale: CGFloat
    @State private var committedOffsetX: Double
    @State private var committedOffsetY: Double
    @State private var showKeyOverlay: Bool = true

    @GestureState private var gestureMagnification: CGFloat = 1.0
    @GestureState private var gestureDrag: CGSize = .zero

    init(
        image: UIImage,
        initialScale: Double,
        initialOffsetX: Double,
        initialOffsetY: Double,
        backgroundOpacity: Double,
        onSave: @escaping (Double, Double, Double) -> Void
    ) {
        self.image = image
        self.backgroundOpacity = backgroundOpacity
        self.onSave = onSave
        _committedScale = State(initialValue: CGFloat(max(1.0, min(5.0, initialScale))))
        _committedOffsetX = State(initialValue: initialOffsetX)
        _committedOffsetY = State(initialValue: initialOffsetY)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let boxW = min(358, max(240, geo.size.width - 32))
                let boxH = boxW * (293.0 / 390.0)
                let liveScale = min(5.0, max(1.0, Double(committedScale * gestureMagnification)))
                let candidateNormX = committedOffsetX + Double(gestureDrag.width / max(1, boxW))
                let candidateNormY = committedOffsetY + Double(gestureDrag.height / max(1, boxH))
                let layout = AIConfiguration.computeBackgroundCropLayout(
                    imageWidth: Double(image.size.width),
                    imageHeight: Double(image.size.height),
                    containerWidth: Double(boxW),
                    containerHeight: Double(boxH),
                    scale: liveScale,
                    normalizedOffsetX: candidateNormX,
                    normalizedOffsetY: candidateNormY
                )

                VStack(spacing: 16) {
                    Text("双指缩放或单指拖动图片，调整在键盘区域显示的画面范围")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    ZStack {
                        BackgroundCheckerboardView()

                        Image(uiImage: image)
                            .resizable()
                            .frame(width: layout.drawWidth, height: layout.drawHeight)
                            .offset(x: layout.offsetX, y: layout.offsetY)
                            .frame(width: boxW, height: boxH)
                            .clipped()
                            .opacity(backgroundOpacity)

                        if showKeyOverlay {
                            KeyboardNineKeyMockOverlay(isDark: false, isTranslucent: true, wireframeOnly: true)
                                .frame(width: 390, height: 293)
                                .scaleEffect(boxW / 390.0)
                                .frame(width: boxW, height: boxH)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: boxW, height: boxH)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: 2)
                    )
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .updating($gestureDrag) { value, state, _ in
                                state = value.translation
                            }
                            .onEnded { value in
                                let currentScale = min(5.0, max(1.0, Double(committedScale)))
                                let nextLayout = AIConfiguration.computeBackgroundCropLayout(
                                    imageWidth: Double(image.size.width),
                                    imageHeight: Double(image.size.height),
                                    containerWidth: Double(boxW),
                                    containerHeight: Double(boxH),
                                    scale: currentScale,
                                    normalizedOffsetX: committedOffsetX + Double(value.translation.width / max(1, boxW)),
                                    normalizedOffsetY: committedOffsetY + Double(value.translation.height / max(1, boxH))
                                )
                                committedOffsetX = nextLayout.clampedNormX
                                committedOffsetY = nextLayout.clampedNormY
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .updating($gestureMagnification) { value, state, _ in
                                state = value
                            }
                            .onEnded { value in
                                let nextScale = CGFloat(min(5.0, max(1.0, Double(committedScale * value))))
                                committedScale = nextScale
                                let clamped = AIConfiguration.computeBackgroundCropLayout(
                                    imageWidth: Double(image.size.width),
                                    imageHeight: Double(image.size.height),
                                    containerWidth: Double(boxW),
                                    containerHeight: Double(boxH),
                                    scale: Double(nextScale),
                                    normalizedOffsetX: committedOffsetX,
                                    normalizedOffsetY: committedOffsetY
                                )
                                committedOffsetX = clamped.clampedNormX
                                committedOffsetY = clamped.clampedNormY
                            }
                    )

                    VStack(spacing: 12) {
                        HStack {
                            Text("放大倍数")
                            Spacer()
                            Text(String(format: "%.2fx", Double(committedScale)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 10) {
                            Image(systemName: "minus.magnifyingglass")
                                .foregroundStyle(.secondary)
                            Slider(value: $committedScale, in: 1.0...5.0, step: 0.05)
                                .onChange(of: committedScale) { nextVal in
                                    let clamped = AIConfiguration.computeBackgroundCropLayout(
                                        imageWidth: Double(image.size.width),
                                        imageHeight: Double(image.size.height),
                                        containerWidth: Double(boxW),
                                        containerHeight: Double(boxH),
                                        scale: Double(nextVal),
                                        normalizedOffsetX: committedOffsetX,
                                        normalizedOffsetY: committedOffsetY
                                    )
                                    committedOffsetX = clamped.clampedNormX
                                    committedOffsetY = clamped.clampedNormY
                                }
                            Image(systemName: "plus.magnifyingglass")
                                .foregroundStyle(.secondary)
                        }

                        Toggle("显示九宫格按键参考线", isOn: $showKeyOverlay)
                            .font(.subheadline)

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                committedScale = 1.0
                                committedOffsetX = 0.0
                                committedOffsetY = 0.0
                            }
                        } label: {
                            Label("重置居中与默认大小", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 20)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
                .navigationTitle("调整壁纸显示区域")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            let finalScale = min(5.0, max(1.0, Double(committedScale)))
                            let finalLayout = AIConfiguration.computeBackgroundCropLayout(
                                imageWidth: Double(image.size.width),
                                imageHeight: Double(image.size.height),
                                containerWidth: Double(boxW),
                                containerHeight: Double(boxH),
                                scale: finalScale,
                                normalizedOffsetX: committedOffsetX,
                                normalizedOffsetY: committedOffsetY
                            )
                            onSave(finalScale, finalLayout.clampedNormX, finalLayout.clampedNormY)
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
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

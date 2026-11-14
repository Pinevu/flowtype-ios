import Foundation

public enum ASRProviderKind: String, Codable, CaseIterable, Identifiable {
    case openAIWhisperCompatible = "openai_whisper"
    case appleOnDeviceSpeech = "apple_speech"
    case geminiAudioDirect = "gemini_audio"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAIWhisperCompatible: return "OpenAI 兼容接口 (Whisper / Groq / 硅基流动)"
        case .appleOnDeviceSpeech: return "Apple 系统语音识别 (本地/免费)"
        case .geminiAudioDirect: return "Google Gemini 原生多模态音频直出"
        }
    }
}

public enum LLMProviderKind: String, Codable, CaseIterable, Identifiable {
    case openAICompatible = "openai_chat"
    case geminiNative = "gemini_native"
    case anthropicClaude = "anthropic_claude"
    case noneRawTranscript = "raw_only"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容 (OpenAI / DeepSeek / Groq / Ollama)"
        case .geminiNative: return "Google Gemini API"
        case .anthropicClaude: return "Anthropic Claude API"
        case .noneRawTranscript: return "跳过 LLM（直接输出识别原文）"
        }
    }
}

public enum VoiceActionMode: String, Codable, CaseIterable, Identifiable {
    case dictate
    case edit
    case translate
    case helpMeWrite

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dictate: return "听写"
        case .edit: return "改写"
        case .translate: return "翻译"
        case .helpMeWrite: return "帮写"
        }
    }

    public var systemImage: String {
        switch self {
        case .dictate: return "mic.fill"
        case .edit: return "wand.and.stars"
        case .translate: return "globe"
        case .helpMeWrite: return "sparkles"
        }
    }
}

public enum KeyboardDefaultTab: String, Codable, CaseIterable, Identifiable {
    case voice
    case pinyin
    case english

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .voice: return "语音面板"
        case .pinyin: return "中文拼音"
        case .english: return "英文全键盘"
        }
    }
}

public enum AppearancePreference: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

public struct AIConfiguration: Codable, Equatable {
    // MARK: - ASR Settings
    public var asrProvider: ASRProviderKind
    public var asrBaseURL: String
    public var asrAPIKey: String
    public var asrModel: String
    public var asrLanguage: String

    // MARK: - LLM Settings
    public var llmProvider: LLMProviderKind
    public var llmBaseURL: String
    public var llmAPIKey: String
    public var llmModel: String
    public var llmTemperature: Double

    // MARK: - Smart Writing & Prompts
    public var enableSmartCleanup: Bool
    public var customDictationPrompt: String
    public var customEditPrompt: String
    public var customTranslatePrompt: String
    public var customHelpWritePrompt: String

    // MARK: - Translation Languages
    public var targetLanguages: [String]
    public var selectedTargetLanguage: String

    // MARK: - Keyboard & Keep-Alive Preferences
    public var autoKeepAlivePiP: Bool
    public var enableAudioBackgroundKeepAlive: Bool
    public var defaultKeyboardTab: KeyboardDefaultTab
    public var enableSwipeToType: Bool
    public var hapticFeedback: Bool
    public var doubleSpacePeriod: Bool
    public var enablePinyinFuzzy: Bool
    public var appearance: AppearancePreference

    public init(
        asrProvider: ASRProviderKind = .openAIWhisperCompatible,
        asrBaseURL: String = "https://api.openai.com/v1",
        asrAPIKey: String = "",
        asrModel: String = "whisper-1",
        asrLanguage: String = "auto",
        llmProvider: LLMProviderKind = .openAICompatible,
        llmBaseURL: String = "https://api.openai.com/v1",
        llmAPIKey: String = "",
        llmModel: String = "gpt-4o-mini",
        llmTemperature: Double = 0.2,
        enableSmartCleanup: Bool = true,
        customDictationPrompt: String = Self.defaultDictationPrompt,
        customEditPrompt: String = Self.defaultEditPrompt,
        customTranslatePrompt: String = Self.defaultTranslatePrompt,
        customHelpWritePrompt: String = Self.defaultHelpWritePrompt,
        targetLanguages: [String] = ["English", "简体中文", "日本語", "한국어", "Español", "Français"],
        selectedTargetLanguage: String = "English",
        autoKeepAlivePiP: Bool = true,
        enableAudioBackgroundKeepAlive: Bool = false,
        defaultKeyboardTab: KeyboardDefaultTab = .voice,
        enableSwipeToType: Bool = true,
        hapticFeedback: Bool = true,
        doubleSpacePeriod: Bool = true,
        enablePinyinFuzzy: Bool = false,
        appearance: AppearancePreference = .system
    ) {
        self.asrProvider = asrProvider
        self.asrBaseURL = asrBaseURL
        self.asrAPIKey = asrAPIKey
        self.asrModel = asrModel
        self.asrLanguage = asrLanguage
        self.llmProvider = llmProvider
        self.llmBaseURL = llmBaseURL
        self.llmAPIKey = llmAPIKey
        self.llmModel = llmModel
        self.llmTemperature = llmTemperature
        self.enableSmartCleanup = enableSmartCleanup
        self.customDictationPrompt = customDictationPrompt
        self.customEditPrompt = customEditPrompt
        self.customTranslatePrompt = customTranslatePrompt
        self.customHelpWritePrompt = customHelpWritePrompt
        self.targetLanguages = targetLanguages
        self.selectedTargetLanguage = selectedTargetLanguage
        self.autoKeepAlivePiP = autoKeepAlivePiP
        self.enableAudioBackgroundKeepAlive = enableAudioBackgroundKeepAlive
        self.defaultKeyboardTab = defaultKeyboardTab
        self.enableSwipeToType = enableSwipeToType
        self.hapticFeedback = hapticFeedback
        self.doubleSpacePeriod = doubleSpacePeriod
        self.enablePinyinFuzzy = enablePinyinFuzzy
        self.appearance = appearance
    }

    public static let defaultDictationPrompt = """
你是智能语音听写润色助手。请将用户的口述识别原文整理成自然、通顺、可直接发送的书面文字：
1. 去除“嗯、呃、啊、那个、就是说”等无意义口头禅和重复卡顿。
2. 识别用户中途改口或自我纠正（例如“明天三点……不对改到四点半”），只保留最终真实意图。
3. 自动补充准确的标点符号；如口述包含步骤或清单，自动整理为清晰的换行列表。
4. 严格尊重个人词典中的人名、产品名和专有名词拼写，不编造未提及的内容。
5. 只输出整理后的最终文本，不要加任何解释、引号或前缀。
"""

    public static let defaultEditPrompt = """
你是智能语音文本编辑助手。用户会提供【待修改文本】和【语音修改指令】。
请严格按照语音指令对文本进行修改（如调整语气、精简、扩写、改错别字、调整格式或直接根据要求撰写回复）。
只输出修改后的最终文本，不要输出解释性说明。
"""

    public static let defaultTranslatePrompt = """
你是母语级实时口语翻译助手。请先去除用户口述中的口头禅与中途改口，然后将其自然、地道地翻译成目标语言。
保持原意与说话语气（正式/轻松），符合目标语言母语者日常表达习惯。只输出译文。
"""

    public static let defaultHelpWritePrompt = """
你是高效写作助手。根据用户口述的简短意图（收件人、核心信息、风格要求）以及上下文，直接生成完整、得体、可直接发送的邮件、消息或文案。
只输出最终正文内容，不要多余说明。
"""
}

public struct ASRPreset: Identifiable {
    public let id: String
    public let name: String
    public let provider: ASRProviderKind
    public let baseURL: String
    public let model: String

    public static let presets: [ASRPreset] = [
        ASRPreset(id: "openai", name: "OpenAI Whisper", provider: .openAIWhisperCompatible, baseURL: "https://api.openai.com/v1", model: "whisper-1"),
        ASRPreset(id: "groq", name: "Groq Whisper Turbo", provider: .openAIWhisperCompatible, baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo"),
        ASRPreset(id: "siliconflow", name: "硅基流动 SenseVoice", provider: .openAIWhisperCompatible, baseURL: "https://api.siliconflow.cn/v1", model: "FunAudioLLM/SenseVoiceSmall"),
        ASRPreset(id: "gemini_audio", name: "Google Gemini 直出", provider: .geminiAudioDirect, baseURL: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-2.5-flash"),
        ASRPreset(id: "apple", name: "Apple 系统语音 (本地)", provider: .appleOnDeviceSpeech, baseURL: "", model: "system-speech")
    ]
}

public struct LLMPreset: Identifiable {
    public let id: String
    public let name: String
    public let provider: LLMProviderKind
    public let baseURL: String
    public let model: String

    public static let presets: [LLMPreset] = [
        LLMPreset(id: "openai", name: "OpenAI GPT-4o-mini", provider: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini"),
        LLMPreset(id: "deepseek", name: "DeepSeek Chat", provider: .openAICompatible, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
        LLMPreset(id: "siliconflow", name: "硅基流动 Qwen", provider: .openAICompatible, baseURL: "https://api.siliconflow.cn/v1", model: "Qwen/Qwen2.5-72B-Instruct"),
        LLMPreset(id: "groq", name: "Groq Llama 3.3", provider: .openAICompatible, baseURL: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile"),
        LLMPreset(id: "gemini", name: "Google Gemini 2.5 Flash", provider: .geminiNative, baseURL: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-2.5-flash"),
        LLMPreset(id: "claude", name: "Anthropic Claude Haiku", provider: .anthropicClaude, baseURL: "https://api.anthropic.com/v1", model: "claude-3-5-haiku-latest"),
        LLMPreset(id: "ollama", name: "本地 Ollama", provider: .openAICompatible, baseURL: "http://127.0.0.1:11434/v1", model: "qwen2.5:7b")
    ]
}

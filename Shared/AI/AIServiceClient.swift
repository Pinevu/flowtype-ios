import Foundation

public enum AIServiceError: LocalizedError {
    case missingAPIKey(String)
    case invalidEndpoint(String)
    case emptyAudio
    case serverError(Int, String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let target):
            return "未配置 \(target) API Key，请在 FlowType 主程序「设置」中填写。"
        case .invalidEndpoint(let url):
            return "无效的接口地址：\(url)"
        case .emptyAudio:
            return "未采集到有效语音，请靠近麦克风再试一次。"
        case .serverError(let code, let detail):
            return "AI 接口返回错误 (\(code))：\(detail)"
        case .invalidResponse(let detail):
            return "无法解析 AI 返回内容：\(detail)"
        }
    }
}

public enum PromptComposer {
    public static func systemPrompt(
        mode: VoiceActionMode,
        config: AIConfiguration,
        personalWords: [PersonalWord],
        targetLanguage: String
    ) -> String {
        var base: String
        switch mode {
        case .dictate:
            base = config.customDictationPrompt
        case .edit:
            base = config.customEditPrompt
        case .translate:
            base = config.customTranslatePrompt + "\n目标语言：\(targetLanguage)"
        case .helpMeWrite:
            base = config.customHelpWritePrompt
        }

        if !personalWords.isEmpty {
            let terms = personalWords.prefix(60).map { word -> String in
                if word.pinyinHint.isEmpty {
                    return word.term
                }
                return "\(word.term)(\(word.pinyinHint))"
            }.joined(separator: "、")
            base += "\n\n【个人词典（若发音相近请优先采用以下专有写法）】\n\(terms)"
        }

        return base
    }

    public static func userMessage(
        mode: VoiceActionMode,
        transcript: String,
        selectedText: String,
        contextBefore: String
    ) -> String {
        switch mode {
        case .dictate:
            if contextBefore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "口述识别原文：\n\(transcript)"
            }
            return "光标前已有上下文：\n\(contextBefore.suffix(300))\n\n本次口述识别原文：\n\(transcript)"

        case .edit:
            let sourceText = selectedText.isEmpty ? contextBefore : selectedText
            if sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "语音修改/写作指令：\n\(transcript)"
            }
            return "【待修改文本】\n\(sourceText)\n\n【语音修改指令】\n\(transcript)"

        case .translate:
            return "请翻译以下口述内容：\n\(transcript)"

        case .helpMeWrite:
            let ctx = selectedText.isEmpty ? contextBefore : selectedText
            if ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "【创作指令】\n\(transcript)"
            }
            return "【参考上下文/待处理文本】\n\(ctx.suffix(500))\n\n【创作指令】\n\(transcript)"
        }
    }

    public static func whisperHotwordPrompt(personalWords: [PersonalWord]) -> String {
        guard !personalWords.isEmpty else { return "" }
        return personalWords.prefix(40).map(\.term).joined(separator: ", ")
    }
}

public final class AIServiceClient {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 45
            cfg.timeoutIntervalForResource = 90
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - Transcription (ASR)

    public func transcribeAudio(
        wavData: Data,
        config: AIConfiguration,
        personalWords: [PersonalWord]
    ) async throws -> String {
        guard wavData.count > 44 else {
            throw AIServiceError.emptyAudio
        }

        switch config.asrProvider {
        case .openAIWhisperCompatible:
            return try await transcribeOpenAIWhisper(wavData: wavData, config: config, personalWords: personalWords)
        case .geminiAudioDirect:
            return try await transcribeWithGemini(wavData: wavData, config: config, personalWords: personalWords)
        case .appleOnDeviceSpeech:
            throw AIServiceError.invalidResponse("Apple 系统语音识别由 AudioCaptureService 直接流式处理")
        }
    }

    public static func modelPrefersNoPrompt(_ model: String) -> Bool {
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.contains("grok")
            || lower.contains("sensevoice")
            || lower.contains("paraformer")
            || lower.contains("glm-asr")
            || lower.contains("voxtral")
            || (lower.contains("qwen") && lower.contains("asr"))
    }

    public static func buildOpenAIWhisperMultipartBody(
        wavData: Data,
        model: String,
        language: String?,
        prompt: String?,
        boundary: String
    ) -> Data {
        var body = Data()

        func appendField(name: String, value: String) {
            body.append(contentsOf: "--\(boundary)\r\n".utf8)
            body.append(contentsOf: "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
            body.append(contentsOf: "\(value)\r\n".utf8)
        }

        appendField(name: "model", value: model.isEmpty ? "whisper-1" : model)
        if let language, !language.isEmpty, language != "auto" {
            appendField(name: "language", value: language)
        }
        if let prompt, !prompt.isEmpty {
            appendField(name: "prompt", value: prompt)
        }

        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: audio/wav\r\n\r\n".utf8)
        body.append(wavData)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        return body
    }

    public static func parseOpenAITranscriptResponse(data: Data) throws -> String {
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let dict = json as? [String: Any] {
                if let errorValue = dict["error"] {
                    let message: String
                    if let errorDict = errorValue as? [String: Any] {
                        message = (errorDict["message"] as? String)
                            ?? (errorDict["code"] as? String)
                            ?? String(describing: errorDict)
                    } else if let errorText = errorValue as? String {
                        message = errorText
                    } else {
                        message = String(describing: errorValue)
                    }
                    throw AIServiceError.serverError(200, String(message.prefix(300)))
                }

                for key in ["text", "transcript", "result", "output", "content"] {
                    if let text = dict[key] as? String {
                        return text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }

                if let nestedData = dict["data"] as? [String: Any] {
                    for key in ["text", "transcript", "result", "content"] {
                        if let text = nestedData[key] as? String {
                            return text.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }

                if let nestedResult = dict["result"] as? [String: Any] {
                    for key in ["text", "transcript", "content"] {
                        if let text = nestedResult[key] as? String {
                            return text.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }

                if let results = dict["results"] as? [[String: Any]], let first = results.first {
                    for key in ["transcript", "text", "content"] {
                        if let text = first[key] as? String {
                            return text.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    if let alts = first["alternatives"] as? [[String: Any]],
                       let transcript = alts.first?["transcript"] as? String {
                        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }

                if let choices = dict["choices"] as? [[String: Any]], let first = choices.first {
                    if let message = first["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        return content.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if let text = first["text"] as? String {
                        return text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }

                throw AIServiceError.invalidResponse("ASR JSON 未包含 text/transcript 字段")
            }

            if let text = json as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let plain = String(data: data, encoding: .utf8) {
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let lower = trimmed.lowercased()
                if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") {
                    throw AIServiceError.invalidResponse("接口返回了 HTML 页面，请检查 ASR 接口地址是否正确")
                }
                return trimmed
            }
        }

        throw AIServiceError.invalidResponse("ASR 未返回 text 字段")
    }

    private func transcribeOpenAIWhisper(
        wavData: Data,
        config: AIConfiguration,
        personalWords: [PersonalWord]
    ) async throws -> String {
        let key = config.asrAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty && !isLocalURL(config.asrBaseURL) {
            throw AIServiceError.missingAPIKey("ASR 语音识别")
        }
        guard let primaryURL = buildURL(base: config.asrBaseURL, suffix: "audio/transcriptions"),
              primaryURL.host != nil else {
            throw AIServiceError.invalidEndpoint(config.asrBaseURL)
        }

        let cleanBase = Self.normalizedBase(config.asrBaseURL)
        let model = config.asrModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "whisper-1"
            : config.asrModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLang = config.asrLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        var currentLanguage: String? = (rawLang.isEmpty || rawLang == "auto") ? nil : rawLang
        let hotwords = PromptComposer.whisperHotwordPrompt(personalWords: personalWords)
        var currentPrompt: String? = (hotwords.isEmpty || Self.modelPrefersNoPrompt(model)) ? nil : hotwords

        var targetURL = primaryURL
        let v1FallbackURL: URL? = {
            guard let baseURL = URL(string: cleanBase),
                  baseURL.path.isEmpty || baseURL.path == "/" else {
                return nil
            }
            return buildURL(base: "\(cleanBase)/v1", suffix: "audio/transcriptions")
        }()
        var triedV1Fallback = false

        for _ in 0..<4 {
            let boundary = "FlowTypeBoundary-\(UUID().uuidString)"
            let body = Self.buildOpenAIWhisperMultipartBody(
                wavData: wavData,
                model: model,
                language: currentLanguage,
                prompt: currentPrompt,
                boundary: boundary
            )

            var request = URLRequest(url: targetURL)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = body

            let (data, response) = try await session.data(for: request)
            do {
                try validateHTTP(response: response, data: data)
                let text = try Self.parseOpenAITranscriptResponse(data: data)
                guard !text.isEmpty else {
                    throw AIServiceError.emptyAudio
                }
                return text
            } catch let AIServiceError.serverError(statusCode, detail) {
                if statusCode == 404, !triedV1Fallback, let fallback = v1FallbackURL {
                    triedV1Fallback = true
                    targetURL = fallback
                    continue
                }

                let lower = detail.lowercased()
                let isParamStatus = (statusCode == 400 || statusCode == 422)
                    || (statusCode == 200 && (lower.contains("unsupported") || lower.contains("prompt") || lower.contains("parameter")))

                if isParamStatus && currentPrompt != nil {
                    currentPrompt = nil
                    continue
                }
                if isParamStatus && currentLanguage != nil {
                    currentLanguage = nil
                    continue
                }
                throw AIServiceError.serverError(statusCode, detail)
            }
        }

        throw AIServiceError.invalidResponse("ASR 请求重试后仍失败")
    }

    private func transcribeWithGemini(
        wavData: Data,
        config: AIConfiguration,
        personalWords: [PersonalWord]
    ) async throws -> String {
        let key = config.asrAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw AIServiceError.missingAPIKey("Gemini ASR")
        }
        let model = config.asrModel.isEmpty ? "gemini-2.5-flash" : config.asrModel
        let base = normalizedBase(config.asrBaseURL.isEmpty ? "https://generativelanguage.googleapis.com/v1beta" : config.asrBaseURL)
        guard let url = URL(string: "\(base)/models/\(model):generateContent?key=\(key)") else {
            throw AIServiceError.invalidEndpoint(base)
        }

        let hotwords = PromptComposer.whisperHotwordPrompt(personalWords: personalWords)
        var prompt = "请逐字准确转录这段语音内容，只输出转录文字本身，不要添加说明。"
        if !hotwords.isEmpty {
            prompt += " 参考词典：\(hotwords)"
        }

        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        ["inline_data": ["mime_type": "audio/wav", "data": wavData.base64EncodedString()]]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)
        return try parseGeminiText(data: data)
    }

    // MARK: - LLM Post-Processing (Polish / Edit / Translate / Help Me Write)

    public func processTranscript(
        transcript: String,
        mode: VoiceActionMode,
        selectedText: String,
        contextBefore: String,
        targetLanguage: String,
        config: AIConfiguration,
        personalWords: [PersonalWord]
    ) async throws -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AIServiceError.emptyAudio
        }

        if config.llmProvider == .noneRawTranscript || (!config.enableSmartCleanup && mode == .dictate) {
            return trimmed
        }

        let systemPrompt = PromptComposer.systemPrompt(
            mode: mode,
            config: config,
            personalWords: personalWords,
            targetLanguage: targetLanguage
        )
        let userMessage = PromptComposer.userMessage(
            mode: mode,
            transcript: trimmed,
            selectedText: selectedText,
            contextBefore: contextBefore
        )

        switch config.llmProvider {
        case .openAICompatible:
            return try await callOpenAIChat(system: systemPrompt, user: userMessage, config: config)
        case .geminiNative:
            return try await callGeminiText(system: systemPrompt, user: userMessage, config: config)
        case .anthropicClaude:
            return try await callAnthropicClaude(system: systemPrompt, user: userMessage, config: config)
        case .noneRawTranscript:
            return trimmed
        }
    }

    private func callOpenAIChat(system: String, user: String, config: AIConfiguration) async throws -> String {
        let key = config.llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty && !isLocalURL(config.llmBaseURL) {
            throw AIServiceError.missingAPIKey("LLM 大模型")
        }
        guard let url = buildURL(base: config.llmBaseURL, suffix: "chat/completions") else {
            throw AIServiceError.invalidEndpoint(config.llmBaseURL)
        }

        let payload: [String: Any] = [
            "model": config.llmModel.isEmpty ? "gpt-4o-mini" : config.llmModel,
            "temperature": config.llmTemperature,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw AIServiceError.invalidResponse("choices 为空")
        }
        return content
    }

    private func callGeminiText(system: String, user: String, config: AIConfiguration) async throws -> String {
        let key = config.llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw AIServiceError.missingAPIKey("Gemini LLM")
        }
        let model = config.llmModel.isEmpty ? "gemini-2.5-flash" : config.llmModel
        let base = normalizedBase(config.llmBaseURL.isEmpty ? "https://generativelanguage.googleapis.com/v1beta" : config.llmBaseURL)
        guard let url = URL(string: "\(base)/models/\(model):generateContent?key=\(key)") else {
            throw AIServiceError.invalidEndpoint(base)
        }

        let payload: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["parts": [["text": user]]]],
            "generationConfig": ["temperature": config.llmTemperature]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)
        return try parseGeminiText(data: data)
    }

    private func callAnthropicClaude(system: String, user: String, config: AIConfiguration) async throws -> String {
        let key = config.llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw AIServiceError.missingAPIKey("Anthropic Claude")
        }
        guard let url = buildURL(base: config.llmBaseURL.isEmpty ? "https://api.anthropic.com/v1" : config.llmBaseURL, suffix: "messages") else {
            throw AIServiceError.invalidEndpoint(config.llmBaseURL)
        }

        let payload: [String: Any] = [
            "model": config.llmModel.isEmpty ? "claude-3-5-haiku-latest" : config.llmModel,
            "max_tokens": 2048,
            "temperature": config.llmTemperature,
            "system": system,
            "messages": [
                ["role": "user", "content": user]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)

        struct ClaudeResponse: Decodable {
            struct Block: Decodable {
                let type: String
                let text: String?
            }
            let content: [Block]
        }

        let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        let text = decoded.content.compactMap(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AIServiceError.invalidResponse("Claude 返回内容为空")
        }
        return text
    }

    // MARK: - Helpers

    private func parseGeminiText(data: Data) throws -> String {
        struct GeminiResponse: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]
                }
                let content: Content
            }
            let candidates: [Candidate]?
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let text = decoded.candidates?.first?.content.parts.compactMap(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw AIServiceError.invalidResponse("Gemini 返回为空")
        }
        return text
    }

    private func validateHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse("非 HTTP 响应")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIServiceError.serverError(http.statusCode, String(body.prefix(300)))
        }
    }

    public static func normalizedBase(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if !s.contains("://") {
            let scheme = isLocalURL(s) ? "http://" : "https://"
            s = scheme + s
        }
        while s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }

    public static func buildOpenAIURL(base: String, suffix: String) -> URL? {
        let cleanBase = normalizedBase(base)
        guard !cleanBase.isEmpty else { return nil }
        if cleanBase.hasSuffix("/" + suffix) {
            return URL(string: cleanBase)
        }
        return URL(string: "\(cleanBase)/\(suffix)")
    }

    public static func isLocalURL(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("127.0.0.1")
            || lower.contains("localhost")
            || lower.contains("192.168.")
            || lower.contains(".local")
            || lower.contains("[::1]")
            || lower.contains("0.0.0.0")
    }

    private func normalizedBase(_ raw: String) -> String {
        Self.normalizedBase(raw)
    }

    private func buildURL(base: String, suffix: String) -> URL? {
        Self.buildOpenAIURL(base: base, suffix: suffix)
    }

    private func isLocalURL(_ raw: String) -> Bool {
        Self.isLocalURL(raw)
    }
}

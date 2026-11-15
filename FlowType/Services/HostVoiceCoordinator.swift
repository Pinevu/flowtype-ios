import Combine
import Foundation
import SwiftUI

@MainActor
public final class HostVoiceCoordinator: ObservableObject {
    @Published public var config: AIConfiguration
    @Published public var dictionary: [PersonalWord]
    @Published public var history: [HistoryRecord]
    @Published public var status: HostRuntimeStatus
    @Published public var selectedTab: Int = 0
    @Published public var lastQuickTestResult: String = ""
    @Published public var lastQuickTestRaw: String = ""
    @Published public var onlineLexiconEntries: [OnlineLexiconEntry] = []
    @Published public var isSyncingOnlineLexicon: Bool = false

    public let pipManager = PiPKeepAliveManager()
    private let audioService = AudioCaptureService()
    private let aiClient = AIServiceClient()
    private let notifyBridge = DarwinNotificationBridge()
    private let store = SharedStore.shared

    private var heartbeatTimer: Timer?
    private var meterTimer: Timer?
    private var recordingStartTime: Date?
    private var latestAudioLevel: Float = 0
    private var latestPartialText: String = ""
    private var activeCommand: VoiceCommandPayload?
    private var lastHandledCommandId: UUID?
    private var pipCancellable: AnyCancellable?

    public init() {
        let loadedConfig = store.loadConfig()
        self.config = loadedConfig
        self.dictionary = store.loadDictionary()
        self.history = store.loadHistory()
        self.onlineLexiconEntries = store.loadOnlineLexiconSnapshot()?.entries ?? []
        self.status = HostRuntimeStatus(
            state: .idle,
            isPiPActive: false,
            isAudioKeepAliveActive: loadedConfig.enableAudioBackgroundKeepAlive,
            heartbeatAt: Date()
        )

        setupAudioCallbacks()
        setupDarwinObservers()
        setupPiPObserver()
        startHeartbeatTimer()

        if loadedConfig.enableAudioBackgroundKeepAlive {
            audioService.startSilentKeepAliveIfNeeded(enabled: true)
            self.status.isAudioKeepAliveActive = audioService.isSilentKeepAliveRunning
            if self.status.isAudioKeepAliveActive {
                self.status.state = .standbyPiP
            }
            publishStatus()
        }

        let storeRef = self.store
        Task.detached(priority: .utility) {
            LexiconDatabase.shared.syncOnlineLexiconIfNeeded(store: storeRef)
        }
        if loadedConfig.onlineLexiconAutoSync,
           !loadedConfig.onlineLexiconURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let needsAutoRefresh: Bool
            if let lastSync = loadedConfig.onlineLexiconLastSyncAt {
                needsAutoRefresh = Date().timeIntervalSince(lastSync) > 900
            } else {
                needsAutoRefresh = true
            }
            if needsAutoRefresh {
                Task { [weak self] in
                    await self?.syncOnlineLexicon()
                }
            }
        }
    }

    deinit {
        heartbeatTimer?.invalidate()
        meterTimer?.invalidate()
    }

    // MARK: - Setup

    private func setupAudioCallbacks() {
        audioService.onAudioLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.latestAudioLevel = level
            }
        }
        audioService.onPartialTranscript = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.latestPartialText = text
            }
        }
    }

    private func setupPiPObserver() {
        pipCancellable = pipManager.$isPiPActive.sink { [weak self] active in
            guard let self else { return }
            self.status.isPiPActive = active
            if active && self.status.state == .idle {
                self.status.state = .standbyPiP
            } else if !active && self.status.state == .standbyPiP && !self.config.enableAudioBackgroundKeepAlive {
                self.status.state = .idle
            }
            self.publishStatus()
        }
    }

    private func setupDarwinObservers() {
        notifyBridge.addObserver(name: AppConfig.Notify.commandPosted) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleIncomingCommand()
            }
        }
        notifyBridge.addObserver(name: AppConfig.Notify.configChanged) { [weak self] in
            Task { @MainActor [weak self] in
                self?.reloadFromStore()
            }
        }
    }

    private func startHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status.heartbeatAt = Date()
                self.status.isPiPActive = self.pipManager.isPiPActive
                if self.config.enableAudioBackgroundKeepAlive && self.status.state != .recording && !self.audioService.isSilentKeepAliveRunning {
                    self.audioService.startSilentKeepAliveIfNeeded(enabled: true)
                }
                self.status.isAudioKeepAliveActive = self.audioService.isSilentKeepAliveRunning
                if self.status.state == .recording, let start = self.recordingStartTime {
                    let elapsed = Date().timeIntervalSince(start)
                    self.status.elapsedSeconds = elapsed
                    self.status.audioLevel = self.latestAudioLevel
                    self.status.partialText = self.latestPartialText
                    self.pipManager.updateDisplay(state: .recording, level: self.latestAudioLevel, elapsed: elapsed)
                }
                self.store.saveStatus(self.status)
            }
        }
    }

    // MARK: - Store & Configuration Updates

    public func reloadFromStore() {
        config = store.loadConfig()
        dictionary = store.loadDictionary()
        history = store.loadHistory()
        audioService.startSilentKeepAliveIfNeeded(enabled: config.enableAudioBackgroundKeepAlive)
        status.isAudioKeepAliveActive = audioService.isSilentKeepAliveRunning
    }

    public func saveConfiguration(_ updated: AIConfiguration) {
        config = updated
        store.saveConfig(updated)
        audioService.startSilentKeepAliveIfNeeded(enabled: updated.enableAudioBackgroundKeepAlive)
        status.isAudioKeepAliveActive = audioService.isSilentKeepAliveRunning
        notifyBridge.post(name: AppConfig.Notify.configChanged)
        publishStatus()
    }

    public func toggleAudioBackgroundKeepAlive() {
        var updated = config
        updated.enableAudioBackgroundKeepAlive.toggle()
        saveConfiguration(updated)
    }

    public func addWord(term: String, pinyinHint: String, category: WordCategory) {
        _ = store.addOrLearnWord(term: term, pinyinHint: pinyinHint, category: category, autoLearned: false)
        dictionary = store.loadDictionary()
        notifyBridge.post(name: AppConfig.Notify.configChanged)
    }

    public func deleteWords(ids: Set<UUID>) {
        store.deleteDictionaryWords(ids: ids)
        dictionary = store.loadDictionary()
        notifyBridge.post(name: AppConfig.Notify.configChanged)
    }

    public func clearAutoLearnedWords() {
        let autoIDs = Set(dictionary.filter(\.autoLearned).map(\.id))
        guard !autoIDs.isEmpty else { return }
        deleteWords(ids: autoIDs)
    }

    // MARK: - Online Custom Lexicon Sync & Import

    public func syncOnlineLexicon(urlString: String? = nil) async {
        guard !isSyncingOnlineLexicon else { return }
        let targetURL = (urlString ?? config.onlineLexiconURL).trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = config
        updated.onlineLexiconURL = targetURL
        guard !targetURL.isEmpty else {
            updated.onlineLexiconLastError = "请先输入词库链接"
            saveConfiguration(updated)
            return
        }

        isSyncingOnlineLexicon = true
        defer { isSyncingOnlineLexicon = false }

        do {
            let entries = try await OnlineLexiconService.fetchAndParse(urlString: targetURL) { term in
                LexiconDatabase.shared.derivePinyin(for: term)
            }
            applyOnlineLexiconEntries(entries, sourceURL: OnlineLexiconService.normalizeRawURLString(targetURL))
        } catch {
            var errCfg = config
            errCfg.onlineLexiconURL = targetURL
            errCfg.onlineLexiconLastError = error.localizedDescription
            saveConfiguration(errCfg)
        }
    }

    @discardableResult
    public func importOnlineLexiconText(_ rawText: String, sourceLabel: String = "手动文本导入") -> Int {
        let entries = OnlineLexiconService.parse(text: rawText) { term in
            LexiconDatabase.shared.derivePinyin(for: term)
        }
        guard !entries.isEmpty else {
            var errCfg = config
            errCfg.onlineLexiconLastError = OnlineLexiconError.emptyOrUnsupportedFormat.localizedDescription
            saveConfiguration(errCfg)
            return 0
        }
        applyOnlineLexiconEntries(entries, sourceURL: sourceLabel)
        return entries.count
    }

    public func clearOnlineLexicon() {
        store.clearOnlineLexiconSnapshot()
        let rev = store.loadOnlineLexiconRevision()
        LexiconDatabase.shared.replaceOnlineWords([], revision: rev)
        onlineLexiconEntries = []
        var updated = config
        updated.onlineLexiconWordCount = 0
        updated.onlineLexiconLastError = ""
        updated.onlineLexiconLastSyncAt = nil
        saveConfiguration(updated)
        notifyBridge.post(name: AppConfig.Notify.onlineLexiconChanged)
    }

    private func applyOnlineLexiconEntries(_ entries: [OnlineLexiconEntry], sourceURL: String) {
        let rev = max(store.loadOnlineLexiconRevision() + 1, Int64(Date().timeIntervalSince1970 * 1000))
        let snapshot = OnlineLexiconSnapshot(
            revision: rev,
            updatedAt: Date(),
            sourceURL: sourceURL,
            entries: entries
        )
        store.saveOnlineLexiconSnapshot(snapshot)
        LexiconDatabase.shared.replaceOnlineWords(entries, revision: rev)
        onlineLexiconEntries = entries

        var updated = config
        if sourceURL.lowercased().hasPrefix("http") {
            updated.onlineLexiconURL = sourceURL
        }
        updated.onlineLexiconLastSyncAt = Date()
        updated.onlineLexiconWordCount = entries.count
        updated.onlineLexiconLastError = ""
        saveConfiguration(updated)
        notifyBridge.post(name: AppConfig.Notify.onlineLexiconChanged)
    }

    public func deleteHistory(ids: Set<UUID>) {
        store.deleteHistory(ids: ids)
        history = store.loadHistory()
    }

    public func clearAllHistory() {
        store.clearHistory()
        history = []
    }

    // MARK: - PiP & Deep Link Handling

    public func togglePiPStandby() {
        if pipManager.isPiPActive {
            pipManager.stopPiP()
        } else {
            pipManager.startPiP()
        }
    }

    public func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == AppConfig.urlScheme.lowercased() else { return }
        let host = (url.host ?? "").lowercased()
        switch host {
        case "start-pip":
            selectedTab = 0
            pipManager.startPiP()
        case "keep-alive":
            selectedTab = 0
            var updated = config
            if !updated.enableAudioBackgroundKeepAlive {
                updated.enableAudioBackgroundKeepAlive = true
                saveConfiguration(updated)
            } else {
                audioService.startSilentKeepAliveIfNeeded(enabled: true)
            }
            if config.autoKeepAlivePiP {
                pipManager.startPiP()
            }
            status.isAudioKeepAliveActive = audioService.isSilentKeepAliveRunning
            if status.state == .idle && (status.isAudioKeepAliveActive || pipManager.isPiPActive) {
                status.state = .standbyPiP
            }
            publishStatus()
        case "record":
            selectedTab = 0
            if config.autoKeepAlivePiP {
                pipManager.startPiP()
            }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let modeStr = components?.queryItems?.first(where: { $0.name == "mode" })?.value ?? "dictate"
            let mode = VoiceActionMode(rawValue: modeStr) ?? .dictate
            Task {
                await startSession(
                    command: VoiceCommandPayload(
                        action: .startRecording,
                        mode: mode,
                        targetLanguage: config.selectedTargetLanguage
                    )
                )
            }
        case "dictionary":
            selectedTab = 2
        case "settings":
            selectedTab = 3
        default:
            selectedTab = 0
        }
    }

    // MARK: - Command Dispatch

    private func handleIncomingCommand() {
        guard let cmd = store.loadCommand() else { return }
        if cmd.action == .ping {
            status.heartbeatAt = Date()
            status.isPiPActive = pipManager.isPiPActive
            publishStatus()
            return
        }

        if cmd.action == .startRecording {
            guard lastHandledCommandId != cmd.requestId else { return }
            lastHandledCommandId = cmd.requestId
            Task {
                await startSession(command: cmd)
            }
        } else if cmd.action == .stopRecording {
            Task {
                await finishSessionAndProcess()
            }
        } else if cmd.action == .cancelRecording {
            cancelSession()
        } else if cmd.action == .processTextEdit {
            guard lastHandledCommandId != cmd.requestId else { return }
            lastHandledCommandId = cmd.requestId
            Task {
                await processDirectTextCommand(cmd)
            }
        }
    }

    // MARK: - Recording & AI Pipeline

    public func toggleQuickTestRecording(mode: VoiceActionMode) async {
        if status.state == .recording {
            await finishSessionAndProcess()
        } else {
            await startSession(
                command: VoiceCommandPayload(
                    action: .startRecording,
                    mode: mode,
                    targetLanguage: config.selectedTargetLanguage
                )
            )
        }
    }

    private func startSession(command: VoiceCommandPayload) async {
        reloadFromStore()
        activeCommand = command
        latestPartialText = ""
        latestAudioLevel = 0
        recordingStartTime = Date()

        do {
            try await audioService.startRecording(
                useAppleSpeech: config.asrProvider == .appleOnDeviceSpeech,
                languageCode: config.asrLanguage
            )
            status.state = .recording
            status.activeRequestId = command.requestId
            status.mode = command.mode
            status.errorMessage = nil
            status.finalResult = ""
            status.rawTranscript = ""
            status.elapsedSeconds = 0
            publishStatus()
            pipManager.updateDisplay(state: .recording, level: 0.2, elapsed: 0)

            meterTimer?.invalidate()
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.status.state == .recording else { return }
                    let elapsed = Date().timeIntervalSince(self.recordingStartTime ?? Date())
                    self.status.audioLevel = self.latestAudioLevel
                    self.status.elapsedSeconds = elapsed
                    self.status.partialText = self.latestPartialText
                    self.status.heartbeatAt = Date()
                    self.publishStatus()
                }
            }
        } catch {
            meterTimer?.invalidate()
            status.state = .error
            status.errorMessage = error.localizedDescription
            publishStatus()
            pipManager.updateDisplay(state: .error, level: 0, elapsed: 0)
        }
    }

    private func cancelSession() {
        meterTimer?.invalidate()
        _ = audioService.stopRecording()
        activeCommand = nil
        if config.enableAudioBackgroundKeepAlive {
            audioService.startSilentKeepAliveIfNeeded(enabled: true)
        }
        status.isAudioKeepAliveActive = audioService.isSilentKeepAliveRunning
        status.state = (pipManager.isPiPActive || status.isAudioKeepAliveActive) ? .standbyPiP : .idle
        status.audioLevel = 0
        status.partialText = ""
        publishStatus()
        pipManager.updateDisplay(state: status.state, level: 0, elapsed: 0)
    }

    private func finishSessionAndProcess() async {
        meterTimer?.invalidate()
        guard let cmd = activeCommand else { return }
        let captured = audioService.stopRecording()
        let duration = captured.durationSeconds

        status.state = .transcribing
        status.audioLevel = 0
        publishStatus()
        pipManager.updateDisplay(state: .transcribing, level: 0, elapsed: duration)

        do {
            let rawText: String
            if config.asrProvider == .appleOnDeviceSpeech {
                rawText = captured.appleSpeechText.trimmingCharacters(in: .whitespacesAndNewlines)
                if rawText.isEmpty {
                    throw AIServiceError.emptyAudio
                }
            } else {
                rawText = try await aiClient.transcribeAudio(
                    wavData: captured.wavData,
                    config: config,
                    personalWords: dictionary
                )
            }

            status.rawTranscript = rawText
            status.state = .polishing
            publishStatus()
            pipManager.updateDisplay(state: .polishing, level: 0, elapsed: duration)

            let polished = try await aiClient.processTranscript(
                transcript: rawText,
                mode: cmd.mode,
                selectedText: cmd.selectedText,
                contextBefore: cmd.contextBefore,
                targetLanguage: cmd.targetLanguage,
                config: config,
                personalWords: dictionary
            )

            lastQuickTestRaw = rawText
            lastQuickTestResult = polished

            let record = HistoryRecord(
                mode: cmd.mode,
                rawTranscript: rawText,
                finalOutput: polished,
                targetLanguage: cmd.mode == .translate ? cmd.targetLanguage : nil,
                durationSeconds: duration
            )
            store.appendHistory(record)
            history = store.loadHistory()

            status.state = .ready
            status.activeRequestId = cmd.requestId
            status.finalResult = polished
            status.errorMessage = nil
            publishStatus()
            pipManager.updateDisplay(state: .ready, level: 0, elapsed: duration)

            if config.enableAudioBackgroundKeepAlive {
                audioService.startSilentKeepAliveIfNeeded(enabled: true)
            }
            status.isAudioKeepAliveActive = audioService.isSilentKeepAliveRunning
            publishStatus()
        } catch {
            if config.enableAudioBackgroundKeepAlive {
                audioService.startSilentKeepAliveIfNeeded(enabled: true)
            }
            status.isAudioKeepAliveActive = audioService.isSilentKeepAliveRunning
            status.state = .error
            status.activeRequestId = cmd.requestId
            status.errorMessage = error.localizedDescription
            publishStatus()
            pipManager.updateDisplay(state: .error, level: 0, elapsed: duration)
        }
    }

    private func processDirectTextCommand(_ cmd: VoiceCommandPayload) async {
        reloadFromStore()
        status.state = .polishing
        status.activeRequestId = cmd.requestId
        publishStatus()

        do {
            let output = try await aiClient.processTranscript(
                transcript: cmd.contextBefore,
                mode: cmd.mode,
                selectedText: cmd.selectedText,
                contextBefore: cmd.contextBefore,
                targetLanguage: cmd.targetLanguage,
                config: config,
                personalWords: dictionary
            )
            status.state = .ready
            status.finalResult = output
            status.errorMessage = nil
            publishStatus()
        } catch {
            status.state = .error
            status.errorMessage = error.localizedDescription
            publishStatus()
        }
    }

    private func publishStatus() {
        status.heartbeatAt = Date()
        store.saveStatus(status)
        notifyBridge.post(name: AppConfig.Notify.statusUpdated)
    }
}

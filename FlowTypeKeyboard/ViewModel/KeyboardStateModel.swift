import Foundation
import ImageIO
import SwiftUI
import UIKit

public enum KeyboardPanel: Equatable, Sendable {
    case voice
    case manual
}

public enum ManualLanguage: Equatable, Sendable {
    case chinesePinyin
    case english

    public var badgeTitle: String {
        switch self {
        case .chinesePinyin: return "拼"
        case .english: return "EN"
        }
    }
}

public enum ManualLayoutPage: Equatable, Sendable {
    case letters
    case numbers
    case symbols
}

public enum ShiftState: Equatable, Sendable {
    case off
    case shifted
    case capsLock
}

@MainActor
public final class KeyboardStateModel: ObservableObject {
    // MARK: - Published UI State
    @Published public var activePanel: KeyboardPanel = .voice
    @Published public var manualLanguage: ManualLanguage = .chinesePinyin
    @Published public var layoutPage: ManualLayoutPage = .letters
    @Published public var shiftState: ShiftState = .off
    @Published public var pinyinLayoutMode: PinyinLayoutMode = .t9

    @Published public var config: AIConfiguration
    @Published public var personalWords: [PersonalWord]
    @Published public var hostStatus: HostRuntimeStatus

    @Published public var voiceMode: VoiceActionMode = .dictate
    @Published public var selectedTargetLanguage: String = "English"

    @Published public var hasFullAccess: Bool = false
    @Published public var needsInputModeSwitchKey: Bool = true
    @Published public var returnKeyLabel: String = "换行"
    @Published public var selectedTextPreview: String = ""
    @Published public var statusBannerMessage: String?

    // MARK: - Pinyin & English Manual Input State
    @Published public var composingPinyin: String = ""
    @Published public var displayPinyin: String = ""
    @Published public var pinyinCandidates: [PinyinCandidate] = []
    @Published public var isCandidateDrawerExpanded: Bool = false
    @Published public var englishSuggestions: [String] = []

    // MARK: - T9 (九宫格) Input State
    @Published public var t9ComposingDigits: String = ""
    @Published public var t9SyllableOptions: [String] = []
    @Published public var selectedT9SyllableFilter: String? = nil
    @Published public var isT9PinyinPickerExpanded: Bool = false
    @Published public var isEmoticonDrawerOpen: Bool = false

    // MARK: - Background Cache & Defaults
    @Published public var customBackgroundImage: UIImage?
    public let t9StarterCandidates: [String] = ["的", "一", "我", "你", "吗", "啊", "可以"]
    @Published public var lastCommittedWord: String? = nil
    @Published public var dynamicIdleCandidates: [String] = ["的", "一", "我", "你", "吗", "啊", "可以"]

    // MARK: - Undo State
    @Published public var canUndoLastAIInsert: Bool = false

    // MARK: - Dependencies & Callbacks
    private let store = SharedStore.shared
    private var lexicon: LexiconDatabase { LexiconDatabase.shared }
    private let textChecker = UITextChecker()
    private let notifyBridge = DarwinNotificationBridge()

    private var lexiconEntries: [UILexiconEntry] = []
    private var loadedBackgroundRevision: Int = -1
    private var lastObservedHostHeartbeatAt: Date = .distantPast
    private var currentPollingInterval: TimeInterval = 0
    private var lastConsumedRequestId: UUID?
    private var lastDictatedTimestamp: Date?
    private var lastDictatedText: String = ""
    private var lastInsertedLength: Int = 0
    private var lastReplacedOriginal: String = ""

    private struct CommittedChineseToken {
        let word: String
        let digits: String
        let pinyin: String
        let timestamp: Date
    }

    private var pendingPhraseTokens: [CommittedChineseToken] = []
    private var lastCommittedSelection: CommittedChineseToken?
    private var lastDeletedMistakeWord: CommittedChineseToken?

    private let hapticGenerator = UIImpactFeedbackGenerator(style: .light)
    private let statusQueue = DispatchQueue(label: "com.flowtype.keyboard.status", qos: .utility)
    private var isStatusPollInFlight = false
    private let t9QueryToken = AtomicCounter()
    private let pinyinQueryToken = AtomicCounter()
    private let englishQueryToken = AtomicCounter()
    private let backgroundLoadToken = AtomicCounter()

    private var statusPollTimer: Timer?
    private var backspaceTimer: Timer?
    private var backspaceStepCount: Int = 0
    private var lastSpaceTapTime: Date = .distantPast
    private var lastShiftTapTime: Date = .distantPast
    private var lastPunctuationTapTime: Date = .distantPast
    private var lastPunctuationIndex: Int = 0
    private var lastPunctuationValue: String = ""
    private var cursorDragAccumulator: CGFloat = 0

    public var proxyProvider: (() -> UITextDocumentProxy?)?
    public var advanceInputModeHandler: (() -> Void)?
    public var openURLHandler: ((URL) -> Void)?

    private let queryQueue = DispatchQueue(label: "com.flowtype.keyboard.query", qos: .userInteractive)

    public init() {
        let cfg = store.loadConfig()
        self.config = cfg
        self.personalWords = store.loadDictionary()
        self.hostStatus = store.loadStatus()
        self.selectedTargetLanguage = cfg.selectedTargetLanguage
        self.pinyinLayoutMode = cfg.defaultPinyinLayout
        switch cfg.defaultKeyboardTab {
        case .voice:
            self.activePanel = .voice
        case .pinyin:
            self.activePanel = .manual
            self.manualLanguage = .chinesePinyin
        case .english:
            self.activePanel = .manual
            self.manualLanguage = .english
        }

        if let ack = store.loadConsumedAck() {
            self.lastConsumedRequestId = ack.requestId
        }
        self.lastObservedHostHeartbeatAt = self.hostStatus.heartbeatAt

        if cfg.hapticFeedback {
            hapticGenerator.prepare()
        }
        queryQueue.async { [store] in
            let db = LexiconDatabase.shared
            db.syncOnlineLexiconIfNeeded(store: store)
        }
        reloadCustomBackgroundImageAsync(force: true)
        setupDarwinObservers()
        startHeartbeatPolling()
    }

    deinit {
        statusPollTimer?.invalidate()
        backspaceTimer?.invalidate()
    }

    // MARK: - Lifecycle & Sync

    private var contextRefreshWorkItem: DispatchWorkItem?

    public func refreshContextFromProxy() {
        guard let proxy = proxyProvider?() else { return }
        if activePanel == .voice {
            let newSelected = proxy.selectedText ?? ""
            if selectedTextPreview != newSelected { selectedTextPreview = newSelected }
        }
        let newReturnLabel = mapReturnKeyTitle(proxy.returnKeyType)
        if returnKeyLabel != newReturnLabel { returnKeyLabel = newReturnLabel }
        if manualLanguage == .english && layoutPage == .letters {
            let before = proxy.documentContextBeforeInput
            updateAutoShiftIfNeeded(before: before)
            refreshEnglishSuggestions(prefetchedBefore: before)
        } else if !englishSuggestions.isEmpty && manualLanguage != .english {
            englishSuggestions = []
        }
    }

    public func scheduleContextRefresh() {
        contextRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshContextFromProxy()
            }
        }
        contextRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: item)
    }

    public func reloadSharedSettings() {
        applyLoadedSettings(store.loadConfig(), words: store.loadDictionary())
        reloadCustomBackgroundImageAsync()
    }

    public func reloadSharedSettingsAsync() {
        let store = self.store
        statusQueue.async { [weak self] in
            let cfg = store.loadConfig()
            let words = store.loadDictionary()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyLoadedSettings(cfg, words: words)
                self.reloadCustomBackgroundImageAsync()
            }
        }
        queryQueue.async { [store] in
            LexiconDatabase.shared.syncOnlineLexiconIfNeeded(store: store)
        }
    }

    private func applyLoadedSettings(_ cfg: AIConfiguration, words: [PersonalWord]) {
        if config != cfg {
            config = cfg
        }
        if personalWords != words {
            personalWords = words
        }
        if !cfg.targetLanguages.contains(selectedTargetLanguage), let first = cfg.targetLanguages.first {
            selectedTargetLanguage = first
        }
    }

    public func reloadCustomBackgroundImageIfNeeded(force: Bool = false) {
        reloadCustomBackgroundImageAsync(force: force)
    }

    public func reloadCustomBackgroundImageAsync(force: Bool = false) {
        if config.backgroundStyle == .customImage {
            let revision = config.customBackgroundRevision
            guard force || loadedBackgroundRevision != revision || customBackgroundImage == nil else { return }
            let token = backgroundLoadToken.increment()
            let counter = backgroundLoadToken
            let store = self.store
            statusQueue.async { [weak self] in
                let prepared: UIImage?
                if let data = store.loadCustomBackgroundImageData() {
                    if let source = CGImageSourceCreateWithData(data as CFData, nil) {
                        let opts: [CFString: Any] = [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: 900,
                            kCGImageSourceCreateThumbnailWithTransform: true
                        ]
                        if let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
                            let img = UIImage(cgImage: cgThumb)
                            prepared = img.preparingForDisplay() ?? img
                        } else if let decoded = UIImage(data: data) {
                            prepared = decoded.preparingForDisplay() ?? decoded
                        } else {
                            prepared = nil
                        }
                    } else if let decoded = UIImage(data: data) {
                        prepared = decoded.preparingForDisplay() ?? decoded
                    } else {
                        prepared = nil
                    }
                } else {
                    prepared = nil
                }
                guard counter.value == token else { return }
                Task { @MainActor [weak self] in
                    guard let self, counter.value == token else { return }
                    self.customBackgroundImage = prepared
                    self.loadedBackgroundRevision = revision
                }
            }
        } else if customBackgroundImage != nil {
            _ = backgroundLoadToken.increment()
            customBackgroundImage = nil
            loadedBackgroundRevision = -1
        }
    }

    public func setSupplementaryLexicon(_ entries: [UILexiconEntry]) {
        lexiconEntries = entries
    }

    private func setupDarwinObservers() {
        notifyBridge.addObserver(name: AppConfig.Notify.statusUpdated) { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncHostStatusAsync()
            }
        }
        notifyBridge.addObserver(name: AppConfig.Notify.configChanged) { [weak self] in
            Task { @MainActor [weak self] in
                self?.reloadSharedSettingsAsync()
            }
        }
        notifyBridge.addObserver(name: AppConfig.Notify.onlineLexiconChanged) { [weak self] in
            Task { @MainActor [weak self] in
                self?.reloadSharedSettingsAsync()
            }
        }
    }

    private var desiredPollingInterval: TimeInterval {
        let activeVoice = (activePanel == .voice
                           || hostStatus.state == .recording
                           || hostStatus.state == .transcribing
                           || hostStatus.state == .polishing)
        return activeVoice ? 0.25 : 2.0
    }

    private func startHeartbeatPolling() {
        scheduleHeartbeatTimer(interval: desiredPollingInterval)
    }

    private func updatePollingCadenceIfNeeded() {
        let target = desiredPollingInterval
        if abs(target - currentPollingInterval) > 0.05 || statusPollTimer == nil {
            scheduleHeartbeatTimer(interval: target)
        }
    }

    private func scheduleHeartbeatTimer(interval: TimeInterval) {
        statusPollTimer?.invalidate()
        currentPollingInterval = interval
        statusPollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncHostStatusAsync()
            }
        }
    }

    public func syncHostStatusAsync() {
        guard !isStatusPollInFlight else { return }
        isStatusPollInFlight = true
        let store = self.store
        statusQueue.async { [weak self] in
            let loaded = store.loadStatus()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isStatusPollInFlight = false
                self.applyLoadedHostStatus(loaded)
            }
        }
    }

    public func syncHostStatusFromStore() {
        let loaded = store.loadStatus()
        applyLoadedHostStatus(loaded)
    }

    private func applyLoadedHostStatus(_ loaded: HostRuntimeStatus) {
        let prevAlive = isHostAlive
        lastObservedHostHeartbeatAt = max(lastObservedHostHeartbeatAt, loaded.heartbeatAt)
        let nextAlive = computeHostAlive(status: loaded, latestHeartbeat: loaded.heartbeatAt)

        // Skip redundant @Published hostStatus writes when only heartbeat timestamp ticked in standby/idle,
        // preventing full SwiftUI keyboard invalidation while typing manually.
        let visualUnchanged: Bool
        if loaded.state == .recording || hostStatus.state == .recording {
            visualUnchanged = (
                loaded.state == hostStatus.state &&
                loaded.activeRequestId == hostStatus.activeRequestId &&
                loaded.partialText == hostStatus.partialText &&
                abs(loaded.audioLevel - hostStatus.audioLevel) < 0.03 &&
                Int(loaded.elapsedSeconds * 10) == Int(hostStatus.elapsedSeconds * 10)
            )
        } else {
            visualUnchanged = (
                loaded.state == hostStatus.state &&
                loaded.activeRequestId == hostStatus.activeRequestId &&
                loaded.mode == hostStatus.mode &&
                loaded.finalResult == hostStatus.finalResult &&
                loaded.errorMessage == hostStatus.errorMessage &&
                loaded.isPiPActive == hostStatus.isPiPActive &&
                loaded.isAudioKeepAliveActive == hostStatus.isAudioKeepAliveActive &&
                prevAlive == nextAlive
            )
        }

        if !visualUnchanged {
            hostStatus = loaded
            handleHostStatusUpdate(loaded)
            updatePollingCadenceIfNeeded()
        }
    }

    private func handleHostStatusUpdate(_ status: HostRuntimeStatus) {
        if status.state == .ready,
           let reqId = status.activeRequestId,
           reqId != lastConsumedRequestId,
           !status.finalResult.isEmpty {
            lastConsumedRequestId = reqId
            let store = self.store
            statusQueue.async {
                store.markResultConsumed(requestId: reqId)
            }
            commitVoiceResult(status.finalResult)
        } else if status.state == .error, let msg = status.errorMessage {
            statusBannerMessage = msg
        }
    }

    // MARK: - Voice Control & IPC

    public var isHostAlive: Bool {
        computeHostAlive(status: hostStatus, latestHeartbeat: max(hostStatus.heartbeatAt, lastObservedHostHeartbeatAt))
    }

    private func computeHostAlive(status: HostRuntimeStatus, latestHeartbeat: Date) -> Bool {
        (status.isPiPActive || status.isAudioKeepAliveActive)
            && abs(Date().timeIntervalSince(latestHeartbeat)) < 4.5
    }

    public func toggleVoiceRecording() {
        triggerHaptic()
        statusBannerMessage = nil
        reloadSharedSettings()

        if hostStatus.state == .recording {
            let cmd = VoiceCommandPayload(
                requestId: hostStatus.activeRequestId ?? UUID(),
                action: .stopRecording,
                mode: voiceMode,
                targetLanguage: selectedTargetLanguage
            )
            store.saveCommand(cmd)
            notifyBridge.post(name: AppConfig.Notify.commandPosted)
            return
        }

        // Check if host is alive via PiP or background audio keep-alive
        syncHostStatusFromStore()
        if !isHostAlive {
            // Wake Host App via Deep Link so it activates microphone (and optional PiP)
            let query = [URLQueryItem(name: "mode", value: voiceMode.rawValue)]
            if let url = AppConfig.deepLinkURL(action: "record", queryItems: query) {
                openURLHandler?(url)
            }
            statusBannerMessage = config.autoKeepAlivePiP
                ? "正在唤醒 FlowType 主程序开启麦克风与画中画..."
                : "正在跳转 FlowType 主程序开启麦克风与后台音频保活..."
            return
        }

        let proxy = proxyProvider?()
        let selected = proxy?.selectedText ?? ""
        let contextBefore = proxy?.documentContextBeforeInput ?? ""

        let cmd = VoiceCommandPayload(
            requestId: UUID(),
            action: .startRecording,
            mode: voiceMode,
            targetLanguage: selectedTargetLanguage,
            selectedText: selected,
            contextBefore: contextBefore
        )
        store.saveCommand(cmd)
        notifyBridge.post(name: AppConfig.Notify.commandPosted)
    }

    public func cancelVoiceRecording() {
        triggerHaptic()
        let cmd = VoiceCommandPayload(
            requestId: hostStatus.activeRequestId ?? UUID(),
            action: .cancelRecording,
            mode: voiceMode,
            targetLanguage: selectedTargetLanguage
        )
        store.saveCommand(cmd)
        notifyBridge.post(name: AppConfig.Notify.commandPosted)
    }

    public func commitVoiceResult(_ text: String) {
        guard let proxy = proxyProvider?() else { return }

        // If user had composing Pinyin buffer, clear it before inserting voice text
        clearComposing()

        let previousSelected = proxy.selectedText ?? ""
        if !previousSelected.isEmpty {
            proxy.deleteBackward()
        }
        proxy.insertText(text)
        pendingPhraseTokens.removeAll()
        lastCommittedSelection = nil

        lastInsertedLength = text.count
        lastReplacedOriginal = previousSelected
        canUndoLastAIInsert = true
        lastDictatedText = text
        lastDictatedTimestamp = Date()
        refreshContextFromProxy()
    }

    public func undoLastAIInsert() {
        guard canUndoLastAIInsert, let proxy = proxyProvider?() else { return }
        triggerHaptic()
        for _ in 0..<lastInsertedLength {
            proxy.deleteBackward()
        }
        if !lastReplacedOriginal.isEmpty {
            proxy.insertText(lastReplacedOriginal)
        }
        canUndoLastAIInsert = false
        lastInsertedLength = 0
        lastReplacedOriginal = ""
        refreshContextFromProxy()
    }

    // MARK: - Panel & Language Switching

    public func switchToPanel(_ panel: KeyboardPanel) {
        triggerHaptic()
        if panel == .voice {
            if !composingPinyin.isEmpty {
                commitComposingAsRawLetters()
            }
            if !t9ComposingDigits.isEmpty {
                commitT9AsRawDigits()
            }
        } else if panel == .manual {
            // 切换手打默认使用九宫格拼音输入
            manualLanguage = .chinesePinyin
            pinyinLayoutMode = .t9
            layoutPage = .letters
        }
        activePanel = panel
        pendingPhraseTokens.removeAll()
        lastCommittedSelection = nil
        isCandidateDrawerExpanded = false
        isT9PinyinPickerExpanded = false
        isEmoticonDrawerOpen = false
        updatePollingCadenceIfNeeded()
        refreshContextFromProxy()
    }

    public func togglePinyinLayoutMode() {
        triggerHaptic()
        if !composingPinyin.isEmpty {
            commitComposingAsRawLetters()
        }
        if !t9ComposingDigits.isEmpty {
            commitT9AsRawDigits()
        }
        pinyinLayoutMode = (pinyinLayoutMode == .t9 ? .qwerty : .t9)
        isCandidateDrawerExpanded = false
        isT9PinyinPickerExpanded = false
        isEmoticonDrawerOpen = false
    }

    public func toggleManualLanguage() {
        triggerHaptic()
        if !composingPinyin.isEmpty {
            commitComposingAsRawLetters()
        }
        if !t9ComposingDigits.isEmpty {
            commitT9AsRawDigits()
        }
        manualLanguage = (manualLanguage == .chinesePinyin) ? .english : .chinesePinyin
        pendingPhraseTokens.removeAll()
        lastCommittedSelection = nil
        layoutPage = .letters
        isCandidateDrawerExpanded = false
        isT9PinyinPickerExpanded = false
        isEmoticonDrawerOpen = false
        shiftState = .off
        updateAutoShiftIfNeeded()
        refreshEnglishSuggestions()
    }

    public func switchLayoutPage(_ page: ManualLayoutPage) {
        triggerHaptic()
        layoutPage = page
        isEmoticonDrawerOpen = false
        isT9PinyinPickerExpanded = false
        isCandidateDrawerExpanded = false
    }

    // MARK: - Key Input Actions

    public func handleKeyTap(_ char: String) {
        triggerHaptic()
        statusBannerMessage = nil

        if layoutPage == .letters && manualLanguage == .chinesePinyin && isASCIILetter(char) {
            let lower = char.lowercased()
            // If user explicitly tapped shift/uppercase in Pinyin mode, insert uppercase English directly
            if shiftState != .off && composingPinyin.isEmpty {
                proxyProvider?()?.insertText(char.uppercased())
                if shiftState == .shifted { shiftState = .off }
                return
            }
            composingPinyin.append(lower)
            updatePinyinCandidates()
            return
        }

        // Direct character insertion (English letters, numbers, symbols, apostrophe)
        if manualLanguage == .chinesePinyin && char == "'" && !composingPinyin.isEmpty {
            if !composingPinyin.hasSuffix("'") {
                composingPinyin.append("'")
                updatePinyinCandidates()
            }
            return
        }

        // If user taps punctuation while composing Pinyin, commit first candidate + punctuation!
        if manualLanguage == .chinesePinyin && !composingPinyin.isEmpty {
            commitTopPinyinCandidate()
        }

        let output: String
        if layoutPage == .letters && isASCIILetter(char) {
            output = (shiftState == .off) ? char.lowercased() : char.uppercased()
            if shiftState == .shifted {
                shiftState = .off
            }
        } else {
            output = char
        }

        proxyProvider?()?.insertText(output)
        scheduleContextRefresh()
    }

    public func handleShiftTap() {
        triggerHaptic()
        let now = Date()
        if shiftState == .shifted && now.timeIntervalSince(lastShiftTapTime) < 0.35 {
            shiftState = .capsLock
        } else if shiftState == .off {
            shiftState = .shifted
        } else {
            shiftState = .off
        }
        lastShiftTapTime = now
    }

    public func handleSpaceTap() {
        triggerHaptic()
        if manualLanguage == .chinesePinyin && pinyinLayoutMode == .t9 && (!t9ComposingDigits.isEmpty || !pinyinCandidates.isEmpty) {
            handleT9SpaceTap()
            return
        }
        if manualLanguage == .chinesePinyin && !composingPinyin.isEmpty {
            commitTopPinyinCandidate()
            return
        }

        guard let proxy = proxyProvider?() else { return }
        let now = Date()
        if config.doubleSpacePeriod,
           now.timeIntervalSince(lastSpaceTapTime) < 0.35,
           let before = proxy.documentContextBeforeInput,
           before.hasSuffix(" "),
           before.count >= 2 {
            let prevChar = before[before.index(before.endIndex, offsetBy: -2)]
            if prevChar.isLetter || prevChar.isNumber {
                proxy.deleteBackward()
                proxy.insertText(manualLanguage == .chinesePinyin ? "。" : ". ")
                lastSpaceTapTime = .distantPast
                refreshContextFromProxy()
                return
            }
        }
        lastSpaceTapTime = now

        if manualLanguage == .english {
            learnCurrentEnglishWordIfNeeded()
        }
        proxy.insertText(" ")
        pendingPhraseTokens.removeAll()
        lastCommittedSelection = nil
        scheduleContextRefresh()
    }

    public func handleReturnTap() {
        triggerHaptic()
        if manualLanguage == .chinesePinyin && pinyinLayoutMode == .t9 && !t9ComposingDigits.isEmpty {
            handleT9ReturnTap()
            return
        }
        if manualLanguage == .chinesePinyin && !composingPinyin.isEmpty {
            commitComposingAsRawLetters()
            return
        }
        if manualLanguage == .english {
            learnCurrentEnglishWordIfNeeded()
        }
        proxyProvider?()?.insertText("\n")
        pendingPhraseTokens.removeAll()
        lastCommittedSelection = nil
        scheduleContextRefresh()
    }

    public func handleBackspaceTap() {
        triggerHaptic()
        if manualLanguage == .chinesePinyin && pinyinLayoutMode == .t9 && (!t9ComposingDigits.isEmpty || selectedT9SyllableFilter != nil) {
            handleT9BackspaceTap()
            return
        }
        if manualLanguage == .chinesePinyin && !composingPinyin.isEmpty {
            composingPinyin.removeLast()
            if composingPinyin.isEmpty {
                clearComposing()
            } else {
                updatePinyinCandidates()
            }
            return
        }

        if let last = lastCommittedSelection,
           Date().timeIntervalSince(last.timestamp) < 6.0,
           let before = proxyProvider?()?.documentContextBeforeInput,
           before.hasSuffix(last.word) {
            lastDeletedMistakeWord = last
            lastCommittedSelection = nil
            pendingPhraseTokens.removeAll()
        }

        proxyProvider?()?.deleteBackward()
        scheduleContextRefresh()
    }

    public func startContinuousBackspace() {
        stopContinuousBackspace()
        backspaceStepCount = 0
        backspaceTimer = Timer.scheduledTimer(withTimeInterval: 0.085, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.backspaceStepCount += 1
                if self.manualLanguage == .chinesePinyin && self.pinyinLayoutMode == .t9 && !self.t9ComposingDigits.isEmpty {
                    self.handleT9BackspaceTap()
                } else if self.manualLanguage == .chinesePinyin && !self.composingPinyin.isEmpty {
                    self.composingPinyin.removeLast()
                    if self.composingPinyin.isEmpty {
                        self.clearComposing()
                    } else {
                        self.updatePinyinCandidates()
                    }
                } else {
                    self.proxyProvider?()?.deleteBackward()
                }
            }
        }
    }

    public func stopContinuousBackspace() {
        guard backspaceTimer != nil else { return }
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        refreshContextFromProxy()
    }

    // MARK: - Spacebar Cursor Trackpad

    public func handleSpaceTrackpadDrag(deltaX: CGFloat) {
        let stepThreshold: CGFloat = 9.0
        cursorDragAccumulator += deltaX
        let steps = Int(cursorDragAccumulator / stepThreshold)
        if steps != 0 {
            cursorDragAccumulator -= CGFloat(steps) * stepThreshold
            proxyProvider?()?.adjustTextPosition(byCharacterOffset: steps)
        }
    }

    public func resetSpaceTrackpad() {
        cursorDragAccumulator = 0
    }

    // MARK: - Pinyin Candidates & Auto-Learning

    public func updatePinyinCandidates() {
        let inputSnapshot = composingPinyin
        guard !inputSnapshot.isEmpty else {
            clearComposing()
            return
        }
        let fuzzy = config.enablePinyinFuzzy
        let words = personalWords
        let lexiconDB = lexicon
        let token = pinyinQueryToken.increment()
        let counter = pinyinQueryToken

        queryQueue.async { [weak self] in
            guard counter.value == token else { return }
            let (seg, cands) = lexiconDB.queryPinyinCandidates(
                rawInput: inputSnapshot,
                fuzzy: fuzzy,
                personalWords: words,
                limit: 64,
                isCancelled: { counter.value != token }
            )
            guard counter.value == token else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      counter.value == token,
                      self.composingPinyin == inputSnapshot else { return }
                if self.displayPinyin != seg.displayPinyin { self.displayPinyin = seg.displayPinyin }
                if self.pinyinCandidates != cands { self.pinyinCandidates = cands }
            }
        }
    }

    public func refreshIdleCandidates() {
        guard let last = lastCommittedWord, !last.isEmpty else {
            if dynamicIdleCandidates != t9StarterCandidates {
                dynamicIdleCandidates = t9StarterCandidates
            }
            return
        }
        let starter = t9StarterCandidates
        let lexiconDB = LexiconDatabase.shared
        queryQueue.async { [weak self] in
            let assocs = lexiconDB.fetchUserAssociations(prevWord: last, limit: 8)
            let next: [String]
            if !assocs.isEmpty {
                var merged = assocs
                for s in starter where !merged.contains(s) && merged.count < 8 {
                    merged.append(s)
                }
                next = merged
            } else {
                next = starter
            }
            Task { @MainActor [weak self] in
                guard let self, self.lastCommittedWord == last else { return }
                if self.dynamicIdleCandidates != next {
                    self.dynamicIdleCandidates = next
                }
            }
        }
    }

    public func selectPinyinCandidate(_ candidate: PinyinCandidate) {
        triggerHaptic()
        guard let proxy = proxyProvider?() else { return }
        proxy.insertText(candidate.text)

        if pinyinLayoutMode == .t9 && !t9ComposingDigits.isEmpty {
            let pureDigits = t9ComposingDigits.replacingOccurrences(of: "'", with: "")
            let consumedDigits = String(pureDigits.prefix(candidate.consumedChars))
            let cleanPy = candidate.displayPinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
            let fullDigits = LexiconDatabase.pinyinToT9Digits(cleanPy)
            let recordedDigits = (Self.isPureChineseCharacters(candidate.text) && !fullDigits.isEmpty && (fullDigits.hasPrefix(consumedDigits) || candidate.isFullMatch))
                ? fullDigits
                : consumedDigits
            let prevWord = lastCommittedWord
            recordLearnedChineseSelection(
                digits: recordedDigits,
                pinyin: candidate.displayPinyin,
                word: candidate.text,
                previousWord: prevWord
            )
            lastCommittedWord = candidate.text
            maybeAutoLearnCorrection(term: candidate.text, pinyinHint: candidate.displayPinyin)

            if candidate.consumedChars >= pureDigits.count || candidate.isFullMatch {
                clearT9Composing()
                refreshIdleCandidates()
            } else {
                let remaining = String(pureDigits.dropFirst(candidate.consumedChars))
                if remaining.isEmpty {
                    clearT9Composing()
                    refreshIdleCandidates()
                } else {
                    isCandidateDrawerExpanded = false
                    t9ComposingDigits = remaining
                    selectedT9SyllableFilter = nil
                    updateT9Candidates()
                }
            }
            scheduleContextRefresh()
            return
        }

        let clean = composingPinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
        let usedPinyin = String(clean.prefix(candidate.consumedChars))
        let resolvedPy = candidate.displayPinyin.isEmpty ? usedPinyin : candidate.displayPinyin
        let cleanPy = resolvedPy.lowercased().filter { $0 >= "a" && $0 <= "z" }
        let digits = LexiconDatabase.pinyinToT9Digits(cleanPy)
        let prevWord = lastCommittedWord

        recordLearnedChineseSelection(
            digits: digits,
            pinyin: cleanPy,
            word: candidate.text,
            previousWord: prevWord
        )
        lastCommittedWord = candidate.text

        // Typeless v2.8.0: auto-learn correction into Personal Dictionary if user edits shortly after dictation
        maybeAutoLearnCorrection(term: candidate.text, pinyinHint: cleanPy)

        let remainingClean = String(clean.dropFirst(candidate.consumedChars))
        if remainingClean.isEmpty {
            clearComposing()
            refreshIdleCandidates()
        } else {
            composingPinyin = remainingClean
            isCandidateDrawerExpanded = false
            updatePinyinCandidates()
        }
        scheduleContextRefresh()
    }

    private func recordLearnedChineseSelection(
        digits: String,
        pinyin: String,
        word: String,
        previousWord: String?
    ) {
        let now = Date()
        let cleanPy = pinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
        let cleanDigits = digits.filter { $0 >= "2" && $0 <= "9" }

        var boostWeight = 1
        if let mistake = lastDeletedMistakeWord,
           now.timeIntervalSince(mistake.timestamp) < 6.0,
           mistake.word != word,
           (!cleanDigits.isEmpty && mistake.digits == cleanDigits)
            || (!cleanPy.isEmpty && mistake.pinyin == cleanPy)
            || (!mistake.word.isEmpty && mistake.word.count == word.count) {
            boostWeight = 3
            lastDeletedMistakeWord = nil
        }

        let lexiconDB = lexicon
        let storeRef = self.store
        let weightSnapshot = boostWeight
        queryQueue.async { [weak self] in
            lexiconDB.recordT9Selection(
                digits: cleanDigits,
                word: word,
                pinyin: cleanPy,
                previousWord: previousWord,
                boostWeight: weightSnapshot
            )
            // Promote repeated multi-char picks or user corrections across sessions into SharedStore PersonalWord
            let isCorrection = weightSnapshot >= 3 && word.count >= 2
            let persistedFreq = word.count >= 2 && Self.isPureChineseCharacters(word)
                ? lexiconDB.fetchUserPhraseFrequency(pinyin: cleanPy, word: word)
                : 0
            if (isCorrection || persistedFreq >= 3) && word.count >= 2 && word.count <= 8 {
                Task { @MainActor [weak self] in
                    self?.promoteLearnedWordToStore(term: word, pinyinHint: cleanPy, store: storeRef)
                }
            }
        }

        let token = CommittedChineseToken(word: word, digits: cleanDigits, pinyin: cleanPy, timestamp: now)
        lastCommittedSelection = token

        // Sequential compound phrase auto-learning: combines consecutive Chinese picks into higher-ranked user phrases
        if Self.isPureChineseCharacters(word), word.count <= 4 {
            if let lastToken = pendingPhraseTokens.last, now.timeIntervalSince(lastToken.timestamp) > 8.0 {
                pendingPhraseTokens.removeAll()
            }
            pendingPhraseTokens.append(token)
            if pendingPhraseTokens.count > 3 {
                pendingPhraseTokens.removeFirst()
            }

            if pendingPhraseTokens.count >= 2 {
                let tailPair = Array(pendingPhraseTokens.suffix(2))
                learnCombinedPhraseTokensIfValid(tailPair)
                if pendingPhraseTokens.count == 3 {
                    learnCombinedPhraseTokensIfValid(pendingPhraseTokens)
                }
            }
        } else {
            pendingPhraseTokens.removeAll()
        }
    }

    private func promoteLearnedWordToStore(term: String, pinyinHint: String, store: SharedStore) {
        statusQueue.async { [weak self] in
            if store.addOrLearnWord(term: term, pinyinHint: pinyinHint, category: .phrase, autoLearned: true) != nil {
                let updated = store.loadDictionary()
                Task { @MainActor [weak self] in
                    self?.personalWords = updated
                }
            }
        }
    }

    private func learnCombinedPhraseTokensIfValid(_ tokens: [CommittedChineseToken]) {
        guard tokens.count >= 2 else { return }
        let combinedWord = tokens.map(\.word).joined()
        let combinedPy = tokens.map(\.pinyin).joined()
        let combinedDigits = tokens.map(\.digits).joined()
        guard combinedWord.count >= 2,
              combinedWord.count <= 8,
              !combinedPy.isEmpty,
              !combinedDigits.isEmpty else { return }

        let lexiconDB = lexicon
        let storeRef = self.store
        queryQueue.async { [weak self] in
            lexiconDB.recordT9Selection(
                digits: combinedDigits,
                word: combinedWord,
                pinyin: combinedPy,
                boostWeight: 1
            )
            // Persist across keyboard restarts using SQLite frequency instead of volatile RAM counters
            if lexiconDB.fetchUserPhraseFrequency(pinyin: combinedPy, word: combinedWord) >= 2 {
                Task { @MainActor [weak self] in
                    self?.promoteLearnedWordToStore(term: combinedWord, pinyinHint: combinedPy, store: storeRef)
                }
            }
        }
    }

    private static func isPureChineseCharacters(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF) ||
            (scalar.value >= 0x3400 && scalar.value <= 0x4DBF)
        }
    }

    public func commitTopPinyinCandidate() {
        if let first = pinyinCandidates.first {
            selectPinyinCandidate(first)
        } else {
            commitComposingAsRawLetters()
        }
    }

    public func commitComposingAsRawLetters() {
        if !t9ComposingDigits.isEmpty {
            let raw = displayPinyin.isEmpty
                ? t9ComposingDigits
                : displayPinyin.replacingOccurrences(of: "'", with: "")
            guard !raw.isEmpty else { return }
            proxyProvider?()?.insertText(raw)
            maybeAutoLearnCorrection(term: raw, pinyinHint: "")
            clearComposing()
            scheduleContextRefresh()
            return
        }
        let raw = composingPinyin.replacingOccurrences(of: "'", with: "")
        guard !raw.isEmpty else { return }
        proxyProvider?()?.insertText(raw)
        maybeAutoLearnCorrection(term: raw, pinyinHint: "")
        clearComposing()
        scheduleContextRefresh()
    }

    public func clearComposing() {
        composingPinyin = ""
        displayPinyin = ""
        pinyinCandidates = []
        isCandidateDrawerExpanded = false
        clearT9Composing()
    }

    // MARK: - T9 (九宫格) Input Handlers

    public func handleT9KeyTap(_ key: String) {
        triggerHaptic()
        if statusBannerMessage != nil { statusBannerMessage = nil }
        if isEmoticonDrawerOpen { isEmoticonDrawerOpen = false }

        switch key {
        case "1":
            // Key 1: If composing, acts as syllable divider "'"; otherwise cycles ，。？！
            if !t9ComposingDigits.isEmpty {
                insertT9SyllableSeparator()
            } else {
                handleT9PunctuationKeyTap()
            }
        case "2", "3", "4", "5", "6", "7", "8", "9":
            t9ComposingDigits.append(key)
            updateT9Candidates()
        default:
            proxyProvider?()?.insertText(key)
            refreshContextFromProxy()
        }
    }

    public func insertT9SyllableSeparator() {
        guard !t9ComposingDigits.isEmpty, !t9ComposingDigits.hasSuffix("'") else { return }
        t9ComposingDigits.append("'")
        updateT9Candidates()
    }

    public func handleT9PunctuationKeyTap() {
        triggerHaptic()
        if statusBannerMessage != nil { statusBannerMessage = nil }
        if isEmoticonDrawerOpen { isEmoticonDrawerOpen = false }
        let cycleMarks = ["，", "。", "？", "！"]

        if !t9ComposingDigits.isEmpty {
            if let first = pinyinCandidates.first {
                selectPinyinCandidate(first)
            } else {
                clearT9Composing()
            }
            let mark = cycleMarks[0]
            proxyProvider?()?.insertText(mark)
            lastPunctuationIndex = 0
            lastPunctuationValue = mark
            lastPunctuationTapTime = Date()
            refreshContextFromProxy()
            return
        }

        let now = Date()
        if now.timeIntervalSince(lastPunctuationTapTime) < 1.2,
           let before = proxyProvider?()?.documentContextBeforeInput,
           !lastPunctuationValue.isEmpty,
           before.hasSuffix(lastPunctuationValue) {
            proxyProvider?()?.deleteBackward()
            lastPunctuationIndex = (lastPunctuationIndex + 1) % cycleMarks.count
        } else {
            lastPunctuationIndex = 0
        }

        let nextMark = cycleMarks[lastPunctuationIndex]
        lastPunctuationValue = nextMark
        lastPunctuationTapTime = now
        proxyProvider?()?.insertText(nextMark)
        scheduleContextRefresh()
    }

    public func toggleCandidateDrawer() {
        isEmoticonDrawerOpen = false
        isT9PinyinPickerExpanded = false
        isCandidateDrawerExpanded.toggle()
        triggerHaptic()
    }

    public func toggleT9PinyinPicker() {
        triggerHaptic()
        guard !t9ComposingDigits.isEmpty else { return }
        isEmoticonDrawerOpen = false
        isT9PinyinPickerExpanded.toggle()
    }

    public func toggleEmoticonDrawer() {
        triggerHaptic()
        isEmoticonDrawerOpen.toggle()
        if isEmoticonDrawerOpen {
            isT9PinyinPickerExpanded = false
            isCandidateDrawerExpanded = false
        }
    }

    public func insertEmoticon(_ text: String) {
        triggerHaptic()
        if manualLanguage == .chinesePinyin && pinyinLayoutMode == .t9 && !t9ComposingDigits.isEmpty {
            if let first = pinyinCandidates.first {
                selectPinyinCandidate(first)
            } else {
                clearT9Composing()
            }
        } else if manualLanguage == .chinesePinyin && !composingPinyin.isEmpty {
            commitTopPinyinCandidate()
        }
        proxyProvider?()?.insertText(text)
        refreshContextFromProxy()
    }

    public func insertStarterCandidate(_ word: String) {
        triggerHaptic()
        proxyProvider?()?.insertText(word)
        if let prev = lastCommittedWord, !prev.isEmpty {
            lexicon.recordT9Selection(digits: "", word: word, pinyin: "", previousWord: prev)
        }
        lastCommittedWord = word
        refreshIdleCandidates()
        scheduleContextRefresh()
    }

    public func updateT9Candidates() {
        let digits = t9ComposingDigits
        guard !digits.isEmpty else {
            clearT9Composing()
            return
        }

        let words = personalWords
        let filter = selectedT9SyllableFilter
        let token = t9QueryToken.increment()
        let counter = t9QueryToken
        let lexicon = self.lexicon
        let pureCount = digits.filter { $0 != "'" }.count
        let needsSentencePhase = pureCount >= 4 || digits.contains("'") || (filter?.contains("'") ?? false)

        let publish: @Sendable ([String], [PinyinCandidate]) -> Void = { [weak self] sylls, cands in
            Task { @MainActor [weak self] in
                guard let self,
                      counter.value == token,
                      self.t9ComposingDigits == digits,
                      self.selectedT9SyllableFilter == filter else { return }
                if self.t9SyllableOptions != sylls { self.t9SyllableOptions = sylls }
                if self.pinyinCandidates != cands { self.pinyinCandidates = cands }
                let display = Self.resolveT9DisplayPinyin(
                    digits: digits,
                    filter: filter,
                    syllables: sylls,
                    candidates: cands
                )
                if self.displayPinyin != display { self.displayPinyin = display }
            }
        }

        // Phase 1: indexed lookups only (instant). Phase 2: sentence lattice decoding, skipped if superseded.
        queryQueue.async {
            guard counter.value == token else { return }
            let fast = lexicon.queryT9Candidates(
                digits: digits,
                pinyinFilter: filter,
                personalWords: words,
                limit: 64,
                includeSentenceDecoding: false,
                isCancelled: { counter.value != token }
            )
            guard counter.value == token else { return }
            publish(fast.syllableOptions, fast.candidates)

            guard needsSentencePhase else { return }
            let full = lexicon.queryT9Candidates(
                digits: digits,
                pinyinFilter: filter,
                personalWords: words,
                limit: 64,
                includeSentenceDecoding: true,
                isCancelled: { counter.value != token }
            )
            guard counter.value == token else { return }
            if full.syllableOptions != fast.syllableOptions || full.candidates != fast.candidates {
                publish(full.syllableOptions, full.candidates)
            }
        }
    }

    public func selectT9SyllableFilter(_ syll: String?) {
        triggerHaptic()
        guard let syll, !syll.isEmpty else {
            selectedT9SyllableFilter = nil
            updateT9Candidates()
            return
        }

        let pureDigits = t9ComposingDigits.replacingOccurrences(of: "'", with: "")
        if let existing = selectedT9SyllableFilter, !existing.isEmpty {
            let parts = existing.split(separator: "'").map(String.init)
            let usedDigits = parts.reduce(0) { $0 + LexiconDatabase.pinyinToT9Digits($1).count }
            let syllLen = LexiconDatabase.pinyinToT9Digits(syll).count
            if usedDigits < pureDigits.count && usedDigits + syllLen <= pureDigits.count {
                selectedT9SyllableFilter = "\(existing)'\(syll)"
            } else if existing == syll {
                selectedT9SyllableFilter = nil
            } else {
                selectedT9SyllableFilter = syll
            }
        } else {
            selectedT9SyllableFilter = syll
        }
        updateT9Candidates()
    }

    public func commitT9AsRawDigits() {
        let letters = displayPinyin.replacingOccurrences(of: "'", with: "")
        let text = letters.isEmpty ? t9ComposingDigits : letters
        guard !text.isEmpty else { return }
        proxyProvider?()?.insertText(text)
        lastCommittedWord = nil
        clearT9Composing()
        refreshIdleCandidates()
        scheduleContextRefresh()
    }

    public func clearT9Composing() {
        t9ComposingDigits = ""
        t9SyllableOptions = []
        selectedT9SyllableFilter = nil
        pinyinCandidates = []
        displayPinyin = ""
        isCandidateDrawerExpanded = false
        isT9PinyinPickerExpanded = false
    }

    public func handleT9SpaceTap() {
        triggerHaptic()
        if let first = pinyinCandidates.first {
            selectPinyinCandidate(first)
            return
        }
        if !t9ComposingDigits.isEmpty {
            commitT9AsRawDigits()
            return
        }
        proxyProvider?()?.insertText(" ")
        lastCommittedWord = nil
        refreshIdleCandidates()
        scheduleContextRefresh()
    }

    private static func resolveT9DisplayPinyin(
        digits: String,
        filter: String?,
        syllables: [String],
        candidates: [PinyinCandidate]
    ) -> String {
        let pureDigits = digits.filter { $0 >= "2" && $0 <= "9" }
        guard !pureDigits.isEmpty else { return "" }

        func fallbackLetter(for d: Character) -> String {
            switch d {
            case "2": return "a"
            case "3": return "d"
            case "4": return "g"
            case "5": return "j"
            case "6": return "m"
            case "7": return "p"
            case "8": return "t"
            case "9": return "w"
            case "'": return "'"
            default: return ""
            }
        }

        func formatSuffixDigits(_ rem: String, preferSyllables: [String]) -> String {
            guard !rem.isEmpty else { return "" }
            if let syl = preferSyllables.first(where: { !$0.isEmpty && $0.count <= rem.count }) {
                let consumed = LexiconDatabase.pinyinToT9Digits(syl)
                if !consumed.isEmpty && rem.hasPrefix(consumed) {
                    let tail = String(rem.dropFirst(consumed.count))
                    if tail.isEmpty { return syl }
                    return syl + "'" + formatSuffixDigits(tail, preferSyllables: [])
                }
            }
            let guessedSylls = LexiconDatabase.syllablesForT9Digits(rem)
            if let syl = guessedSylls.first(where: { !$0.isEmpty }) {
                let consumed = LexiconDatabase.pinyinToT9Digits(syl)
                if !consumed.isEmpty && rem.hasPrefix(consumed) {
                    let tail = String(rem.dropFirst(consumed.count))
                    if tail.isEmpty { return syl }
                    return syl + "'" + formatSuffixDigits(tail, preferSyllables: [])
                }
            }
            return rem.map { fallbackLetter(for: $0) }.joined()
        }

        let normalizedFilter = filter?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let f = normalizedFilter, !f.isEmpty {
            let filterDigits = LexiconDatabase.pinyinToT9Digits(f)
            let cleanAfterFilter = pureDigits.hasPrefix(filterDigits)
                ? String(pureDigits.dropFirst(filterDigits.count))
                : pureDigits

            if let firstCand = candidates.first(where: { $0.isFullMatch }) ?? candidates.first {
                let py = firstCand.displayPinyin
                    .replacingOccurrences(of: " ", with: "'")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !py.isEmpty && py.rangeOfCharacter(from: .decimalDigits) == nil {
                    let matchedCount = py.lowercased().filter { $0 >= "a" && $0 <= "z" }.count
                    let prefixJoined = py.lowercased().hasPrefix(f) ? py : (f + "'" + py)
                    let totalMatched = prefixJoined.lowercased().filter { $0 >= "a" && $0 <= "z" }.count
                    if totalMatched >= pureDigits.count {
                        return prefixJoined
                    }
                    let remCount = max(0, pureDigits.count - max(matchedCount, totalMatched))
                    let rem = String(pureDigits.suffix(remCount))
                    let suffix = formatSuffixDigits(rem, preferSyllables: syllables)
                    return suffix.isEmpty ? prefixJoined : (prefixJoined + "'" + suffix)
                }
            }

            if !cleanAfterFilter.isEmpty {
                let suffix = formatSuffixDigits(cleanAfterFilter, preferSyllables: syllables)
                return suffix.isEmpty ? f : (f + "'" + suffix)
            }
            return f
        }

        if let bestFull = candidates.first(where: { $0.isFullMatch && !$0.displayPinyin.isEmpty && $0.displayPinyin.rangeOfCharacter(from: .decimalDigits) == nil }) {
            let py = bestFull.displayPinyin
                .replacingOccurrences(of: " ", with: "'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanPy = py.lowercased().filter { $0 >= "a" && $0 <= "z" }
            let cleanDigits = LexiconDatabase.pinyinToT9Digits(cleanPy)
            if cleanDigits.hasPrefix(pureDigits) {
                if cleanPy.count > pureDigits.count {
                    return PinyinSyllableParser.segment(rawInput: String(cleanPy.prefix(pureDigits.count))).displayPinyin
                }
                return py
            }
            if cleanPy.count < pureDigits.count, pureDigits.hasPrefix(cleanDigits) {
                let rem = String(pureDigits.dropFirst(cleanPy.count))
                let suffix = formatSuffixDigits(rem, preferSyllables: [])
                return suffix.isEmpty ? py : (py + "'" + suffix)
            }
        }

        if let firstCand = candidates.first(where: { !$0.displayPinyin.isEmpty && $0.displayPinyin.rangeOfCharacter(from: .decimalDigits) == nil }) {
            let py = firstCand.displayPinyin
                .replacingOccurrences(of: " ", with: "'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanPy = py.lowercased().filter { $0 >= "a" && $0 <= "z" }
            let cleanDigits = LexiconDatabase.pinyinToT9Digits(cleanPy)
            if cleanDigits.hasPrefix(pureDigits) {
                if cleanPy.count > pureDigits.count {
                    return PinyinSyllableParser.segment(rawInput: String(cleanPy.prefix(pureDigits.count))).displayPinyin
                }
                return py
            }
            if cleanPy.count < pureDigits.count, pureDigits.hasPrefix(cleanDigits) {
                let rem = String(pureDigits.dropFirst(cleanPy.count))
                let suffix = formatSuffixDigits(rem, preferSyllables: [])
                return suffix.isEmpty ? py : (py + "'" + suffix)
            }
        }

        return formatSuffixDigits(pureDigits, preferSyllables: syllables)
    }

    public func handleT9ReturnTap() {
        triggerHaptic()
        if !t9ComposingDigits.isEmpty {
            // iOS Native 9-key: 确认 commits composed pinyin / letters
            let textToCommit = displayPinyin.isEmpty ? t9ComposingDigits : displayPinyin.replacingOccurrences(of: "'", with: "")
            proxyProvider?()?.insertText(textToCommit)
            lastCommittedWord = nil
            clearT9Composing()
            refreshIdleCandidates()
            scheduleContextRefresh()
            return
        }
        proxyProvider?()?.insertText("\n")
        lastCommittedWord = nil
        refreshIdleCandidates()
        scheduleContextRefresh()
    }

    public func handleT9BackspaceTap() {
        triggerHaptic()
        if let existing = selectedT9SyllableFilter, !existing.isEmpty {
            var parts = existing.split(separator: "'").map(String.init)
            if parts.count > 1 {
                parts.removeLast()
                selectedT9SyllableFilter = parts.joined(separator: "'")
            } else {
                selectedT9SyllableFilter = nil
            }
            updateT9Candidates()
            return
        }
        if !t9ComposingDigits.isEmpty {
            t9ComposingDigits.removeLast()
            if t9ComposingDigits.isEmpty {
                clearT9Composing()
            } else {
                updateT9Candidates()
            }
            return
        }
        proxyProvider?()?.deleteBackward()
        scheduleContextRefresh()
    }

    // MARK: - English Completions

    public func refreshEnglishSuggestions(prefetchedBefore: String? = nil) {
        let beforeText: String?
        if let prefetchedBefore {
            beforeText = prefetchedBefore
        } else {
            beforeText = proxyProvider?()?.documentContextBeforeInput
        }
        guard let before = beforeText else {
            if !englishSuggestions.isEmpty { englishSuggestions = [] }
            return
        }
        let currentWord = extractTrailingASCIIWord(from: before)
        guard !currentWord.isEmpty else {
            if !englishSuggestions.isEmpty { englishSuggestions = [] }
            return
        }

        var localHits: [String] = []
        var seenLocal = Set<String>()
        for entry in lexiconEntries {
            if entry.userInput.lowercased().hasPrefix(currentWord.lowercased()),
               seenLocal.insert(entry.documentText.lowercased()).inserted {
                localHits.append(entry.documentText)
            }
        }

        let wordsSnapshot = personalWords
        let token = englishQueryToken.increment()
        let counter = englishQueryToken
        let lexiconDB = LexiconDatabase.shared

        queryQueue.async { [weak self] in
            let dbHits = lexiconDB.queryEnglishCompletions(prefix: currentWord, personalWords: wordsSnapshot, limit: 6)
            guard counter.value == token else { return }

            Task { @MainActor [weak self] in
                guard let self, counter.value == token, self.manualLanguage == .english else { return }
                var merged: [String] = []
                var seen = Set<String>()
                func add(_ w: String) {
                    if seen.insert(w.lowercased()).inserted {
                        merged.append(w)
                    }
                }
                for w in localHits { add(w) }
                for w in dbHits { add(w) }

                // Only invoke UIKit UITextChecker on main thread when lexicon hits are sparse.
                if merged.count < 3 && currentWord.count >= 2 {
                    let nsRange = NSRange(location: 0, length: currentWord.utf16.count)
                    let checkerHits = self.textChecker.completions(forPartialWordRange: nsRange, in: currentWord, language: "en_US") ?? []
                    for w in checkerHits.prefix(4) {
                        add(w)
                    }
                }

                let limited = Array(merged.prefix(5))
                if self.englishSuggestions != limited {
                    self.englishSuggestions = limited
                }
            }
        }
    }

    public func applyEnglishSuggestion(_ word: String) {
        triggerHaptic()
        guard let proxy = proxyProvider?() else { return }
        let currentWord = extractTrailingASCIIWord(from: proxy.documentContextBeforeInput ?? "")
        for _ in 0..<currentWord.count {
            proxy.deleteBackward()
        }
        let finalWord = (shiftState != .off && currentWord.first?.isUppercase == true)
            ? word.prefix(1).uppercased() + word.dropFirst()
            : word
        proxy.insertText(finalWord + " ")
        let lexiconDB = LexiconDatabase.shared
        queryQueue.async {
            lexiconDB.recordEnglishSelection(word: finalWord)
        }
        maybeAutoLearnCorrection(term: finalWord, pinyinHint: "")
        shiftState = .off
        scheduleContextRefresh()
    }

    private func learnCurrentEnglishWordIfNeeded() {
        guard let before = proxyProvider?()?.documentContextBeforeInput else { return }
        let word = extractTrailingASCIIWord(from: before)
        if word.count >= 2 {
            let lexiconDB = LexiconDatabase.shared
            queryQueue.async {
                lexiconDB.recordEnglishSelection(word: word)
            }
            maybeAutoLearnCorrection(term: word, pinyinHint: "")
        }
    }

    private func maybeAutoLearnCorrection(term: String, pinyinHint: String) {
        guard let dictatedAt = lastDictatedTimestamp,
              Date().timeIntervalSince(dictatedAt) < 35.0,
              term.count >= 2,
              !lastDictatedText.contains(term) else {
            return
        }
        let store = self.store
        statusQueue.async { [weak self] in
            // Persist learned terms in background to avoid main-thread file/Keychain writes during typing.
            if store.addOrLearnWord(term: term, pinyinHint: pinyinHint, category: .phrase, autoLearned: true) != nil {
                let updated = store.loadDictionary()
                Task { @MainActor [weak self] in
                    self?.personalWords = updated
                }
            }
        }
    }

    // MARK: - Helpers

    private func updateAutoShiftIfNeeded() {
        updateAutoShiftIfNeeded(before: proxyProvider?()?.documentContextBeforeInput)
    }

    private func updateAutoShiftIfNeeded(before fetchedBefore: String?) {
        guard manualLanguage == .english, layoutPage == .letters, shiftState != .capsLock else { return }
        guard let before = fetchedBefore else {
            if shiftState != .shifted { shiftState = .shifted }
            return
        }
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let target: ShiftState = (before.isEmpty || before.hasSuffix("\n") ||
            (before.hasSuffix(" ") && (trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?"))))
            ? .shifted
            : .off
        if shiftState != target {
            shiftState = target
        }
    }

    private func extractTrailingASCIIWord(from text: String) -> String {
        var chars: [Character] = []
        for ch in text.reversed() {
            if (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || ch == "'" {
                chars.append(ch)
            } else {
                break
            }
        }
        return String(chars.reversed())
    }

    private func isASCIILetter(_ s: String) -> Bool {
        guard s.count == 1, let ch = s.first else { return false }
        return (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")
    }

    private func mapReturnKeyTitle(_ type: UIReturnKeyType?) -> String {
        switch type {
        case .send: return "发送"
        case .search: return "搜索"
        case .go: return "前往"
        case .done: return "完成"
        case .next: return "下一项"
        case .join: return "加入"
        default: return "换行"
        }
    }

    public func triggerHaptic() {
        guard config.hapticFeedback else { return }
        hapticGenerator.impactOccurred()
        hapticGenerator.prepare()
    }
}


/// Thread-safe monotonically increasing token used to cancel stale background lexicon queries.
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        current &+= 1
        return current
    }
}

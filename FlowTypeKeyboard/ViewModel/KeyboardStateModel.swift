import Foundation
import SwiftUI
import UIKit

public enum KeyboardPanel: Equatable {
    case voice
    case manual
}

public enum ManualLanguage: Equatable {
    case chinesePinyin
    case english

    public var badgeTitle: String {
        switch self {
        case .chinesePinyin: return "拼"
        case .english: return "EN"
        }
    }
}

public enum ManualLayoutPage: Equatable {
    case letters
    case numbers
    case symbols
}

public enum ShiftState: Equatable {
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
    @Published public var customBackgroundImageData: Data?
    public let t9StarterCandidates: [String] = ["的", "一", "我", "你", "在", "是", "了", "不", "有", "好"]

    // MARK: - Undo State
    @Published public var canUndoLastAIInsert: Bool = false

    // MARK: - Dependencies & Callbacks
    private let store = SharedStore.shared
    private let lexicon = LexiconDatabase.shared
    private let textChecker = UITextChecker()
    private let notifyBridge = DarwinNotificationBridge()

    private var lexiconEntries: [UILexiconEntry] = []
    private var loadedBackgroundRevision: Int = -1
    private var lastConsumedRequestId: UUID?
    private var lastDictatedTimestamp: Date?
    private var lastDictatedText: String = ""
    private var lastInsertedLength: Int = 0
    private var lastReplacedOriginal: String = ""

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

        reloadCustomBackgroundImageIfNeeded(force: true)
        setupDarwinObservers()
        startHeartbeatPolling()
    }

    deinit {
        statusPollTimer?.invalidate()
        backspaceTimer?.invalidate()
    }

    // MARK: - Lifecycle & Sync

    public func refreshContextFromProxy() {
        guard let proxy = proxyProvider?() else { return }
        selectedTextPreview = proxy.selectedText ?? ""
        returnKeyLabel = mapReturnKeyTitle(proxy.returnKeyType)
        updateAutoShiftIfNeeded()
        if manualLanguage == .english && layoutPage == .letters {
            refreshEnglishSuggestions()
        }
    }

    public func reloadSharedSettings() {
        config = store.loadConfig()
        personalWords = store.loadDictionary()
        if !config.targetLanguages.contains(selectedTargetLanguage), let first = config.targetLanguages.first {
            selectedTargetLanguage = first
        }
        reloadCustomBackgroundImageIfNeeded()
    }

    public func reloadCustomBackgroundImageIfNeeded(force: Bool = false) {
        if config.backgroundStyle == .customImage {
            if force || loadedBackgroundRevision != config.customBackgroundRevision || customBackgroundImageData == nil {
                customBackgroundImageData = store.loadCustomBackgroundImageData()
                loadedBackgroundRevision = config.customBackgroundRevision
            }
        } else if customBackgroundImageData != nil {
            customBackgroundImageData = nil
            loadedBackgroundRevision = -1
        }
    }

    public func setSupplementaryLexicon(_ entries: [UILexiconEntry]) {
        lexiconEntries = entries
    }

    private func setupDarwinObservers() {
        notifyBridge.addObserver(name: AppConfig.Notify.statusUpdated) { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncHostStatusFromStore()
            }
        }
        notifyBridge.addObserver(name: AppConfig.Notify.configChanged) { [weak self] in
            Task { @MainActor [weak self] in
                self?.reloadSharedSettings()
            }
        }
    }

    private func startHeartbeatPolling() {
        statusPollTimer?.invalidate()
        statusPollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let loaded = self.store.loadStatus()
                if loaded != self.hostStatus {
                    self.hostStatus = loaded
                    self.handleHostStatusUpdate(loaded)
                }
            }
        }
    }

    public func syncHostStatusFromStore() {
        let loaded = store.loadStatus()
        hostStatus = loaded
        handleHostStatusUpdate(loaded)
    }

    private func handleHostStatusUpdate(_ status: HostRuntimeStatus) {
        if status.state == .ready,
           let reqId = status.activeRequestId,
           reqId != lastConsumedRequestId,
           !status.finalResult.isEmpty {
            lastConsumedRequestId = reqId
            store.markResultConsumed(requestId: reqId)
            commitVoiceResult(status.finalResult)
        } else if status.state == .error, let msg = status.errorMessage {
            statusBannerMessage = msg
        }
    }

    // MARK: - Voice Control & IPC

    public var isHostAlive: Bool {
        hostStatus.isHostAlive
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
        if !hostStatus.isHostAlive {
            // Wake Host App via Deep Link so it activates microphone & PiP
            let query = [URLQueryItem(name: "mode", value: voiceMode.rawValue)]
            if let url = AppConfig.deepLinkURL(action: "record", queryItems: query) {
                openURLHandler?(url)
            }
            statusBannerMessage = "正在唤醒 FlowType 主程序开启麦克风与画中画..."
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
        isCandidateDrawerExpanded = false
        isT9PinyinPickerExpanded = false
        isEmoticonDrawerOpen = false
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
        refreshContextFromProxy()
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
        refreshContextFromProxy()
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
        refreshContextFromProxy()
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

        proxyProvider?()?.deleteBackward()
        refreshContextFromProxy()
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

        queryQueue.async { [weak self] in
            let (seg, cands) = lexiconDB.queryPinyinCandidates(
                rawInput: inputSnapshot,
                fuzzy: fuzzy,
                personalWords: words,
                limit: 40
            )
            Task { @MainActor [weak self] in
                guard let self, self.composingPinyin == inputSnapshot else { return }
                self.displayPinyin = seg.displayPinyin
                self.pinyinCandidates = cands
            }
        }
    }

    public func selectPinyinCandidate(_ candidate: PinyinCandidate) {
        triggerHaptic()
        guard let proxy = proxyProvider?() else { return }
        proxy.insertText(candidate.text)

        if pinyinLayoutMode == .t9 && !t9ComposingDigits.isEmpty {
            if !candidate.displayPinyin.isEmpty {
                lexicon.recordChineseSelection(pinyin: candidate.displayPinyin, word: candidate.text)
            }
            maybeAutoLearnCorrection(term: candidate.text, pinyinHint: candidate.displayPinyin)

            let pureDigits = t9ComposingDigits.replacingOccurrences(of: "'", with: "")
            if candidate.consumedChars >= pureDigits.count || candidate.isFullMatch {
                clearT9Composing()
            } else {
                let remaining = String(pureDigits.dropFirst(candidate.consumedChars))
                if remaining.isEmpty {
                    clearT9Composing()
                } else {
                    t9ComposingDigits = remaining
                    selectedT9SyllableFilter = nil
                    updateT9Candidates()
                }
            }
            refreshContextFromProxy()
            return
        }

        let clean = composingPinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
        let usedPinyin = String(clean.prefix(candidate.consumedChars))
        lexicon.recordChineseSelection(pinyin: usedPinyin, word: candidate.text)

        // Typeless v2.8.0: auto-learn correction into Personal Dictionary if user edits shortly after dictation
        maybeAutoLearnCorrection(term: candidate.text, pinyinHint: usedPinyin)

        let remainingClean = String(clean.dropFirst(candidate.consumedChars))
        if remainingClean.isEmpty {
            clearComposing()
        } else {
            composingPinyin = remainingClean
            isCandidateDrawerExpanded = false
            updatePinyinCandidates()
        }
        refreshContextFromProxy()
    }

    public func commitTopPinyinCandidate() {
        if let first = pinyinCandidates.first {
            selectPinyinCandidate(first)
        } else {
            commitComposingAsRawLetters()
        }
    }

    public func commitComposingAsRawLetters() {
        let raw = composingPinyin.replacingOccurrences(of: "'", with: "")
        guard !raw.isEmpty else { return }
        proxyProvider?()?.insertText(raw)
        maybeAutoLearnCorrection(term: raw, pinyinHint: "")
        clearComposing()
        refreshContextFromProxy()
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
        statusBannerMessage = nil
        isEmoticonDrawerOpen = false

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
        statusBannerMessage = nil
        isEmoticonDrawerOpen = false
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
        refreshContextFromProxy()
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
        refreshContextFromProxy()
    }

    public func updateT9Candidates() {
        let digits = t9ComposingDigits
        guard !digits.isEmpty else {
            clearT9Composing()
            return
        }

        let words = personalWords
        let filter = selectedT9SyllableFilter
        queryQueue.async { [weak self] in
            guard let self else { return }
            let (sylls, cands) = self.lexicon.queryT9Candidates(
                digits: digits,
                pinyinFilter: filter,
                personalWords: words,
                limit: 40
            )
            Task { @MainActor [weak self] in
                guard let self,
                      self.t9ComposingDigits == digits,
                      self.selectedT9SyllableFilter == filter else { return }
                self.t9SyllableOptions = sylls
                self.pinyinCandidates = cands
                self.displayPinyin = filter ?? digits
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
        let raw = t9ComposingDigits
        guard !raw.isEmpty else { return }
        proxyProvider?()?.insertText(raw)
        clearT9Composing()
        refreshContextFromProxy()
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
        refreshContextFromProxy()
    }

    public func handleT9ReturnTap() {
        triggerHaptic()
        if let first = pinyinCandidates.first {
            selectPinyinCandidate(first)
            return
        }
        if !t9ComposingDigits.isEmpty {
            commitT9AsRawDigits()
            return
        }
        proxyProvider?()?.insertText("\n")
        refreshContextFromProxy()
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
        refreshContextFromProxy()
    }

    // MARK: - English Completions

    public func refreshEnglishSuggestions() {
        guard let proxy = proxyProvider?(),
              let before = proxy.documentContextBeforeInput else {
            englishSuggestions = []
            return
        }
        let currentWord = extractTrailingASCIIWord(from: before)
        guard !currentWord.isEmpty else {
            englishSuggestions = []
            return
        }

        var merged: [String] = []
        var seen = Set<String>()
        func add(_ w: String) {
            if seen.insert(w.lowercased()).inserted {
                merged.append(w)
            }
        }

        // 1. UILexicon shortcuts
        for entry in lexiconEntries {
            if entry.userInput.lowercased().hasPrefix(currentWord.lowercased()) {
                add(entry.documentText)
            }
        }

        // 2. Bundled frequency lexicon + Personal Dictionary
        for w in lexicon.queryEnglishCompletions(prefix: currentWord, personalWords: personalWords, limit: 6) {
            add(w)
        }

        // 3. System UITextChecker completions
        let nsRange = NSRange(location: 0, length: currentWord.utf16.count)
        let checkerHits = textChecker.completions(forPartialWordRange: nsRange, in: currentWord, language: "en_US") ?? []
        for w in checkerHits.prefix(4) {
            add(w)
        }

        englishSuggestions = Array(merged.prefix(5))
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
        lexicon.recordEnglishSelection(word: finalWord)
        maybeAutoLearnCorrection(term: finalWord, pinyinHint: "")
        shiftState = .off
        refreshContextFromProxy()
    }

    private func learnCurrentEnglishWordIfNeeded() {
        guard let before = proxyProvider?()?.documentContextBeforeInput else { return }
        let word = extractTrailingASCIIWord(from: before)
        if word.count >= 2 {
            lexicon.recordEnglishSelection(word: word)
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
        // Only auto-learn meaningful terms (Chinese >=2 chars or English >=3 chars)
        if let learned = store.addOrLearnWord(term: term, pinyinHint: pinyinHint, category: .phrase, autoLearned: true) {
            personalWords = store.loadDictionary()
            _ = learned
        }
    }

    // MARK: - Helpers

    private func updateAutoShiftIfNeeded() {
        guard manualLanguage == .english, layoutPage == .letters, shiftState != .capsLock else { return }
        guard let before = proxyProvider?()?.documentContextBeforeInput else {
            shiftState = .shifted
            return
        }
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        if before.isEmpty || before.hasSuffix("\n") ||
            (before.hasSuffix(" ") && (trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?"))) {
            shiftState = .shifted
        } else {
            shiftState = .off
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
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.impactOccurred()
    }
}

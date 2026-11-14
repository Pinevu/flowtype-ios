import Foundation

public enum VoiceCommandAction: String, Codable {
    case ping
    case startRecording
    case stopRecording
    case cancelRecording
    case processTextEdit
}

public struct VoiceCommandPayload: Codable, Equatable {
    public var requestId: UUID
    public var action: VoiceCommandAction
    public var mode: VoiceActionMode
    public var targetLanguage: String
    public var selectedText: String
    public var contextBefore: String
    public var timestamp: Date

    public init(
        requestId: UUID = UUID(),
        action: VoiceCommandAction,
        mode: VoiceActionMode = .dictate,
        targetLanguage: String = "English",
        selectedText: String = "",
        contextBefore: String = "",
        timestamp: Date = Date()
    ) {
        self.requestId = requestId
        self.action = action
        self.mode = mode
        self.targetLanguage = targetLanguage
        self.selectedText = selectedText
        self.contextBefore = contextBefore
        self.timestamp = timestamp
    }
}

public enum HostVoiceState: String, Codable {
    case idle
    case standbyPiP
    case recording
    case transcribing
    case polishing
    case ready
    case error
}

public struct HostRuntimeStatus: Codable, Equatable {
    public var state: HostVoiceState
    public var activeRequestId: UUID?
    public var mode: VoiceActionMode
    public var audioLevel: Float
    public var elapsedSeconds: Double
    public var partialText: String
    public var rawTranscript: String
    public var finalResult: String
    public var errorMessage: String?
    public var isPiPActive: Bool
    public var isAudioKeepAliveActive: Bool
    public var heartbeatAt: Date

    public init(
        state: HostVoiceState = .idle,
        activeRequestId: UUID? = nil,
        mode: VoiceActionMode = .dictate,
        audioLevel: Float = 0,
        elapsedSeconds: Double = 0,
        partialText: String = "",
        rawTranscript: String = "",
        finalResult: String = "",
        errorMessage: String? = nil,
        isPiPActive: Bool = false,
        isAudioKeepAliveActive: Bool = false,
        heartbeatAt: Date = .distantPast
    ) {
        self.state = state
        self.activeRequestId = activeRequestId
        self.mode = mode
        self.audioLevel = audioLevel
        self.elapsedSeconds = elapsedSeconds
        self.partialText = partialText
        self.rawTranscript = rawTranscript
        self.finalResult = finalResult
        self.errorMessage = errorMessage
        self.isPiPActive = isPiPActive
        self.isAudioKeepAliveActive = isAudioKeepAliveActive
        self.heartbeatAt = heartbeatAt
    }

    public var isHostAlive: Bool {
        (isPiPActive || isAudioKeepAliveActive) && abs(Date().timeIntervalSince(heartbeatAt)) < 3.0
    }
}

public struct ConsumedResultAck: Codable, Equatable {
    public var requestId: UUID
    public var consumedAt: Date
}

// MARK: - Darwin Notification Helper

public final class DarwinNotificationBridge {
    private final class ObserverBox {
        let name: String
        let callback: () -> Void
        init(name: String, callback: @escaping () -> Void) {
            self.name = name
            self.callback = callback
        }
    }

    private var boxes: [ObserverBox] = []
    private let lock = NSLock()

    public init() {}

    deinit {
        removeAllObservers()
    }

    public func post(name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    public func addObserver(name: String, callback: @escaping () -> Void) {
        let box = ObserverBox(name: name, callback: callback)
        lock.lock()
        boxes.append(box)
        lock.unlock()

        let pointer = Unmanaged.passUnretained(box).toOpaque()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            pointer,
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let box = Unmanaged<ObserverBox>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    box.callback()
                }
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    public func removeAllObservers() {
        lock.lock()
        let current = boxes
        boxes.removeAll()
        lock.unlock()

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for box in current {
            let pointer = Unmanaged.passUnretained(box).toOpaque()
            CFNotificationCenterRemoveObserver(center, pointer, CFNotificationName(box.name as CFString), nil)
        }
    }
}

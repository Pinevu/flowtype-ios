import AVFoundation
import Foundation
import Speech

public enum AudioCaptureError: LocalizedError {
    case permissionDenied
    case audioEngineUnavailable
    case audioSessionConflict(Int)
    case speechRecognizerUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "请在系统设置中允许 FlowType 访问麦克风权限。"
        case .audioEngineUnavailable:
            return "无法初始化麦克风音频引擎。"
        case .audioSessionConflict(let code):
            return "麦克风被其他后台音频或系统策略占用（错误 \(code)），请暂停其他播放/通话或从主程序唤起录音。"
        case .speechRecognizerUnavailable(let reason):
            return "系统语音识别不可用：\(reason)"
        }
    }
}

public final class AudioCaptureService {
    private let audioEngine = AVAudioEngine()
    private var samplesLock = NSLock()
    private var capturedInt16Samples: [Int16] = []
    private var isCapturing = false

    private var speechRecognizer: SFSpeechRecognizer?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SFSpeechRecognitionTask?
    private var latestSpeechTranscript: String = ""

    private var keepAlivePlayer: AVAudioPlayer?
    private var shouldKeepAlive: Bool = false
    private var interruptionObserver: NSObjectProtocol?
    private lazy var silentLoopWAVData: Data = {
        let silentSamples = [Int16](repeating: 0, count: 16000)
        return AudioWAVEncoder.encodePCM16Mono(samples: silentSamples, sampleRate: 16000)
    }()

    public var isSilentKeepAliveRunning: Bool {
        keepAlivePlayer?.isPlaying == true
    }

    public var onAudioLevel: ((Float) -> Void)?
    public var onPartialTranscript: ((String) -> Void)?

    public init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let info = note.userInfo,
                  let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
            if type == .ended && self.shouldKeepAlive && !self.isCapturing {
                self.startSilentKeepAliveIfNeeded(enabled: true)
            }
        }
    }

    deinit {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    public func ensureMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                return await AVAudioApplication.requestRecordPermission()
            @unknown default:
                return false
            }
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    public func ensureSpeechRecognitionPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    public func configureAudioSessionForPiPOnly() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }

    public func startSilentKeepAliveIfNeeded(enabled: Bool) {
        shouldKeepAlive = enabled
        guard enabled else {
            stopSilentKeepAlive()
            return
        }
        if keepAlivePlayer?.isPlaying == true { return }
        do {
            try configureAudioSessionForPiPOnly()
            let player = try AVAudioPlayer(data: silentLoopWAVData)
            player.numberOfLoops = -1
            player.volume = 0.0
            player.prepareToPlay()
            player.play()
            keepAlivePlayer = player
        } catch {
            print("[AudioCaptureService] Failed silent keep-alive: \(error)")
        }
    }

    public func stopSilentKeepAlive() {
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
    }

    public func startRecording(useAppleSpeech: Bool, languageCode: String) async throws {
        guard await ensureMicrophonePermission() else {
            throw AudioCaptureError.permissionDenied
        }

        if useAppleSpeech {
            let speechOK = await ensureSpeechRecognitionPermission()
            if !speechOK {
                throw AudioCaptureError.speechRecognizerUnavailable("未授予语音识别权限")
            }
        }

        stopRecordingInternal(deactivateSession: false)
        // Pause silent playback cleanly before switching audio session into capture mode
        keepAlivePlayer?.stop()

        let session = AVAudioSession.sharedInstance()
        #if compiler(>=6.2)
        let options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers]
        #else
        let options: AVAudioSession.CategoryOptions = [.allowBluetooth, .defaultToSpeaker, .mixWithOthers]
        #endif
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
            try session.setActive(true)
        } catch {
            let nsErr = error as NSError
            if nsErr.code == AVAudioSession.ErrorCode.insufficientPriority.rawValue ||
                nsErr.code == AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue ||
                nsErr.code == 561015905 {
                throw AudioCaptureError.audioSessionConflict(nsErr.code)
            }
            throw error
        }

        resetCapturedSamples()

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.audioEngineUnavailable
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.audioEngineUnavailable
        }

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        if useAppleSpeech {
            let localeId = resolveLocaleIdentifier(languageCode)
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId))
            guard let recognizer, recognizer.isAvailable else {
                throw AudioCaptureError.speechRecognizerUnavailable("当前地区语言 (\(localeId)) 不可用")
            }
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                req.requiresOnDeviceRecognition = false
            }
            self.speechRecognizer = recognizer
            self.speechRequest = req
            self.speechTask = recognizer.recognitionTask(with: req) { [weak self] result, _ in
                guard let self, let result else { return }
                let text = result.bestTranscription.formattedString
                self.samplesLock.lock()
                self.latestSpeechTranscript = text
                self.samplesLock.unlock()
                self.onPartialTranscript?(text)
            }
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.speechRequest?.append(buffer)

            // Compute RMS meter level
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameLength {
                    let s = channelData[i]
                    sum += s * s
                }
                let rms = frameLength > 0 ? sqrt(sum / Float(frameLength)) : 0
                let normalized = min(1.0, max(0.0, rms * 9.0))
                self.onAudioLevel?(normalized)
            }

            // Resample to 16kHz mono Int16
            if let converter {
                let ratio = targetFormat.sampleRate / inputFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
                if let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) {
                    var error: NSError?
                    var consumed = false
                    converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                        if consumed {
                            outStatus.pointee = .noDataNow
                            return nil
                        }
                        consumed = true
                        outStatus.pointee = .haveData
                        return buffer
                    }
                    if error == nil, let floatPtr = convertedBuffer.floatChannelData?[0] {
                        let count = Int(convertedBuffer.frameLength)
                        var chunk: [Int16] = []
                        chunk.reserveCapacity(count)
                        for i in 0..<count {
                            let clamped = max(-1.0, min(1.0, floatPtr[i]))
                            chunk.append(Int16(clamped * Float(Int16.max)))
                        }
                        self.samplesLock.lock()
                        self.capturedInt16Samples.append(contentsOf: chunk)
                        self.samplesLock.unlock()
                    }
                }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isCapturing = true
        } catch {
            stopRecordingInternal(deactivateSession: false)
            let nsErr = error as NSError
            if nsErr.code == AVAudioSession.ErrorCode.insufficientPriority.rawValue ||
                nsErr.code == AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue ||
                nsErr.code == 561015905 {
                throw AudioCaptureError.audioSessionConflict(nsErr.code)
            }
            throw error
        }
    }

    private func resetCapturedSamples() {
        samplesLock.lock()
        defer { samplesLock.unlock() }
        capturedInt16Samples.removeAll(keepingCapacity: true)
        latestSpeechTranscript = ""
    }

    public func stopRecording() -> (wavData: Data, appleSpeechText: String, durationSeconds: Double) {
        let result = stopRecordingInternal(deactivateSession: false)
        return result
    }

    @discardableResult
    private func stopRecordingInternal(deactivateSession: Bool) -> (wavData: Data, appleSpeechText: String, durationSeconds: Double) {
        if isCapturing {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            audioEngine.reset()
            isCapturing = false
        }

        speechRequest?.endAudio()
        speechTask?.finish()
        speechRequest = nil
        speechTask = nil
        speechRecognizer = nil

        samplesLock.lock()
        let samples = capturedInt16Samples
        let transcript = latestSpeechTranscript
        capturedInt16Samples.removeAll()
        samplesLock.unlock()

        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } else {
            // Switch back to passive playback category so orange mic indicator turns off when idle
            try? configureAudioSessionForPiPOnly()
        }

        let duration = Double(samples.count) / 16000.0
        let wav = AudioWAVEncoder.encodePCM16Mono(samples: samples, sampleRate: 16000)
        return (wav, transcript, duration)
    }

    private func resolveLocaleIdentifier(_ code: String) -> String {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "zh", "zh-cn", "zh-hans": return "zh-CN"
        case "zh-tw", "zh-hant": return "zh-TW"
        case "yue", "zh-hk", "yue-hans", "yue-hant": return "zh-HK"
        case "en", "en-us": return "en-US"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "es": return "es-ES"
        case "fr": return "fr-FR"
        case "", "auto":
            if let preferred = Locale.preferredLanguages.first?.lowercased() {
                if preferred.hasPrefix("zh-hant") || preferred.hasPrefix("zh-tw") { return "zh-TW" }
                if preferred.hasPrefix("zh-hk") || preferred.hasPrefix("yue") { return "zh-HK" }
                if preferred.hasPrefix("zh") { return "zh-CN" }
                if preferred.hasPrefix("ja") { return "ja-JP" }
                if preferred.hasPrefix("ko") { return "ko-KR" }
                if preferred.hasPrefix("es") { return "es-ES" }
                if preferred.hasPrefix("fr") { return "fr-FR" }
                if preferred.hasPrefix("en") { return "en-US" }
            }
            if SFSpeechRecognizer.supportedLocales().contains(Locale.current) {
                return Locale.current.identifier
            }
            return "zh-CN"
        default:
            return code
        }
    }
}

import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import UIKit

public final class PiPSampleBufferView: UIView {
    public override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    public var displayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable:next force_cast
        return layer as! AVSampleBufferDisplayLayer
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspectFill
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        displayLayer.videoGravity = .resizeAspectFill
        backgroundColor = .clear
    }
}

public final class PiPKeepAliveManager: NSObject, ObservableObject {
    @Published public private(set) var isPiPSupported: Bool = AVPictureInPictureController.isPictureInPictureSupported()
    @Published public private(set) var isPiPActive: Bool = false
    @Published public private(set) var lastErrorMessage: String?

    public let hostView = PiPSampleBufferView(
        frame: CGRect(
            x: 0,
            y: 0,
            width: KeyboardKeyGestureMap.pipOptimalRenderWidth,
            height: KeyboardKeyGestureMap.pipOptimalRenderHeight
        )
    )

    private var pipController: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var pendingStartWorkItem: DispatchWorkItem?
    private var pendingStart = false
    private var frameTimer: Timer?
    private var currentState: HostVoiceState = .standbyPiP
    private var currentLevel: Float = 0
    private var currentElapsed: Double = 0
    private var frameCounter: Int64 = 0

    public override init() {
        super.init()
        setupPiP()
    }

    deinit {
        possibleObservation?.invalidate()
        pendingStartWorkItem?.cancel()
        stopFramePump()
    }

    public func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            isPiPSupported = false
            return
        }
        isPiPSupported = true

        if pipController == nil {
            let contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: hostView.displayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: contentSource)
            controller.delegate = self
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            controller.requiresLinearPlayback = true
            possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] ctrl, _ in
                let isPossible = ctrl.isPictureInPicturePossible
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if isPossible && self.pendingStart && self.pipController?.isPictureInPictureActive != true {
                        self.triggerStartNow()
                    }
                }
            }
            pipController = controller
        }

        // Prime layer with initial frame so PiP can start immediately when requested
        enqueueStatusFrame()
        startFramePump()
    }

    public func updateDisplay(state: HostVoiceState, level: Float, elapsed: Double) {
        currentState = state
        currentLevel = level
        currentElapsed = elapsed
        enqueueStatusFrame()
    }

    public func startPiP() {
        lastErrorMessage = nil
        pendingStart = true
        pendingStartWorkItem?.cancel()
        setupPiP()

        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            do {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
            } catch {
                let nsErr = error as NSError
                if nsErr.code == AVAudioSession.ErrorCode.insufficientPriority.rawValue ||
                    nsErr.code == AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue {
                    // Background app holds exclusive audio priority; still attempt PiP activation with sampleBuffer layer
                    lastErrorMessage = "提示：其他应用正占用高优先级音频（\(nsErr.code)），若画中画未弹出请先暂停媒体后再试"
                } else {
                    lastErrorMessage = "音频会话激活提示：\(error.localizedDescription)"
                }
            }
        }

        enqueueStatusFrame()

        if pipController?.isPictureInPicturePossible == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.triggerStartNow()
            }
        } else {
            // Wait up to 2.5s for isPictureInPicturePossible KVO instead of failing immediately
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.pendingStart else { return }
                self.triggerStartNow()
            }
            pendingStartWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: timeout)
        }
    }

    private func triggerStartNow() {
        pendingStart = false
        pendingStartWorkItem?.cancel()
        pendingStartWorkItem = nil
        guard let controller = pipController else { return }
        if !controller.isPictureInPictureActive {
            controller.startPictureInPicture()
        } else {
            isPiPActive = true
            lastErrorMessage = nil
        }
    }

    public func stopPiP() {
        pendingStart = false
        pendingStartWorkItem?.cancel()
        pendingStartWorkItem = nil
        pipController?.stopPictureInPicture()
        isPiPActive = false
    }

    private func startFramePump() {
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.enqueueStatusFrame()
        }
    }

    private func stopFramePump() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func enqueueStatusFrame() {
        guard let pixelBuffer = renderStatusPixelBuffer(
            width: KeyboardKeyGestureMap.pipOptimalRenderWidth,
            height: KeyboardKeyGestureMap.pipOptimalRenderHeight
        ) else { return }
        var formatDesc: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard fmtStatus == noErr, let formatDesc else { return }

        frameCounter += 1
        let pts = CMTime(value: frameCounter, timescale: 2)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 2),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let bufStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard bufStatus == noErr, let sBuf = sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sBuf, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
            dict[kCMSampleAttachmentKey_DisplayImmediately] = kCFBooleanTrue
        }

        if #available(iOS 17.0, *) {
            let renderer = hostView.displayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
            }
            if renderer.isReadyForMoreMediaData {
                renderer.enqueue(sBuf)
            }
        } else {
            if hostView.displayLayer.status == .failed {
                hostView.displayLayer.flush()
            }
            if hostView.displayLayer.isReadyForMoreMediaData {
                hostView.displayLayer.enqueue(sBuf)
            }
        }
    }

    private func renderStatusPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        // Flip coordinates so CoreText/UIKit drawing is upright
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        UIColor(red: 0.09, green: 0.11, blue: 0.16, alpha: 1.0).setFill()
        UIBezierPath(rect: rect).fill()

        // Status accent dot & ultra-compact HUD (240x100 @ 2.4:1)
        let dotColor: UIColor
        let title: String
        let subtitle: String
        switch currentState {
        case .recording:
            dotColor = UIColor.systemRed
            title = String(format: "录音 %.1fs", currentElapsed)
            subtitle = "点键盘停止"
        case .transcribing:
            dotColor = UIColor.systemOrange
            title = "语音转写中..."
            subtitle = "实时识别中"
        case .polishing:
            dotColor = UIColor.systemBlue
            title = "AI 整理中..."
            subtitle = "即将自动上屏"
        case .ready:
            dotColor = UIColor.systemGreen
            title = "已就绪并上屏"
            subtitle = "轻点键盘即说"
        case .error:
            dotColor = UIColor.systemYellow
            title = "录音需重连"
            subtitle = "点键盘修复重试"
        case .idle, .standbyPiP:
            dotColor = UIColor.systemGreen
            title = "Lintype 保活中"
            subtitle = "可双指缩至最小·滑边隐藏"
        }

        dotColor.setFill()
        UIBezierPath(ovalIn: CGRect(x: 14, y: 24, width: 10, height: 10)).fill()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        (title as NSString).draw(at: CGPoint(x: 30, y: 20), withAttributes: titleAttrs)

        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: UIColor(white: 0.78, alpha: 1.0)
        ]
        (subtitle as NSString).draw(at: CGPoint(x: 30, y: 46), withAttributes: subAttrs)

        // Compact waveform bars on the right side
        let barCount = 4
        let baseX = width - 48
        for idx in 0..<barCount {
            let phase = abs(sin(Double(frameCounter) * 0.9 + Double(idx) * 0.8))
            let amp = currentState == .recording ? max(0.25, Double(currentLevel) * phase + 0.2) : 0.22
            let barH = CGFloat(8.0 + amp * 32.0)
            let barY = (CGFloat(height) - barH) / 2.0
            let barRect = CGRect(x: CGFloat(baseX + idx * 9), y: barY, width: 5, height: barH)
            UIColor(red: 0.35, green: 0.72, blue: 1.0, alpha: 0.9).setFill()
            UIBezierPath(roundedRect: barRect, cornerRadius: 2.5).fill()
        }

        return pb
    }
}

// MARK: - AVPictureInPictureControllerDelegate & Playback Delegate

extension PiPKeepAliveManager: AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.pendingStart = false
            self.pendingStartWorkItem?.cancel()
            self.pendingStartWorkItem = nil
            self.isPiPActive = true
            self.lastErrorMessage = nil
        }
    }

    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isPiPActive = false
        }
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        DispatchQueue.main.async {
            self.pendingStart = false
            self.isPiPActive = false
            let nsErr = error as NSError
            if nsErr.code == AVAudioSession.ErrorCode.insufficientPriority.rawValue ||
                nsErr.code == AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue {
                self.lastErrorMessage = "其他应用正占用高优先级音频（\(nsErr.code)），请先暂停其他媒体播放或通话后再试。"
            } else {
                self.lastErrorMessage = "画中画启动失败：\(error.localizedDescription)"
            }
        }
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // Keep active regardless of system pause toggle
        enqueueStatusFrame()
    }

    public func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    public func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        enqueueStatusFrame()
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval interval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void
    ) {
        completionHandler()
    }
}

public struct PiPHostPreviewRepresentable: UIViewRepresentable {
    public let view: PiPSampleBufferView

    public func makeUIView(context: Context) -> PiPSampleBufferView {
        view
    }

    public func updateUIView(_ uiView: PiPSampleBufferView, context: Context) {}
}

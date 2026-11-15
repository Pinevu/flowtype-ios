import SwiftUI
import UIKit

// MARK: - Touch-Down Multi-Touch Rollover Coordinator

@MainActor
final class ActiveKeyboardTouchTracker {
    static let shared = ActiveKeyboardTouchTracker()
    private let activeKeys = NSHashTable<NativeKeyTouchView>.weakObjects()

    func register(_ view: NativeKeyTouchView) {
        activeKeys.add(view)
    }

    func unregister(_ view: NativeKeyTouchView) {
        activeKeys.remove(view)
    }

    /// Commits any earlier held typing key cleanly in touch-down order when a second thumb lands fast.
    func commitPendingTapTouchesForRollover(excluding newView: NativeKeyTouchView) {
        for view in activeKeys.allObjects {
            guard view !== newView else { continue }
            view.commitTapForRolloverIfEligible()
        }
    }
}

// MARK: - Shared Keyboard Popup Overlay Canvas (No Clipping Across Keys & Top Bands)

@MainActor
final class NativeKeyPopupCanvasView: UIView {
    static let canvasTag = 94210

    var isDarkMode: Bool = false

    private let bubbleLayer = CAShapeLayer()
    private let bubbleLabel = UILabel()
    private var optionLabels: [UILabel] = []
    private var highlightLayer = CALayer()
    private var visibleOwner: ObjectIdentifier?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        tag = Self.canvasTag
        layer.zPosition = 999

        bubbleLayer.shadowColor = UIColor.black.cgColor
        bubbleLayer.shadowOpacity = 0.24
        bubbleLayer.shadowRadius = 4.5
        bubbleLayer.shadowOffset = CGSize(width: 0, height: 2)
        bubbleLayer.isHidden = true
        layer.addSublayer(bubbleLayer)

        highlightLayer.cornerRadius = 7
        highlightLayer.isHidden = true
        layer.addSublayer(highlightLayer)

        bubbleLabel.textAlignment = .center
        bubbleLabel.isHidden = true
        addSubview(bubbleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func find(from view: UIView) -> NativeKeyPopupCanvasView? {
        var cursor: UIView? = view
        while let current = cursor {
            if let found = current.viewWithTag(canvasTag) as? NativeKeyPopupCanvasView {
                return found
            }
            cursor = current.superview
        }
        return view.window?.viewWithTag(canvasTag) as? NativeKeyPopupCanvasView
    }

    func showSingleBubble(
        owner: AnyObject,
        anchorFrameInCanvas anchor: CGRect,
        text: String,
        isSwipeHighlight: Bool
    ) {
        guard bounds.width > 10, bounds.height > 10 else { return }
        visibleOwner = ObjectIdentifier(owner)
        hideOptionLabels()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let bubbleW = max(anchor.width + 14, 44)
        let bubbleH = max(anchor.height + 8, 48)
        let rawX = anchor.midX - bubbleW * 0.5
        let clampedX = min(max(4, rawX), bounds.width - bubbleW - 4)
        let rawY = anchor.minY - bubbleH - 4
        let clampedY = max(4, rawY)
        let bubbleRect = CGRect(x: clampedX, y: clampedY, width: bubbleW, height: bubbleH)

        let fillColor: UIColor = isSwipeHighlight
            ? .systemBlue
            : (isDarkMode ? UIColor(white: 0.36, alpha: 0.98) : .white)

        bubbleLayer.frame = bounds
        bubbleLayer.path = UIBezierPath(roundedRect: bubbleRect, cornerRadius: 10).cgPath
        bubbleLayer.fillColor = fillColor.cgColor
        bubbleLayer.strokeColor = (isDarkMode ? UIColor.white.withAlphaComponent(0.14) : UIColor.black.withAlphaComponent(0.10)).cgColor
        bubbleLayer.lineWidth = 0.5
        bubbleLayer.isHidden = false

        bubbleLabel.frame = bubbleRect
        bubbleLabel.text = text
        bubbleLabel.font = .systemFont(ofSize: isSwipeHighlight ? 26 : 27, weight: isSwipeHighlight ? .bold : .medium)
        bubbleLabel.textColor = isSwipeHighlight ? .white : (isDarkMode ? .white : .label)
        bubbleLabel.adjustsFontSizeToFitWidth = true
        bubbleLabel.minimumScaleFactor = 0.55
        bubbleLabel.isHidden = false

        CATransaction.commit()
    }

    func showLongPressStrip(
        owner: AnyObject,
        anchorFrameInCanvas anchor: CGRect,
        options: [String],
        selectedIndex: Int
    ) -> [CGRect] {
        guard bounds.width > 10, bounds.height > 10, !options.isEmpty else { return [] }
        visibleOwner = ObjectIdentifier(owner)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        bubbleLabel.isHidden = true

        let count = options.count
        let maxTotalWidth = bounds.width - 12
        let itemWidth = min(38, max(28, (maxTotalWidth - 12) / CGFloat(count)))
        let stripWidth = itemWidth * CGFloat(count) + 12
        let stripHeight: CGFloat = 46

        let desiredX = anchor.midX - stripWidth * 0.5
        let clampedX = min(max(6, desiredX), bounds.width - stripWidth - 6)
        let clampedY = max(4, anchor.minY - stripHeight - 8)
        let stripRect = CGRect(x: clampedX, y: clampedY, width: stripWidth, height: stripHeight)

        let stripBg: UIColor = isDarkMode ? UIColor(white: 0.25, alpha: 0.98) : UIColor(white: 0.99, alpha: 0.98)
        bubbleLayer.frame = bounds
        bubbleLayer.path = UIBezierPath(roundedRect: stripRect, cornerRadius: 11).cgPath
        bubbleLayer.fillColor = stripBg.cgColor
        bubbleLayer.strokeColor = (isDarkMode ? UIColor.white.withAlphaComponent(0.16) : UIColor.black.withAlphaComponent(0.12)).cgColor
        bubbleLayer.lineWidth = 0.5
        bubbleLayer.isHidden = false

        ensureOptionLabelCount(count)
        var cellRects: [CGRect] = []
        let safeIdx = min(max(0, selectedIndex), count - 1)

        for idx in 0..<count {
            let cellRect = CGRect(
                x: stripRect.minX + 6 + CGFloat(idx) * itemWidth,
                y: stripRect.minY + 4,
                width: itemWidth,
                height: stripHeight - 8
            )
            cellRects.append(cellRect)

            let label = optionLabels[idx]
            label.frame = cellRect
            label.text = options[idx]
            let isSelected = idx == safeIdx
            label.font = .systemFont(ofSize: options[idx].count > 1 ? 14 : 20, weight: isSelected ? .semibold : .regular)
            label.textColor = isSelected ? .white : (isDarkMode ? .white : .label)
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.55
            label.isHidden = false
        }

        if safeIdx < cellRects.count {
            highlightLayer.frame = cellRects[safeIdx]
            highlightLayer.backgroundColor = UIColor.systemBlue.cgColor
            highlightLayer.isHidden = false
        }

        CATransaction.commit()
        return cellRects
    }

    func hide(for owner: AnyObject) {
        guard visibleOwner == ObjectIdentifier(owner) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubbleLayer.isHidden = true
        bubbleLabel.isHidden = true
        highlightLayer.isHidden = true
        hideOptionLabels()
        CATransaction.commit()
        visibleOwner = nil
    }

    private func ensureOptionLabelCount(_ needed: Int) {
        while optionLabels.count < needed {
            let lbl = UILabel()
            lbl.textAlignment = .center
            lbl.isHidden = true
            addSubview(lbl)
            optionLabels.append(lbl)
        }
        for i in needed..<optionLabels.count {
            optionLabels[i].isHidden = true
        }
    }

    private func hideOptionLabels() {
        highlightLayer.isHidden = true
        for lbl in optionLabels {
            lbl.isHidden = true
        }
    }
}

struct NativeKeyPopupOverlayView: UIViewRepresentable {
    let isDark: Bool

    func makeUIView(context: Context) -> NativeKeyPopupCanvasView {
        let view = NativeKeyPopupCanvasView()
        view.isDarkMode = isDark
        return view
    }

    func updateUIView(_ uiView: NativeKeyPopupCanvasView, context: Context) {
        uiView.isDarkMode = isDark
    }
}

// MARK: - Tactile Native Key View (0ms Touch-Down + Rollover + Swipe-Up + Long-Press)

struct NativeKeyPresentation: Equatable {
    var title: String = ""
    var systemImage: String? = nil
    var subtitle: String? = nil
    var secondaryHint: String? = nil
    var fontSize: CGFloat = 17
    var fontWeight: UIFont.Weight = .regular
    var tracking: CGFloat = 0
    var subtitleFontSize: CGFloat = 11
    var cornerRadius: CGFloat = 6
    var fillColor: UIColor = .white
    var pressedColor: UIColor = UIColor(white: 0.82, alpha: 1)
    var edgeColor: UIColor = UIColor.black.withAlphaComponent(0.28)
    var textColor: UIColor = .label
    var tintColor: UIColor = .label
    var isDark: Bool = false
    var showsPopover: Bool = true
    var popoverTitle: String? = nil
    var swipeUpText: String? = nil
    var longPressOptions: [String] = []
    var participatesInRollover: Bool = true
    var hapticEnabled: Bool = true
}

struct NativeTactileKey: UIViewRepresentable {
    let presentation: NativeKeyPresentation
    let onTap: () -> Void
    var onCommitSpecial: ((String) -> Void)? = nil
    var onTouchDown: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onCommitSpecial: onCommitSpecial, onTouchDown: onTouchDown)
    }

    func makeUIView(context: Context) -> NativeKeyTouchView {
        let view = NativeKeyTouchView()
        context.coordinator.configure(view: view, presentation: presentation)
        return view
    }

    func updateUIView(_ uiView: NativeKeyTouchView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onCommitSpecial = onCommitSpecial
        context.coordinator.onTouchDown = onTouchDown
        context.coordinator.configure(view: uiView, presentation: presentation)
    }

    final class Coordinator {
        var onTap: () -> Void
        var onCommitSpecial: ((String) -> Void)?
        var onTouchDown: (() -> Void)?
        private var lastPresentation: NativeKeyPresentation?

        init(onTap: @escaping () -> Void, onCommitSpecial: ((String) -> Void)?, onTouchDown: (() -> Void)?) {
            self.onTap = onTap
            self.onCommitSpecial = onCommitSpecial
            self.onTouchDown = onTouchDown
        }

        @MainActor
        func configure(view: NativeKeyTouchView, presentation: NativeKeyPresentation) {
            view.onTapAction = { [weak self] in self?.onTap() }
            view.onSpecialAction = { [weak self] text in
                if let handler = self?.onCommitSpecial {
                    handler(text)
                }
            }
            view.onTouchDownAction = onTouchDown == nil ? nil : { [weak self] in self?.onTouchDown?() }
            if lastPresentation != presentation {
                lastPresentation = presentation
                view.apply(presentation: presentation)
            }
        }
    }
}

@MainActor
final class NativeKeyTouchView: UIView {
    var onTapAction: (() -> Void)?
    var onSpecialAction: ((String) -> Void)?
    var onTouchDownAction: (() -> Void)?

    private var presentation = NativeKeyPresentation()

    private let edgeLayer = CALayer()
    private let cardLayer = CALayer()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let secondaryHintLabel = UILabel()
    private let iconImageView = UIImageView()

    private var activeTouch: UITouch?
    private var startCanvasPoint: CGPoint = .zero
    private var isPressed = false
    private var isSwipedUp = false
    private var isLongPressMenuVisible = false
    private var longPressCellRects: [CGRect] = []
    private var selectedLongPressIndex = 0
    private var committedByRollover = false
    private var longPressWorkItem: DispatchWorkItem?

    private static let impactLight = UIImpactFeedbackGenerator(style: .light)
    private static let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private static let selectionFeedback = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear

        layer.addSublayer(edgeLayer)
        layer.addSublayer(cardLayer)

        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.65
        addSubview(titleLabel)

        subtitleLabel.textAlignment = .center
        subtitleLabel.adjustsFontSizeToFitWidth = true
        subtitleLabel.minimumScaleFactor = 0.7
        addSubview(subtitleLabel)

        secondaryHintLabel.textAlignment = .right
        addSubview(secondaryHintLabel)

        iconImageView.contentMode = .center
        addSubview(iconImageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            cancelTouchSession()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let cr = presentation.cornerRadius
        cardLayer.frame = bounds
        cardLayer.cornerRadius = cr

        edgeLayer.frame = CGRect(x: 2, y: max(0, bounds.height - 2.5), width: max(0, bounds.width - 4), height: 3.5)
        edgeLayer.cornerRadius = 1.75

        if let hint = presentation.secondaryHint, !hint.isEmpty {
            secondaryHintLabel.isHidden = false
            secondaryHintLabel.frame = CGRect(x: 4, y: 2, width: max(0, bounds.width - 9), height: 12)
        } else {
            secondaryHintLabel.isHidden = true
        }

        if let sysImg = presentation.systemImage, !sysImg.isEmpty {
            iconImageView.isHidden = false
            if let sub = presentation.subtitle, !sub.isEmpty {
                titleLabel.isHidden = true
                subtitleLabel.isHidden = false
                iconImageView.frame = CGRect(x: 0, y: max(4, bounds.height * 0.16), width: bounds.width, height: max(14, bounds.height * 0.42))
                subtitleLabel.frame = CGRect(x: 3, y: bounds.height * 0.58, width: max(0, bounds.width - 6), height: max(12, bounds.height * 0.32))
            } else {
                titleLabel.isHidden = true
                subtitleLabel.isHidden = true
                iconImageView.frame = bounds.insetBy(dx: 6, dy: 8)
            }
        } else {
            iconImageView.isHidden = true
            subtitleLabel.isHidden = true
            titleLabel.isHidden = false
            let topOffset: CGFloat = (presentation.secondaryHint?.isEmpty == false && bounds.height >= 40) ? 4 : 0
            titleLabel.frame = CGRect(x: 3, y: topOffset, width: max(0, bounds.width - 6), height: max(0, bounds.height - topOffset))
        }

        CATransaction.commit()
    }

    func apply(presentation p: NativeKeyPresentation) {
        self.presentation = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardLayer.backgroundColor = (isPressed ? p.pressedColor : p.fillColor).cgColor
        cardLayer.cornerRadius = p.cornerRadius
        edgeLayer.backgroundColor = p.edgeColor.cgColor
        edgeLayer.isHidden = p.edgeColor == .clear

        if p.tracking != 0 {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: p.fontSize, weight: p.fontWeight),
                .foregroundColor: p.textColor,
                .kern: p.tracking
            ]
            titleLabel.attributedText = NSAttributedString(string: p.title, attributes: attrs)
        } else {
            titleLabel.attributedText = nil
            titleLabel.text = p.title
            titleLabel.font = .systemFont(ofSize: p.fontSize, weight: p.fontWeight)
            titleLabel.textColor = p.textColor
        }

        if let hint = p.secondaryHint, !hint.isEmpty {
            secondaryHintLabel.text = hint
            secondaryHintLabel.font = .systemFont(ofSize: 9.5, weight: .medium)
            secondaryHintLabel.textColor = p.textColor.withAlphaComponent(0.45)
        }

        if let sysName = p.systemImage, !sysName.isEmpty {
            let symCfg = UIImage.SymbolConfiguration(font: .systemFont(ofSize: p.fontSize, weight: p.fontWeight))
            iconImageView.image = UIImage(systemName: sysName, withConfiguration: symCfg)
            iconImageView.tintColor = p.tintColor
        } else {
            iconImageView.image = nil
        }

        if let sub = p.subtitle, !sub.isEmpty {
            subtitleLabel.text = sub
            subtitleLabel.font = .systemFont(ofSize: p.subtitleFontSize, weight: .medium)
            subtitleLabel.textColor = p.tintColor
        }
        CATransaction.commit()
        setNeedsLayout()
    }

    func commitTapForRolloverIfEligible() {
        guard isPressed,
              presentation.participatesInRollover,
              !isSwipedUp,
              !isLongPressMenuVisible,
              !committedByRollover else { return }
        committedByRollover = true
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        setPressedAppearance(false)
        NativeKeyPopupCanvasView.find(from: self)?.hide(for: self)
        ActiveKeyboardTouchTracker.shared.unregister(self)
        onTapAction?()
    }

    // MARK: Touch Lifecycle

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        if activeTouch != nil {
            cancelTouchSession()
        }

        activeTouch = touch
        committedByRollover = false
        isSwipedUp = false
        isLongPressMenuVisible = false
        longPressCellRects = []
        selectedLongPressIndex = 0

        if presentation.participatesInRollover {
            ActiveKeyboardTouchTracker.shared.commitPendingTapTouchesForRollover(excluding: self)
            ActiveKeyboardTouchTracker.shared.register(self)
        }

        let canvas = NativeKeyPopupCanvasView.find(from: self)
        startCanvasPoint = touch.location(in: canvas ?? self)
        setPressedAppearance(true)

        if let onTouchDownAction {
            onTouchDownAction()
        } else if presentation.hapticEnabled {
            Self.impactLight.impactOccurred()
            Self.impactLight.prepare()
        }

        if presentation.showsPopover, let canvas {
            let anchor = convert(bounds, to: canvas)
            canvas.showSingleBubble(
                owner: self,
                anchorFrameInCanvas: anchor,
                text: presentation.popoverTitle ?? presentation.title,
                isSwipeHighlight: false
            )
        }

        if !presentation.longPressOptions.isEmpty {
            let item = DispatchWorkItem { [weak self] in
                self?.enterLongPressMenu()
            }
            longPressWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34, execute: item)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), !committedByRollover else { return }
        let canvas = NativeKeyPopupCanvasView.find(from: self)
        let pt = touch.location(in: canvas ?? self)
        let dx = pt.x - startCanvasPoint.x
        let dy = pt.y - startCanvasPoint.y

        if isLongPressMenuVisible, let canvas {
            updateLongPressSelection(canvasX: pt.x, canvas: canvas)
            return
        }

        if abs(dx) > 10 || abs(dy) > 10 {
            longPressWorkItem?.cancel()
            longPressWorkItem = nil
        }

        if let upText = presentation.swipeUpText, !upText.isEmpty {
            if !isSwipedUp && dy <= -22 {
                isSwipedUp = true
                if presentation.hapticEnabled {
                    Self.impactLight.impactOccurred(intensity: 0.85)
                }
                if let canvas {
                    let anchor = convert(bounds, to: canvas)
                    canvas.showSingleBubble(
                        owner: self,
                        anchorFrameInCanvas: anchor,
                        text: upText,
                        isSwipeHighlight: true
                    )
                }
            } else if isSwipedUp && dy > -14 {
                isSwipedUp = false
                if presentation.showsPopover, let canvas {
                    let anchor = convert(bounds, to: canvas)
                    canvas.showSingleBubble(
                        owner: self,
                        anchorFrameInCanvas: anchor,
                        text: presentation.popoverTitle ?? presentation.title,
                        isSwipeHighlight: false
                    )
                } else {
                    canvas?.hide(for: self)
                }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        let canvas = NativeKeyPopupCanvasView.find(from: self)
        let pt = touch.location(in: canvas ?? self)
        let dx = pt.x - startCanvasPoint.x
        let dy = pt.y - startCanvasPoint.y

        let wasRolloverCommitted = committedByRollover
        let wasLongPress = isLongPressMenuVisible
        let pickedLongPressIdx = selectedLongPressIndex
        let wasSwipeUp = isSwipedUp

        cleanupVisualSession()

        guard !wasRolloverCommitted else { return }

        if wasLongPress && pickedLongPressIdx < presentation.longPressOptions.count {
            let picked = presentation.longPressOptions[pickedLongPressIdx]
            onSpecialAction?(picked)
        } else if wasSwipeUp, let upText = presentation.swipeUpText {
            onSpecialAction?(upText)
        } else if abs(dx) <= 72 && dy <= 68 {
            onTapAction?()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelTouchSession()
    }

    private func enterLongPressMenu() {
        guard isPressed, !committedByRollover, !isSwipedUp,
              !presentation.longPressOptions.isEmpty,
              let canvas = NativeKeyPopupCanvasView.find(from: self) else { return }

        isLongPressMenuVisible = true
        selectedLongPressIndex = 0
        if presentation.hapticEnabled {
            Self.impactMedium.impactOccurred()
        }
        let anchor = convert(bounds, to: canvas)
        longPressCellRects = canvas.showLongPressStrip(
            owner: self,
            anchorFrameInCanvas: anchor,
            options: presentation.longPressOptions,
            selectedIndex: 0
        )
    }

    private func updateLongPressSelection(canvasX: CGFloat, canvas: NativeKeyPopupCanvasView) {
        guard !longPressCellRects.isEmpty else { return }
        var nearestIdx = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (idx, rect) in longPressCellRects.enumerated() {
            if canvasX >= rect.minX && canvasX <= rect.maxX {
                nearestIdx = idx
                break
            }
            let d = abs(canvasX - rect.midX)
            if d < bestDist {
                bestDist = d
                nearestIdx = idx
            }
        }
        if nearestIdx != selectedLongPressIndex {
            selectedLongPressIndex = nearestIdx
            if presentation.hapticEnabled {
                Self.selectionFeedback.selectionChanged()
            }
            let anchor = convert(bounds, to: canvas)
            longPressCellRects = canvas.showLongPressStrip(
                owner: self,
                anchorFrameInCanvas: anchor,
                options: presentation.longPressOptions,
                selectedIndex: nearestIdx
            )
        }
    }

    private func setPressedAppearance(_ pressed: Bool) {
        isPressed = pressed
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardLayer.backgroundColor = (pressed ? presentation.pressedColor : presentation.fillColor).cgColor
        CATransaction.commit()
    }

    private func cleanupVisualSession() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        ActiveKeyboardTouchTracker.shared.unregister(self)
        NativeKeyPopupCanvasView.find(from: self)?.hide(for: self)
        setPressedAppearance(false)
        activeTouch = nil
        isSwipedUp = false
        isLongPressMenuVisible = false
        longPressCellRects = []
        committedByRollover = false
    }

    private func cancelTouchSession() {
        cleanupVisualSession()
    }
}

// MARK: - Exclusive Native Chevron Control (Candidate Bar Expand/Collapse)

struct NativeChevronControl: UIViewRepresentable {
    let isOpen: Bool
    let isHighlightedBadge: Bool
    let isDark: Bool
    let hapticEnabled: Bool
    var onTouchDown: (() -> Void)? = nil
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTouchDown: onTouchDown, action: action)
    }

    func makeUIView(context: Context) -> NativeChevronUIView {
        let v = NativeChevronUIView()
        context.coordinator.configure(view: v, isOpen: isOpen, isHighlightedBadge: isHighlightedBadge, isDark: isDark, hapticEnabled: hapticEnabled)
        return v
    }

    func updateUIView(_ uiView: NativeChevronUIView, context: Context) {
        context.coordinator.onTouchDown = onTouchDown
        context.coordinator.action = action
        context.coordinator.configure(view: uiView, isOpen: isOpen, isHighlightedBadge: isHighlightedBadge, isDark: isDark, hapticEnabled: hapticEnabled)
    }

    final class Coordinator {
        var onTouchDown: (() -> Void)?
        var action: () -> Void
        init(onTouchDown: (() -> Void)?, action: @escaping () -> Void) {
            self.onTouchDown = onTouchDown
            self.action = action
        }

        @MainActor
        func configure(view: NativeChevronUIView, isOpen: Bool, isHighlightedBadge: Bool, isDark: Bool, hapticEnabled: Bool) {
            view.onTouchDown = onTouchDown == nil ? nil : { [weak self] in self?.onTouchDown?() }
            view.onActivate = { [weak self] in self?.action() }
            view.hapticEnabled = hapticEnabled
            view.updateStyle(isOpen: isOpen, isHighlightedBadge: isHighlightedBadge, isDark: isDark)
        }
    }
}

@MainActor
final class NativeChevronUIView: UIControl {
    var onTouchDown: (() -> Void)?
    var onActivate: (() -> Void)?
    var hapticEnabled: Bool = true

    private let pillLayer = CALayer()
    private let iconView = UIImageView()
    private var startPoint: CGPoint = .zero
    private var lastIsOpen: Bool = false
    private var lastIsHighlightedBadge: Bool = false
    private var lastIsDark: Bool = false
    private static let haptic = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isExclusiveTouch = true
        backgroundColor = .clear

        pillLayer.cornerRadius = 8
        layer.addSublayer(pillLayer)

        iconView.contentMode = .center
        addSubview(iconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillLayer.frame = bounds.insetBy(dx: 5, dy: 6)
        iconView.frame = bounds
        CATransaction.commit()
    }

    func updateStyle(isOpen: Bool, isHighlightedBadge: Bool, isDark: Bool) {
        lastIsOpen = isOpen
        lastIsHighlightedBadge = isHighlightedBadge
        lastIsDark = isDark
        let sym = isOpen ? "chevron.up" : "chevron.down"
        let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        iconView.image = UIImage(systemName: sym, withConfiguration: cfg)
        if isOpen {
            iconView.tintColor = .systemBlue
        } else if isHighlightedBadge {
            iconView.tintColor = isDark ? .white : .label
        } else {
            iconView.tintColor = .secondaryLabel
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillLayer.backgroundColor = isOpen
            ? UIColor.systemBlue.withAlphaComponent(0.14).cgColor
            : (isHighlightedBadge
               ? (isDark ? UIColor.white.withAlphaComponent(0.10) : UIColor.black.withAlphaComponent(0.06)).cgColor
               : UIColor.clear.cgColor)
        CATransaction.commit()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if let t = touches.first {
            startPoint = t.location(in: self)
        }
        if let onTouchDown {
            onTouchDown()
        } else if hapticEnabled {
            Self.haptic.impactOccurred()
            Self.haptic.prepare()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillLayer.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.18).cgColor
        iconView.tintColor = .systemBlue
        CATransaction.commit()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        updateStyle(isOpen: lastIsOpen, isHighlightedBadge: lastIsHighlightedBadge, isDark: lastIsDark)
        guard let t = touches.first else { return }
        let pt = t.location(in: self)
        let dx = abs(pt.x - startPoint.x)
        let dy = abs(pt.y - startPoint.y)
        if bounds.insetBy(dx: -18, dy: -16).contains(pt) || (dx < 52 && dy < 48) {
            onActivate?()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        updateStyle(isOpen: lastIsOpen, isHighlightedBadge: lastIsHighlightedBadge, isDark: lastIsDark)
    }
}

struct KeyPaletteUIColors: Equatable {
    let isDark: Bool
    let isTranslucent: Bool

    var key: UIColor {
        isDark
            ? UIColor(white: 0.29, alpha: isTranslucent ? 0.88 : 1.0)
            : UIColor.white.withAlphaComponent(isTranslucent ? 0.90 : 1.0)
    }

    var keyPressed: UIColor {
        isDark ? UIColor(white: 0.43, alpha: 1.0) : UIColor(white: 0.78, alpha: 1.0)
    }

    var special: UIColor {
        isDark
            ? UIColor(white: 0.19, alpha: isTranslucent ? 0.86 : 1.0)
            : UIColor(red: 0.68, green: 0.70, blue: 0.75, alpha: isTranslucent ? 0.86 : 1.0)
    }

    var specialPressed: UIColor {
        isDark
            ? UIColor(white: 0.30, alpha: 1.0)
            : UIColor(red: 0.56, green: 0.58, blue: 0.64, alpha: 1.0)
    }

    var accentFill: UIColor {
        UIColor.systemBlue.withAlphaComponent(0.20)
    }

    var accentPressed: UIColor {
        UIColor.systemBlue.withAlphaComponent(0.32)
    }

    var edge: UIColor {
        UIColor.black.withAlphaComponent(isDark ? 0.50 : 0.28)
    }

    var primaryText: UIColor {
        isDark ? .white : UIColor(white: 0.08, alpha: 1.0)
    }
}

// MARK: - Native UIKit Hold-Repeat Key (Backspace)

struct NativeHoldRepeatKey: UIViewRepresentable {
    let systemImage: String
    let fontSize: CGFloat
    let cornerRadius: CGFloat
    let fillColor: UIColor
    let pressedColor: UIColor
    let edgeColor: UIColor
    let tintColor: UIColor
    let hapticEnabled: Bool
    var onTouchDown: (() -> Void)? = nil
    let onTap: () -> Void
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTouchDown: onTouchDown, onTap: onTap, onHoldStart: onHoldStart, onHoldEnd: onHoldEnd)
    }

    func makeUIView(context: Context) -> NativeHoldRepeatUIView {
        let v = NativeHoldRepeatUIView()
        context.coordinator.bind(view: v)
        v.update(
            systemImage: systemImage,
            fontSize: fontSize,
            cornerRadius: cornerRadius,
            fill: fillColor,
            pressed: pressedColor,
            edge: edgeColor,
            tint: tintColor,
            hapticEnabled: hapticEnabled
        )
        return v
    }

    func updateUIView(_ uiView: NativeHoldRepeatUIView, context: Context) {
        context.coordinator.onTouchDown = onTouchDown
        context.coordinator.onTap = onTap
        context.coordinator.onHoldStart = onHoldStart
        context.coordinator.onHoldEnd = onHoldEnd
        context.coordinator.bind(view: uiView)
        uiView.update(
            systemImage: systemImage,
            fontSize: fontSize,
            cornerRadius: cornerRadius,
            fill: fillColor,
            pressed: pressedColor,
            edge: edgeColor,
            tint: tintColor,
            hapticEnabled: hapticEnabled
        )
    }

    final class Coordinator {
        var onTouchDown: (() -> Void)?
        var onTap: () -> Void
        var onHoldStart: () -> Void
        var onHoldEnd: () -> Void

        init(onTouchDown: (() -> Void)?, onTap: @escaping () -> Void, onHoldStart: @escaping () -> Void, onHoldEnd: @escaping () -> Void) {
            self.onTouchDown = onTouchDown
            self.onTap = onTap
            self.onHoldStart = onHoldStart
            self.onHoldEnd = onHoldEnd
        }

        @MainActor
        func bind(view: NativeHoldRepeatUIView) {
            view.onTouchDown = onTouchDown == nil ? nil : { [weak self] in self?.onTouchDown?() }
            view.onTap = { [weak self] in self?.onTap() }
            view.onHoldStart = { [weak self] in self?.onHoldStart() }
            view.onHoldEnd = { [weak self] in self?.onHoldEnd() }
        }
    }
}

@MainActor
final class NativeHoldRepeatUIView: UIView {
    var onTouchDown: (() -> Void)?
    var onTap: (() -> Void)?
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?
    var hapticEnabled: Bool = true

    private let edgeLayer = CALayer()
    private let cardLayer = CALayer()
    private let iconView = UIImageView()

    private var fillColor: UIColor = .systemGray3
    private var pressedColor: UIColor = .systemGray2
    private var isPressed = false
    private var didEnterHold = false
    private var holdWorkItem: DispatchWorkItem?
    private var startPoint: CGPoint = .zero
    private static let haptic = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isExclusiveTouch = true
        layer.addSublayer(edgeLayer)
        layer.addSublayer(cardLayer)
        iconView.contentMode = .center
        addSubview(iconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            abortHold()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardLayer.frame = bounds
        edgeLayer.frame = CGRect(x: 2, y: max(0, bounds.height - 2.5), width: max(0, bounds.width - 4), height: 3.5)
        edgeLayer.cornerRadius = 1.75
        iconView.frame = bounds
        CATransaction.commit()
    }

    func update(
        systemImage: String,
        fontSize: CGFloat,
        cornerRadius: CGFloat,
        fill: UIColor,
        pressed: UIColor,
        edge: UIColor,
        tint: UIColor,
        hapticEnabled: Bool
    ) {
        self.fillColor = fill
        self.pressedColor = pressed
        self.hapticEnabled = hapticEnabled
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardLayer.cornerRadius = cornerRadius
        cardLayer.backgroundColor = (isPressed ? pressed : fill).cgColor
        edgeLayer.backgroundColor = edge.cgColor
        edgeLayer.isHidden = edge == .clear
        let cfg = UIImage.SymbolConfiguration(pointSize: fontSize, weight: .medium)
        iconView.image = UIImage(systemName: systemImage, withConfiguration: cfg)
        iconView.tintColor = tint
        CATransaction.commit()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        startPoint = touch.location(in: self)
        didEnterHold = false
        isPressed = true
        updateBg()
        if let onTouchDown {
            onTouchDown()
        } else if hapticEnabled {
            Self.haptic.impactOccurred()
            Self.haptic.prepare()
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPressed else { return }
            self.didEnterHold = true
            self.onHoldStart?()
        }
        holdWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34, execute: work)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        let wasHold = didEnterHold
        let pt = touches.first?.location(in: self) ?? startPoint
        didEnterHold = false
        isPressed = false
        updateBg()

        if wasHold {
            onHoldEnd?()
        } else if abs(pt.x - startPoint.x) < 56 && abs(pt.y - startPoint.y) < 56 {
            onTap?()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        abortHold()
    }

    private func abortHold() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        if didEnterHold {
            didEnterHold = false
            onHoldEnd?()
        }
        if isPressed {
            isPressed = false
            updateBg()
        }
    }

    private func updateBg() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardLayer.backgroundColor = (isPressed ? pressedColor : fillColor).cgColor
        CATransaction.commit()
    }
}

// MARK: - Native UIKit Spacebar with Tap + Long-Press Cursor Trackpad

struct NativeSpacebarKey: UIViewRepresentable {
    let title: String
    let fontSize: CGFloat
    let cornerRadius: CGFloat
    let fillColor: UIColor
    let pressedColor: UIColor
    let edgeColor: UIColor
    let textColor: UIColor
    let hapticEnabled: Bool
    var onTouchDown: (() -> Void)? = nil
    let onTap: () -> Void
    let onTrackpadDrag: (CGFloat) -> Void
    let onTrackpadEnd: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTouchDown: onTouchDown, onTap: onTap, onTrackpadDrag: onTrackpadDrag, onTrackpadEnd: onTrackpadEnd)
    }

    func makeUIView(context: Context) -> NativeSpacebarUIView {
        let v = NativeSpacebarUIView()
        context.coordinator.bind(view: v)
        v.update(
            title: title,
            fontSize: fontSize,
            cornerRadius: cornerRadius,
            fill: fillColor,
            pressed: pressedColor,
            edge: edgeColor,
            textColor: textColor,
            hapticEnabled: hapticEnabled
        )
        return v
    }

    func updateUIView(_ uiView: NativeSpacebarUIView, context: Context) {
        context.coordinator.onTouchDown = onTouchDown
        context.coordinator.onTap = onTap
        context.coordinator.onTrackpadDrag = onTrackpadDrag
        context.coordinator.onTrackpadEnd = onTrackpadEnd
        context.coordinator.bind(view: uiView)
        uiView.update(
            title: title,
            fontSize: fontSize,
            cornerRadius: cornerRadius,
            fill: fillColor,
            pressed: pressedColor,
            edge: edgeColor,
            textColor: textColor,
            hapticEnabled: hapticEnabled
        )
    }

    final class Coordinator {
        var onTouchDown: (() -> Void)?
        var onTap: () -> Void
        var onTrackpadDrag: (CGFloat) -> Void
        var onTrackpadEnd: () -> Void

        init(onTouchDown: (() -> Void)?, onTap: @escaping () -> Void, onTrackpadDrag: @escaping (CGFloat) -> Void, onTrackpadEnd: @escaping () -> Void) {
            self.onTouchDown = onTouchDown
            self.onTap = onTap
            self.onTrackpadDrag = onTrackpadDrag
            self.onTrackpadEnd = onTrackpadEnd
        }

        @MainActor
        func bind(view: NativeSpacebarUIView) {
            view.onTouchDown = onTouchDown == nil ? nil : { [weak self] in self?.onTouchDown?() }
            view.onTap = { [weak self] in self?.onTap() }
            view.onTrackpadDrag = { [weak self] dx in self?.onTrackpadDrag(dx) }
            view.onTrackpadEnd = { [weak self] in self?.onTrackpadEnd() }
        }
    }
}

@MainActor
final class NativeSpacebarUIView: UIView {
    var onTouchDown: (() -> Void)?
    var onTap: (() -> Void)?
    var onTrackpadDrag: ((CGFloat) -> Void)?
    var onTrackpadEnd: (() -> Void)?
    var hapticEnabled: Bool = true

    private let edgeLayer = CALayer()
    private let cardLayer = CALayer()
    private let titleLabel = UILabel()

    private var normalTitle: String = ""
    private var normalFontSize: CGFloat = 14
    private var fillColor: UIColor = .white
    private var pressedColor: UIColor = .systemGray4
    private var normalTextColor: UIColor = .secondaryLabel

    private var activeTouch: UITouch?
    private var startPoint: CGPoint = .zero
    private var lastTrackpadX: CGFloat = 0
    private var isPressed = false
    private var isTrackpadActive = false
    private var holdWorkItem: DispatchWorkItem?
    private static let hapticLight = UIImpactFeedbackGenerator(style: .light)
    private static let hapticMedium = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        layer.addSublayer(edgeLayer)
        layer.addSublayer(cardLayer)
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.7
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            resetState()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardLayer.frame = bounds
        edgeLayer.frame = CGRect(x: 3, y: max(0, bounds.height - 2.5), width: max(0, bounds.width - 6), height: 3.5)
        edgeLayer.cornerRadius = 1.75
        titleLabel.frame = bounds.insetBy(dx: 6, dy: 0)
        CATransaction.commit()
    }

    func update(
        title: String,
        fontSize: CGFloat,
        cornerRadius: CGFloat,
        fill: UIColor,
        pressed: UIColor,
        edge: UIColor,
        textColor: UIColor,
        hapticEnabled: Bool
    ) {
        self.normalTitle = title
        self.normalFontSize = fontSize
        self.fillColor = fill
        self.pressedColor = pressed
        self.normalTextColor = textColor
        self.hapticEnabled = hapticEnabled
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardLayer.cornerRadius = cornerRadius
        edgeLayer.backgroundColor = edge.cgColor
        edgeLayer.isHidden = edge == .clear
        CATransaction.commit()
        refreshVisuals()
    }

    private func refreshVisuals() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isTrackpadActive {
            cardLayer.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.22).cgColor
            titleLabel.text = "◀ 滑动移动光标 ▶"
            titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
            titleLabel.textColor = .systemBlue
        } else {
            cardLayer.backgroundColor = (isPressed ? pressedColor : fillColor).cgColor
            titleLabel.text = normalTitle
            titleLabel.font = .systemFont(ofSize: normalFontSize, weight: .regular)
            titleLabel.textColor = normalTextColor
        }
        CATransaction.commit()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        activeTouch = touch
        startPoint = touch.location(in: self)
        lastTrackpadX = startPoint.x
        isPressed = true
        isTrackpadActive = false
        refreshVisuals()
        if let onTouchDown {
            onTouchDown()
        } else if hapticEnabled {
            Self.hapticLight.impactOccurred()
            Self.hapticLight.prepare()
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPressed else { return }
            self.isTrackpadActive = true
            self.refreshVisuals()
            if self.hapticEnabled {
                Self.hapticMedium.impactOccurred()
            }
        }
        holdWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        let pt = touch.location(in: self)
        if isTrackpadActive {
            let delta = pt.x - lastTrackpadX
            lastTrackpadX = pt.x
            onTrackpadDrag?(delta)
        } else if abs(pt.x - startPoint.x) > 12 || abs(pt.y - startPoint.y) > 12 {
            holdWorkItem?.cancel()
            holdWorkItem = nil
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        let pt = touch.location(in: self)
        let wasTrackpad = isTrackpadActive
        resetState()
        if wasTrackpad {
            onTrackpadEnd?()
        } else if abs(pt.x - startPoint.x) < 60 && abs(pt.y - startPoint.y) < 56 {
            onTap?()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let wasTrackpad = isTrackpadActive
        resetState()
        if wasTrackpad {
            onTrackpadEnd?()
        }
    }

    private func resetState() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        activeTouch = nil
        isPressed = false
        isTrackpadActive = false
        refreshVisuals()
    }
}

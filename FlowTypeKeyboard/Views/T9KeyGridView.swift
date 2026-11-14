import SwiftUI

// MARK: - Key Palette & Press Style

struct KeyPalette: Equatable {
    let isDark: Bool
    let isTranslucent: Bool

    init(colorScheme: ColorScheme, isTranslucent: Bool) {
        self.isDark = colorScheme == .dark
        self.isTranslucent = isTranslucent
    }

    var key: Color {
        isDark
            ? Color(white: 0.29).opacity(isTranslucent ? 0.88 : 1.0)
            : Color.white.opacity(isTranslucent ? 0.90 : 1.0)
    }

    var keyPressed: Color {
        isDark ? Color(white: 0.42) : Color(white: 0.80)
    }

    var special: Color {
        isDark
            ? Color(white: 0.19).opacity(isTranslucent ? 0.86 : 1.0)
            : Color(red: 0.68, green: 0.70, blue: 0.75).opacity(isTranslucent ? 0.86 : 1.0)
    }

    var specialPressed: Color {
        isDark ? Color(white: 0.30) : Color(red: 0.56, green: 0.58, blue: 0.64)
    }

    var edge: Color {
        Color.black.opacity(isDark ? 0.50 : 0.28)
    }
}

/// Zero-latency keycap with instant pressed-state feedback on touch-down (DragGesture minimumDistance: 0).
struct T9ResponsiveKey<Label: View>: View {
    let fill: Color
    let pressedFill: Color
    let edge: Color
    var cornerRadius: CGFloat = 7
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isPressed = false

    var body: some View {
        label()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(edge)
                        .frame(height: 1.5)
                        .padding(.horizontal, 3)
                        .offset(y: 1)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isPressed ? pressedFill : fill)
                }
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                        }
                    }
                    .onEnded { value in
                        isPressed = false
                        if abs(value.translation.width) < 44 && abs(value.translation.height) < 44 {
                            action()
                        }
                    }
            )
    }
}

/// Key that supports tap on release and press-and-hold repeat (used for backspace).
struct HoldRepeatKey<Label: View>: View {
    let fill: Color
    let pressedFill: Color
    let edge: Color
    let onTap: () -> Void
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isPressed = false
    @State private var didHold = false
    @State private var holdWork: DispatchWorkItem?

    var body: some View {
        label()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(edge)
                        .frame(height: 1.5)
                        .padding(.horizontal, 3)
                        .offset(y: 1)
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isPressed ? pressedFill : fill)
                }
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        didHold = false
                        let work = DispatchWorkItem {
                            didHold = true
                            onHoldStart()
                        }
                        holdWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
                    }
                    .onEnded { value in
                        isPressed = false
                        holdWork?.cancel()
                        holdWork = nil
                        if didHold {
                            onHoldEnd()
                        } else if abs(value.translation.width) < 44, abs(value.translation.height) < 44 {
                            onTap()
                        }
                        didHold = false
                    }
            )
            .onDisappear {
                holdWork?.cancel()
                holdWork = nil
                if didHold {
                    didHold = false
                    onHoldEnd()
                }
                isPressed = false
            }
    }
}

// MARK: - Nine-Key Grid (isolated so typing does not re-render it)

struct T9GridState: Equatable {
    var isComposing: Bool
    var isPickerExpanded: Bool
    var isEmoticonOpen: Bool
    var selectedFilter: String?
    var syllableOptions: [String]
    var returnTitle: String
    var returnIsAccent: Bool
    var isTranslucent: Bool
}

struct T9KeyGridView: View, Equatable {
    let model: KeyboardStateModel
    let state: T9GridState
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: T9KeyGridView, rhs: T9KeyGridView) -> Bool {
        lhs.model === rhs.model && lhs.state == rhs.state
    }

    private enum KeyKind {
        case normal
        case special
        case accent
    }

    private var palette: KeyPalette {
        KeyPalette(colorScheme: colorScheme, isTranslucent: state.isTranslucent)
    }

    var body: some View {
        GeometryReader { geo in
            let rowSpacing: CGFloat = 7
            let colSpacing: CGFloat = 6
            let rowHeight = max(36, (geo.size.height - rowSpacing * 3) / 4)
            let span2Height = rowHeight * 2 + rowSpacing
            let colWidth = max(46, (geo.size.width - colSpacing * 4) / 5)
            let span2Width = colWidth * 2 + colSpacing

            HStack(alignment: .top, spacing: colSpacing) {
                leftColumn(colWidth: colWidth, rowHeight: rowHeight, span2Height: span2Height, rowSpacing: rowSpacing)
                centerColumns(colWidth: colWidth, rowHeight: rowHeight, span2Width: span2Width, rowSpacing: rowSpacing, colSpacing: colSpacing)
                rightColumn(colWidth: colWidth, rowHeight: rowHeight, span2Height: span2Height, rowSpacing: rowSpacing)
            }
        }
    }

    // MARK: Columns

    @ViewBuilder
    private func leftColumn(colWidth: CGFloat, rowHeight: CGFloat, span2Height: CGFloat, rowSpacing: CGFloat) -> some View {
        if state.isPickerExpanded && state.isComposing {
            pinyinSidebar(width: colWidth, height: rowHeight * 4 + rowSpacing * 3)
        } else {
            VStack(spacing: rowSpacing) {
                capKey("123", size: 15, kind: .special, width: colWidth, height: rowHeight) {
                    model.switchLayoutPage(.numbers)
                }
                capKey("#@¥", size: 15, kind: .special, width: colWidth, height: rowHeight) {
                    model.switchLayoutPage(.symbols)
                }
                capKey("ABC", size: 16, kind: .special, width: colWidth, height: span2Height) {
                    model.toggleManualLanguage()
                }
            }
        }
    }

    private func centerColumns(colWidth: CGFloat, rowHeight: CGFloat, span2Width: CGFloat, rowSpacing: CGFloat, colSpacing: CGFloat) -> some View {
        VStack(spacing: rowSpacing) {
            HStack(spacing: colSpacing) {
                capKey(",。?!", size: 16, kind: .normal, width: colWidth, height: rowHeight) {
                    model.handleT9PunctuationKeyTap()
                }
                letterKey("2", "ABC", colWidth, rowHeight)
                letterKey("3", "DEF", colWidth, rowHeight)
            }
            HStack(spacing: colSpacing) {
                letterKey("4", "GHI", colWidth, rowHeight)
                letterKey("5", "JKL", colWidth, rowHeight)
                letterKey("6", "MNO", colWidth, rowHeight)
            }
            HStack(spacing: colSpacing) {
                letterKey("7", "PQRS", colWidth, rowHeight)
                letterKey("8", "TUV", colWidth, rowHeight)
                letterKey("9", "WXYZ", colWidth, rowHeight)
            }
            HStack(spacing: colSpacing) {
                let filterActive = state.selectedFilter != nil || state.isPickerExpanded
                capKey(
                    state.selectedFilter ?? "选拼音",
                    size: 14,
                    kind: filterActive ? .accent : .normal,
                    foreground: filterActive ? .blue : (state.isComposing ? .primary : .secondary),
                    width: colWidth,
                    height: rowHeight
                ) {
                    model.toggleT9PinyinPicker()
                }

                SpacebarTrackpadKey(
                    title: "空格",
                    fixedWidth: span2Width,
                    height: rowHeight,
                    keyColor: palette.key,
                    pressedColor: palette.keyPressed,
                    edgeColor: palette.edge,
                    onTap: { model.handleT9SpaceTap() },
                    onTrackpadDrag: { dx in model.handleSpaceTrackpadDrag(deltaX: dx) },
                    onTrackpadEnd: { model.resetSpaceTrackpad() }
                )
            }
        }
    }

    private func rightColumn(colWidth: CGFloat, rowHeight: CGFloat, span2Height: CGFloat, rowSpacing: CGFloat) -> some View {
        VStack(spacing: rowSpacing) {
            HoldRepeatKey(
                fill: palette.special,
                pressedFill: palette.specialPressed,
                edge: palette.edge,
                onTap: { model.handleBackspaceTap() },
                onHoldStart: { model.startContinuousBackspace() },
                onHoldEnd: { model.stopContinuousBackspace() }
            ) {
                Image(systemName: "delete.left")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(width: colWidth, height: rowHeight)

            capKey(
                "^_^",
                size: 15,
                kind: state.isEmoticonOpen ? .accent : .special,
                foreground: state.isEmoticonOpen ? .blue : .primary,
                width: colWidth,
                height: rowHeight
            ) {
                model.toggleEmoticonDrawer()
            }

            T9ResponsiveKey(
                fill: state.returnIsAccent ? Color.blue : palette.special,
                pressedFill: state.returnIsAccent ? Color.blue.opacity(0.75) : palette.specialPressed,
                edge: palette.edge,
                cornerRadius: 7
            ) {
                model.handleReturnTap()
            } label: {
                Text(state.returnTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(state.returnIsAccent ? Color.white : Color.primary)
            }
            .frame(width: colWidth, height: span2Height)
        }
    }

    // MARK: Key Builders

    private func letterKey(_ digit: String, _ letters: String, _ width: CGFloat, _ height: CGFloat) -> some View {
        T9ResponsiveKey(
            fill: palette.key,
            pressedFill: palette.keyPressed,
            edge: palette.edge,
            cornerRadius: 7
        ) {
            model.handleT9KeyTap(digit)
        } label: {
            ZStack(alignment: .topTrailing) {
                Text(letters)
                    .font(.system(size: 17, weight: .medium))
                    .tracking(1.4)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text(digit)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.60))
                    .padding(.top, 4)
                    .padding(.trailing, 6)
            }
        }
        .frame(width: width, height: height)
        .accessibilityLabel("\(digit) \(letters)")
    }

    private func capKey(
        _ title: String,
        size: CGFloat,
        kind: KeyKind,
        foreground: Color = .primary,
        tracking: CGFloat = 0,
        width: CGFloat,
        height: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        let fill: Color
        let pressed: Color
        switch kind {
        case .normal:
            fill = palette.key
            pressed = palette.keyPressed
        case .special:
            fill = palette.special
            pressed = palette.specialPressed
        case .accent:
            fill = Color.blue.opacity(0.20)
            pressed = Color.blue.opacity(0.32)
        }
        return T9ResponsiveKey(
            fill: fill,
            pressedFill: pressed,
            edge: palette.edge,
            cornerRadius: 7,
            action: action
        ) {
            Text(title)
                .font(.system(size: size, weight: .medium))
                .tracking(tracking)
                .foregroundStyle(foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: width, height: height)
    }

    // MARK: Pinyin Syllable Sidebar (选拼音)

    private func pinyinSidebar(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 4) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    if state.selectedFilter != nil {
                        sidebarButton("重选", width: width - 4, height: 30, kind: .accent, foreground: .orange) {
                            model.selectT9SyllableFilter(nil)
                        }
                    }

                    ForEach(state.syllableOptions, id: \.self) { syll in
                        let isSelected = state.selectedFilter == syll
                        sidebarButton(syll, width: width - 4, height: 34, kind: isSelected ? .accent : .normal, foreground: isSelected ? .blue : .primary) {
                            model.selectT9SyllableFilter(syll)
                        }
                    }

                    sidebarButton("分词 '", width: width - 4, height: 30, kind: .normal, foreground: .secondary) {
                        model.insertT9SyllableSeparator()
                    }
                }
                .padding(.vertical, 3)
            }

            sidebarButton("收起", width: width - 4, height: 30, kind: .accent, foreground: .blue) {
                model.toggleT9PinyinPicker()
            }
            .padding(.bottom, 3)
        }
        .frame(width: width, height: height)
        .background(palette.special)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func sidebarButton(
        _ title: String,
        width: CGFloat,
        height: CGFloat,
        kind: KeyKind,
        foreground: Color,
        action: @escaping () -> Void
    ) -> some View {
        let fill: Color = kind == .accent ? Color.blue.opacity(0.20) : palette.key
        let pressed: Color = kind == .accent ? Color.blue.opacity(0.32) : palette.keyPressed
        return T9ResponsiveKey(
            fill: fill,
            pressedFill: pressed,
            edge: Color.clear,
            cornerRadius: 6,
            action: action
        ) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(foreground)
                .lineLimit(1)
        }
        .frame(width: width, height: height)
    }
}

import SwiftUI

public struct ManualKeyboardPanel: View {
    @ObservedObject var model: KeyboardStateModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var emoticonTab: Int = 0

    public var body: some View {
        VStack(spacing: 0) {
            // Band 1 (32pt): Pinyin Syllable Preview Bar ABOVE candidates (matches native iOS)
            pinyinPreviewBar
                .frame(height: 32)
                .padding(.horizontal, 10)

            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.22))
                .frame(height: 0.5)

            if model.isEmoticonDrawerOpen {
                emoticonDrawerView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isCandidateDrawerExpanded && !model.pinyinCandidates.isEmpty {
                expandedCandidateDrawer
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Band 2 (43.5pt): Full-width Candidate Words Bar
                candidateOrAccessoryBar
                    .frame(height: 43.5)
                    .padding(.horizontal, 6)

                // Band 3 (7pt top + 205pt keys + 5pt bottom = 217pt -> 293pt total)
                keyGrid
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 3)
                    .padding(.top, 7)
                    .padding(.bottom, 5)
            }
        }
    }

    // MARK: - 0. Native Pinyin Preview Bar (Above Candidates)

    @ViewBuilder
    private var pinyinPreviewBar: some View {
        if model.manualLanguage == .chinesePinyin && model.pinyinLayoutMode == .t9 && model.layoutPage == .letters && !model.t9ComposingDigits.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    let display = model.displayPinyin
                    let firstSyl = model.t9SyllableOptions.first
                    let showSeparateDisplay = !display.isEmpty && (display != firstSyl || model.selectedT9SyllableFilter != nil)

                    if showSeparateDisplay {
                        Button {
                            model.commitComposingAsRawLetters()
                        } label: {
                            Text(display)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(model.selectedT9SyllableFilter != nil ? Color.blue : Color.primary)
                                .lineLimit(1)
                                .frame(height: 32)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(model.t9SyllableOptions.prefix(8), id: \.self) { syll in
                        let isSelected = model.selectedT9SyllableFilter == syll
                            || (!showSeparateDisplay && syll == firstSyl)
                        Button {
                            model.selectT9SyllableFilter(syll)
                        } label: {
                            Text(syll)
                                .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(
                                    model.selectedT9SyllableFilter == syll
                                        ? Color.blue
                                        : (isSelected ? Color.primary : Color.secondary)
                                )
                                .lineLimit(1)
                                .frame(height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if model.selectedT9SyllableFilter != nil {
                        Button {
                            model.selectT9SyllableFilter(nil)
                        } label: {
                            Text("重选")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.blue.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else if model.manualLanguage == .chinesePinyin && !model.composingPinyin.isEmpty {
            HStack(spacing: 10) {
                Button {
                    model.commitComposingAsRawLetters()
                } label: {
                    Text(model.displayPinyin)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)

                if let topDisplay = model.pinyinCandidates.first?.displayPinyin,
                   !topDisplay.isEmpty,
                   topDisplay != model.displayPinyin {
                    Text("自动更正 → \(topDisplay)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                }
                Spacer()
            }
        } else {
            HStack(spacing: 8) {
                if model.canUndoLastAIInsert {
                    Button {
                        model.undoLastAIInsert()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                            Text("撤销语音")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if model.needsInputModeSwitchKey {
                    Button {
                        model.triggerHaptic()
                        model.advanceInputModeHandler?()
                    } label: {
                        Image(systemName: "globe")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 1. Candidate / Suggestion Bar

    @ViewBuilder
    private var candidateOrAccessoryBar: some View {
        if model.manualLanguage == .chinesePinyin && model.pinyinLayoutMode == .t9 && model.layoutPage == .letters {
            if !model.t9ComposingDigits.isEmpty {
                t9CandidateBar
            } else {
                t9IdleCandidateBar
            }
        } else if model.manualLanguage == .chinesePinyin && !model.composingPinyin.isEmpty {
            qwertyCandidateBar
        } else if model.manualLanguage == .english && !model.englishSuggestions.isEmpty {
            englishSuggestionBar
        } else {
            idleAccessoryBar
        }
    }

    private var t9IdleCandidateBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.dynamicIdleCandidates, id: \.self) { word in
                        Button {
                            model.insertStarterCandidate(word)
                        } label: {
                            Text(word)
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 15)
                                .frame(height: 43.5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().frame(height: 22)

            candidateChevronButton(isOpen: model.isEmoticonDrawerOpen) {
                model.toggleEmoticonDrawer()
            }
        }
    }

    private var t9CandidateBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 20) {
                    ForEach(Array(model.pinyinCandidates.prefix(20).enumerated()), id: \.element.id) { idx, cand in
                        Button {
                            model.selectPinyinCandidate(cand)
                        } label: {
                            Text(cand.text)
                                .font(.system(size: 20, weight: idx == 0 ? .medium : .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .frame(height: 43.5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
            }

            Divider().frame(height: 22)

            candidateChevronButton(isOpen: model.isCandidateDrawerExpanded) {
                model.triggerHaptic()
                model.isEmoticonDrawerOpen = false
                model.isCandidateDrawerExpanded.toggle()
            }
        }
    }

    private func candidateChevronButton(isOpen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 43.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var qwertyCandidateBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(Array(model.pinyinCandidates.prefix(18).enumerated()), id: \.element.id) { idx, cand in
                        Button {
                            model.selectPinyinCandidate(cand)
                        } label: {
                            Text(idx == 0 ? "\(cand.text)" : "\(idx + 1).\(cand.text)")
                                .font(.system(size: 18, weight: idx == 0 ? .semibold : .regular))
                                .foregroundStyle(idx == 0 ? Color.blue : Color.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(idx == 0 ? Color.blue.opacity(0.12) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
            }

            Button {
                model.triggerHaptic()
                model.isCandidateDrawerExpanded.toggle()
            } label: {
                Image(systemName: model.isCandidateDrawerExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 43.5)
            }
            .buttonStyle(.plain)
        }
    }

    private var englishSuggestionBar: some View {
        HStack(spacing: 6) {
            ForEach(model.englishSuggestions, id: \.self) { suggestion in
                Button {
                    model.applyEnglishSuggestion(suggestion)
                } label: {
                    Text(suggestion)
                        .font(.system(size: 15))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(keyBackgroundColor.opacity(0.55))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var idleAccessoryBar: some View {
        HStack(spacing: 6) {
            let quickPunct = model.manualLanguage == .chinesePinyin
                ? ["，", "。", "？", "！", "、"]
                : [",", ".", "?", "!", "'"]
            ForEach(quickPunct, id: \.self) { p in
                Button {
                    model.handleKeyTap(p)
                } label: {
                    Text(p)
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(keyBackgroundColor.opacity(0.45))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if model.manualLanguage == .chinesePinyin {
                Button {
                    model.togglePinyinLayoutMode()
                } label: {
                    Text(model.pinyinLayoutMode == .t9 ? "26键" : "九键")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 7)
                        .frame(height: 28)
                        .background(specialKeyBackgroundColor)
                        .foregroundStyle(.primary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Button {
                model.switchToPanel(.voice)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: model.isHostAlive ? "mic.fill" : "mic")
                    Text("语音")
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.blue.opacity(0.15))
                .foregroundStyle(.blue)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 2. Expanded Candidate Grid Drawer

    private var expandedCandidateDrawer: some View {
        VStack(spacing: 6) {
            // Syllable filter bar (aligns with native iOS 9-key keyboard)
            if model.pinyinLayoutMode == .t9 && !model.t9SyllableOptions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            model.selectT9SyllableFilter(nil)
                        } label: {
                            Text("全部")
                                .font(.system(size: 13, weight: model.selectedT9SyllableFilter == nil ? .semibold : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(model.selectedT9SyllableFilter == nil ? Color.blue.opacity(0.18) : specialKeyBackgroundColor)
                                .foregroundStyle(model.selectedT9SyllableFilter == nil ? Color.blue : Color.primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        ForEach(model.t9SyllableOptions, id: \.self) { syll in
                            let isSelected = model.selectedT9SyllableFilter == syll
                            Button {
                                model.selectT9SyllableFilter(syll)
                            } label: {
                                Text(syll)
                                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(isSelected ? Color.blue.opacity(0.18) : specialKeyBackgroundColor)
                                    .foregroundStyle(isSelected ? Color.blue : Color.primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                }
            }

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 8) {
                    ForEach(model.pinyinCandidates) { cand in
                        Button {
                            model.selectPinyinCandidate(cand)
                        } label: {
                            Text(cand.text)
                                .font(.system(size: 16))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(keyBackgroundColor)
                                .foregroundStyle(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }

            HStack(spacing: 8) {
                Button {
                    model.clearComposing()
                } label: {
                    Text("清空拼音")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(specialKeyBackgroundColor)
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    model.handleBackspaceTap()
                } label: {
                    Image(systemName: "delete.left")
                        .frame(width: 64, height: 36)
                        .background(specialKeyBackgroundColor)
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    model.isCandidateDrawerExpanded = false
                } label: {
                    Text("返回键盘")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 88, height: 36)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    // MARK: - 3. Responsive Key Grid

    @ViewBuilder
    private var keyGrid: some View {
        if model.manualLanguage == .chinesePinyin && model.pinyinLayoutMode == .t9 && model.layoutPage == .letters {
            t9KeyGrid
        } else {
            qwertyKeyGrid
        }
    }

    private var t9KeyGrid: some View {
        T9KeyGridView(model: model, state: t9GridState)
            .equatable()
    }

    private var t9GridState: T9GridState {
        let composing = !model.t9ComposingDigits.isEmpty
        return T9GridState(
            isComposing: composing,
            isPickerExpanded: model.isT9PinyinPickerExpanded,
            isEmoticonOpen: model.isEmoticonDrawerOpen,
            selectedFilter: model.selectedT9SyllableFilter,
            syllableOptions: model.isT9PinyinPickerExpanded ? model.t9SyllableOptions : [],
            returnTitle: effectiveReturnTitle,
            returnIsAccent: isComposingChinesePinyin || model.returnKeyLabel != "换行",
            isHostAlive: model.isHostAlive,
            isTranslucent: isCustomOrTranslucentBackdrop
        )
    }

    private var emoticonDrawerView: some View {
        let kaomojiList = [
            "^_^", "(≧▽≦)", "(つ✧ω✧)つ", "(｡•́︿•̀｡)",
            "ヾ(≧▽≦*)o", "(๑•̀ㅂ•́)و✧", "¯\\_(ツ)_/¯", "(╯°□°)╯︵ ┻━┻",
            "(*/ω＼*)", "(´▽｀)", "(ノ_<。)", "ヽ(✿ﾟ▽ﾟ)ノ",
            "(˘･_･˘)", "(・∀・)", "(╥_╥)", "(*^▽^*)"
        ]
        let emojiList = [
            "😂", "❤️", "👍", "🙏", "🎉", "😭", "🔥", "✨",
            "🥰", "🤔", "👏", "😎", "🤣", "😘", "💯", "🥹",
            "🫡", "🫶", "😜", "🤝", "🥳", "😴", "🙄", "👀"
        ]

        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    model.triggerHaptic()
                    emoticonTab = 0
                } label: {
                    Text("颜文字")
                        .font(.system(size: 13, weight: emoticonTab == 0 ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(emoticonTab == 0 ? Color.blue.opacity(0.18) : specialKeyBackgroundColor)
                        .foregroundStyle(emoticonTab == 0 ? Color.blue : Color.primary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    model.triggerHaptic()
                    emoticonTab = 1
                } label: {
                    Text("常用 Emoji")
                        .font(.system(size: 13, weight: emoticonTab == 1 ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(emoticonTab == 1 ? Color.blue.opacity(0.18) : specialKeyBackgroundColor)
                        .foregroundStyle(emoticonTab == 1 ? Color.blue : Color.primary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    model.handleBackspaceTap()
                } label: {
                    Image(systemName: "delete.left")
                        .font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(specialKeyBackgroundColor)
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    model.toggleEmoticonDrawer()
                } label: {
                    Text("返回")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue.opacity(0.16))
                        .foregroundStyle(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            ScrollView {
                let columns = emoticonTab == 0
                    ? Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
                    : Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)
                let items = emoticonTab == 0 ? kaomojiList : emojiList

                LazyVGrid(columns: columns, spacing: 7) {
                    ForEach(items, id: \.self) { item in
                        Button {
                            model.insertEmoticon(item)
                        } label: {
                            Text(item)
                                .font(.system(size: emoticonTab == 0 ? 13 : 22))
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .background(keyBackgroundColor)
                                .foregroundStyle(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
        }
    }

    private var qwertyGridState: QwertyGridState {
        QwertyGridState(
            manualLanguage: model.manualLanguage,
            layoutPage: model.layoutPage,
            pinyinLayoutMode: model.pinyinLayoutMode,
            shiftState: model.shiftState,
            isHostAlive: model.isHostAlive,
            spacebarTitle: spacebarTitle,
            returnTitle: effectiveReturnTitle,
            isReturnAccent: isComposingChinesePinyin || model.returnKeyLabel != "换行",
            isTranslucent: isCustomOrTranslucentBackdrop
        )
    }

    private var qwertyKeyGrid: some View {
        QwertyKeyGridView(model: model, state: qwertyGridState)
            .equatable()
    }

    private var spacebarTitle: String {
        if model.manualLanguage == .chinesePinyin {
            return model.composingPinyin.isEmpty ? "空格 · 拼音" : "选定首词"
        }
        return "space"
    }

    private var isComposingChinesePinyin: Bool {
        model.manualLanguage == .chinesePinyin &&
        (!model.composingPinyin.isEmpty || !model.t9ComposingDigits.isEmpty)
    }

    private var effectiveReturnTitle: String {
        if isComposingChinesePinyin {
            return "确认"
        }
        return model.returnKeyLabel
    }

    private var isCustomOrTranslucentBackdrop: Bool {
        model.config.backgroundStyle != .system || model.config.backgroundOpacity < 0.98
    }

    private var palette: KeyPalette {
        KeyPalette(colorScheme: colorScheme, isTranslucent: isCustomOrTranslucentBackdrop)
    }

    private var keyBackgroundColor: Color { palette.key }

    private var specialKeyBackgroundColor: Color { palette.special }
}

// MARK: - Isolated QWERTY / Numbers / Symbols Grid

private struct QwertyGridState: Equatable {
    var manualLanguage: ManualLanguage
    var layoutPage: ManualLayoutPage
    var pinyinLayoutMode: PinyinLayoutMode
    var shiftState: ShiftState
    var isHostAlive: Bool
    var spacebarTitle: String
    var returnTitle: String
    var isReturnAccent: Bool
    var isTranslucent: Bool
}

private struct QwertyKeyGridView: View, Equatable {
    let model: KeyboardStateModel
    let state: QwertyGridState
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: QwertyKeyGridView, rhs: QwertyKeyGridView) -> Bool {
        lhs.model === rhs.model && lhs.state == rhs.state
    }

    private var palette: KeyPalette {
        KeyPalette(colorScheme: colorScheme, isTranslucent: state.isTranslucent)
    }

    var body: some View {
        GeometryReader { geo in
            let rowSpacing: CGFloat = 8
            let colSpacing: CGFloat = 5
            let rowHeight = max(36, (geo.size.height - rowSpacing * 3) / 4)
            let standardKeyWidth = (geo.size.width - colSpacing * 9) / 10

            VStack(spacing: rowSpacing) {
                // Row 1 (10 keys)
                HStack(spacing: colSpacing) {
                    ForEach(row1Keys, id: \.self) { label in
                        CharacterKeyButton(
                            label: displayLabel(label),
                            width: standardKeyWidth,
                            height: rowHeight,
                            keyColor: palette.key
                        ) {
                            model.handleKeyTap(label)
                        }
                    }
                }

                // Row 2 (9 keys in letters, 10 keys in numbers/symbols)
                HStack(spacing: colSpacing) {
                    if state.layoutPage == .letters {
                        Spacer(minLength: 0)
                    }
                    ForEach(row2Keys, id: \.self) { label in
                        let w = state.layoutPage == .letters
                            ? standardKeyWidth
                            : (geo.size.width - colSpacing * 9) / 10
                        CharacterKeyButton(
                            label: displayLabel(label),
                            width: w,
                            height: rowHeight,
                            keyColor: palette.key
                        ) {
                            model.handleKeyTap(label)
                        }
                    }
                    if state.layoutPage == .letters {
                        Spacer(minLength: 0)
                    }
                }

                // Row 3 (Modifier + 7/5 keys + Backspace)
                HStack(spacing: colSpacing) {
                    row3LeftModifier(width: standardKeyWidth * 1.38, height: rowHeight)

                    let centerKeys = row3Keys
                    let centerAvail = geo.size.width - (standardKeyWidth * 1.38) * 2 - colSpacing * CGFloat(centerKeys.count + 1)
                    let centerKeyW = centerAvail / CGFloat(centerKeys.count)

                    ForEach(centerKeys, id: \.self) { label in
                        CharacterKeyButton(
                            label: displayLabel(label),
                            width: centerKeyW,
                            height: rowHeight,
                            keyColor: palette.key
                        ) {
                            model.handleKeyTap(label)
                        }
                    }

                    HoldRepeatKey(
                        fill: palette.special,
                        pressedFill: palette.specialPressed,
                        edge: palette.edge,
                        onTap: { model.handleBackspaceTap() },
                        onHoldStart: { model.startContinuousBackspace() },
                        onHoldEnd: { model.stopContinuousBackspace() }
                    ) {
                        Image(systemName: "delete.left")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .frame(width: standardKeyWidth * 1.38, height: rowHeight)
                }

                // Row 4 (123/ABC/九键 + Voice/九键 + 中/EN + Spacebar Trackpad + Return)
                HStack(spacing: colSpacing) {
                    Button {
                        let targetPage: ManualLayoutPage = (state.layoutPage == .letters) ? .numbers : .letters
                        model.switchLayoutPage(targetPage)
                    } label: {
                        let pageBackTitle = (state.manualLanguage == .chinesePinyin && state.pinyinLayoutMode == .t9) ? "九键" : "ABC"
                        Text(state.layoutPage == .letters ? "123" : pageBackTitle)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: standardKeyWidth * 1.30, height: rowHeight)
                            .background(palette.special)
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.switchToPanel(.voice)
                    } label: {
                        Image(systemName: state.isHostAlive ? "mic.fill" : "mic")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: standardKeyWidth * 1.15, height: rowHeight)
                            .background(palette.special)
                            .foregroundStyle(state.isHostAlive ? .blue : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.toggleManualLanguage()
                    } label: {
                        let langSwitchTitle = (state.manualLanguage == .chinesePinyin)
                            ? "EN"
                            : (state.pinyinLayoutMode == .t9 ? "九键" : "拼")
                        Text(langSwitchTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: standardKeyWidth * 1.25, height: rowHeight)
                            .background(palette.special)
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    SpacebarTrackpadKey(
                        title: state.spacebarTitle,
                        height: rowHeight,
                        keyColor: palette.key,
                        pressedColor: palette.keyPressed,
                        edgeColor: palette.edge,
                        onTap: { model.handleSpaceTap() },
                        onTrackpadDrag: { dx in model.handleSpaceTrackpadDrag(deltaX: dx) },
                        onTrackpadEnd: { model.resetSpaceTrackpad() }
                    )

                    Button {
                        model.handleReturnTap()
                    } label: {
                        Text(state.returnTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: standardKeyWidth * 1.85, height: rowHeight)
                            .background(state.isReturnAccent ? Color.blue : palette.special)
                            .foregroundStyle(state.isReturnAccent ? Color.white : Color.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var row1Keys: [String] {
        switch state.layoutPage {
        case .letters: return ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
        case .numbers: return ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
        case .symbols: return ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
        }
    }

    private var row2Keys: [String] {
        switch state.layoutPage {
        case .letters:
            return ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
        case .numbers:
            return state.manualLanguage == .chinesePinyin
                ? ["-", "/", "：", "；", "（", "）", "¥", "&", "@", "”"]
                : ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]
        case .symbols:
            return state.manualLanguage == .chinesePinyin
                ? ["_", "\\", "|", "~", "《", "》", "€", "£", "、", "·"]
                : ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
        }
    }

    private var row3Keys: [String] {
        switch state.layoutPage {
        case .letters:
            return ["z", "x", "c", "v", "b", "n", "m"]
        case .numbers, .symbols:
            return state.manualLanguage == .chinesePinyin
                ? ["。", "，", "？", "！", "’"]
                : [".", ",", "?", "!", "'"]
        }
    }

    private func displayLabel(_ key: String) -> String {
        guard state.layoutPage == .letters else { return key }
        return state.shiftState == .off ? key.lowercased() : key.uppercased()
    }

    private var shiftIconName: String {
        switch state.shiftState {
        case .off: return "shift"
        case .shifted: return "shift.fill"
        case .capsLock: return "capslock.fill"
        }
    }

    @ViewBuilder
    private func row3LeftModifier(width: CGFloat, height: CGFloat) -> some View {
        switch state.layoutPage {
        case .letters:
            Button {
                model.handleShiftTap()
            } label: {
                Image(systemName: shiftIconName)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: width, height: height)
                    .background(state.shiftState == .off ? palette.special : palette.key)
                    .foregroundStyle(state.shiftState == .capsLock ? .blue : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

        case .numbers:
            Button {
                model.triggerHaptic()
                model.layoutPage = .symbols
            } label: {
                Text("#+=")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: width, height: height)
                    .background(palette.special)
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

        case .symbols:
            Button {
                model.triggerHaptic()
                model.layoutPage = .numbers
            } label: {
                Text("123")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: width, height: height)
                    .background(palette.special)
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Character Key Button with Zero-Delay Touch + Keycap Popover

private struct CharacterKeyButton: View {
    let label: String
    let width: CGFloat
    let height: CGFloat
    let keyColor: Color
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        ZStack {
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.black.opacity(0.22))
                    .frame(height: 1.5)
                    .padding(.horizontal, 3)
                    .offset(y: 1)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(keyColor)
            }

            Text(label)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary)
        }
        .frame(width: width, height: height)
        .overlay(alignment: .top) {
            if isPressed {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(keyColor)
                        .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
                    Text(label)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .frame(width: max(width + 10, 42), height: height + 10)
                .offset(y: -(height + 6))
                .allowsHitTesting(false)
            }
        }
        .zIndex(isPressed ? 100 : 0)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        isPressed = true
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    action()
                }
        )
    }
}

// MARK: - Spacebar with Tap + Long-Press Cursor Trackpad

struct SpacebarTrackpadKey: View {
    let title: String
    var fixedWidth: CGFloat? = nil
    let height: CGFloat
    let keyColor: Color
    var pressedColor: Color? = nil
    var edgeColor: Color? = nil
    var titleFontSize: CGFloat = 13
    var titleColor: Color = .secondary
    let onTap: () -> Void
    let onTrackpadDrag: (CGFloat) -> Void
    let onTrackpadEnd: () -> Void

    @State private var isTrackpadActive = false
    @State private var isPressed = false
    @State private var lastDragX: CGFloat?

    private var currentFill: Color {
        if isTrackpadActive { return Color.blue.opacity(0.22) }
        if isPressed, let pressedColor { return pressedColor }
        return keyColor
    }

    var body: some View {
        ZStack {
            if let edgeColor {
                Capsule()
                    .fill(edgeColor)
                    .frame(height: 1.5)
                    .padding(.horizontal, 3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .offset(y: 1)
            }
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(currentFill)

            Text(isTrackpadActive ? "◀ 滑动移动光标 ▶" : title)
                .font(.system(size: isTrackpadActive ? 13 : titleFontSize, weight: .regular))
                .foregroundStyle(isTrackpadActive ? Color.blue : titleColor)
        }
        .frame(maxWidth: fixedWidth == nil ? .infinity : fixedWidth)
        .frame(width: fixedWidth, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isPressed { isPressed = true }
                    if isTrackpadActive {
                        if let prevX = lastDragX {
                            onTrackpadDrag(value.location.x - prevX)
                        }
                        lastDragX = value.location.x
                    }
                }
                .onEnded { value in
                    isPressed = false
                    if isTrackpadActive {
                        isTrackpadActive = false
                        lastDragX = nil
                        onTrackpadEnd()
                    } else if abs(value.translation.width) < 44 && abs(value.translation.height) < 44 {
                        onTap()
                    }
                }
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.32)
                .onEnded { _ in
                    if !isTrackpadActive {
                        isTrackpadActive = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                }
        )
    }
}

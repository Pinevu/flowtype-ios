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
            } else {
                // Band 2 (43.5pt): Anchored Candidate Bar (or Expanded Header with same top-right chevron)
                Group {
                    if model.isCandidateDrawerExpanded && !model.pinyinCandidates.isEmpty {
                        expandedCandidateHeaderBar
                    } else {
                        candidateOrAccessoryBar
                    }
                }
                .frame(height: 43.5)
                .padding(.horizontal, 6)

                if model.isCandidateDrawerExpanded && !model.pinyinCandidates.isEmpty {
                    // Downward Candidate Expansion (replaces Band 3 below Band 2 seamlessly)
                    expandedCandidateDrawer
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Band 3 (7pt top + 205pt keys + 5pt bottom = 217pt -> 293pt total)
                    keyGrid
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 3)
                        .padding(.top, 7)
                        .padding(.bottom, 5)
                }
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
                HStack(spacing: 20) {
                    ForEach(Array(model.pinyinCandidates.prefix(24).enumerated()), id: \.element.id) { idx, cand in
                        Text(cand.text)
                            .font(.system(size: 20, weight: idx == 0 ? .medium : .regular))
                            .foregroundStyle(idx == 0 ? Color.blue : Color.primary)
                            .lineLimit(1)
                            .frame(height: 43.5)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectPinyinCandidate(cand)
                            }
                    }
                }
                .padding(.horizontal, 10)
            }

            Divider().frame(height: 22)

            candidateChevronButton(isOpen: model.isCandidateDrawerExpanded) {
                model.toggleCandidateDrawer()
            }
        }
    }

    private func candidateChevronButton(isOpen: Bool, action: @escaping () -> Void) -> some View {
        InstantChevronToggle(isOpen: isOpen, action: action)
    }

    private var qwertyCandidateBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(model.pinyinCandidates.prefix(22).enumerated()), id: \.element.id) { idx, cand in
                        Text(idx == 0 ? "\(cand.text)" : "\(idx + 1).\(cand.text)")
                            .font(.system(size: 18, weight: idx == 0 ? .semibold : .regular))
                            .foregroundStyle(idx == 0 ? Color.blue : Color.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(idx == 0 ? Color.blue.opacity(0.12) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectPinyinCandidate(cand)
                            }
                    }
                }
                .padding(.horizontal, 6)
            }

            Divider().frame(height: 22)

            candidateChevronButton(isOpen: model.isCandidateDrawerExpanded) {
                model.toggleCandidateDrawer()
            }
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

    // MARK: - 2. Downward Expanded Candidate Grid Drawer

    private var expandedCandidateHeaderBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text("向下展开候选（\(model.pinyinCandidates.count)）")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    if model.pinyinLayoutMode == .t9 && model.selectedT9SyllableFilter != nil {
                        Text("全部音节")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.14))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                            .onTapGesture {
                                model.selectT9SyllableFilter(nil)
                            }
                    }

                    if model.pinyinLayoutMode == .t9 {
                        Text("分词 '")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(specialKeyBackgroundColor)
                            .foregroundStyle(.primary)
                            .clipShape(Capsule())
                            .onTapGesture {
                                model.insertT9SyllableSeparator()
                            }
                    }
                }
                .padding(.horizontal, 10)
            }

            Divider().frame(height: 22)

            candidateChevronButton(isOpen: true) {
                model.toggleCandidateDrawer()
            }
        }
    }

    private var expandedCandidateDrawer: some View {
        let candidates = model.pinyinCandidates
        let hasLongPhrase = candidates.prefix(12).contains { $0.text.count >= 4 }
        let cols = hasLongPhrase ? 4 : 5
        let rows: [[(offset: Int, element: PinyinCandidate)]] = stride(from: 0, to: candidates.count, by: cols).map { start in
            let end = min(start + cols, candidates.count)
            return (start..<end).map { ($0, candidates[$0]) }
        }
        let hairline = colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)

        return VStack(spacing: 0) {
            Rectangle()
                .fill(hairline)
                .frame(height: 0.5)

            ScrollView(showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, rowItems in
                        HStack(spacing: 0) {
                            ForEach(rowItems, id: \.element.id) { item in
                                Text(item.element.text)
                                    .font(.system(size: 18, weight: item.offset == 0 ? .semibold : .regular))
                                    .foregroundStyle(item.offset == 0 ? Color.blue : Color.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.62)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 43)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        model.selectPinyinCandidate(item.element)
                                    }
                                    .overlay(alignment: .trailing) {
                                        Rectangle()
                                            .fill(hairline)
                                            .frame(width: 0.5)
                                    }
                            }
                            if rowItems.count < cols {
                                ForEach(0..<(cols - rowItems.count), id: \.self) { _ in
                                    Color.clear
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 43)
                                }
                            }
                        }
                        Rectangle()
                            .fill(hairline)
                            .frame(height: 0.5)
                    }
                }
            }

            Rectangle()
                .fill(hairline)
                .frame(height: 0.5)

            HStack(spacing: 8) {
                Text("清空拼音")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(specialKeyBackgroundColor)
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.clearComposing()
                    }

                Image(systemName: "delete.left")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 68, height: 32)
                    .background(specialKeyBackgroundColor)
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.handleBackspaceTap()
                    }

                Text("收起")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 78, height: 32)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.isCandidateDrawerExpanded = false
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
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

/// Zero-delay touch-responsive chevron toggle placed next to scrollable candidate strips.
private struct InstantChevronToggle: View {
    let isOpen: Bool
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isPressed ? Color.blue : Color.secondary)
            .frame(width: 38, height: 43.5)
            .background(isPressed ? Color.blue.opacity(0.10) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

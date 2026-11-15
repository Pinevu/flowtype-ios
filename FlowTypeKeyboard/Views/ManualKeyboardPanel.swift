import SwiftUI

public struct ManualKeyboardPanel: View {
    @ObservedObject var model: KeyboardStateModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var emoticonTab: Int = 0

    public var body: some View {
        VStack(spacing: 0) {
            candidateOrAccessoryBar
                .frame(height: 36)
                .padding(.horizontal, 6)

            Divider().opacity(0.25)

            if model.isEmoticonDrawerOpen {
                emoticonDrawerView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isCandidateDrawerExpanded && !model.pinyinCandidates.isEmpty {
                expandedCandidateDrawer
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                keyGrid
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
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
                                .frame(height: 40)
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
            // iOS Native Pinyin chip preview at left
            if !model.displayPinyin.isEmpty {
                Button {
                    model.commitComposingAsRawLetters()
                } label: {
                    Text(model.displayPinyin)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.blue.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)

                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 4)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(Array(model.pinyinCandidates.prefix(24).enumerated()), id: \.element.id) { idx, cand in
                        Button {
                            model.selectPinyinCandidate(cand)
                        } label: {
                            Text(cand.text)
                                .font(.system(size: 20, weight: idx == 0 ? .medium : .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .frame(height: 40)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
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
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var qwertyCandidateBar: some View {
        HStack(spacing: 6) {
            // Tap composing pinyin preview to insert raw ASCII letters
            Button {
                model.commitComposingAsRawLetters()
            } label: {
                Text(model.displayPinyin)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.pinyinCandidates.prefix(18).enumerated()), id: \.element.id) { idx, cand in
                        Button {
                            model.selectPinyinCandidate(cand)
                        } label: {
                            Text(idx == 0 ? "\(cand.text)" : "\(idx + 1).\(cand.text)")
                                .font(.system(size: 16, weight: idx == 0 ? .semibold : .regular))
                                .foregroundStyle(idx == 0 ? Color.blue : Color.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(idx == 0 ? Color.blue.opacity(0.12) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                model.triggerHaptic()
                model.isCandidateDrawerExpanded.toggle()
            } label: {
                Image(systemName: model.isCandidateDrawerExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
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

    private var qwertyKeyGrid: some View {
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
                            keyColor: keyBackgroundColor
                        ) {
                            model.handleKeyTap(label)
                        }
                    }
                }

                // Row 2 (9 keys in letters, 10 keys in numbers/symbols)
                HStack(spacing: colSpacing) {
                    if model.layoutPage == .letters {
                        Spacer(minLength: 0)
                    }
                    ForEach(row2Keys, id: \.self) { label in
                        let w = model.layoutPage == .letters
                            ? standardKeyWidth
                            : (geo.size.width - colSpacing * 9) / 10
                        CharacterKeyButton(
                            label: displayLabel(label),
                            width: w,
                            height: rowHeight,
                            keyColor: keyBackgroundColor
                        ) {
                            model.handleKeyTap(label)
                        }
                    }
                    if model.layoutPage == .letters {
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
                            keyColor: keyBackgroundColor
                        ) {
                            model.handleKeyTap(label)
                        }
                    }

                    backspaceKey(width: standardKeyWidth * 1.38, height: rowHeight)
                }

                // Row 4 (123/ABC/九键 + Voice/九键 + 中/EN + Spacebar Trackpad + Return)
                HStack(spacing: colSpacing) {
                    // 123 / ABC / 九键 toggle
                    Button {
                        let targetPage: ManualLayoutPage = (model.layoutPage == .letters) ? .numbers : .letters
                        model.switchLayoutPage(targetPage)
                    } label: {
                        let pageBackTitle = (model.manualLanguage == .chinesePinyin && model.pinyinLayoutMode == .t9) ? "九键" : "ABC"
                        Text(model.layoutPage == .letters ? "123" : pageBackTitle)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: standardKeyWidth * 1.45, height: rowHeight)
                            .background(specialKeyBackgroundColor)
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    // Quick Nine-Key / Voice toggle
                    if model.manualLanguage == .chinesePinyin && model.layoutPage == .letters {
                        Button {
                            model.togglePinyinLayoutMode()
                        } label: {
                            Text("九键")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: standardKeyWidth * 1.15, height: rowHeight)
                                .background(specialKeyBackgroundColor)
                                .foregroundStyle(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            model.switchToPanel(.voice)
                        } label: {
                            Image(systemName: model.isHostAlive ? "mic.fill" : "mic")
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: standardKeyWidth * 1.15, height: rowHeight)
                                .background(specialKeyBackgroundColor)
                                .foregroundStyle(.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    // Chinese / English toggle
                    Button {
                        model.toggleManualLanguage()
                    } label: {
                        let langSwitchTitle = (model.manualLanguage == .chinesePinyin)
                            ? "EN"
                            : (model.pinyinLayoutMode == .t9 ? "九键" : "拼")
                        Text(langSwitchTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: standardKeyWidth * 1.25, height: rowHeight)
                            .background(specialKeyBackgroundColor)
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    // Spacebar with Cursor Trackpad
                    SpacebarTrackpadKey(
                        title: spacebarTitle,
                        height: rowHeight,
                        keyColor: keyBackgroundColor,
                        onTap: { model.handleSpaceTap() },
                        onTrackpadDrag: { dx in model.handleSpaceTrackpadDrag(deltaX: dx) },
                        onTrackpadEnd: { model.resetSpaceTrackpad() }
                    )

                    // Return / Confirm Key
                    Button {
                        model.handleReturnTap()
                    } label: {
                        Text(effectiveReturnTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: standardKeyWidth * 1.85, height: rowHeight)
                            .background(effectiveReturnColor)
                            .foregroundStyle(effectiveReturnForeground)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Key Definitions

    private var row1Keys: [String] {
        switch model.layoutPage {
        case .letters: return ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
        case .numbers: return ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
        case .symbols: return ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
        }
    }

    private var row2Keys: [String] {
        switch model.layoutPage {
        case .letters:
            return ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
        case .numbers:
            return model.manualLanguage == .chinesePinyin
                ? ["-", "/", "：", "；", "（", "）", "¥", "&", "@", "”"]
                : ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]
        case .symbols:
            return model.manualLanguage == .chinesePinyin
                ? ["_", "\\", "|", "~", "《", "》", "€", "£", "、", "·"]
                : ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
        }
    }

    private var row3Keys: [String] {
        switch model.layoutPage {
        case .letters:
            return ["z", "x", "c", "v", "b", "n", "m"]
        case .numbers, .symbols:
            return model.manualLanguage == .chinesePinyin
                ? ["。", "，", "？", "！", "’"]
                : [".", ",", "?", "!", "'"]
        }
    }

    private func displayLabel(_ key: String) -> String {
        guard model.layoutPage == .letters else { return key }
        if model.manualLanguage == .chinesePinyin {
            return model.shiftState == .off ? key.lowercased() : key.uppercased()
        }
        return model.shiftState == .off ? key.lowercased() : key.uppercased()
    }

    @ViewBuilder
    private func row3LeftModifier(width: CGFloat, height: CGFloat) -> some View {
        switch model.layoutPage {
        case .letters:
            Button {
                model.handleShiftTap()
            } label: {
                Image(systemName: shiftIconName)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: width, height: height)
                    .background(model.shiftState == .off ? specialKeyBackgroundColor : keyBackgroundColor)
                    .foregroundStyle(model.shiftState == .capsLock ? .blue : .primary)
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
                    .background(specialKeyBackgroundColor)
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
                    .background(specialKeyBackgroundColor)
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func backspaceKey(width: CGFloat, height: CGFloat) -> some View {
        Image(systemName: "delete.left")
            .font(.system(size: 17, weight: .medium))
            .frame(width: width, height: height)
            .background(specialKeyBackgroundColor)
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onTapGesture {
                model.handleBackspaceTap()
            }
            .onLongPressGesture(minimumDuration: 0.35, perform: {}, onPressingChanged: { pressing in
                if pressing {
                    model.startContinuousBackspace()
                } else {
                    model.stopContinuousBackspace()
                }
            })
    }

    private var shiftIconName: String {
        switch model.shiftState {
        case .off: return "shift"
        case .shifted: return "shift.fill"
        case .capsLock: return "capslock.fill"
        }
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

    private var effectiveReturnColor: Color {
        if isComposingChinesePinyin || model.returnKeyLabel != "换行" {
            return .blue
        }
        return specialKeyBackgroundColor
    }

    private var effectiveReturnForeground: Color {
        if isComposingChinesePinyin || model.returnKeyLabel != "换行" {
            return .white
        }
        return .primary
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
            RoundedRectangle(cornerRadius: edgeColor == nil ? 6 : 7, style: .continuous)
                .fill(currentFill)

            Text(isTrackpadActive ? "◀ 滑动移动光标 ▶" : title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isTrackpadActive ? .blue : .secondary)
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
